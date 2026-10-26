--[[=========================================================================
tests/modcheck/test_multinode.lua

用真实 CCBModCheckProtocol.lua + CCBModCheckController.lua 在 Lua 5.1
（lupa.lua51）里跑多节点仿真：每个节点一个 controller 实例，适配器共享
一个虚拟世界，私聊包按真实收发投递。不是镜像实现。

运行：
  python tests/modcheck/run_tests.py
=========================================================================]]

local ROOT = os.getenv("CCB_TOOLKITS_ROOT")
if not ROOT or ROOT == "" then
    ROOT = "."
end

local function readAll(path)
    local f, err = io.open(path, "rb")
    if not f then
        error("cannot open " .. path .. ": " .. tostring(err))
    end
    local data = f:read("*a")
    f:close()
    return data
end

local luaDir = ROOT:gsub("\\", "/") .. "/MPH/ModCheck/"
assert(loadstring(readAll(luaDir .. "CCBModCheckProtocol.lua"), "@protocol"))()
assert(loadstring(readAll(luaDir .. "CCBModCheckController.lua"), "@controller"))()

local P = assert(rawget(_G, "CCBModCheckProtocol"))
local Ctl = assert(rawget(_G, "CCBModCheckController"))

local WORLD_SERIAL = 0
local failures = 0
local passes = 0

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

local function ok(cond, label)
    if not cond then
        error(label or "assertion failed", 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not string.find(text, needle, 1, true) then
        error(string.format("%s: %q not found in %q", label, needle, tostring(text)), 2)
    end
end

local function hex64(s)
    local out = {}
    for i = 1, 4 do
        out[#out + 1] = P.HashString("native" .. i .. "|" .. s)
    end
    return table.concat(out)
end

--=========================================================================
-- 世界 / 节点
--=========================================================================

local World = {}
World.__index = World

function World.New(hostId, ids)
    WORLD_SERIAL = WORLD_SERIAL + 1
    local w = setmetatable({
        serial = WORLD_SERIAL,
        sid = "sid-" .. WORLD_SERIAL,
        now = 1000,
        hostId = hostId,
        online = {},
        participants = {},
        pv = {},
        room = {},
        outbox = {},
        reminders = {},
        nodes = {},
        packetCount = 0,
        maxPackets = 20000,
    }, World)
    for _, id in ipairs(ids) do
        w:AddParticipant(id)
        w:NewNode(id)
    end
    return w
end

function World:AddParticipant(id, identity)
    self.online[tostring(id)] = true
    for _, p in ipairs(self.participants) do
        if tostring(p.id) == tostring(id) then
            p.identity = identity or p.identity
            return
        end
    end
    self.participants[#self.participants + 1] = {
        id = id,
        name = "Player" .. tostring(id),
        identity = identity or ("ident-" .. tostring(id) .. "-" .. self.serial),
        observer = false,
    }
end

function World:RemoveParticipant(id)
    self.online[tostring(id)] = nil
end

function World:ParticipantList()
    local out = {}
    for _, p in ipairs(self.participants) do
        if self.online[tostring(p.id)] then
            out[#out + 1] = p
        end
    end
    return out
end

function World:NewNode(id, opts)
    opts = opts or {}
    local w = self
    local node = {
        id = id,
        world = w,
        scanCount = 0,
        cancelCount = 0,
        beginCalls = 0,
        getInfoCalls = 0,
        beginManifests = {},
        pollJobs = {},
        skew = opts.skew or 0,
        snapshots = {},
        core = {},
        scanDelay = opts.scanDelay or 0.5,
        coreAvailable = opts.coreAvailable ~= false,
        salt = opts.salt or "salt",
        manifest = opts.manifest or {
            { id = "ccb-core", version = "1", name = "CCB Core", hash = "h-core-" .. (opts.salt or "a") },
            { id = "ccb-ui", version = "2", name = "CCB UI", hash = "h-ui-" .. (opts.salt or "a") },
            { id = "ccb-balance", version = "3", name = "CCB Balance", hash = "h-bal-" .. (opts.salt or "a") },
        },
    }

    local currentJob = nil
    local jobs = 0

    local function manifestSnapshot()
        local out = {}
        for i = 1, #node.manifest do
            local m = node.manifest[i]
            out[#out + 1] = {
                id = tostring(m.id),
                version = tostring(m.version),
                name = tostring(m.name or ""),
                hash = tostring(m.hash),
            }
        end
        return out
    end

    local function computeTotal(mods)
        local rows = {}
        for i = 1, #mods do
            local m = mods[i]
            rows[#rows + 1] = m.id .. "|" .. m.version .. "|" .. m.hash
        end
        table.sort(rows)
        return hex64(table.concat(rows, "\n"))
    end

    function node.core.GetInfo()
        node.getInfoCalls = (node.getInfoCalls or 0) + 1
        if not node.coreAvailable then
            return {
                apiVersion = 1,
                pluginVersion = "0.1.0",
                buildId = "test-build",
                coverage = "ccb-code-v1",
                provider = "Civ6DllLoader",
                available = false,
                errorCode = "CORE_NOT_LOADED",
            }
        end
        return {
            apiVersion = 1,
            pluginVersion = "0.1.0",
            buildId = "test-build",
            coverage = "ccb-code-v1",
            provider = "Civ6DllLoader",
            available = true,
        }
    end

    -- 四个原生接口全部 dot 调用：第一个参数就是业务实参，不能是 core 自身。
    function node.core.BeginScan(manifest)
        ok(manifest ~= node.core, "BeginScan must be dot-called without self")
        node.beginCalls = node.beginCalls + 1
        if not node.coreAvailable then
            return nil, "CORE_NOT_LOADED"
        end
        if type(manifest) ~= "table" or manifest[1] == nil then
            return nil, "BAD_MANIFEST"
        end
        if #manifest > 512 then
            return nil, "TOO_MANY_MODS"
        end
        node.beginManifests[#node.beginManifests + 1] = manifest
        jobs = jobs + 1
        node.scanCount = node.scanCount + 1
        currentJob = {
            id = jobs,
            mods = manifestSnapshot(),
            startedAt = w.now,
            cancelled = false,
        }
        return jobs
    end

    function node.core.PollScan(job)
        ok(type(job) == "number", "PollScan jobId must be the number returned by BeginScan")
        node.pollJobs[#node.pollJobs + 1] = job
        if not currentJob or currentJob.id ~= job then
            return { state = "unknown" }
        end
        if currentJob.cancelled then
            return { state = "cancelled" }
        end
        local elapsed = w.now - currentJob.startedAt
        if elapsed < node.scanDelay then
            return { state = (elapsed < node.scanDelay / 2) and "queued" or "running" }
        end
        return {
            state = "done",
            total = computeTotal(currentJob.mods),
            coverage = "ccb-code-v1",
            complete = true,
            mods = currentJob.mods,
        }
    end

    function node.core.CancelScan(job)
        ok(type(job) == "number", "CancelScan jobId must be a number")
        if currentJob and currentJob.id == job then
            currentJob.cancelled = true
            node.cancelCount = node.cancelCount + 1
            return true
        end
        return false
    end

    node.adapter = {
        now = function()
            return w.now + (node.skew or 0)
        end,
        localId = function()
            return node.id
        end,
        hostId = function()
            return w.hostId
        end,
        sessionId = function()
            return w.sid
        end,
        participants = function()
            return w:ParticipantList()
        end,
        manifest = function()
            local out = {}
            for i = 1, #node.manifest do
                local m = node.manifest[i]
                out[#out + 1] = { id = m.id, version = m.version, name = m.name }
            end
            return out
        end,
        getCore = function()
            -- 返回原生原始表：apiVersion 等元数据只能经 GetInfo 取得。
            return node.core
        end,
        getPlayerValue = function(pid, key)
            local t = w.pv[tostring(pid)]
            return t and t[key] or nil
        end,
        setPlayerValue = function(key, value)
            w.pv[tostring(node.id)] = w.pv[tostring(node.id)] or {}
            w.pv[tostring(node.id)][key] = value
            return true
        end,
        getRoomValue = function(key)
            return w.room[key]
        end,
        setRoomValue = function(key, value)
            w.room[key] = value
            return true
        end,
        sendWhisper = function(pid, text)
            ok(#text <= 180, "packet exceeds 180 bytes: " .. tostring(#text))
            ok(string.sub(text, 1, 7) == "CCBMC1|", "bad packet prefix")
            w.outbox[#w.outbox + 1] = { from = node.id, to = pid, text = text }
            return true
        end,
        sendReminder = function(pid, text)
            w.reminders[#w.reminders + 1] = { from = node.id, to = pid, text = text, at = w.now }
            return true
        end,
        render = function(snapshot)
            node.snapshots[#node.snapshots + 1] = snapshot
            node.snapshot = snapshot
        end,
        log = function(text)
            if os.getenv("CCB_TEST_VERBOSE") == "1" then
                print("    log " .. tostring(node.id) .. ": " .. tostring(text))
            end
        end,
    }

    node.controller = Ctl.New(node.adapter)
    w.nodes[tostring(id)] = node
    return node
end

function World:Flush()
    local guard = 0
    self.packetLog = self.packetLog or {}
    while #self.outbox > 0 do
        guard = guard + 1
        if guard > self.maxPackets then
            error("packet storm: " .. tostring(guard))
        end
        local batch = self.outbox
        self.outbox = {}
        for i = 1, #batch do
            local pkt = batch[i]
            self.packetCount = self.packetCount + 1
            local parsed = P.ParsePacket(pkt.text)
            if parsed then
                parsed.from = pkt.from
                parsed.to = pkt.to
                parsed.raw = pkt.text
                self.packetLog[#self.packetLog + 1] = parsed
            end
            local target = self.nodes[tostring(pkt.to)]
            if target and target.controller then
                target.controller:OnChat(pkt.from, pkt.to, pkt.text, 0)
            end
        end
    end
end

function World:Step(dt, times)
    times = times or 1
    for _ = 1, times do
        self.now = self.now + dt
        local ids = {}
        for id in pairs(self.nodes) do
            ids[#ids + 1] = id
        end
        table.sort(ids, function(a, b)
            return tonumber(a) < tonumber(b)
        end)
        for i = 1, #ids do
            local node = self.nodes[ids[i]]
            if self.online[ids[i]] then
                node.controller:Tick()
            end
        end
        self:Flush()
    end
end

function World:StepUntil(limitSeconds, dt, cond)
    local spent = 0
    while spent <= limitSeconds do
        self:Step(dt, 1)
        spent = spent + dt
        local done = cond()
        if done then
            return spent
        end
    end
    return nil
end

function World:CountType(msgType)
    local n = 0
    for _, pkt in ipairs(self.packetLog or {}) do
        if pkt.type == msgType then
            n = n + 1
        end
    end
    return n
end

function World:RemindersTo(pid)
    local out = {}
    for _, r in ipairs(self.reminders) do
        if tostring(r.to) == tostring(pid) then
            out[#out + 1] = r
        end
    end
    return out
end

function World:PacketsTo(pid)
    local out = {}
    for _, p in ipairs(self.packetLog or {}) do
        if tostring(p.to) == tostring(pid) then
            out[#out + 1] = p
        end
    end
    return out
end

--=========================================================================
-- 场景
--=========================================================================

local scenarios = {}

local function scenario(name, fn)
    scenarios[#scenarios + 1] = { name = name, fn = fn }
end

scenario("enter does not scan and does not create round", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 3)

    eq(host.beginCalls, 0, "host BeginScan after Enter")
    eq(client.beginCalls, 0, "client BeginScan after Enter")
    ok(host.controller.rid == nil, "host must not create round on Enter")
    ok(client.controller.rid == nil, "client must not adopt absent round")
    local hs = host.controller:GetSnapshot()
    eq(hs.checking, false, "host checking")
    eq(hs.canCheck, true, "host canCheck")
    eq(host.controller.rid, nil, "host rid")
    local cs = client.controller:GetSnapshot()
    eq(cs.canCheck, false, "client canCheck without round")
end)

scenario("host check: both green, zero detail packets", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)

    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        local cs = client.controller:GetSnapshot()
        return hs.players[1] and hs.players[1].color == "green"
            and hs.players[2] and hs.players[2].color == "green"
            and cs.players[2] and cs.players[2].color == "green"
            and cs.players[1] and cs.players[1].color == "green"
    end)
    ok(spent, "did not converge to all green")
    eq(w:CountType("L"), 0, "list chunks on identical total")
    eq(w:CountType("Q"), 0, "list requests on identical total")
    eq(#w.reminders, 0, "reminders on all green")
    eq(host.controller:GetSnapshot().summary.red, 0, "host red count")
    eq(client.controller:GetSnapshot().summary.red, 0, "client red count")
    eq(host.scanCount, 1, "host scan count")
    eq(client.scanCount, 1, "client scan count")
end)

scenario("same version different content is red with on-demand details", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    client.manifest[2].hash = "different-file-bytes"
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()

    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "red"
            and hs.players[2].reason == "diff"
            and #hs.players[2].details > 0
    end)
    ok(spent, "content difference did not become red with details")
    local hs = host.controller:GetSnapshot()
    local d = hs.players[2].details[1]
    eq(d.kind, "content", "diff kind")
    eq(d.id, "ccb-ui", "diff id")
    ok(w:CountType("L") > 0, "expected list chunks after mismatch")
    ok(w:CountType("Q") > 0, "expected list request after mismatch")

    local cs = client.controller:GetSnapshot()
    eq(cs.players[2].color, "red", "client self color")
    eq(cs.players[2].reason, "diff", "client self reason")
end)

scenario("missing multiple mods reports missing details", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    table.remove(client.manifest, 3)
    table.remove(client.manifest, 2)
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "red"
            and hs.players[2].count >= 2
    end)
    ok(spent, "missing mods not reported")
    local hs = host.controller:GetSnapshot()
    local kinds = {}
    for _, d in ipairs(hs.players[2].details) do
        kinds[d.kind] = true
    end
    ok(kinds.missing, "expected missing kind")
end)

scenario("no toolbox: protocol silent, one chat reminder, canCheck stays true", function()
    local w = World.New(1, { 1, 2 })
    w:AddParticipant(3)
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(5, 10) -- 50s

    local hs = host.controller:GetSnapshot()
    eq(hs.players[3].color, "yellow", "no toolbox color")
    eq(hs.players[3].reason, "no-response", "no toolbox reason")
    eq(#w:PacketsTo(3), 0, "protocol packets to member without toolbox")
    local rem = w:RemindersTo(3)
    eq(#rem, 1, "reminder count")
    contains(rem[1].text, "工具箱", "no-response reminder text")
    eq(hs.canCheck, true, "canCheck must stay true after no response")

    host.controller:Check()
    w:Step(5, 4)
    eq(#w:RemindersTo(3), 1, "manual recheck must not duplicate reminder")
end)

scenario("no core: yellow, no scan, core reminder", function()
    local w = World.New(1, { 1, 2, 4 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    local nocore = w.nodes["4"]
    nocore.coreAvailable = false
    host.controller:Enter()
    client.controller:Enter()
    nocore.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(3, 6)

    eq(nocore.beginCalls, 0, "no-core member must not BeginScan")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[4].color, "yellow", "no-core color")
    eq(hs.players[4].reason, "no-core", "no-core reason")
    local rem = w:RemindersTo(4)
    eq(#rem, 1, "no-core reminder count")
    contains(rem[1].text, "核心", "no-core reminder text")
end)

scenario("scan timeout 120s does not misreport missing toolbox", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    client.scanDelay = 500
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(5, 26) -- 130s

    local hs = host.controller:GetSnapshot()
    eq(hs.players[2].color, "yellow", "slow scanner color")
    ok(hs.players[2].reason == "scan-timeout" or hs.players[2].reason == "scan-error",
        "slow scanner reason: " .. tostring(hs.players[2].reason))
    eq(#w:RemindersTo(2), 0, "must not remind no-core/no-response for slow scan")
    ok(client.controller.scan.errorCode == "scan-timeout" or client.controller.scan.status == "error",
        "client scan should hit its own 120s timeout")
end)

scenario("late join scans only the newcomer", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "green"
    end)
    ok(spent, "baseline did not turn green")
    local hostScans = host.scanCount
    local clientScans = client.scanCount

    w:AddParticipant(4)
    local late = w:NewNode(4, { salt = "late" })
    late.manifest[#late.manifest + 1] = {
        id = "ccb-extra", version = "1", name = "CCB Extra", hash = "h-extra",
    }
    late.controller:Enter()
    w:Step(0.25, 8)

    eq(host.scanCount, hostScans, "host must not rescan on late join")
    eq(client.scanCount, clientScans, "existing client must not rescan on late join")
    eq(late.scanCount, 1, "newcomer scan count")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[2].color, "green", "existing client still green")
    eq(hs.players[4].color, "red", "late joiner differs")
end)

scenario("manifest change cancels scan, invalidates round, no auto check", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.scanDelay = 20
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(0.5, 2)
    local scans = host.scanCount

    host.manifest[1].version = "9"
    w:Step(0.5, 2)
    ok(host.cancelCount >= 1, "scan should be cancelled on manifest change")
    eq(host.controller.rid, nil, "round cleared on manifest change")
    eq(w.room[P.KEYS.ROUND] or "", "", "room round cleared")
    w:Step(0.5, 4)
    eq(host.scanCount, scans, "must not auto-start a new scan")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[2].color, "yellow", "peer yellow after invalidation")
end)

scenario("host change invalidates without auto check", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        return host.controller:GetSnapshot().players[2]
            and host.controller:GetSnapshot().players[2].color == "green"
    end)
    ok(spent, "setup not green")
    local scans = host.scanCount + client.scanCount

    w.hostId = 2
    w:Step(0.5, 3)
    eq(host.controller.rid, nil, "old host rid cleared")
    eq(client.controller.rid, nil, "new host rid cleared")
    eq(host.scanCount + client.scanCount, scans, "no auto scan after host change")
    local ns = client.controller:GetSnapshot()
    eq(ns.role, "host", "client becomes host")
    eq(ns.canCheck, true, "new host can check")
end)

scenario("replayed old connection packet rejected, slot reuse resets results", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(0.25, 4)

    local oldHello, oldSummary
    for _, p in ipairs(w.packetLog) do
        if p.type == "H" and tostring(p.from) == "2" then
            oldHello = oldHello or p
        elseif p.type == "S" and tostring(p.from) == "2" then
            oldSummary = p
        end
    end
    ok(oldHello, "expected hello packet from client")
    ok(oldSummary, "expected summary packet from client")

    client.controller:Leave()
    w:RemoveParticipant(2)
    w:Step(0.2, 2)
    w:AddParticipant(2, "ident-rejoined-2")
    client.controller:Enter()
    w:Step(0.2, 2)

    local raw = P.BuildPacket(oldHello)
    ok(raw, "rebuild old hello")
    host.controller:OnChat("2", "1", raw, 0)
    ok(host.controller.lastProtocolError == "STALE_CONNECTION"
        or host.controller.lastProtocolError == "OLD_TOKEN"
        or host.controller.lastProtocolError == "STALE_ROUND",
        "old connection packet must be rejected, got " .. tostring(host.controller.lastProtocolError))

    -- 旧连接的逐 Mod 摘要/结果也不得复用
    host.controller.lastProtocolError = nil
    host.controller:OnChat("2", "1", P.BuildPacket(oldSummary), 0)
    eq(host.controller.lastProtocolError, "STALE_CONNECTION", "old summary rejected")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[2].color, "yellow", "old slot results cleared after rejoin")
end)

scenario("wrong sender, request, recipient and session rejected", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 3)
    host.controller:Check()
    w:Step(0.25, 4)

    local rid = host.controller.rid
    ok(rid, "host rid exists")
    local cap = client.controller.cap
    ok(cap and cap.token, "client cap token")

    local function pkt(over)
        local msg = {
            type = "H",
            rid = rid,
            sid = w.sid,
            host = "1",
            from = "2",
            to = "1",
            token = cap.token,
            request = P.DeriveRequest(rid, cap.token, "req"),
            fields = { "1", "checking", "", "0", "ccb-code-v1", "Civ6DllLoader", "0", "" },
        }
        for k, v in pairs(over or {}) do
            msg[k] = v
        end
        return P.BuildPacket(msg)
    end

    host.controller:OnChat("2", "1", pkt({ from = "1" }), 0)
    eq(host.controller.lastProtocolError, "FAKE_SENDER", "fake sender")

    host.controller:OnChat("2", "1", pkt({ request = "deadbeefcafe" }), 0)
    eq(host.controller.lastProtocolError, "BAD_REQUEST", "bad request")

    host.controller:OnChat("2", "1", pkt({ to = "9" }), 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "misdirected")

    host.controller:OnChat("2", "1", pkt({ sid = "other-sid" }), 0)
    eq(host.controller.lastProtocolError, "STALE_SESSION", "stale session")

    host.controller:OnChat("2", "1", pkt({ rid = "old-round" }), 0)
    eq(host.controller.lastProtocolError, "STALE_ROUND", "stale round")

    -- 已离开/不在名单的旧成员
    host.controller.lastProtocolError = nil
    host.controller:OnChat("3", "1", pkt({ from = "3" }), 0)
    eq(host.controller.lastProtocolError, "NON_MEMBER", "old member rejected")
end)

scenario("duplicate packets are idempotent", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    client.manifest[3].hash = "diff-hash"
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()

    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "red"
            and hs.players[2].reason == "diff"
            and #hs.players[2].details > 0
    end)
    ok(spent, "did not become red with details")

    local chunk
    local hello
    for _, p in ipairs(w.packetLog) do
        if p.type == "L" and tostring(p.from) == "2" then
            chunk = p
        elseif p.type == "H" and tostring(p.from) == "2" then
            hello = p
        end
    end
    ok(chunk, "expected list chunk")
    ok(hello, "expected hello")
    local rawChunk = chunk.raw
    local rawHello = hello.raw
    host.controller.lastProtocolError = nil
    host.controller:OnChat("2", "1", rawChunk, 0)
    host.controller:OnChat("2", "1", rawChunk, 0)
    host.controller:OnChat("2", "1", rawHello, 0)
    eq(host.controller.lastProtocolError, nil, "duplicate packets must not error")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[2].color, "red", "still red after duplicates")
end)

scenario("protocol and manifest limits", function()
    local huge = {}
    for i = 1, 600 do
        huge[i] = { id = "mod-" .. i, version = "1", name = "M" .. i, hash = "h" .. i }
    end
    local packets, err = P.BuildListPackets({
        rid = "r", sid = "s", host = "1", from = "1", to = "2",
        token = P.NewToken("t"), request = P.DeriveRequest("r", P.NewToken("t"), "list"),
        digest = P.HashMods(huge), mods = huge,
    })
    eq(packets, nil, "600-mod list must be rejected")
    ok(err == "TOO_MANY_MODS", "expected TOO_MANY_MODS, got " .. tostring(err))

    local long = "CCBMC1|H|r|s|1|1|2|" .. string.rep("a", 200)
    local parsed, perr = P.ParsePacket(long)
    eq(parsed, nil, "oversized packet rejected")
    ok(perr == "PACKET_TOO_LONG" or perr == "BAD_PACKET", "oversize error " .. tostring(perr))

    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.manifest = {}
    for i = 1, 600 do
        host.manifest[i] = { id = "m-" .. i, version = "1", name = "M" .. i, hash = "h" .. i }
    end
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(0.5, 3)
    eq(host.beginCalls, 0, "controller must reject >512 manifest before scanning")
    local hs = host.controller:GetSnapshot()
    eq(hs.players[1].color, "yellow", "oversized manifest yellow")
    ok(host.controller.scan.errorCode == "MANIFEST_TOO_LARGE"
        or host.controller.scan.errorCode == "TOO_MANY_MODS",
        "oversize scan error " .. tostring(host.controller.scan.errorCode))
end)

scenario("manual recheck does not resend reminder", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    client.manifest[1].hash = "changed"
    host.controller:Enter()
    client.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        return #w:RemindersTo(2) == 1
    end)
    ok(spent, "expected first diff reminder")
    w:Step(5, 12) -- 60s, 越过冷却
    host.controller:Check()
    w:Step(1, 10)
    eq(#w:RemindersTo(2), 1, "manual recheck must not resend reminder")
end)

--=========================================================================
-- 原生接口 / 队列 / 连接 token / 时钟
--=========================================================================

local function enterAll(w, ids)
    for _, id in ipairs(ids) do
        local n = w.nodes[tostring(id)]
        if n then
            n.controller:Enter()
        end
    end
end

local function bigManifest(count)
    local out = {}
    for i = 1, count do
        out[i] = {
            id = string.format("mod-%03d", i),
            version = "1",
            name = "M" .. i,
            hash = "hash-" .. tostring(i) .. "-0123456789abcdef0123456789abcdef",
        }
    end
    return out
end

scenario("native core is dot-called: GetInfo, manifest and numeric jobId", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "green"
    end)
    ok(spent, "did not turn green")

    -- fake 内部已在 BeginScan/PollScan 断言“第一个参数不是 core 自身”。
    ok(host.beginCalls >= 1, "BeginScan must be called")
    eq(host.beginCalls, 1, "host BeginScan exactly once")
    ok(host.getInfoCalls >= 1, "GetInfo must be called")
    local m = host.beginManifests[1]
    ok(type(m) == "table" and #m == 3, "BeginScan first arg must be the manifest array")
    eq(m[1].id, "ccb-core", "manifest first id")
    ok(type(host.pollJobs[1]) == "number", "PollScan jobId must be number")
    ok(type(client.pollJobs[1]) == "number", "client PollScan jobId must be number")
    eq(host.cancelCount, 0, "no cancel on clean scan")
end)

scenario("wrong GetInfo stays yellow and never scans", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.core.GetInfo = function()
        return {
            apiVersion = 2,
            pluginVersion = "0.1.0",
            buildId = "test-build",
            coverage = "ccb-code-v1",
            provider = "Civ6DllLoader",
            available = true,
        }
    end
    enterAll(w, { 1, 2 })
    w:Step(0.2, 3)
    local hs = host.controller:GetSnapshot()
    eq(hs.players[1].color, "yellow", "wrong GetInfo yellow")
    eq(hs.players[1].reason, "core-unavailable", "wrong GetInfo reason")
    eq(hs.canCheck, false, "wrong GetInfo cannot check")
    host.controller:Check()
    w:Step(0.2, 3)
    eq(host.beginCalls, 0, "must never scan with incompatible GetInfo")
end)

scenario("client clock skew +/-1h uses host-local scan receipts", function()
    -- +1h：客机时钟超前。宿主必须按自己的接收时刻在 120s 后判超时；
    -- 旧实现用客机 cap.startedAt+120，会永远停在 checking。
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(0.25, 4)
    local cap = client.controller.cap
    ok(cap and cap.token, "client cap ready")
    local fake = {
        rid = host.controller.rid,
        apiVersion = 1,
        pluginVersion = "0.1.0",
        buildId = "test-build",
        coverage = "ccb-code-v1",
        provider = "Civ6DllLoader",
        available = true,
        errorCode = "",
        token = cap.token,
        status = "checking",
        startedAt = w.now + 3600,
        count = 0,
        total = "",
    }
    w.pv["2"][P.KEYS.CAP] = P.EncodeCapability(fake)
    for _ = 1, 26 do
        w.now = w.now + 5
        host.controller:Tick()
    end
    local slow = host.controller:GetSnapshot()
    eq(slow.players[2].reason, "scan-timeout", "+1h skew must time out on host clock")
    eq(#w:RemindersTo(2), 0, "scan timeout must not become a toolbox reminder")

    -- -1h：客机时钟落后。1s 时仍是 checking（不能拿客机本地时间直接比），
    -- 扫描完成后转绿且不提醒。
    local w2 = World.New(1, { 1, 2 })
    local host2 = w2.nodes["1"]
    local client2 = w2.nodes["2"]
    client2.skew = -3600
    client2.scanDelay = 5
    enterAll(w2, { 1, 2 })
    w2:Step(0.2, 2)
    host2.controller:Check()
    w2:Step(0.25, 4)
    eq(host2.controller:GetSnapshot().players[2].reason, "checking", "-1h skew must still be checking")
    local spent = w2:StepUntil(15, 0.25, function()
        local s = host2.controller:GetSnapshot()
        return s.players[2] and s.players[2].color == "green"
    end)
    ok(spent, "-1h skew did not turn green")
    eq(host2.controller:GetSnapshot().players[2].reason, "ok", "-1h skew reason")
    eq(#w2:RemindersTo(2), 0, "-1h skew must not remind")
end)
scenario("engine recipient, packet recipient, sender, request and token enforced", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    enterAll(w, { 1, 2 })
    w:Step(0.2, 3)
    host.controller:Check()
    w:Step(0.2, 3)

    local rid = host.controller.rid
    local cap = client.controller.cap
    ok(rid and cap and cap.token, "fixture ready")
    local function pkt(over)
        local msg = {
            type = "H", rid = rid, sid = w.sid, host = "1",
            from = "2", to = "1", token = cap.token,
            request = P.DeriveRequest(rid, cap.token, "req"),
            fields = { "1", "checking", "", "0", "ccb-code-v1", "Civ6DllLoader", "0", "" },
        }
        for k, v in pairs(over or {}) do
            msg[k] = v
        end
        return P.BuildPacket(msg)
    end

    local valid = pkt()
    host.controller:OnChat("2", "1", valid, 0)
    eq(host.controller.lastProtocolError, nil, "valid hello accepted")

    -- 真实引擎 to 必须是本机；广播/空/错人一律拒绝。
    host.controller:OnChat("2", "", valid, 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "broadcast engine to")
    host.controller:OnChat("2", "-1", valid, 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "broadcast -1 engine to")
    host.controller:OnChat("2", "9", valid, 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "engine to other player")

    -- 包内 to 同样必须是本机。
    host.controller:OnChat("2", "1", pkt({ to = "" }), 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "empty packet to")
    host.controller:OnChat("2", "1", pkt({ to = "9" }), 0)
    eq(host.controller.lastProtocolError, "MISDIRECTED", "packet to other player")

    host.controller:OnChat("2", "1", pkt({ from = "1" }), 0)
    eq(host.controller.lastProtocolError, "FAKE_SENDER", "wrong from")

    host.controller:OnChat("2", "1", pkt({ request = "000000000000" }), 0)
    eq(host.controller.lastProtocolError, "BAD_REQUEST", "wrong nonce/request")

    host.controller:OnChat("2", "1", pkt({ token = "deadbeefdeadbeef" }), 0)
    eq(host.controller.lastProtocolError, "STALE_CONNECTION", "wrong connection token")
end)

scenario("list details go through a bounded 8-per-tick send queue", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.manifest = bigManifest(120)
    client.manifest = bigManifest(120)
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "green"
    end)
    ok(spent, "big identical manifest did not turn green")
    eq(w:CountType("L"), 0, "identical SHA256 must not send any detail chunk")

    client.controller:ClearSendQueue()
    eq(client.controller:SendList(1), true, "enqueue detail list")
    local queued = #client.controller.sendQueue
    ok(queued > 8, "fixture should produce more than 8 chunks, got " .. tostring(queued))

    local before = w:CountType("L")
    w:Step(0.25, 1)
    local delta = w:CountType("L") - before
    ok(delta <= 8, "one tick must send at most 8 packets, sent " .. tostring(delta))
    ok(delta > 0, "queue must make progress")

    local drained = w:StepUntil(60, 0.25, function()
        return #client.controller.sendQueue == 0
    end)
    ok(drained, "queue did not drain")
    eq(w:CountType("L") - before, queued, "all queued chunks delivered")
    eq(host.controller:GetSnapshot().players[2].color, "green", "still green after list")
end)

scenario("send queue expires after 120s and is cleared on round change", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.manifest = bigManifest(120)
    client.manifest = bigManifest(120)
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "green"
    end)
    ok(spent, "setup not green")

    client.controller:ClearSendQueue()
    eq(client.controller:SendList(1), true, "enqueue for expiry")
    local queued = #client.controller.sendQueue
    local before = w:CountType("L")
    w.now = w.now + 121
    eq(client.controller:DrainSendQueue(), 0, "expired packets must not be sent")
    eq(#client.controller.sendQueue, 0, "expired queue empty")
    eq(w:CountType("L"), before, "no expired packet on wire")
    eq(client.controller.sendDropped, queued, "all dropped as expired")

    -- 换轮：残留队列直接清空。
    eq(client.controller:SendList(1), true, "enqueue for round change")
    ok(#client.controller.sendQueue > 0, "queue refilled")
    host.controller:Check()
    w:Step(0.25, 3)
    eq(#client.controller.sendQueue, 0, "round change must clear queue")
end)

scenario("per-peer queue is bounded by 256KiB and Leave clears it", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.manifest = bigManifest(120)
    client.manifest = bigManifest(120)
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    ok(w:StepUntil(10, 0.25, function()
        local hs = host.controller:GetSnapshot()
        return hs.players[2] and hs.players[2].color == "green"
    end), "setup not green")

    client.controller:ClearSendQueue()
    local refused = false
    for _ = 1, 200 do
        if not client.controller:SendList(1) then
            refused = true
            break
        end
    end
    ok(refused, "queue must refuse beyond 256KiB per peer")
    ok((client.controller.sendQueueBytes["1"] or 0) <= 262144, "queue bytes bounded")
    local errs = table.concat(client.controller.errors, ",")
    contains(errs, "QUEUE_OVERFLOW", "overflow must be recorded")

    client.controller:Leave()
    eq(#client.controller.sendQueue, 0, "Leave clears send queue")
    eq(client.controller.sendQueueBytes["1"], nil, "Leave clears per-peer bytes")
end)

scenario("RESULTS rows are bound to the current connection token", function()
    local enc = P.EncodeResults("r1", {
        { pid = 2, color = "green", code = "ok", count = 0, token = "abcd1234" },
    })
    local dec = P.DecodeResults(enc)
    eq(dec.players[1].token, "abcd1234", "RES token roundtrip")

    local w = World.New(1, { 1, 2, 3 })
    local host = w.nodes["1"]
    local c2 = w.nodes["2"]
    local c3 = w.nodes["3"]
    enterAll(w, { 1, 2, 3 })
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(15, 0.25, function()
        local s = host.controller:GetSnapshot()
        return s.players[2] and s.players[2].color == "green"
            and s.players[3] and s.players[3].color == "green"
            and host.controller:GetSnapshot().players[1].color == "green"
    end)
    ok(spent, "3-node setup not green")
    w:Step(1, 4)

    local oldRaw = w.room[P.KEYS.RESULTS]
    local oldDec = P.DecodeResults(oldRaw)
    local oldToken = c2.controller.token
    local oldRow
    for _, row in ipairs(oldDec.players) do
        if tostring(row.pid) == "2" then
            oldRow = row
        end
    end
    ok(oldRow and oldRow.color == "green", "old RES row green")
    eq(oldRow.token, oldToken, "old RES row carries connection token")

    c2.controller:Leave()
    w:RemoveParticipant(2)
    w:Step(0.2, 2)
    w:AddParticipant(2, "ident-rejoined-for-res")
    c2.controller:Enter()
    w:Step(0.2, 2)
    ok(c2.controller.token ~= oldToken, "rejoined member gets a new token")

    -- 把槽位复用前的旧 RES 塞回房间；客户端 Tick 不能把旧绿色当本轮结果。
    w.room[P.KEYS.RESULTS] = oldRaw
    c3.controller:Tick()
    local snap = c3.controller:GetSnapshot()
    eq(snap.players[2].color, "yellow", "stale RES green must not survive slot reuse")
    ok(snap.players[2].reason ~= "ok", "stale RES reason must not be ok")
end)

scenario("reminders: once per identity, 2s spacing, rejoin cooldown", function()
    local w = World.New(1, { 1, 2, 3 })
    local host = w.nodes["1"]
    local c2 = w.nodes["2"]
    local c3 = w.nodes["3"]
    c2.manifest[1].hash = "diff-two"
    c3.manifest[1].hash = "diff-three"
    enterAll(w, { 1, 2, 3 })
    w:Step(0.2, 2)
    host.controller:Check()
    local spent = w:StepUntil(30, 0.25, function()
        return #w:RemindersTo(2) >= 1 and #w:RemindersTo(3) >= 1
    end)
    ok(spent, "expected one reminder per differing member")
    w:Step(0.25, 8)
    local r2 = w:RemindersTo(2)
    local r3 = w:RemindersTo(3)
    eq(#r2, 1, "member 2 reminded once")
    eq(#r3, 1, "member 3 reminded once")
    ok(math.abs(r3[1].at - r2[1].at) >= 1.999, "reminders must be >=2s apart")

    -- 同 identity 60s 内重进：不再提醒。
    local identity = w.participants[3].identity
    c3.controller:Leave()
    w:RemoveParticipant(3)
    w:Step(0.2, 2)
    w:AddParticipant(3, identity)
    c3.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(1, 12)
    eq(#w:RemindersTo(3), 1, "rejoin within 60s must not remind again")

    -- 冷却期满（>60s）后同 identity 重进，允许再提醒一次。
    c3.controller:Leave()
    w:RemoveParticipant(3)
    w:Step(5, 14) -- +70s
    w:AddParticipant(3, identity)
    c3.controller:Enter()
    w:Step(0.2, 2)
    host.controller:Check()
    local again = w:StepUntil(20, 0.25, function()
        return #w:RemindersTo(3) >= 2
    end)
    ok(again, "identity cooldown must expire after 60s")
end)

scenario("failed scan keeps manual recheck enabled", function()
    local w = World.New(1, { 1, 2 })
    local host = w.nodes["1"]
    local client = w.nodes["2"]
    host.manifest = bigManifest(600)
    enterAll(w, { 1, 2 })
    w:Step(0.2, 2)
    host.controller:Check()
    w:Step(0.5, 3)
    eq(host.controller.scan.status, "error", "oversized manifest must fail the scan")
    eq(host.controller:GetSnapshot().canCheck, true, "check button must not stay disabled")

    -- 修正清单后可再次发起扫描，而不是永久禁用。
    host.manifest = bigManifest(3)
    w:Step(0.25, 2)
    local before = host.beginCalls
    host.controller:Check()
    w:Step(0.25, 3)
    ok(host.beginCalls > before, "manual recheck after failure must scan again")
    ok(host.controller.rid ~= nil, "recheck must create a fresh round")
end)

--=========================================================================
-- 运行
--=========================================================================

local only = os.getenv("CCB_TEST_ONLY")
print(string.format("Lua: %s / CCB ModCheck real-module multinode tests", _VERSION))
for _, sc in ipairs(scenarios) do
    local selected = (not only or only == "" or string.find(sc.name, only, 1, true) ~= nil)
    if selected then
        local okRun, er = pcall(sc.fn)
        if okRun then
            passes = passes + 1
            print("PASS  " .. sc.name)
        else
            failures = failures + 1
            print("FAIL  " .. sc.name)
            print("      " .. tostring(er))
        end
    end
end

print(string.format("RESULT: %d passed, %d failed", passes, failures))
if failures > 0 then
    error(string.format("%d scenario(s) failed", failures))
end
