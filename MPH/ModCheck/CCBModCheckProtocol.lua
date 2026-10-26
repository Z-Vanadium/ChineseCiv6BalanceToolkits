--[[=========================================================================
CCBModCheckProtocol.lua

CCB MOD Check 的纯 Lua 协议层：序列化 / 分片 / 重组 / 比较辅助。
不引用 Controls、UI、引擎 API；Lua 5.1 兼容。

安全边界：
  * 单包 <= 180 字节；单个成员清单 <= 256 KiB；Mod 数 <= 512。
  * 包内 from/to/host/session/round/token/request 都必须由控制器按真实
    引擎发送者与成员连接身份校验；本文件只负责解析与长度限制。
  * P.HashString 是 16 hex 的短校验，只用于连接 token / request 派生 /
    清单传输校验，绝不作为“文件一致”的绿灯判据。正式绿灯必须使用原生
    PollScan.done.total（64 hex SHA256）。

线格式（所有字段经 Escape 转义）：
  CCBMC1|<type>|<rid>|<sid>|<host>|<from>|<to>|<token>|<request>|<body>
  type: P 探针 / H HELLO / A ACK / S 摘要 / Q 详单请求 / L 详单分片 / X 取消
  L body: <seq>|<chunks>|<transportDigest>|<chunkText>
=========================================================================]]

local P = {}

P.API_VERSION = 1
P.PREFIX = "CCBMC1|"
P.MAGIC = "CCBMC1"
P.COVERAGE = "ccb-code-v1"

P.MAX_PACKET_BYTES = 180
P.MAX_LIST_BYTES = 262144
P.MAX_MODS = 512
P.MAX_CHUNKS = 4096

P.T = {
    PROBE = "P",
    HELLO = "H",
    ACK = "A",
    SUMMARY = "S",
    LIST_REQ = "Q",
    LIST_CHUNK = "L",
    CANCEL = "X",
}

P.KEYS = {
    CAP = "CCBMC_CAP",
    SUMMARY = "CCBMC_SUM",
    ROUND = "CCBMC_ROUND",
    RESULTS = "CCBMC_RES",
}

P.COLOR = { GREEN = "green", RED = "red", YELLOW = "yellow" }

P.CODE = {
    OK = "ok",
    DIFF = "diff",
    CHECKING = "check",
    NO_RESPONSE = "noresp",
    NO_CORE = "nocore",
    STALE = "stale",
    ERROR = "error",
    WAIT = "wait",
}

local ESCAPE_MAP = {
    ["%"] = "%25",
    ["|"] = "%7C",
    [";"] = "%3B",
    [","] = "%2C",
    ["\r"] = "%0D",
    ["\n"] = "%0A",
}

local UNESCAPE_MAP = {
    ["25"] = "%",
    ["7C"] = "|",
    ["3B"] = ";",
    ["2C"] = ",",
    ["0D"] = "\r",
    ["0A"] = "\n",
}

local function tostr(v)
    if v == nil then
        return ""
    end
    return tostring(v)
end

--=========================================================================
-- 基础工具
--=========================================================================

function P.Escape(value)
    if value == nil then
        return ""
    end
    return (string.gsub(tostring(value), "[%%|;,\r\n]", ESCAPE_MAP))
end

function P.Unescape(value)
    if value == nil then
        return ""
    end
    return (string.gsub(tostring(value), "%%(%x%x)", function(hex)
        return UNESCAPE_MAP[string.upper(hex)]
    end))
end

-- 保留空字段的切分
function P.SplitText(text, sep)
    local out = {}
    local pos = 1
    if text == nil then
        return out
    end
    while true do
        local s, e = string.find(text, sep, pos, true)
        if not s then
            out[#out + 1] = string.sub(text, pos)
            return out
        end
        out[#out + 1] = string.sub(text, pos, s - 1)
        pos = e + 1
    end
end

function P.EncodeFields(fields)
    local out = {}
    for i = 1, #fields do
        out[i] = P.Escape(fields[i])
    end
    return table.concat(out, "|")
end

function P.DecodeFields(text)
    if text == nil or text == "" then
        return {}
    end
    local parts = P.SplitText(text, "|")
    for i = 1, #parts do
        parts[i] = P.Unescape(parts[i])
    end
    return parts
end

-- 16 hex 短校验。只用于 token / request / 清单传输完整性，不作绿灯判据。
function P.HashString(s)
    s = tostr(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = string.byte(s, i)
        h1 = (h1 * 33 + b) % 4294967291
        h2 = (h2 * 31 + b) % 4294967279
    end
    return string.format("%08x%08x", h1, h2)
end

function P.NormalizeId(id)
    return string.lower(tostr(id))
end

function P.SanitizeName(name, maxChars)
    local s = tostr(name)
    s = string.gsub(s, "[\r\n\t]", " ")
    s = string.gsub(s, "%c", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    local limit = maxChars or 32
    if #s > limit then
        s = string.sub(s, 1, limit)
    end
    return s
end

-- 原生 PollScan.done.total 必须是 64 hex SHA256；缺失/过短/非 hex 一律不能绿。
function P.ValidTotal(total)
    if type(total) ~= "string" or #total ~= 64 then
        return false
    end
    return string.match(total, "^[0-9a-fA-F]+$") ~= nil
end

function P.ValidToken(token)
    if type(token) ~= "string" then
        return false
    end
    if #token < 8 or #token > 32 then
        return false
    end
    return string.match(token, "^[0-9a-fA-F]+$") ~= nil
end

local tokenSeq = 0

-- 连接 token：同一 controller 的 Enter 生成新 token；槽位复用/重进不会复用。
function P.NewToken(seed)
    tokenSeq = tokenSeq + 1
    return P.HashString("tok|" .. tostr(seed) .. "|" .. tostr(tokenSeq))
end

-- request 绑定 rid + 连接 token + 用途；旧连接/旧轮的 request 无法通过。
function P.DeriveRequest(rid, token, purpose)
    return string.sub(P.HashString("req|" .. tostr(rid) .. "|" .. tostr(token)
        .. "|" .. tostr(purpose)), 1, 12)
end

--=========================================================================
-- Mod 清单规范化 / 摘要 / 比较
--=========================================================================

function P.NormalizeMods(raw)
    if type(raw) ~= "table" then
        return nil, "BAD_MODS"
    end
    if #raw > P.MAX_MODS then
        return nil, "TOO_MANY_MODS"
    end
    local out = {}
    local seen = {}
    for i = 1, #raw do
        local item = raw[i]
        if type(item) ~= "table" then
            return nil, "BAD_MOD_ITEM"
        end
        local id = item.id
        if id == nil or (type(id) ~= "string" and type(id) ~= "number") then
            return nil, "BAD_MOD_ID"
        end
        id = tostring(id)
        if id == "" then
            return nil, "BAD_MOD_ID"
        end
        local key = P.NormalizeId(id)
        if seen[key] then
            return nil, "DUPLICATE_MOD_ID"
        end
        seen[key] = true

        local version = item.version
        if version == nil then
            version = ""
        elseif type(version) ~= "string" and type(version) ~= "number" then
            return nil, "BAD_MOD_VERSION"
        end
        version = tostring(version)

        local official = (item.official == true or item.official == 1
            or item.official == "1" or item.official == "true")
        local hash = item.hash
        if hash == nil then
            hash = ""
        else
            hash = tostring(hash)
        end
        if official then
            hash = ""
        elseif hash == "" then
            return nil, "MISSING_MOD_HASH"
        end

        local rec = {
            id = id,
            version = version,
            hash = hash,
            official = official,
        }
        if item.name ~= nil then
            rec.name = tostring(item.name)
        end
        out[#out + 1] = rec
    end

    table.sort(out, function(a, b)
        return P.NormalizeId(a.id) < P.NormalizeId(b.id)
    end)
    return out
end

function P.ModRow(mod)
    return table.concat({
        P.Escape(mod.id),
        P.Escape(mod.version),
        P.Escape(mod.hash or ""),
        mod.official and "1" or "0",
    }, ",")
end

-- 传输校验摘要（16 hex）。只用于确认分片重组后文本未损坏，不是绿灯判据。
function P.HashMods(mods)
    local rows = {}
    for i = 1, #mods do
        local m = mods[i]
        rows[#rows + 1] = table.concat({
            P.NormalizeId(m.id),
            "|",
            tostring(m.version),
            "|",
            tostring(m.hash or ""),
            "|",
            m.official and "1" or "0",
        })
    end
    return P.HashString("list-v1\n" .. table.concat(rows, "\n"))
end

-- 传输格式：每行 id,version,hash,official，行间 ";"
function P.EncodeModList(mods)
    local rows = {}
    for i = 1, #mods do
        rows[#rows + 1] = P.ModRow(mods[i])
    end
    return table.concat(rows, ";")
end

function P.DecodeModList(text)
    if type(text) ~= "string" or text == "" then
        return nil, "EMPTY_LIST"
    end
    if #text > P.MAX_LIST_BYTES then
        return nil, "LIST_TOO_LARGE"
    end
    local rawRows = P.SplitText(text, ";")
    if #rawRows > P.MAX_MODS then
        return nil, "TOO_MANY_MODS"
    end
    local out = {}
    local seen = {}
    for i = 1, #rawRows do
        local row = rawRows[i]
        if row ~= "" then
            local cells = P.SplitText(row, ",")
            if #cells ~= 4 then
                return nil, "BAD_LIST_ROW"
            end
            local id = P.Unescape(cells[1])
            if id == "" then
                return nil, "BAD_LIST_ROW"
            end
            local key = P.NormalizeId(id)
            if seen[key] then
                return nil, "DUPLICATE_MOD_ID"
            end
            seen[key] = true
            local official = (cells[4] == "1")
            local hash = P.Unescape(cells[3])
            if not official and hash == "" then
                return nil, "BAD_LIST_ROW"
            end
            out[#out + 1] = {
                id = id,
                version = P.Unescape(cells[2]),
                hash = official and "" or hash,
                official = official,
            }
        end
    end
    if #out == 0 then
        return nil, "EMPTY_LIST"
    end
    table.sort(out, function(a, b)
        return P.NormalizeId(a.id) < P.NormalizeId(b.id)
    end)
    return out
end

-- 逐项比较；差异只有“红”的语义，调用方决定未知/错误用黄。
function P.CompareLists(localMods, remoteMods)
    local result = { equal = false, diffs = {}, compared = 0 }
    if type(localMods) ~= "table" or type(remoteMods) ~= "table" then
        return result
    end
    local localMap = {}
    for i = 1, #localMods do
        local m = localMods[i]
        localMap[P.NormalizeId(m.id)] = m
    end
    local remoteMap = {}
    for i = 1, #remoteMods do
        local m = remoteMods[i]
        remoteMap[P.NormalizeId(m.id)] = m
    end

    local ids = {}
    for key in pairs(localMap) do
        ids[#ids + 1] = key
    end
    for key in pairs(remoteMap) do
        if not localMap[key] then
            ids[#ids + 1] = key
        end
    end
    table.sort(ids)

    for i = 1, #ids do
        local key = ids[i]
        local a = localMap[key]
        local b = remoteMap[key]
        result.compared = result.compared + 1
        if a == nil then
            result.diffs[#result.diffs + 1] = {
                kind = "missing",
                id = b.id,
                remoteVersion = b.version,
                name = b.name,
            }
        elseif b == nil then
            result.diffs[#result.diffs + 1] = {
                kind = "extra",
                id = a.id,
                localVersion = a.version,
                name = a.name,
            }
        elseif tostring(a.version) ~= tostring(b.version) then
            result.diffs[#result.diffs + 1] = {
                kind = "version",
                id = a.id,
                localVersion = a.version,
                remoteVersion = b.version,
                name = a.name,
            }
        elseif (not a.official) and (tostring(a.hash) ~= tostring(b.hash)) then
            result.diffs[#result.diffs + 1] = {
                kind = "content",
                id = a.id,
                localVersion = a.version,
                remoteVersion = b.version,
                name = a.name,
            }
        end
    end

    result.equal = (#result.diffs == 0)
    return result
end

--=========================================================================
-- 配置键值（能力 / 摘要 / 轮次 / 短结果）
--=========================================================================

-- CAP：rid|api|plugin|build|coverage|provider|available|errorCode|token|status|startedAt|count|total
function P.EncodeCapability(cap)
    cap = cap or {}
    return P.PREFIX .. "CAP|" .. P.EncodeFields({
        tostr(cap.rid),
        tostr(cap.apiVersion or P.API_VERSION),
        tostr(cap.pluginVersion),
        tostr(cap.buildId),
        tostr(cap.coverage),
        tostr(cap.provider),
        cap.available and "1" or "0",
        tostr(cap.errorCode),
        tostr(cap.token),
        tostr(cap.status),
        tostr(cap.startedAt or 0),
        tostr(cap.count or 0),
        tostr(cap.total),
    })
end

function P.DecodeCapability(text)
    if type(text) ~= "string" then
        return nil, "NOT_TEXT"
    end
    local tag = P.PREFIX .. "CAP|"
    if string.sub(text, 1, #tag) ~= tag then
        return nil, "NOT_CAP"
    end
    local f = P.DecodeFields(string.sub(text, #tag + 1))
    if #f < 13 then
        return nil, "BAD_CAP"
    end
    local apiVersion = tonumber(f[2])
    if apiVersion ~= P.API_VERSION then
        return nil, "API_MISMATCH"
    end
    return {
        rid = f[1],
        apiVersion = apiVersion,
        pluginVersion = f[3],
        buildId = f[4],
        coverage = f[5],
        provider = f[6],
        available = (f[7] == "1"),
        errorCode = f[8],
        token = f[9],
        status = f[10],
        startedAt = tonumber(f[11]) or 0,
        count = tonumber(f[12]) or 0,
        total = f[13],
    }
end

-- SUM：rid|token|status|total|count|startedAt|coverage|provider|time|errorCode
function P.EncodeSummary(sum)
    sum = sum or {}
    return P.PREFIX .. "SUM|" .. P.EncodeFields({
        tostr(sum.rid),
        tostr(sum.token),
        tostr(sum.status or "error"),
        tostr(sum.total),
        tostr(sum.count or 0),
        tostr(sum.startedAt or 0),
        tostr(sum.coverage),
        tostr(sum.provider),
        tostr(sum.time or 0),
        tostr(sum.errorCode),
    })
end

function P.DecodeSummary(text)
    if type(text) ~= "string" then
        return nil, "NOT_TEXT"
    end
    local tag = P.PREFIX .. "SUM|"
    if string.sub(text, 1, #tag) ~= tag then
        return nil, "NOT_SUMMARY"
    end
    local f = P.DecodeFields(string.sub(text, #tag + 1))
    if #f < 10 then
        return nil, "BAD_SUMMARY"
    end
    return {
        rid = f[1],
        token = f[2],
        status = f[3],
        total = f[4],
        count = tonumber(f[5]) or 0,
        startedAt = tonumber(f[6]) or 0,
        coverage = f[7],
        provider = f[8],
        time = tonumber(f[9]) or 0,
        errorCode = f[10],
    }
end

function P.EncodeRound(rnd)
    rnd = rnd or {}
    return P.PREFIX .. "RND|" .. P.EncodeFields({
        tostr(rnd.rid),
        tostr(rnd.sid),
        tostr(rnd.host),
        tostr(rnd.epoch or 0),
        tostr(rnd.phase or "open"),
        tostr(rnd.created or 0),
    })
end

function P.DecodeRound(text)
    if type(text) ~= "string" then
        return nil, "NOT_TEXT"
    end
    local tag = P.PREFIX .. "RND|"
    if string.sub(text, 1, #tag) ~= tag then
        return nil, "NOT_ROUND"
    end
    local f = P.DecodeFields(string.sub(text, #tag + 1))
    if #f < 5 then
        return nil, "BAD_ROUND"
    end
    return {
        rid = f[1],
        sid = f[2],
        host = f[3],
        epoch = tonumber(f[4]) or 0,
        phase = f[5],
        created = tonumber(f[6]) or 0,
    }
end

-- RES：首字段 rid；每行 pid|color|code|count|token。token 是该成员本轮
-- 连接 token；客户端显示前必须与当前 CAP token 比对，槽位复用后的旧行
-- 即使仍是 green 也不能显示。
function P.EncodeResults(rid, rows)
    local out = { tostr(rid) }
    if type(rows) == "table" then
        for i = 1, #rows do
            local r = rows[i]
            out[#out + 1] = P.EncodeFields({
                tostr(r.pid),
                tostr(r.color),
                tostr(r.code),
                tostr(r.count or 0),
                tostr(r.token),
            })
        end
    end
    -- 行用 ";" 分隔，字段才用 "|"；否则逐行字段与行分隔符冲突。
    return P.PREFIX .. "RES|" .. table.concat(out, ";")
end

function P.DecodeResults(text)
    if type(text) ~= "string" then
        return nil, "NOT_TEXT"
    end
    local tag = P.PREFIX .. "RES|"
    if string.sub(text, 1, #tag) ~= tag then
        return nil, "NOT_RESULTS"
    end
    local parts = P.SplitText(string.sub(text, #tag + 1), ";")
    if #parts < 1 or parts[1] == "" then
        return nil, "BAD_RESULTS"
    end
    local rows = {}
    for i = 2, #parts do
        local f = P.DecodeFields(parts[i])
        if #f >= 3 then
            rows[#rows + 1] = {
                pid = f[1],
                color = f[2],
                code = f[3],
                count = tonumber(f[4]) or 0,
                -- 旧格式无 token：留空，客户端一律视为不匹配当前连接。
                token = tostr(f[5]),
            }
        end
    end
    return { rid = parts[1], players = rows }
end

--=========================================================================
-- 网络包
--=========================================================================

function P.IsProtocolText(text)
    return type(text) == "string" and string.sub(text, 1, #P.PREFIX) == P.PREFIX
end

local function packetHeader(msg)
    return P.PREFIX
        .. tostr(msg.type)
        .. "|" .. P.Escape(msg.rid or "")
        .. "|" .. P.Escape(msg.sid or "")
        .. "|" .. P.Escape(msg.host or "")
        .. "|" .. P.Escape(msg.from or "")
        .. "|" .. P.Escape(msg.to or "")
        .. "|" .. P.Escape(msg.token or "")
        .. "|" .. P.Escape(msg.request or "")
        .. "|"
end

-- 单包消息（P/H/A/S/Q/X）。超长返回 nil, "PACKET_TOO_LONG"。
function P.BuildPacket(msg)
    if type(msg) ~= "table" or msg.type == nil then
        return nil, "BAD_MESSAGE"
    end
    local body = msg.body
    if body == nil and type(msg.fields) == "table" then
        body = P.EncodeFields(msg.fields)
    end
    local packet = packetHeader(msg) .. (body or "")
    if #packet > P.MAX_PACKET_BYTES then
        return nil, "PACKET_TOO_LONG"
    end
    return packet
end

-- 逐 Mod 清单分片。msg={rid,sid,host,from,to,token,request,digest,mods|text}
function P.BuildListPackets(msg)
    if type(msg) ~= "table" then
        return nil, "BAD_MESSAGE"
    end
    local digest = tostring(msg.digest or "")
    if digest == "" then
        return nil, "MISSING_DIGEST"
    end
    local rowsText = msg.text
    if rowsText == nil and type(msg.mods) == "table" then
        rowsText = P.EncodeModList(msg.mods)
    end
    if type(rowsText) ~= "string" or rowsText == "" then
        return nil, "EMPTY_LIST"
    end
    if #rowsText > P.MAX_LIST_BYTES then
        return nil, "LIST_TOO_LARGE"
    end

    local rows = P.SplitText(rowsText, ";")
    if #rows > P.MAX_MODS then
        return nil, "TOO_MANY_MODS"
    end
    for i = 1, #rows do
        if rows[i] == "" then
            return nil, "BAD_LIST_ROW"
        end
    end

    local header = packetHeader({
        type = P.T.LIST_CHUNK,
        rid = msg.rid,
        sid = msg.sid,
        host = msg.host,
        from = msg.from,
        to = msg.to,
        token = msg.token,
        request = msg.request,
    })
    local digestText = P.Escape(digest)

    local function tryBuild(totalHint)
        local totalStr = tostring(totalHint)
        local overhead = #header + #totalStr + 1 + #totalStr + 1 + #digestText + 1
        local maxBody = P.MAX_PACKET_BYTES - overhead
        if maxBody < 24 then
            return nil, "PACKET_TOO_LONG"
        end
        local chunks = {}
        local current = {}
        local currentLen = 0
        for i = 1, #rows do
            local row = rows[i]
            if #row > maxBody then
                return nil, "ROW_TOO_LONG"
            end
            local add = #row + (#current > 0 and 1 or 0)
            if currentLen + add > maxBody then
                chunks[#chunks + 1] = table.concat(current, ";")
                current = { row }
                currentLen = #row
            else
                current[#current + 1] = row
                currentLen = currentLen + add
            end
        end
        if #current > 0 then
            chunks[#chunks + 1] = table.concat(current, ";")
        end
        return chunks
    end

    local totalHint = 1
    local chunks = nil
    for _ = 1, 4 do
        local built, err = tryBuild(totalHint)
        if not built then
            return nil, err
        end
        chunks = built
        if #tostring(#chunks) == #tostring(totalHint) then
            break
        end
        totalHint = #chunks
    end
    if chunks == nil or #chunks == 0 then
        return nil, "EMPTY_LIST"
    end
    if #chunks > P.MAX_CHUNKS then
        return nil, "TOO_MANY_CHUNKS"
    end

    local total = #chunks
    local packets = {}
    for i = 1, total do
        local packet = header
            .. tostring(i) .. "|" .. tostring(total) .. "|"
            .. digestText .. "|" .. chunks[i]
        if #packet > P.MAX_PACKET_BYTES then
            return nil, "PACKET_TOO_LONG"
        end
        packets[#packets + 1] = packet
    end
    return packets
end

function P.ParsePacket(text)
    if type(text) ~= "string" then
        return nil, "NOT_TEXT"
    end
    if #text > P.MAX_PACKET_BYTES then
        return nil, "PACKET_TOO_LONG"
    end
    if not P.IsProtocolText(text) then
        return nil, "NOT_PROTOCOL"
    end
    local rest = string.sub(text, #P.PREFIX + 1)
    local parts = P.SplitText(rest, "|")
    if #parts < 8 then
        return nil, "BAD_PACKET"
    end
    local msg = {
        type = parts[1],
        rid = P.Unescape(parts[2]),
        sid = P.Unescape(parts[3]),
        host = P.Unescape(parts[4]),
        from = P.Unescape(parts[5]),
        to = P.Unescape(parts[6]),
        token = P.Unescape(parts[7]),
        request = P.Unescape(parts[8]),
    }
    if msg.type == P.T.LIST_CHUNK then
        if #parts < 11 then
            return nil, "BAD_CHUNK"
        end
        msg.seq = tonumber(parts[9])
        msg.chunks = tonumber(parts[10])
        msg.digest = P.Unescape(parts[11])
        msg.chunk = table.concat(parts, "|", 12)
        if not msg.seq or not msg.chunks then
            return nil, "BAD_CHUNK"
        end
        if msg.seq < 1 or msg.chunks < 1 or msg.seq > msg.chunks then
            return nil, "BAD_CHUNK"
        end
        if msg.chunks > P.MAX_CHUNKS then
            return nil, "TOO_MANY_CHUNKS"
        end
        if msg.digest == "" or msg.chunk == "" then
            return nil, "BAD_CHUNK"
        end
        msg.fields = {}
    else
        msg.body = table.concat(parts, "|", 9)
        msg.fields = P.DecodeFields(msg.body)
    end
    return msg
end

-- 清单重组器：绑定 token/request 之外的 transport digest / total，
-- 按 seq 去重，限制总字节与片数。完成结果仍需调用方按 64hex 原生 total
-- 判定绿灯；transport digest 只证明文本未损坏。
function P.NewAssembler(opts)
    opts = opts or {}
    local a = {
        digest = opts.digest,
        total = nil,
        count = 0,
        bytes = 0,
        chunks = {},
        maxBytes = opts.maxBytes or P.MAX_LIST_BYTES,
        maxChunks = opts.maxChunks or P.MAX_CHUNKS,
    }

    function a:Accept(msg)
        if type(msg) ~= "table" or msg.type ~= P.T.LIST_CHUNK then
            return nil, "NOT_CHUNK"
        end
        if msg.digest ~= self.digest then
            return nil, "DIGEST_MISMATCH"
        end
        if self.total ~= nil and self.total ~= msg.chunks then
            return nil, "TOTAL_MISMATCH"
        end
        if msg.chunks > self.maxChunks then
            return nil, "TOO_MANY_CHUNKS"
        end
        if #msg.chunk > self.maxBytes then
            return nil, "TOO_LARGE"
        end
        if self.chunks[msg.seq] == nil then
            if self.bytes + #msg.chunk > self.maxBytes then
                return nil, "TOO_LARGE"
            end
            self.chunks[msg.seq] = msg.chunk
            self.count = self.count + 1
            self.bytes = self.bytes + #msg.chunk
        end
        self.total = msg.chunks
        if self.count < self.total then
            return "partial"
        end
        local parts = {}
        for i = 1, self.total do
            local chunk = self.chunks[i]
            if chunk == nil then
                return "partial"
            end
            parts[#parts + 1] = chunk
        end
        return "complete", table.concat(parts)
    end

    function a:IsComplete()
        return self.total ~= nil and self.count == self.total
    end

    return a
end

CCBModCheckProtocol = P
return P
