-- Shared helpers for the root-scan specs: oracle checks, corpus generator,
-- files, /proc/self/status, monotonic clock and raw mmap.

local ffi   = require("ffi")
local R     = require("rs_runner")
local cjson = require("cjson.safe").new()

local U = {}

U.cjson = cjson
U.null = cjson.null


pcall(ffi.cdef, [[
typedef long rs_time_t;
struct rs_timespec { rs_time_t tv_sec; long tv_nsec; };
int clock_gettime(int clk_id, struct rs_timespec *tp);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int munmap(void *addr, size_t length);
int mprotect(void *addr, size_t len, int prot);
long sysconf(int name);
]])

U.PROT_NONE, U.PROT_READ, U.PROT_WRITE = 0, 1, 2
U.MAP_PRIVATE, U.MAP_ANONYMOUS = 0x02, 0x20
U.MAP_FAILED = ffi.cast("void *", -1)

local ts = ffi.new("struct rs_timespec")
function U.now_ns()
    ffi.C.clock_gettime(1, ts)  -- CLOCK_MONOTONIC
    return tonumber(ts.tv_sec) * 1e9 + tonumber(ts.tv_nsec)
end

function U.page_size()
    return tonumber(ffi.C.sysconf(30))   -- _SC_PAGESIZE on Linux
end


function U.status()
    local f = assert(io.open("/proc/self/status", "r"))
    local s = f:read("*a")
    f:close()
    local out = {}
    for k in ("VmRSS VmHWM RssAnon RssFile VmSize"):gmatch("%S+") do
        out[k] = tonumber(s:match(k .. ":%s+(%d+)"))
    end
    return out
end


-- reset VmHWM to the current RSS (Linux >= 4.0, own process)
function U.reset_hwm()
    local f = io.open("/proc/self/clear_refs", "w")
    if not f then return false end
    local ok = f:write("5")
    f:close()
    return ok and true or false
end


function U.lua_kb()
    return collectgarbage("count")
end


function U.write_file(path, data)
    local f = assert(io.open(path, "wb"))
    assert(f:write(data))
    f:close()
end


function U.tmp(name)
    return "/tmp/rs-" .. ngx.worker.pid() .. "-" .. name
end


-- --------------------------------------------------------------------------
-- Oracle: compare an index against lua-cjson on the same document
-- --------------------------------------------------------------------------

-- Checks member order/offsets against the text and cjson. Returns true if all
-- checks passed. `doc` is the cjson decode of `json` (optional).
function U.check_index(t, json, idx, label, doc)
    doc = doc or cjson.decode(json)
    local ok = t:ok(type(doc) == "table", label .. ": cjson accepts")
    if not ok then return false end

    local prev_end = idx.root_start + 1
    local seen = {}
    local count = 0
    for i, m in ipairs(idx.members) do
        local tag = label .. " member#" .. i .. " " .. R.show(m.key)
        ok = t:ok(m.key_start >= prev_end and m.key_start < m.key_end
                  and m.key_end <= m.value_start and m.value_start < m.value_end,
                  tag .. ": offsets ordered " .. R.show(m)) and ok
        prev_end = m.value_end
        local ktext = json:sub(m.key_start + 1, m.key_end)
        ok = t:eq(cjson.decode(ktext), m.key, tag .. ": key text decodes to key") and ok
        local vtext = json:sub(m.value_start + 1, m.value_end)
        local v = cjson.decode(vtext)
        if not m.duplicate then
            ok = t:deq(v, doc[m.key], tag .. ": value slice equals cjson") and ok
        else
            ok = t:ok(v ~= nil or vtext == "null", tag .. ": duplicate value slice decodes") and ok
        end
        local c1 = vtext:sub(1, 1)
        local want_type = (c1 == "{" and "object") or (c1 == "[" and "array") or (c1 == '"' and "string")
            or ((c1 == "t" or c1 == "f") and "boolean") or (c1 == "n" and "null") or "number"
        ok = t:eq(m.type, want_type, tag .. ": type") and ok
        if not seen[m.key] then
            seen[m.key] = true
            count = count + 1
        end
    end
    ok = t:ok(prev_end <= idx.root_end, label .. ": last member before root end") and ok
    ok = t:eq(json:sub(idx.root_end, idx.root_end), "}", label .. ": root_end follows '}'") and ok
    local ncj = 0
    for _ in pairs(doc) do ncj = ncj + 1 end
    ok = t:eq(count, ncj, label .. ": distinct key count equals cjson") and ok
    return ok
end


-- value of a dotted path (<= 2 segments) in a cjson-decoded doc
function U.cj_path(doc, path)
    local a, b = path:match("^([^.]+)%.(.+)$")
    if not a then
        return doc[path]
    end
    local p = doc[a]
    if type(p) ~= "table" then return nil end
    -- an array parent never has a named child (lua-cjson decodes [] to a table too)
    if #p > 0 then return nil end
    return p[b]
end


-- --------------------------------------------------------------------------
-- Random corpus
-- --------------------------------------------------------------------------

local Gen = {}
Gen.__index = Gen

function U.gen(seed)
    return setmetatable({ s = seed % 2147483647 }, Gen)
end

-- Park-Miller minimal standard; deterministic across LuaJIT builds
function Gen:rand(n)
    self.s = (self.s * 16807) % 2147483647
    if n then
        return self.s % n + 1
    end
    return self.s / 2147483647
end

function Gen:pick(list)
    return list[self:rand(#list)]
end

local WS = { " ", "\t", "\n", "\r", "  ", "\r\n" }

function Gen:ws()
    local r = self:rand(10)
    if r <= 6 then return "" end
    return self:pick(WS)
end

local PLAIN = { "a", "b", "z", "0", "9", " ", "-", "_", ".", "中", "文", "é", "😀", "𝄞", "/", "#" }

-- JSON string literal for the Lua string `s`, randomly escaped
function Gen:quote(s)
    local out = { '"' }
    -- iterate UTF-8 characters
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local r = self:rand(12)
        local b = ch:byte()
        if ch == '"' then
            out[#out + 1] = '\\"'
        elseif ch == "\\" then
            out[#out + 1] = "\\\\"
        elseif b < 0x20 then
            out[#out + 1] = string.format("\\u%04x", b)
        elseif r == 1 and #ch == 1 then
            out[#out + 1] = string.format("\\u%04X", b)
        elseif r == 2 and #ch == 4 then
            -- surrogate pair escape
            local c1, c2, c3, c4 = ch:byte(1, 4)
            local cp = (c1 - 0xF0) * 0x40000 + (c2 - 0x80) * 0x1000 + (c3 - 0x80) * 0x40 + (c4 - 0x80)
            cp = cp - 0x10000
            out[#out + 1] = string.format("\\u%04x\\u%04x", 0xD800 + math.floor(cp / 0x400), 0xDC00 + cp % 0x400)
        elseif r == 3 and ch == "/" then
            out[#out + 1] = "\\/"
        elseif r == 4 and #ch == 3 then
            local c1, c2, c3 = ch:byte(1, 3)
            local cp = (c1 - 0xE0) * 0x1000 + (c2 - 0x80) * 0x40 + (c3 - 0x80)
            out[#out + 1] = string.format("\\u%04x", cp)
        else
            out[#out + 1] = ch
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

function Gen:str(maxlen)
    local n = self:rand(maxlen or 8) - 1
    local t = {}
    for i = 1, n do
        local r = self:rand(20)
        if r == 1 then t[i] = '"'
        elseif r == 2 then t[i] = "\\"
        elseif r == 3 then t[i] = "\n"
        elseif r == 4 then t[i] = "\0"
        else t[i] = self:pick(PLAIN) end
    end
    return table.concat(t)
end

local NUMS = { "0", "-0", "1", "-1", "42", "3.25", "-0.5", "1e3", "1E-2", "2.5e+10", "123456789", "-987.0e1" }

function Gen:value(depth)
    local r = self:rand(depth > 4 and 6 or 9)
    if r == 1 then return self:quote(self:str(10)) end
    if r == 2 then return self:pick(NUMS) end
    if r == 3 then return self:pick({ "true", "false" }) end
    if r == 4 then return "null" end
    if r == 5 or r == 6 then return self:quote(self:str(4)) end
    if r == 7 or r == 8 then
        local n = self:rand(4) - 1
        local items = {}
        for i = 1, n do
            items[i] = self:ws() .. self:value(depth + 1) .. self:ws()
        end
        return "[" .. self:ws() .. table.concat(items, ",") .. "]"
    end
    return self:object(depth + 1, self:rand(4) - 1)
end

local KEYS = { "model", "prompt_cache_key", "metadata", "messages", "stream", "stream_options",
               "service_tier", "user_id", "tools", "n", "k", "中文", "😀", "" }

function Gen:key()
    if self:rand(3) == 1 then
        return self:str(6)
    end
    return self:pick(KEYS)
end

function Gen:object(depth, n, keyset)
    local items = {}
    for i = 1, n do
        local k = keyset and keyset[i] or self:key()
        local v
        if k == "metadata" and self:rand(2) == 1 then
            v = self:object(depth + 1, self:rand(3), { "user_id", self:key(), "user_id" })
        else
            v = self:value(depth)
        end
        items[i] = self:ws() .. self:quote(k) .. self:ws() .. ":" .. self:ws() .. v .. self:ws()
    end
    return "{" .. self:ws() .. table.concat(items, ",") .. "}"
end

-- a top-level document; `unique` avoids duplicate top-level keys
function Gen:document(unique)
    local n = self:rand(7) - 1
    local keys, used = {}, {}
    for i = 1, n do
        local k
        for _ = 1, 8 do
            k = self:key()
            if not unique or not used[k] then break end
        end
        if unique and used[k] then
            k = "k" .. i .. "_" .. self:rand(1000)
        end
        used[k] = true
        keys[i] = k
    end
    return self:ws() .. self:object(1, n, keys) .. self:ws()
end

function Gen:mutate(s)
    local r = self:rand(6)
    local pos = self:rand(#s)
    if r == 1 then      -- delete one byte
        return s:sub(1, pos - 1) .. s:sub(pos + 1)
    elseif r == 2 then  -- insert a syntax byte
        return s:sub(1, pos - 1) .. self:pick({ ",", ":", "{", "}", "[", "]", '"', "\\", "x", "0", " ", "\1", "\255" }) .. s:sub(pos)
    elseif r == 3 then  -- replace one byte
        return s:sub(1, pos - 1) .. string.char(self:rand(256) - 1) .. s:sub(pos + 1)
    elseif r == 4 then  -- truncate
        return s:sub(1, pos - 1)
    elseif r == 5 then  -- duplicate a slice
        local e = math.min(#s, pos + self:rand(8))
        return s:sub(1, e) .. s:sub(pos, e) .. s:sub(e + 1)
    else                -- swap two bytes
        local q = self:rand(#s)
        if q < pos then pos, q = q, pos end
        return s:sub(1, pos - 1) .. s:sub(q, q) .. s:sub(pos + 1, q - 1) .. s:sub(pos, pos) .. s:sub(q + 1)
    end
end


function U.hex(s, max)
    max = max or 128
    local part = s:sub(1, max)
    return (part:gsub(".", function(c) return string.format("%02x", c:byte()) end)) ..
           (#s > max and ("...(" .. #s .. " bytes)") or "")
end


return U
