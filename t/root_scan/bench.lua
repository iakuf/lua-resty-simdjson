-- resty t/root_scan/bench.lua <shape> <bytes> <mode> [--reps=N]
-- One sample per process (plus optional warm repetitions). Prints one JSON line
-- per repetition. shape: S1 base64 | S2 messages | S3 escaped | S4 dense.
-- mode: A-string A-file B-string B-file getmany-string cjson-string.
-- Measured around the single call: C-side t_*_ns (root-scan), wall clock,
-- ΔVmHWM after clear_refs (peak above the pre-call RSS), RssAnon/RssFile and
-- Lua heap deltas, copied bytes.

package.path = "t/root_scan/?.lua;lib/?.lua;lib/?/init.lua;" .. package.path

local U  = require("rs_util")
local rs = require("resty.simdjson.root_scan")

local shape, bytes, mode = arg[1], tonumber(arg[2]), arg[3]
local reps = 1
for i = 4, #arg do
    local r = arg[i]:match("^%-%-reps=(%d+)$")
    if r then reps = tonumber(r) end
end

local HEAD = '{"model":"gpt-4o","stream":true,"stream_options":{"include_usage":true},' ..
             '"prompt_cache_key":"pk-123","metadata":{"user_id":"user-1"},"messages":['
local TAIL = '],"service_tier":"auto"}'

local function fill(n, unit)
    return string.rep(unit, math.floor(n / #unit)) .. string.rep("a", n % #unit)
end

local function make(sh, n)
    if sh == "S1" then
        local pre = '{"role":"user","content":[{"type":"text","text":"describe"},' ..
                    '{"type":"image_url","image_url":{"url":"data:image/png;base64,'
        local post = '"}}]}'
        local k = n - #HEAD - #TAIL - #pre - #post
        return HEAD .. pre .. fill(k, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4") .. post .. TAIL
    elseif sh == "S2" or sh == "S3" then
        local unit = sh == "S2" and string.rep("x", 100)
            or string.rep('line \\"q\\" \\\\ \\n\\t \\u00e9 \\ud83d\\ude00 ', 8)
        local parts, size, i = {}, #HEAD + #TAIL, 0
        while true do
            i = i + 1
            local m = '{"role":"' .. (i % 2 == 0 and "assistant" or "user") .. '","content":"' .. i .. ":" .. unit .. '"}'
            if size + #m + 1 > n then break end
            parts[i] = m
            size = size + #m + 1
        end
        local body = HEAD .. table.concat(parts, ",") .. TAIL
        -- pad inside the first message content to hit n exactly
        local pad = n - #body
        if pad > 0 then
            body = body:gsub('"content":"1:', '"content":"1:' .. string.rep("p", pad), 1)
        end
        return body
    elseif sh == "S4" then
        local pre = '{"role":"user","content":['
        local post = '0]}'
        local k = n - #HEAD - #TAIL - #pre - #post
        local body = string.rep("0,", math.floor(k / 2))
        if k % 2 == 1 then body = body .. " " end
        return HEAD .. pre .. body .. post .. TAIL
    end
    error("unknown shape " .. tostring(sh))
end

local PATHS  = { "model", "prompt_cache_key", "metadata.user_id", "stream", "stream_options", "service_tier" }
local FIELDS = { "model", "prompt_cache_key", "metadata.user_id" }

local json = make(shape, bytes)
assert(#json == bytes, "size " .. #json .. " ~= " .. bytes)
local path
if mode:match("%-file$") then
    path = U.tmp("bench.json")
    U.write_file(path, json)
    json = nil
end
local cj = require("cjson.safe").new()
local gjson = require("resty.simdjson.gjson")

local function call()
    if mode == "A-string" then return rs.scan_string(json, { paths = PATHS, validate = "strict" }) end
    if mode == "A-file" then return rs.scan_file(path, { paths = PATHS, validate = "strict" }) end
    if mode == "B-string" then return rs.scan_string(json, { paths = PATHS, validate = "shallow" }) end
    if mode == "B-file" then return rs.scan_file(path, { paths = PATHS, validate = "shallow" }) end
    if mode == "getmany-string" then
        local g = gjson.new(true)
        local v, e = g:get_many(json, FIELDS)
        g:destroy()
        return v, e
    end
    if mode == "cjson-string" then return cj.decode(json) end
    error("unknown mode " .. tostring(mode))
end

-- warm-up on a tiny document: page in the library code and run simdjson's CPU
-- dispatch once, so the sample reflects a long-lived worker, not process start
do
    local tiny = '{"model":"gpt-4o","prompt_cache_key":"p","metadata":{"user_id":"u"}}'
    local wpath = U.tmp("warm.json")
    U.write_file(wpath, tiny)
    rs.scan_string(tiny, { paths = PATHS, validate = "strict" })
    rs.scan_string(tiny, { paths = PATHS, validate = "shallow" })
    rs.scan_file(wpath, { paths = PATHS, validate = "strict" })
    local g = gjson.new(true)
    g:get_many(tiny, FIELDS)
    g:destroy()
    cj.decode(tiny)
    os.remove(wpath)
end

for rep = 1, reps do
    collectgarbage()
    collectgarbage()
    local before = U.status()
    local lua0 = U.lua_kb()
    U.reset_hwm()
    local w0 = U.now_ns()
    local res, err = call()
    local wall = U.now_ns() - w0
    local lua1 = U.lua_kb()
    local after = U.status()
    local rec = {
        shape = shape, bytes = bytes, mode = mode, rep = rep, ok = res ~= nil, err = err and tostring(err) or nil,
        wall_ns = wall, d_hwm_kb = after.VmHWM - before.VmRSS, d_rss_kb = after.VmRSS - before.VmRSS,
        d_anon_kb = after.RssAnon - before.RssAnon, d_file_kb = after.RssFile - before.RssFile,
        d_lua_kb = lua1 - lua0, rss_before_kb = before.VmRSS,
    }
    if type(res) == "table" and res.timing then
        rec.t_total_ns, rec.t_index_ns = res.timing.total_ns, res.timing.index_ns
        rec.t_walk_ns, rec.t_input_ns = res.timing.walk_ns, res.timing.input_ns
        rec.copied_bytes, rec.members = res.copied_bytes, #res.members
        rec.model_ok = res.map and res.map.model == "gpt-4o"
    elseif mode == "getmany-string" then
        rec.model_ok = res and res.model == "gpt-4o"
    elseif mode == "cjson-string" then
        rec.model_ok = res and res.model == "gpt-4o"
    end
    print(cj.encode(rec))
end
if path then os.remove(path) end
