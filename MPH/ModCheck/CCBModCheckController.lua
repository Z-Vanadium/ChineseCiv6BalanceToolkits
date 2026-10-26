--[[=========================================================================
CCBModCheckController.lua

CCB MOD Check 业务控制器（纯 Lua，Lua 5.1 兼容）。
不引用 Controls、UI、引擎 API，只通过 adapter 访问环境，便于真实多节点离线模型。

adapter 契约（严格按 PVPCore docs/CCB-ModCheck-implementation-2026-10-26.md）：
  now()                          -> number 秒
  localId()                      -> playerID
  hostId()                       -> playerID
  sessionId()                    -> string
  participants()                 -> { {id=,name=,identity=,observer=} } 仅在线真人
  manifest()                     -> { {id=GUID,version=string|number,name=可选} }
  getCore()                      -> nil | GetInfo 表 + BeginScan/PollScan/CancelScan
  getPlayerValue(pid,key)        -> string|nil
  setPlayerValue(key,value)      -> ok,err?
  getRoomValue(key)              -> string|nil
  setRoomValue(key,value)        -> ok,err?
  sendWhisper(pid,text)          -> ok,err?    仅发给指定玩家
  sendReminder(pid,text)         -> ok,err?    可读普通聊天提醒（非协议）
  render(snapshot)               -> void
  log(text)                      -> void

对象接口：New(adapter), Enter/Leave/Tick/Check/OnRosterChanged/
OnManifestChanged/OnHostChanged/OnChat/GetSnapshot。

关键语义：
  * 进房不扫描、不自动建轮次；只有房主 Check 建立 round 并 fresh 扫描，
    客机收到有效 round 后自动扫描。已有有效基准时补人只扫新人。
  * 绿灯只看原生 PollScan.done.total（64 hex SHA256）；HashString 只用于
    连接 token / request / 清单传输校验，绝不当一致性判据。
  * 相同 total 不交换逐 Mod 清单；不同才向已声明兼容能力者定向请求。
  * 能力/轮次/摘要走 PlayerConfig/GameConfig 键；只有已声明兼容的成员
    才会收到探针/清单协议包；未装工具箱者只收可读聊天提醒。
  * 所有包绑定真实 from/to/host/session/round/token/request；旧轮次、
    旧连接、槽位复用包一律拒绝。
=========================================================================]]

local P = CCBModCheckProtocol
assert(type(P) == "table", "CCBModCheckProtocol must load first")

local C = {}
C.__index = C

local PROBE_INTERVAL = 10       -- 首次探针 / HELLO 重试间隔
local NO_RESPONSE_WAIT = 20     -- 10s 探针 + 20s 重试后仍无能力声明才提醒
local SCAN_TIMEOUT = 120        -- 单成员从自己开始扫描起算
local REMINDER_COOLDOWN = 60    -- 同身份重进冷却（跨 controller 实例）
local REMINDER_SPACING = 2      -- 全局提醒最小间隔
local RES_PUBLISH_INTERVAL = 2
local MAX_ASSEMBLERS = 16
local MAX_ERRORS = 8
local SEND_PER_TICK = 8       -- 每 Tick 最多发出的协议包数（防同帧包风暴）
local SEND_TTL = 120          -- 待发队列过期时间（秒）
local SEND_BYTES_PER_PEER = 262144 -- 单成员待发明细上限（256 KiB 数据 + 分片头）

local R = {
    OK = "ok",
    DIFF = "diff",
    DIGEST = "digest-mismatch",
    CHECKING = "checking",
    WAITING = "waiting",
    NO_CORE = "no-core",
    NO_RESPONSE = "no-response",
    SCAN_ERROR = "scan-error",
    SCAN_TIMEOUT = "scan-timeout",
    CORE_UNAVAILABLE = "core-unavailable",
    STALE = "stale-round",
    WAITING_ROUND = "waiting-round",
    HOST_NO_CORE = "host-no-core",
    HOST_NO_RESPONSE = "host-no-response",
    PROTOCOL_ERROR = "protocol-error",
    NO_MANIFEST = "no-manifest",
    INCOMPATIBLE = "incompatible",
}

-- 同房间同成员只自动提醒一次；重进 60s 冷却。key = sid|identity。
local reminderLedger = {}

local function tostr(v)
    if v == nil then
        return ""
    end
    return tostring(v)
end

local function sameId(a, b)
    return tostr(a) == tostr(b) and tostr(a) ~= ""
end

local function sortedKeys(map)
    local keys = {}
    for k in pairs(map) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostr(a) < tostr(b)
    end)
    return keys
end

local function copyDiffs(cmp, limit)
    local out = {}
    if type(cmp) ~= "table" or type(cmp.diffs) ~= "table" then
        return out
    end
    local max = limit or 20
    for i = 1, math.min(#cmp.diffs, max) do
        local d = cmp.diffs[i]
        out[#out + 1] = {
            kind = d.kind,
            id = d.id,
            name = d.name,
            localVersion = d.localVersion,
            remoteVersion = d.remoteVersion,
        }
    end
    return out
end

local function call(self, name, ...)
    local fn = self.adapter and self.adapter[name]
    if type(fn) ~= "function" then
        return nil, "NO_ADAPTER_" .. tostr(name)
    end
    return fn(...)
end

local function coreCall(self, name, ...)
    local core = self.core
    local fn = core and core[name]
    if type(fn) ~= "function" then
        return nil, "CORE_NO_" .. tostr(name)
    end
    -- 原生四接口是 dot 调用（GetInfo()/BeginScan(manifest)/PollScan(jobId)/
    -- CancelScan(jobId)），不能把 core 当 self 传进去。
    local ok, a, b = pcall(fn, ...)
    if not ok then
        return nil, tostr(a)
    end
    return a, b
end

local function emptyScan()
    return {
        status = "none", -- none|queued|checking|done|error
        job = nil,
        startedAt = 0,
        total = nil,
        mods = nil,
        count = 0,
        coverage = "",
        provider = "",
        fingerprint = nil,
        errorCode = nil,
        time = 0,
        rid = nil,
        pending = false,
        busyUntil = 0,
        attempts = 0,
    }
end

--=========================================================================
-- 构造
--=========================================================================

function C.New(adapter)
    assert(type(adapter) == "table", "adapter table required")
    local self = setmetatable({}, C)
    self.adapter = adapter
    self.inRoom = false
    self.enteredAt = 0
    self.pid = nil
    self.hostId = nil
    self.sid = ""
    self.token = nil
    self.epoch = 0
    self.rid = nil
    self.roundStart = 0
    self.roundPhase = "none"

    self.participants = {}
    self.participantMap = {}

    self.manifest = {}
    self.manifestFingerprint = ""

    self.core = nil
    self.coreAvailable = false
    self.coreError = nil
    self.coreProvider = ""
    self.coreBuildId = ""
    self.coreCoverage = ""

    self.scan = emptyScan()
    self.canCheck = false

    self.cap = nil
    self.hostCap = nil
    self.hostSum = nil
    self.hostAcked = false
    self.hostSeen = 0
    self.lastHello = 0
    self.lastSummaryKey = nil

    self.peerStates = {}
    self.compare = {}
    self.assemblers = {}
    self.results = {}

    -- 有界发送队列：详单分片不能在同一帧全部发出。
    self.sendQueue = {}
    self.sendQueueBytes = {}
    self.sendDropped = 0

    self.reminded = {}
    self.lastReminderAt = -999
    self.lastResPublish = -999
    self.lastResSignature = ""

    self.errors = {}
    self.lastProtocolError = nil
    self.dirty = true
    self.lastRenderSignature = ""

    return self
end

--=========================================================================
-- 基础
--=========================================================================

function C:Now()
    return tonumber(call(self, "now")) or 0
end

function C:Log(text)
    call(self, "log", "[CCBModCheck] " .. tostr(text))
end

function C:Error(code)
    self.lastProtocolError = tostr(code)
    self.errors[#self.errors + 1] = tostr(code)
    while #self.errors > MAX_ERRORS do
        table.remove(self.errors, 1)
    end
    self.dirty = true
end

function C:IsHost()
    return sameId(self.pid, self.hostId)
end

function C:RefreshParticipants()
    local list = call(self, "participants")
    local map = {}
    local arr = {}
    if type(list) == "table" then
        for i = 1, #list do
            local p = list[i]
            if type(p) == "table" and p.id ~= nil then
                local id = tonumber(p.id) or p.id
                map[tostr(id)] = {
                    id = id,
                    name = tostr(p.name),
                    identity = tostr(p.identity),
                    observer = p.observer == true,
                }
                arr[#arr + 1] = map[tostr(id)]
            end
        end
    end
    self.participants = arr
    self.participantMap = map
end

function C:ValidPeer(pid)
    return self.participantMap[tostr(pid)] ~= nil
end

function C:IdentityOf(pid)
    local p = self.participantMap[tostr(pid)]
    if p and p.identity ~= "" then
        return p.identity
    end
    return tostr(pid)
end

function C:NameOf(pid)
    local p = self.participantMap[tostr(pid)]
    if p and p.name ~= "" then
        return P.SanitizeName(p.name, 24)
    end
    return tostr(pid)
end

--=========================================================================
-- 原生核心 / 清单
--=========================================================================

-- getCore() 返回原生 CCBModCheck 原始表；元数据每次经 GetInfo() 获取。
-- 不能期待 core.apiVersion / core.available 等字段直接存在。
function C:RefreshCore()
    local core, err = call(self, "getCore")
    if type(core) ~= "table" then
        self.core = nil
        self.coreAvailable = false
        self.coreError = tostr(err or "CORE_UNAVAILABLE")
        return false
    end
    self.core = core
    local info, infoErr = coreCall(self, "GetInfo")
    if type(info) ~= "table" then
        self.coreAvailable = false
        self.coreError = tostr(infoErr or "CORE_UNAVAILABLE")
        self.coreProvider = ""
        self.coreBuildId = ""
        self.coreCoverage = ""
        return false
    end
    self.coreProvider = tostr(info.provider)
    self.coreBuildId = tostr(info.buildId)
    self.coreCoverage = tostr(info.coverage)
    if info.available == false then
        self.coreAvailable = false
        self.coreError = tostr(info.errorCode or "CORE_UNAVAILABLE")
        return false
    end
    local apiOk = tonumber(info.apiVersion) == P.API_VERSION
    local providerOk = info.provider == "Civ6DllLoader"
    local buildOk = type(info.buildId) == "string" and info.buildId ~= ""
    local coverageOk = info.coverage == P.COVERAGE
    local methodsOk = type(core.GetInfo) == "function"
        and type(core.BeginScan) == "function"
        and type(core.PollScan) == "function"
        and type(core.CancelScan) == "function"
    if not (apiOk and providerOk and buildOk and coverageOk and methodsOk) then
        self.coreAvailable = false
        self.coreError = "API_INCOMPATIBLE"
        return false
    end
    self.corePluginVersion = tostr(info.pluginVersion)
    self.coreAvailable = true
    self.coreError = nil
    return true
end

function C:BuildManifest()
    local raw = call(self, "manifest")
    local out = {}
    if type(raw) ~= "table" then
        return out
    end
    for i = 1, #raw do
        local it = raw[i]
        if type(it) == "table" and it.id ~= nil then
            out[#out + 1] = {
                id = tostr(it.id),
                version = it.version,
                name = it.name,
            }
        end
    end
    return out
end

function C:LoadManifest()
    self.manifest = self:BuildManifest()
    self.manifestFingerprint = C.FingerprintManifest(self.manifest)
    return self.manifest
end

function C.FingerprintManifest(manifest)
    local rows = {}
    for i = 1, #manifest do
        local m = manifest[i]
        rows[#rows + 1] = tostr(m.id) .. "=" .. tostr(m.version) .. "=" .. tostr(m.name)
    end
    table.sort(rows)
    return P.HashString(table.concat(rows, "\n"))
end

function C:CheckManifestChanged()
    local out = self:BuildManifest()
    local fp = C.FingerprintManifest(out)
    if fp ~= self.manifestFingerprint then
        self:OnManifestChanged()
    end
end

--=========================================================================
-- 能力 / 摘要配置键
--=========================================================================

function C.ScanStatusForCap(scan)
    if scan.status == "done" then
        return "done"
    elseif scan.status == "checking" or scan.status == "queued" then
        return "checking"
    elseif scan.status == "error" then
        return "error"
    end
    return "idle"
end

function C:WriteCapability()
    local scan = self.scan
    local done = (scan.status == "done" and P.ValidTotal(scan.total))
    local cap = {
        rid = self.rid or "",
        apiVersion = P.API_VERSION,
        pluginVersion = self.corePluginVersion or "",
        buildId = self.coreBuildId or "",
        coverage = self.coreCoverage or "",
        provider = self.coreProvider or "",
        available = self.coreAvailable,
        errorCode = self.coreError or scan.errorCode or "",
        token = self.token or "",
        status = C.ScanStatusForCap(scan),
        startedAt = scan.startedAt or 0,
        count = done and scan.count or 0,
        total = done and scan.total or "",
    }
    self.cap = cap
    local ok, err = call(self, "setPlayerValue", P.KEYS.CAP, P.EncodeCapability(cap))
    if not ok then
        self:Log("setPlayerValue(CAP) failed: " .. tostr(err))
    end
end

function C:WriteSummary()
    local scan = self.scan
    local done = (scan.status == "done" and P.ValidTotal(scan.total))
    local sum = {
        rid = self.rid or "",
        token = self.token or "",
        status = C.ScanStatusForCap(scan),
        total = done and scan.total or "",
        count = done and scan.count or 0,
        startedAt = scan.startedAt or 0,
        coverage = self.coreCoverage or "",
        provider = self.coreProvider or "",
        time = self:Now(),
        errorCode = scan.errorCode or "",
    }
    local ok, err = call(self, "setPlayerValue", P.KEYS.SUMMARY, P.EncodeSummary(sum))
    if not ok then
        self:Log("setPlayerValue(SUM) failed: " .. tostr(err))
    end
end

function C:ReadCap(pid)
    if sameId(pid, self.pid) and self.cap then
        return self.cap
    end
    local raw = call(self, "getPlayerValue", pid, P.KEYS.CAP)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local cap, err = P.DecodeCapability(raw)
    if not cap then
        return nil, err
    end
    return cap
end

function C:ReadSummary(pid)
    if sameId(pid, self.pid) then
        local scan = self.scan
        return {
            rid = self.rid or "",
            token = self.token or "",
            status = C.ScanStatusForCap(scan),
            total = scan.total,
            count = scan.count,
            startedAt = scan.startedAt,
            coverage = self.coreCoverage,
            provider = self.coreProvider,
            time = scan.time,
            errorCode = scan.errorCode,
        }
    end
    local raw = call(self, "getPlayerValue", pid, P.KEYS.SUMMARY)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local sum, err = P.DecodeSummary(raw)
    if not sum then
        return nil, err
    end
    return sum
end

--=========================================================================
-- 本地扫描
--=========================================================================

function C:CancelLocalScan()
    if self.scan.job then
        coreCall(self, "CancelScan", self.scan.job)
        self.scan.job = nil
    end
    self.scan.pending = false
end

function C:ResetLocalScan()
    self:CancelLocalScan()
    self.scan = emptyScan()
    self.scan.rid = self.rid
    self.dirty = true
end

function C:SelfTotal()
    if self.scan.status == "done" and P.ValidTotal(self.scan.total) and self.scan.count > 0 then
        return self.scan.total
    end
    return nil
end

function C:FailScan(code)
    self:CancelLocalScan()
    self.scan.status = "error"
    self.scan.errorCode = tostr(code)
    self.scan.job = nil
    self.scan.total = nil
    self.scan.mods = nil
    self.scan.count = 0
    self.dirty = true
    self:WriteCapability()
    self:WriteSummary()
    self:Log("scan failed: " .. tostr(code))
end

-- 只有房主 Check、客机收到有效 round、或客机手动重查才调用。
function C:BeginLocalScan(force)
    if not self.inRoom then
        return false
    end
    if not self:RefreshCore() then
        self:FailScan(self.coreError or R.CORE_UNAVAILABLE)
        return false
    end
    if #self.manifest == 0 then
        self:FailScan(R.NO_MANIFEST)
        return false
    end
    if #self.manifest > P.MAX_MODS then
        self:FailScan("MANIFEST_TOO_LARGE")
        return false
    end
    if not force and self.scan.status == "done"
        and self.scan.fingerprint == self.manifestFingerprint
        and self.scan.rid == self.rid then
        return true
    end
    if not force and self.scan.status == "checking" then
        return true
    end

    self:CancelLocalScan()
    local now = self:Now()
    local job, berr = coreCall(self, "BeginScan", self.manifest)
    if job == nil then
        if tostr(berr) == "BUSY" then
            self.scan.status = "checking"
            self.scan.pending = true
            self.scan.attempts = math.min((self.scan.attempts or 0) + 1, 5)
            self.scan.busyUntil = now + math.min(10, 2 * self.scan.attempts)
            self.scan.startedAt = now
            self.scan.rid = self.rid
            self.dirty = true
            self:WriteCapability()
            self:WriteSummary()
            return true
        end
        self:FailScan(berr or "BEGIN_FAILED")
        return false
    end

    self.scan.status = "checking"
    self.scan.job = job
    self.scan.startedAt = now
    self.scan.fingerprint = self.manifestFingerprint
    self.scan.rid = self.rid
    self.scan.pending = false
    self.scan.attempts = 0
    self.scan.errorCode = nil
    self.scan.total = nil
    self.dirty = true
    self:WriteCapability()
    self:WriteSummary()
    return true
end

function C:AcceptScanDone(st)
    local mods, merr = P.NormalizeMods(st.mods)
    local coverage = tostr(st.coverage or self.coreCoverage)
    if not P.ValidTotal(st.total) then
        return nil, "MISSING_TOTAL"
    end
    if coverage ~= P.COVERAGE then
        return nil, "BAD_COVERAGE"
    end
    if not mods or #mods == 0 then
        return nil, merr or "EMPTY_MODS"
    end
    return {
        mods = mods,
        total = st.total,
        count = #mods,
        coverage = coverage,
    }
end

function C:PollLocalScan()
    local scan = self.scan
    if scan.status ~= "checking" then
        return
    end
    local now = self:Now()
    if scan.job == nil then
        if scan.pending and now >= scan.busyUntil then
            scan.pending = false
            self:BeginLocalScan(true)
        end
        return
    end
    if now - scan.startedAt > SCAN_TIMEOUT then
        self:FailScan(R.SCAN_TIMEOUT)
        return
    end
    local st, err = coreCall(self, "PollScan", scan.job)
    if type(st) ~= "table" then
        self:FailScan(err or "POLL_FAILED")
        return
    end
    if st.state == "done" then
        local ok, code = self:AcceptScanDone(st)
        if not ok then
            self:FailScan(code)
            return
        end
        if scan.fingerprint ~= self.manifestFingerprint then
            coreCall(self, "CancelScan", scan.job)
            scan.job = nil
            self:BeginLocalScan(true)
            return
        end
        scan.job = nil
        scan.status = "done"
        scan.total = ok.total
        scan.mods = ok.mods
        scan.count = ok.count
        scan.coverage = ok.coverage
        scan.provider = self.coreProvider
        scan.errorCode = nil
        scan.time = now
        self.dirty = true
        self:WriteCapability()
        self:WriteSummary()
        self:Log("scan done total=" .. tostr(scan.total))
    elseif st.state == "error" or st.state == "cancelled" or st.state == "unknown" then
        self:FailScan(st.errorCode or st.error or ("SCAN_" .. tostr(st.state)))
    end
end

--=========================================================================
-- 轮次 / 失效
--=========================================================================

function C:ReadRound()
    local raw = call(self, "getRoomValue", P.KEYS.ROUND)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local rnd, err = P.DecodeRound(raw)
    if not rnd then
        return nil, err
    end
    return rnd
end

function C:StartRound(why)
    if not self:IsHost() then
        return
    end
    self.epoch = (self.epoch or 0) + 1
    local now = self:Now()
    local rid = tostr(self.sid) .. "-" .. tostr(self.pid) .. "-" .. tostr(self.epoch)
        .. "-" .. string.sub(P.HashString("rnd|" .. tostr(now) .. "|" .. tostr(self.token)
            .. "|" .. tostr(self.epoch)), 1, 6)
    self.rid = rid
    self.roundStart = now
    self.roundPhase = "open"
    self.compare = {}
    self.assemblers = {}
    self.results = {}
    self.lastResSignature = ""
    self:ClearSendQueue()
    for key, st in pairs(self.peerStates) do
        if st.token then
            st.request = P.DeriveRequest(rid, st.token, "req")
            st.listRequest = P.DeriveRequest(rid, st.token, "list")
        end
        st.compare = nil
        st.listReqCount = 0
        st.listReqAt = 0
        st.listSeen = 0
        st.listRequested = false
        st.hostListSent = false
        st.scanStart = 0
        st.total = nil
        st.status = nil
        st.summary = nil
        st.probeCount = 0
        st.probeAt = 0
        self.compare[key] = nil
    end

    call(self, "setRoomValue", P.KEYS.ROUND, P.EncodeRound({
        rid = rid,
        sid = self.sid,
        host = self.pid,
        epoch = self.epoch,
        phase = "open",
        created = now,
    }))
    call(self, "setRoomValue", P.KEYS.RESULTS, P.EncodeResults(rid, {}))
    self:WriteCapability()
    self:WriteSummary()
    self.dirty = true
    self:Log("round start (" .. tostr(why) .. ") " .. rid)
end

function C:AdoptRound(rnd)
    if type(rnd) ~= "table" or rnd.phase ~= "open" then
        return false
    end
    if tostr(rnd.sid) ~= self.sid or not sameId(rnd.host, self.hostId) then
        return false
    end
    if self.rid == rnd.rid then
        return false
    end
    self.rid = rnd.rid
    self.roundStart = self:Now()
    self.roundPhase = "open"
    self.results = {}
    self:ClearSendQueue()
    self.selfCompare = nil
    self.hostList = nil
    self.hostCap = nil
    self.hostSum = nil
    self.hostAcked = false
    self.hostSeen = 0
    self.lastHello = 0
    self.lastSummaryKey = nil
    self:ResetLocalScan()
    self.scan.status = "queued"
    self.scan.rid = self.rid
    self.dirty = true
    self:WriteCapability()
    self:WriteSummary()
    self:Log("round adopted " .. tostr(self.rid))
    return true
end

-- 旧结果失效，但绝不自动开启新检查。
function C:InvalidateRound(why)
    local had = (self.rid ~= nil) or self.roundPhase == "open"
    self:CancelLocalScan()
    self:ClearSendQueue()
    self.rid = nil
    self.roundPhase = "invalid"
    self.roundStart = 0
    self.scan = emptyScan()
    self.compare = {}
    self.assemblers = {}
    self.results = {}
    self.hostCap = nil
    self.hostSum = nil
    self.hostAcked = false
    self.dirty = true
    if self:IsHost() then
        for key, st in pairs(self.peerStates) do
            st.compare = nil
            st.listReqCount = 0
            st.listSeen = 0
            st.hostListSent = false
            st.total = nil
            st.status = nil
            st.summary = nil
        end
        call(self, "setRoomValue", P.KEYS.ROUND, "")
        call(self, "setRoomValue", P.KEYS.RESULTS, "")
    end
    self:WriteCapability()
    self:WriteSummary()
    self:RenderIfNeeded(true)
    if had then
        self:Log("round invalidated: " .. tostr(why))
    end
end

--=========================================================================
-- 发送
--=========================================================================

function C:SendWhisper(pid, packet)
    local ok, err = call(self, "sendWhisper", pid, packet)
    if not ok then
        self:Log("sendWhisper failed: " .. tostr(err))
    end
    return ok
end

-- 有界发送队列：详单可能上百片，不能在同一个 Tick 里全部 SendChat。
function C:ClearSendQueue(pid)
    if pid == nil then
        self.sendQueue = {}
        self.sendQueueBytes = {}
        return
    end
    local key = tostr(pid)
    local keep = {}
    for i = 1, #self.sendQueue do
        if tostr(self.sendQueue[i].to) ~= key then
            keep[#keep + 1] = self.sendQueue[i]
        end
    end
    self.sendQueue = keep
    self.sendQueueBytes[key] = nil
end

function C:EnqueueSend(pid, packets)
    if type(packets) ~= "table" or #packets == 0 then
        return false
    end
    local key = tostr(pid)
    local used = self.sendQueueBytes[key] or 0
    local added = 0
    for i = 1, #packets do
        local pkt = packets[i]
        if type(pkt) ~= "string" or #pkt > P.MAX_PACKET_BYTES then
            self:Error("QUEUE_BAD_PACKET")
            return false
        end
        added = added + #pkt
    end
    if used + added > SEND_BYTES_PER_PEER then
        self:Error("QUEUE_OVERFLOW")
        return false
    end
    local now = self:Now()
    for i = 1, #packets do
        self.sendQueue[#self.sendQueue + 1] = {
            to = pid,
            packet = packets[i],
            at = now,
            rid = self.rid,
            token = self.token,
        }
    end
    self.sendQueueBytes[key] = used + added
    return true
end

-- 每 Tick 最多 SEND_PER_TICK 个包；过期/换轮/换 token 的残留直接丢弃。
function C:DrainSendQueue(limit)
    local max = limit or SEND_PER_TICK
    local sent = 0
    local now = self:Now()
    -- 过期/失效条目只丢弃、不占发送额度；失败的 sendWhisper 计入 tries，
    -- 防止整队发送失败时同一帧无限重试。
    local tries = 0
    while sent < max and tries < max and #self.sendQueue > 0 do
        local q = table.remove(self.sendQueue, 1)
        local key = tostr(q.to)
        local bytes = (self.sendQueueBytes[key] or 0) - #q.packet
        self.sendQueueBytes[key] = bytes > 0 and bytes or nil
        local expired = (now - (q.at or 0)) > SEND_TTL
        local stale = (q.rid ~= self.rid) or not sameId(q.token, self.token)
        if expired or stale then
            self.sendDropped = self.sendDropped + 1
        else
            local ok, err = call(self, "sendWhisper", q.to, q.packet)
            if ok then
                sent = sent + 1
            else
                tries = tries + 1
                self.sendDropped = self.sendDropped + 1
                self:Log("queued sendWhisper failed: " .. tostr(err))
            end
        end
    end
    return sent
end

function C:HelloFields()
    local scan = self.scan
    local done = (scan.status == "done" and P.ValidTotal(scan.total))
    return {
        self.coreAvailable and "1" or "0",
        C.ScanStatusForCap(scan),
        done and scan.total or "",
        tostr(done and scan.count or 0),
        tostr(self.coreCoverage or ""),
        tostr(self.coreProvider or ""),
        tostr(scan.startedAt or 0),
        tostr(scan.errorCode or ""),
    }
end

function C:SendHello()
    if self:IsHost() or not self.rid or not P.ValidToken(self.token) then
        return false
    end
    local hcap = self:ReadCap(self.hostId)
    if not hcap or not hcap.available or tostr(hcap.rid) ~= self.rid
        or not P.ValidToken(hcap.token) then
        return false
    end
    local request = P.DeriveRequest(self.rid, self.token, "req")
    local pkt = P.BuildPacket({
        type = P.T.HELLO,
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = self.hostId,
        token = self.token,
        request = request,
        fields = self:HelloFields(),
    })
    if not pkt then
        return false
    end
    self.lastHello = self:Now()
    return self:SendWhisper(self.hostId, pkt)
end

function C:SendAck(pid)
    local st = self:GetPeer(pid)
    if not st or not st.request then
        return false
    end
    local pkt = P.BuildPacket({
        type = P.T.ACK,
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = pid,
        token = self.token,
        request = st.request,
        fields = self:HelloFields(),
    })
    if pkt then
        self:SendWhisper(pid, pkt)
    end
end

function C:SendProbe(pid)
    local st = self:GetPeer(pid)
    if not st or not st.request then
        return false
    end
    local pkt = P.BuildPacket({
        type = P.T.PROBE,
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = pid,
        token = self.token,
        request = st.request,
        body = "",
    })
    if pkt then
        self:SendWhisper(pid, pkt)
    end
end

function C:SummaryKey()
    local scan = self.scan
    local done = (scan.status == "done" and P.ValidTotal(scan.total))
    return C.ScanStatusForCap(scan) .. "|" .. tostr(done and scan.total or "") .. "|"
        .. tostr(self.token) .. "|" .. tostr(self.rid)
end

function C:SendSummary(force)
    if self:IsHost() or not self.rid or not P.ValidToken(self.token) then
        return false
    end
    local key = self:SummaryKey()
    if not force and key == self.lastSummaryKey then
        return true
    end
    local pkt = P.BuildPacket({
        type = P.T.SUMMARY,
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = self.hostId,
        token = self.token,
        request = P.DeriveRequest(self.rid, self.token, "req"),
        fields = self:HelloFields(),
    })
    if pkt then
        self:SendWhisper(self.hostId, pkt)
        self.lastSummaryKey = key
        return true
    end
    return false
end

function C:SendList(pid)
    if not self.rid or not P.ValidToken(self.token) then
        return false
    end
    if self.scan.status ~= "done" or not self.scan.mods or not P.ValidTotal(self.scan.total) then
        return false
    end
    local packets, err = P.BuildListPackets({
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = pid,
        token = self.token,
        request = P.DeriveRequest(self.rid, self.token, "list"),
        digest = P.HashMods(self.scan.mods),
        mods = self.scan.mods,
    })
    if not packets then
        self:Log("BuildListPackets failed: " .. tostr(err))
        self:Error("LIST_" .. tostr(err))
        return false
    end
    return self:EnqueueSend(pid, packets)
end

-- 房主把自己的逐 Mod 清单发给兼容客户端（仅在 total 不同、客户端声明兼容时）。
function C:SendHostList(pid)
    if not self:IsHost() or not self.rid then
        return false
    end
    if self.scan.status ~= "done" or not self.scan.mods or not P.ValidTotal(self.scan.total) then
        return false
    end
    local targetCap = self:ReadCap(pid)
    if not targetCap or not P.ValidToken(targetCap.token) then
        return false
    end
    local packets, err = P.BuildListPackets({
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = pid,
        token = self.token,
        request = P.DeriveRequest(self.rid, targetCap.token, "list"),
        digest = P.HashMods(self.scan.mods),
        mods = self.scan.mods,
    })
    if not packets then
        self:Log("BuildListPackets(host) failed: " .. tostr(err))
        return false
    end
    return self:EnqueueSend(pid, packets)
end

function C:RequestList(pid)
    local st = self:GetPeer(pid)
    if not st or not st.listRequest then
        return false
    end
    if (st.listReqCount or 0) >= 2 then
        return false
    end
    local cap = self:ReadCap(pid)
    if not cap or not P.ValidToken(cap.token) then
        return false
    end
    local pkt = P.BuildPacket({
        type = P.T.LIST_REQ,
        rid = self.rid,
        sid = self.sid,
        host = self.hostId,
        from = self.pid,
        to = pid,
        token = self.token,
        request = st.listRequest,
        body = P.EncodeFields({ tostr(self:SelfTotal() or "") }),
    })
    if pkt then
        st.listReqCount = (st.listReqCount or 0) + 1
        st.listReqAt = self:Now()
        self:SendWhisper(pid, pkt)
        return true
    end
    return false
end

--=========================================================================
-- 分片重组
--=========================================================================

function C:AssemblerKey(pid, msg)
    return tostr(pid) .. "|" .. tostr(self.rid) .. "|" .. tostr(msg.token)
        .. "|" .. tostr(msg.request) .. "|" .. tostr(msg.digest)
end

function C:GetAssembler(pid, msg)
    local key = self:AssemblerKey(pid, msg)
    local entry = self.assemblers[key]
    if entry == nil then
        local count = 0
        local oldestKey, oldestAt = nil, nil
        for k, v in pairs(self.assemblers) do
            count = count + 1
            if oldestAt == nil or (v.startedAt or 0) < oldestAt then
                oldestAt = v.startedAt
                oldestKey = k
            end
        end
        if count >= MAX_ASSEMBLERS and oldestKey then
            self.assemblers[oldestKey] = nil
        end
        entry = {
            asm = P.NewAssembler({ digest = msg.digest }),
            startedAt = self:Now(),
        }
        self.assemblers[key] = entry
    end
    return entry.asm
end

function C:DropAssemblersFor(pid)
    local prefix = tostr(pid) .. "|"
    for k in pairs(self.assemblers) do
        if string.sub(k, 1, #prefix) == prefix then
            self.assemblers[k] = nil
        end
    end
end

function C:HandleListChunk(pid, msg)
    local asm = self:GetAssembler(pid, msg)
    local state, text = asm:Accept(msg)
    if state == nil then
        self:Error("CHUNK_" .. tostr(text))
        return
    end
    if state == "partial" then
        return
    end
    local key = self:AssemblerKey(pid, msg)
    self.assemblers[key] = nil
    local mods, derr = P.DecodeModList(text)
    if not mods then
        self:Error("LIST_" .. tostr(derr))
        return
    end
    if P.HashMods(mods) ~= msg.digest then
        self:Error("LIST_DIGEST_MISMATCH")
        return
    end
    self:OnPeerList(pid, mods)
end

function C:OnPeerList(pid, mods)
    if self.scan.status ~= "done" or not self.scan.mods then
        return
    end
    -- 以客机为视角：客机缺的 Mod 记为 missing，多出来的记为 extra。
    local cmp = P.CompareLists(mods, self.scan.mods)
    if self:IsHost() then
        local st = self:GetPeer(pid)
        local cap = self:ReadCap(pid)
        if not cap or not sameId(cap.token, st.token) then
            return
        end
        -- 相同 total 不保留逐 Mod 结果
        if self:SelfTotal() and P.ValidTotal(cap.total) and cap.total == self:SelfTotal() then
            self.compare[tostr(pid)] = nil
            st.compare = nil
            return
        end
        self.compare[tostr(pid)] = cmp
        st.compare = cmp
        st.listSeen = self:Now()
        self.dirty = true
        self:PublishResults(true)
    else
        if not sameId(pid, self.hostId) then
            return
        end
        local hcap = self:ReadCap(self.hostId)
        if not hcap then
            return
        end
        if self:SelfTotal() and P.ValidTotal(hcap.total) and hcap.total == self:SelfTotal() then
            return
        end
        self.hostList = mods
        self.selfCompare = cmp
        self.dirty = true
    end
end

--=========================================================================
-- 收包
--=========================================================================

function C:GetPeer(pid)
    local key = tostr(pid)
    local st = self.peerStates[key]
    if st == nil then
        st = { firstSeen = self:Now() }
        self.peerStates[key] = st
    end
    return st
end

function C:ResetPeer(pid, token)
    local key = tostr(pid)
    local st = {
        token = token,
        request = P.DeriveRequest(self.rid, token, "req"),
        listRequest = P.DeriveRequest(self.rid, token, "list"),
        firstSeen = self:Now(),
        probeCount = 0,
    }
    self.peerStates[key] = st
    self.compare[key] = nil
    self.reminded[key] = nil
    self:ClearSendQueue(pid)
    self:DropAssemblersFor(pid)
    self.results[key] = nil
    self.dirty = true
end

function C:EvictPeer(pid)
    local key = tostr(pid)
    self.peerStates[key] = nil
    self.compare[key] = nil
    self.results[key] = nil
    self:ClearSendQueue(pid)
    self:DropAssemblersFor(pid)
end

function C:OnChat(from, to, text, targetType)
    if not P.IsProtocolText(text) then
        return false
    end
    if not self.inRoom then
        return true
    end
    -- 引擎给出的真实接收者必须就是本机：广播（-1/空）或发给别人的包不消费。
    if not sameId(to, self.pid) then
        self:Error("MISDIRECTED")
        return true
    end
    self:RefreshParticipants()

    local fid = tonumber(from) or from
    if fid == nil or sameId(fid, self.pid) then
        return true
    end

    local msg, err = P.ParsePacket(text)
    if not msg then
        self:Error("PACKET_" .. tostr(err))
        return true
    end
    if not sameId(msg.from, fid) then
        self:Error("FAKE_SENDER")
        return true
    end
    if not self:ValidPeer(fid) then
        self:Error("NON_MEMBER")
        return true
    end
    if tostr(msg.sid) ~= self.sid then
        self:Error("STALE_SESSION")
        return true
    end
    if not sameId(msg.host, self.hostId) then
        self:Error("STALE_HOST")
        return true
    end
    if not sameId(msg.to, self.pid) then
        self:Error("MISDIRECTED")
        return true
    end
    if self.rid == nil or tostr(msg.rid) ~= tostr(self.rid) then
        self:Error("STALE_ROUND")
        return true
    end

    if self:IsHost() then
        local cap = self:ReadCap(fid)
        if not cap or not P.ValidToken(cap.token) then
            self:Error("NO_CONNECTION")
            return true
        end
        if not sameId(cap.token, msg.token) then
            self:Error("STALE_CONNECTION")
            return true
        end
        local st = self:GetPeer(fid)
        if not sameId(st.token, cap.token) then
            self:ResetPeer(fid, cap.token)
            st = self:GetPeer(fid)
        end
        local expected
        if msg.type == P.T.LIST_CHUNK then
            expected = st.listRequest
        elseif msg.type == P.T.HELLO or msg.type == P.T.SUMMARY
            or msg.type == P.T.PROBE or msg.type == P.T.ACK then
            expected = st.request
        else
            self:Error("BAD_TYPE")
            return true
        end
        if expected == nil or msg.request ~= expected then
            self:Error("BAD_REQUEST")
            return true
        end
        self:HostOnPacket(fid, msg)
    else
        if not sameId(fid, self.hostId) then
            self:Error("NOT_HOST")
            return true
        end
        local hcap = self:ReadCap(self.hostId)
        if not hcap or not P.ValidToken(hcap.token) then
            self:Error("NO_HOST_CONNECTION")
            return true
        end
        if not sameId(hcap.token, msg.token) then
            self:Error("STALE_CONNECTION")
            return true
        end
        local request = P.DeriveRequest(self.rid, self.token, "req")
        local listRequest = P.DeriveRequest(self.rid, self.token, "list")
        local expected
        if msg.type == P.T.LIST_CHUNK or msg.type == P.T.LIST_REQ then
            expected = listRequest
        elseif msg.type == P.T.ACK or msg.type == P.T.PROBE then
            expected = request
        else
            self:Error("BAD_TYPE")
            return true
        end
        if msg.request ~= expected then
            self:Error("BAD_REQUEST")
            return true
        end
        self:ClientOnPacket(fid, msg)
    end
    self.dirty = true
    return true
end

function C:HostOnPacket(pid, msg)
    local st = self:GetPeer(pid)
    st.lastSeen = self:Now()
    if msg.type == P.T.HELLO then
        st.hello = true
        self:ApplyHelloState(st, msg.fields or {})
        self:SendAck(pid)
    elseif msg.type == P.T.SUMMARY or msg.type == P.T.ACK then
        -- 不再回 ACK：否则 SUMMARY/ACK 会互相触发形成包风暴。
        st.ack = true
        self:ApplyHelloState(st, msg.fields or {})
    elseif msg.type == P.T.LIST_CHUNK then
        self:HandleListChunk(pid, msg)
    elseif msg.type == P.T.PROBE then
        self:SendAck(pid)
    end
end

function C:ApplyHelloState(st, fields)
    st.available = (fields[1] == "1")
    st.status = fields[2]
    if P.ValidTotal(fields[3]) then
        st.total = fields[3]
    end
    st.count = tonumber(fields[4]) or 0
end

function C:ClientOnPacket(pid, msg)
    if msg.type == P.T.ACK then
        self.hostAcked = true
        self.hostSeen = self:Now()
        self:ApplyHostState(msg.fields or {})
        self:SendSummary()
    elseif msg.type == P.T.PROBE then
        self.hostSeen = self:Now()
        self:SendHello()
    elseif msg.type == P.T.LIST_REQ then
        self.hostSeen = self:Now()
        self:SendList(self.hostId)
    elseif msg.type == P.T.LIST_CHUNK then
        self.hostSeen = self:Now()
        self:HandleListChunk(pid, msg)
    elseif msg.type == P.T.CANCEL then
        self.selfCompare = nil
        self.hostList = nil
        self:Error("ROUND_CANCELLED")
    end
end

function C:ApplyHostState(fields)
    self.hostSum = {
        rid = self.rid,
        status = fields[2] or "",
        total = fields[3] or "",
        count = tonumber(fields[4]) or 0,
        coverage = fields[5] or "",
        provider = fields[6] or "",
        startedAt = tonumber(fields[7]) or 0,
    }
end

--=========================================================================
-- 评价
--=========================================================================

function C:PeerCompatible(cap)
    if not cap or not cap.available then
        return false
    end
    if cap.apiVersion ~= P.API_VERSION then
        return false
    end
    if cap.coverage ~= P.COVERAGE then
        return false
    end
    if tostr(cap.provider) == "" or tostr(cap.buildId) == "" then
        return false
    end
    if tostr(self.coreProvider) ~= "" and tostr(cap.provider) ~= tostr(self.coreProvider) then
        return false
    end
    return P.ValidToken(cap.token)
end

function C:EvaluateSelfHost()
    if not self.coreAvailable then
        return P.COLOR.YELLOW, R.CORE_UNAVAILABLE, {}
    end
    if self.rid == nil then
        return P.COLOR.YELLOW, R.WAITING, {}
    end
    if self.scan.status == "done" then
        if self:SelfTotal() then
            return P.COLOR.GREEN, R.OK, {}
        end
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}
    end
    if self.scan.status == "error" then
        return P.COLOR.YELLOW, self.scan.errorCode or R.SCAN_ERROR, {}
    end
    return P.COLOR.YELLOW, R.CHECKING, {}
end

-- 房主看单个成员；sideEffects 负责连接重置、探针、清单请求与提醒。
function C:ClassifyPeer(pid, sideEffects)
    local now = self:Now()
    local key = tostr(pid)
    local st = self:GetPeer(pid)
    if st.firstSeen == nil or st.firstSeen == 0 then
        st.firstSeen = now
    end

    local cap, capErr = self:ReadCap(pid)
    if cap == nil and capErr ~= nil then
        return P.COLOR.YELLOW, R.INCOMPATIBLE, {}, 0, nil
    end
    if cap == nil then
        if sideEffects and self:SelfTotal() and now - st.firstSeen >= NO_RESPONSE_WAIT then
            self:MaybeRemind(pid, "no-response", nil, 0)
        end
        if now - st.firstSeen >= NO_RESPONSE_WAIT then
            return P.COLOR.YELLOW, R.NO_RESPONSE, {}, 0, nil
        end
        return P.COLOR.YELLOW, R.WAITING, {}, 0, nil
    end

    if not P.ValidToken(cap.token) then
        return P.COLOR.YELLOW, R.INCOMPATIBLE, {}, 0, cap
    end
    if st.token == nil or not sameId(st.token, cap.token) then
        if sideEffects then
            self:ResetPeer(pid, cap.token)
            st = self:GetPeer(pid)
        else
            return P.COLOR.YELLOW, R.STALE, {}, 0, cap
        end
    end

    if tostr(cap.rid) ~= tostr(self.rid) then
        return P.COLOR.YELLOW, R.STALE, {}, 0, cap
    end

    st.available = cap.available
    st.status = cap.status
    st.scanStart = cap.startedAt or 0
    st.count = cap.count or 0

    if not cap.available then
        if sideEffects and self:SelfTotal() then
            self:MaybeRemind(pid, "no-core", nil, 0)
        end
        return P.COLOR.YELLOW, R.NO_CORE, {}, 0, cap
    end

    if not self:PeerCompatible(cap) then
        return P.COLOR.YELLOW, R.INCOMPATIBLE, {}, 0, cap
    end

    if cap.status == "checking" then
        -- 客机 cap.startedAt 是客机本地时钟，房主直接 +120 比较会被时钟偏移
        -- 误导；以房主首次收到本 round/token 的 checking 声明的本地时刻起算。
        if st.checkingAt == nil or tostr(st.checkingRid) ~= tostr(self.rid)
            or not sameId(st.checkingToken, cap.token) then
            st.checkingAt = now
            st.checkingRid = self.rid
            st.checkingToken = cap.token
        end
        if sideEffects and (st.hello == nil or st.ack == nil) and (st.probeCount or 0) < 2 then
            local due = st.firstSeen + PROBE_INTERVAL * ((st.probeCount or 0) + 1)
            if now >= due then
                st.probeCount = (st.probeCount or 0) + 1
                st.probeAt = now
                self:SendProbe(pid)
            end
        end
        if now - st.checkingAt > SCAN_TIMEOUT then
            return P.COLOR.YELLOW, R.SCAN_TIMEOUT, {}, 0, cap
        end
        return P.COLOR.YELLOW, R.CHECKING, {}, 0, cap
    end
    st.checkingAt = nil
    st.checkingRid = nil
    st.checkingToken = nil

    if cap.status == "error" then
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}, 0, cap
    end

    if cap.status == "idle" then
        return P.COLOR.YELLOW, R.WAITING, {}, 0, cap
    end

    if cap.status ~= "done" then
        return P.COLOR.YELLOW, R.WAITING, {}, 0, cap
    end

    -- done：必须 64hex 原生 total + 覆盖范围 + 非空清单，否则黄。
    if not P.ValidTotal(cap.total) or (cap.count or 0) <= 0
        or cap.coverage ~= P.COVERAGE then
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}, 0, cap
    end

    local hostTotal = self:SelfTotal()
    if not hostTotal then
        return P.COLOR.YELLOW, R.CHECKING, {}, 0, cap
    end

    if cap.total == hostTotal then
        if sideEffects then
            self.compare[key] = nil
            st.compare = nil
        end
        return P.COLOR.GREEN, R.OK, {}, 0, cap
    end

    local cmp = self.compare[key]
    if cmp == nil then
        if sideEffects and self:PeerCompatible(cap) then
            if not st.listRequested then
                st.listRequested = true
                self:RequestList(pid)
            elseif (st.listReqCount or 0) < 2
                and now - (st.listReqAt or 0) >= PROBE_INTERVAL then
                self:RequestList(pid)
            end
            if not st.hostListSent then
                st.hostListSent = true
                self:SendHostList(pid)
            end
        end
        -- 先给兼容客户端一点时间回传逐 Mod 明细；明细迟迟不到才发泛化红灯。
        if sideEffects and self:SelfTotal() and now - st.firstSeen >= 15 then
            self:MaybeRemind(pid, "red", nil, 0)
        end
        return P.COLOR.RED, R.DIGEST, { { kind = "digest" } }, 0, cap
    end

    if cmp.equal then
        -- 原生 total 不同但逐 Mod 相同：仍不能绿，也不能伪装成差异。
        return P.COLOR.RED, R.DIGEST, { { kind = "digest" } }, 0, cap
    end

    if sideEffects and self:SelfTotal() then
        self:MaybeRemind(pid, "red", cmp.diffs, #cmp.diffs)
    end
    return P.COLOR.RED, R.DIFF, copyDiffs(cmp), #cmp.diffs, cap
end

function C:EvaluatePeer(pid)
    local color, reason, details, count = self:ClassifyPeer(pid, false)
    return color, reason, details, count
end

function C:EvaluateSelfClient()
    if not self.coreAvailable then
        return P.COLOR.YELLOW, R.CORE_UNAVAILABLE, {}
    end
    if not self.rid then
        return P.COLOR.YELLOW, R.WAITING, {}
    end
    if self.scan.status == "error" then
        return P.COLOR.YELLOW, self.scan.errorCode or R.SCAN_ERROR, {}
    end
    if self.scan.status ~= "done" then
        return P.COLOR.YELLOW, R.CHECKING, {}
    end
    if not self:SelfTotal() then
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}
    end

    local hcap = self:ReadCap(self.hostId)
    if hcap == nil then
        if self:Now() - (self.roundStart or 0) >= NO_RESPONSE_WAIT then
            return P.COLOR.YELLOW, R.HOST_NO_RESPONSE, {}
        end
        return P.COLOR.YELLOW, R.WAITING, {}
    end
    if not hcap.available then
        return P.COLOR.YELLOW, R.HOST_NO_CORE, {}
    end
    if tostr(hcap.rid) ~= tostr(self.rid) then
        return P.COLOR.YELLOW, R.STALE, {}
    end
    if hcap.status == "checking" then
        return P.COLOR.YELLOW, R.CHECKING, {}
    end
    if hcap.status == "error" then
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}
    end
    if hcap.status ~= "done" then
        return P.COLOR.YELLOW, R.WAITING, {}
    end
    if not P.ValidTotal(hcap.total) or hcap.coverage ~= P.COVERAGE then
        return P.COLOR.YELLOW, R.SCAN_ERROR, {}
    end
    if hcap.total == self:SelfTotal() then
        return P.COLOR.GREEN, R.OK, {}
    end
    if self.selfCompare then
        if self.selfCompare.equal then
            return P.COLOR.RED, R.DIGEST, { { kind = "digest" } }
        end
        return P.COLOR.RED, R.DIFF, copyDiffs(self.selfCompare)
    end
    return P.COLOR.RED, R.DIGEST, { { kind = "digest" } }
end

--=========================================================================
-- 结果发布（房主）
--=========================================================================

local function codeFor(color, reason)
    if color == P.COLOR.GREEN then
        return P.CODE.OK
    end
    if reason == R.NO_CORE or reason == R.HOST_NO_CORE then
        return P.CODE.NO_CORE
    end
    if reason == R.NO_RESPONSE or reason == R.HOST_NO_RESPONSE or reason == R.WAITING then
        return P.CODE.WAIT
    end
    if reason == R.STALE then
        return P.CODE.STALE
    end
    if reason == R.SCAN_ERROR or reason == R.SCAN_TIMEOUT
        or reason == R.INCOMPATIBLE or reason == R.CORE_UNAVAILABLE then
        return P.CODE.ERROR
    end
    if color == P.COLOR.RED then
        return P.CODE.DIFF
    end
    return P.CODE.CHECKING
end

function C:CollectRows()
    local rows = {}
    if not self:IsHost() then
        return rows
    end
    for i = 1, #self.participants do
        local p = self.participants[i]
        local color, reason, details, count
        if sameId(p.id, self.pid) then
            color, reason, details = self:EvaluateSelfHost()
            count = 0
        else
            color, reason, details, count = self:EvaluatePeer(p.id)
        end
        local pcap = self:ReadCap(p.id)
        rows[#rows + 1] = {
            pid = p.id,
            color = color,
            code = codeFor(color, reason),
            count = count or (details and #details) or 0,
            token = pcap and tostr(pcap.token) or "",
        }
    end
    return rows
end

function C:PublishResults(force)
    if not self:IsHost() or not self.rid then
        return
    end
    local now = self:Now()
    local rows = self:CollectRows()
    local parts = {}
    for i = 1, #rows do
        local r = rows[i]
        parts[#parts + 1] = tostr(r.pid) .. ":" .. r.color .. ":" .. r.code .. ":"
            .. tostr(r.count) .. ":" .. tostr(r.token)
    end
    local sig = table.concat(parts, ",")
    if not force and sig == self.lastResSignature then
        return
    end
    if not force and now - self.lastResPublish < RES_PUBLISH_INTERVAL then
        return
    end
    self.lastResPublish = now
    self.lastResSignature = sig
    self.results = rows
    call(self, "setRoomValue", P.KEYS.RESULTS, P.EncodeResults(self.rid, rows))
end

--=========================================================================
-- 提醒
--=========================================================================

local KIND_LABEL = {
    content = "内容不同",
    version = "版本不同",
    missing = "缺失",
    extra = "多余",
}

function C:MaybeRemind(pid, kind, diffs, count)
    if not self:IsHost() or not self:SelfTotal() then
        return false
    end
    local key = tostr(pid)
    if self.reminded[key] then
        return false
    end
    local now = self:Now()
    if now - (self.lastReminderAt or -999) < REMINDER_SPACING then
        return false
    end
    local identityKey = self.sid .. "|" .. self:IdentityOf(pid)
    local last = reminderLedger[identityKey]
    if last ~= nil and now - last < REMINDER_COOLDOWN then
        return false
    end

    local name = self:NameOf(pid)
    local text
    if kind == "no-response" then
        text = "[CCB] " .. name .. "：未收到工具箱回应，请确认已安装并启用 CCB 工具箱 2.0；"
            .. "首次 XP2 初始化后请完全退出并重启。"
    elseif kind == "no-core" then
        text = "[CCB] " .. name .. "：工具箱核心未就绪，请完全退出并重启游戏；"
            .. "仍未加载时按主菜单说明检查核心安装。"
    else
        local parts = {}
        local shown = 0
        if type(diffs) == "table" then
            for i = 1, math.min(#diffs, 3) do
                local d = diffs[i]
                local label = KIND_LABEL[d.kind] or "不同"
                local nm = d.name and tostr(d.name) ~= "" and P.SanitizeName(d.name, 16)
                    or string.sub(tostr(d.id), 1, 8)
                parts[#parts + 1] = nm .. "（" .. label .. "）"
                shown = shown + 1
            end
        end
        if shown == 0 then
            text = "[CCB] " .. name .. "：CCB Mod 与本机不同，请使用同一发布包。"
        else
            local rest = (count or #diffs) - shown
            text = "[CCB] " .. name .. "：CCB Mod 差异：" .. table.concat(parts, "、")
            if rest > 0 then
                text = text .. "，另有" .. tostr(rest) .. "项"
            end
            text = text .. "。建议使用同一发布包。"
        end
    end

    local ok = call(self, "sendReminder", pid, text)
    if ok then
        self.reminded[key] = true
        self.lastReminderAt = now
        reminderLedger[identityKey] = now
        self:Log("reminder " .. kind .. " -> " .. key)
        return true
    end
    self:Log("sendReminder failed -> " .. key)
    return false
end

--=========================================================================
-- 节奏
--=========================================================================

function C:HostTick()
    local now = self:Now()
    if self.rid == nil then
        if self.scan.job then
            self:CancelLocalScan()
        end
        self:WriteCapability()
        self.dirty = true
        return
    end

    if self:RefreshCore() then
        if self.scan.status ~= "done" and self.scan.status ~= "error"
            and self.scan.job == nil and not self.scan.pending then
            if self.scan.status == "none" then
                self:BeginLocalScan(true)
            end
        end
    end
    self:PollLocalScan()

    for i = 1, #self.participants do
        local p = self.participants[i]
        if not sameId(p.id, self.pid) then
            self:ClassifyPeer(p.id, true)
        end
    end

    self:PublishResults(false)
end

function C:ClientTick()
    local now = self:Now()
    local rnd = self:ReadRound()
    if not rnd then
        if self.rid then
            self:CancelLocalScan()
            self.rid = nil
            self.roundPhase = "none"
            self.scan = emptyScan()
            self.results = {}
            self.selfCompare = nil
            self.hostList = nil
            self.hostCap = nil
            self.hostSum = nil
            self.hostAcked = false
            self.lastSummaryKey = nil
            self:WriteCapability()
            self:WriteSummary()
            self.dirty = true
        end
        return
    end

    if rnd.rid ~= self.rid then
        self:AdoptRound(rnd)
    end
    if not self.rid then
        return
    end

    -- 收到有效 round 后才自动扫描；同一轮不重复扫描。
    if self.scan.status == "queued"
        or (self.scan.status == "none" and self.scan.rid ~= self.rid) then
        self.scan.status = "queued"
        self:BeginLocalScan(false)
    end
    self:PollLocalScan()

    -- 扫描状态/结果变化主动同步给房主；同一状态不重复发。
    if self.scan.status == "done" and self:SelfTotal() then
        local key = self:SummaryKey()
        if key ~= self.lastSummaryKey then
            self:SendSummary()
        end
    end

    self.hostCap = self:ReadCap(self.hostId)
    self.hostSum = self:ReadSummary(self.hostId)

    if not self.hostAcked and self.hostCap and self.hostCap.available
        and tostr(self.hostCap.rid) == self.rid
        and now - (self.lastHello or -999) >= PROBE_INTERVAL then
        self:SendHello()
    end

    local resRaw = call(self, "getRoomValue", P.KEYS.RESULTS)
    if type(resRaw) == "string" and resRaw ~= "" then
        local res, rerr = P.DecodeResults(resRaw)
        if res and tostr(res.rid) == tostr(self.rid) then
            local map = {}
            for i = 1, #res.players do
                local row = res.players[i]
                local pcap = self:ReadCap(row.pid)
                -- 行内 connection token 必须与成员当前 CAP 一致；槽位复用后
                -- 旧 RES 的 green 不能被当成本轮结果。
                if pcap and sameId(pcap.token, row.token)
                    and tostr(pcap.rid) == tostr(self.rid) then
                    map[tostr(row.pid)] = row
                end
            end
            self.results = map
            self.dirty = true
        elseif rerr then
            self:Error("RESULTS_" .. tostr(rerr))
        end
    end
end

--=========================================================================
-- 快照
--=========================================================================

function C:GetSnapshot()
    local players = {}
    local green, red, yellow = 0, 0, 0
    local checking = (self.scan.status == "checking")

    local function add(pid, color, reason, details, count)
        if pid == nil then
            return
        end
        players[pid] = {
            color = color,
            reason = reason,
            details = details or {},
            count = count or 0,
        }
        if color == P.COLOR.GREEN then
            green = green + 1
        elseif color == P.COLOR.RED then
            red = red + 1
        else
            yellow = yellow + 1
        end
    end

    if self:IsHost() then
        for i = 1, #self.participants do
            local p = self.participants[i]
            if sameId(p.id, self.pid) then
                local color, reason, details = self:EvaluateSelfHost()
                add(p.id, color, reason, details, 0)
            else
                local color, reason, details, count = self:EvaluatePeer(p.id)
                add(p.id, color, reason, details, count)
            end
        end
    else
        local selfColor, selfReason, selfDetails = self:EvaluateSelfClient()
        add(self.pid, selfColor, selfReason, selfDetails, 0)
        for i = 1, #self.participants do
            local p = self.participants[i]
            if not sameId(p.id, self.pid) then
                local row = self.results[tostr(p.id)]
                if row then
                    local pcap = self:ReadCap(p.id)
                    if not pcap or not sameId(pcap.token, row.token)
                        or tostr(pcap.rid) ~= tostr(self.rid) then
                        row = nil
                    end
                end
                if row then
                    local color = row.color
                    if color ~= P.COLOR.GREEN and color ~= P.COLOR.RED then
                        color = P.COLOR.YELLOW
                    end
                    add(p.id, color, row.code or R.CHECKING, {}, row.count or 0)
                else
                    add(p.id, P.COLOR.YELLOW, R.WAITING, {}, 0)
                end
            end
        end
    end

    local total = green + red + yellow
    local canCheck = self.coreAvailable and (#self.manifest > 0)
        and not checking
    if not self:IsHost() then
        canCheck = canCheck and self.rid ~= nil
    end

    local state = "idle"
    if not canCheck and not checking then
        state = "blocked"
    elseif red > 0 then
        state = "issue"
    elseif checking or yellow > 0 then
        state = "checking"
    elseif total > 0 and green == total then
        state = "ok"
    end

    return {
        role = self:IsHost() and "host" or "client",
        rid = self.rid,
        sid = self.sid,
        phase = self.roundPhase,
        canCheck = canCheck,
        checking = checking,
        state = state,
        players = players,
        results = self.results,
        errors = self.errors,
        lastProtocolError = self.lastProtocolError,
        summary = {
            total = total,
            green = green,
            red = red,
            yellow = yellow,
            text = string.format("一致 %d · 差异 %d · 未知 %d", green, red, yellow),
        },
    }
end

function C:Signature(snapshot)
    local parts = { snapshot.role, tostr(snapshot.rid), snapshot.state,
        snapshot.canCheck and "1" or "0", snapshot.checking and "1" or "0" }
    for _, pid in ipairs(sortedKeys(snapshot.players)) do
        local p = snapshot.players[pid]
        parts[#parts + 1] = tostr(pid) .. p.color .. p.reason .. tostr(p.count)
    end
    return table.concat(parts, "|")
end

function C:RenderIfNeeded(force)
    local snapshot = self:GetSnapshot()
    local sig = self:Signature(snapshot)
    if force or self.dirty or sig ~= self.lastRenderSignature then
        self.lastRenderSignature = sig
        self.dirty = false
        call(self, "render", snapshot)
    end
    return snapshot
end

--=========================================================================
-- 生命周期
--=========================================================================

function C:Enter()
    self.inRoom = true
    self.enteredAt = self:Now()
    self.token = P.NewToken(tostr(call(self, "sessionId")) .. "|"
        .. tostr(call(self, "localId")) .. "|" .. tostr(self.enteredAt) .. "|"
        .. tostr(self.epoch))

    self.pid = tonumber(call(self, "localId")) or call(self, "localId")
    self.hostId = tonumber(call(self, "hostId")) or call(self, "hostId")
    self.sid = tostr(call(self, "sessionId"))

    self:RefreshParticipants()
    self:LoadManifest()
    self:RefreshCore()
    self.scan = emptyScan()
    self.peerStates = {}
    self.compare = {}
    self.assemblers = {}
    self.results = {}
    self.reminded = {}
    self:ClearSendQueue()

    if self:IsHost() then
        -- 进房不建轮次、不扫描；旧的房主轮次没有本进程基准，直接失效。
        if self:ReadRound() then
            call(self, "setRoomValue", P.KEYS.ROUND, "")
            call(self, "setRoomValue", P.KEYS.RESULTS, "")
        end
        self.rid = nil
        self.roundPhase = "none"
    else
        local rnd = self:ReadRound()
        if rnd and rnd.phase == "open" and tostr(rnd.sid) == self.sid
            and sameId(rnd.host, self.hostId) then
            self:AdoptRound(rnd)
            self.scan.status = "queued"
        end
    end

    self:WriteCapability()
    self:WriteSummary()
    self.dirty = true
    self:RenderIfNeeded(true)
    return self:GetSnapshot()
end

function C:Leave()
    self:CancelLocalScan()
    self:ClearSendQueue()
    self.inRoom = false
    self.rid = nil
    self.roundPhase = "none"
    self.scan = emptyScan()
    self.peerStates = {}
    self.compare = {}
    self.assemblers = {}
    self.results = {}
    self.selfCompare = nil
    self.hostCap = nil
    self.hostSum = nil
    self.hostAcked = false
    self.dirty = true
    self:RenderIfNeeded(true)
end

function C:Check()
    if not self.inRoom then
        return self:GetSnapshot()
    end
    self:LoadManifest()
    if self:IsHost() then
        if not self.coreAvailable or #self.manifest == 0 then
            self:FailScan(not self.coreAvailable and (self.coreError or R.CORE_UNAVAILABLE) or R.NO_MANIFEST)
            return self:GetSnapshot()
        end
        self:StartRound("check")
        self:BeginLocalScan(true)
        self:PublishResults(true)
    else
        if self.rid then
            self:BeginLocalScan(true)
            self:SendSummary()
        end
    end
    self.dirty = true
    self:RenderIfNeeded(false)
    return self:GetSnapshot()
end

function C:OnRosterChanged()
    if not self.inRoom then
        return self:GetSnapshot()
    end
    self:RefreshParticipants()
    if self:IsHost() then
        local present = {}
        for i = 1, #self.participants do
            local p = self.participants[i]
            present[tostr(p.id)] = true
            if not sameId(p.id, self.pid) then
                local st = self.peerStates[tostr(p.id)]
                if st == nil then
                    self:GetPeer(p.id)
                end
            end
        end
        for key in pairs(self.peerStates) do
            if not present[key] then
                self:EvictPeer(key)
            end
        end
        self:PublishResults(true)
    end
    self.dirty = true
    self:RenderIfNeeded(false)
    return self:GetSnapshot()
end

function C:OnManifestChanged()
    if not self.inRoom then
        return self:GetSnapshot()
    end
    self:LoadManifest()
    self:InvalidateRound("manifest")
    self.dirty = true
    self:RenderIfNeeded(false)
    return self:GetSnapshot()
end

function C:OnHostChanged()
    if not self.inRoom then
        return self:GetSnapshot()
    end
    local newHost = tonumber(call(self, "hostId")) or call(self, "hostId")
    if sameId(newHost, self.hostId) then
        return self:GetSnapshot()
    end
    self.hostId = newHost
    self.rid = nil
    self.roundPhase = "none"
    self:CancelLocalScan()
    self:ClearSendQueue()
    self.scan = emptyScan()
    self.peerStates = {}
    self.compare = {}
    self.assemblers = {}
    self.results = {}
    self.selfCompare = nil
    self.hostCap = nil
    self.hostSum = nil
    self.hostAcked = false
    self.dirty = true
    if self:IsHost() then
        call(self, "setRoomValue", P.KEYS.ROUND, "")
        call(self, "setRoomValue", P.KEYS.RESULTS, "")
    end
    self:WriteCapability()
    self:WriteSummary()
    self:RenderIfNeeded(true)
    return self:GetSnapshot()
end

function C:Tick()
    if not self.inRoom then
        return self:GetSnapshot()
    end
    self:RefreshParticipants()
    self:CheckManifestChanged()

    local sid = tostr(call(self, "sessionId"))
    if sid ~= self.sid then
        self.sid = sid
        self:InvalidateRound("session")
    end
    local newHost = tonumber(call(self, "hostId")) or call(self, "hostId")
    if not sameId(newHost, self.hostId) then
        self:OnHostChanged()
    end

    if self:IsHost() then
        self:HostTick()
    else
        self:ClientTick()
    end
    self:DrainSendQueue(SEND_PER_TICK)
    return self:RenderIfNeeded(false)
end

CCBModCheckController = C
return C
