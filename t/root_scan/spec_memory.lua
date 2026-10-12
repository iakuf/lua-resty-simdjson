-- Leak and heap checks. Default: 1 MB document, 2000 string scans / 200 file
-- scans; RSS growth between scan 100 and the end <= 2 MiB, Lua heap growth
-- after full GC <= 64 KiB. Mixed sizes report residual RSS (not a gate).
-- --heavy: 50 MB base64 body in string and file mode (timing, peak, heap).
-- Light mode (valgrind): a few scans per path, no RSS/heap/timing assertions;
-- leak detection is then valgrind's job.

local rs = require("resty.simdjson.root_scan")
local U  = require("rs_util")

local PATHS = { "model", "prompt_cache_key", "metadata.user_id", "stream", "stream_options" }

local function body(bytes)
    local head = '{"model":"gpt-4o","stream":true,"stream_options":{"include_usage":true},' ..
                 '"metadata":{"user_id":"u"},"messages":[{"role":"user","content":[{"type":"text",' ..
                 '"text":"describe"},{"type":"image_url","image_url":{"url":"data:image/png;base64,'
    local tail = '"}}]}],"prompt_cache_key":"pk"}'
    local n = bytes - #head - #tail
    local unit = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    local s = string.rep(unit, math.floor(n / #unit)) .. string.rep("A", n % #unit)
    return head .. s .. tail
end

local function loop(t, label, n, fn, light)
    if light then
        for i = 1, n do
            t:ok(fn() ~= nil, label .. ": scan " .. i)
        end
        return
    end
    local rss100, lua100
    for i = 1, n do
        local idx = fn()
        if i == 1 then t:ok(idx ~= nil, label .. ": scan ok") end
        if i == 100 then
            collectgarbage()
            collectgarbage()
            rss100, lua100 = U.status().VmRSS, U.lua_kb()
        end
    end
    collectgarbage()
    collectgarbage()
    local rss, lua = U.status().VmRSS, U.lua_kb()
    t:ok(rss - rss100 <= 2048, string.format("%s: RSS growth %d KiB <= 2048", label, rss - rss100))
    t:ok(lua - lua100 <= 64, string.format("%s: Lua heap growth %.1f KiB <= 64", label, lua - lua100))
    t:note({ case = label, scans = n, rss_after_100_kb = rss100, rss_end_kb = rss,
             lua_after_100_kb = math.floor(lua100), lua_end_kb = math.floor(lua) })
end

local function one(t, label, fn, len, file_mode)
    collectgarbage()
    collectgarbage()
    local before = U.status()
    local lua0 = U.lua_kb()
    t:ok(U.reset_hwm(), label .. ": clear_refs available")
    local w0 = U.now_ns()
    local idx, err = fn()
    local wall = U.now_ns() - w0
    local lua1 = U.lua_kb()
    local after = U.status()
    t:ok(idx ~= nil, label .. ": scan ok (" .. tostring(err) .. ")")
    if not idx then return end
    local d_hwm = after.VmHWM - before.VmRSS
    local rec = {
        case = label, bytes = len, t_total_ms = idx.timing.total_ns / 1e6, t_index_ms = idx.timing.index_ns / 1e6,
        t_walk_ms = idx.timing.walk_ns / 1e6, t_input_ms = idx.timing.input_ns / 1e6, wall_ms = wall / 1e6,
        d_vmhwm_kb = d_hwm, d_rss_anon_kb = after.RssAnon - before.RssAnon,
        d_rss_file_kb = after.RssFile - before.RssFile, d_lua_kb = lua1 - lua0, copied_bytes = idx.copied_bytes,
    }
    if file_mode then
        -- VmHWM includes the mapped page-cache pages of the body itself
        rec.d_vmhwm_anon_estimate_kb = d_hwm - math.ceil(len / 4096) * 4
    end
    t:note(rec)
    t:ok(lua1 - lua0 <= 512, string.format("%s: Lua heap +%.1f KiB <= 512", label, lua1 - lua0))
    if idx.copied_bytes == 0 and not file_mode then
        t:ok(d_hwm <= 2048, string.format("%s: zero-copy peak +%d KiB <= 2048", label, d_hwm))
    end
    if file_mode then
        t:ok(rec.d_vmhwm_anon_estimate_kb <= 2048,
             string.format("%s: anonymous peak estimate +%d KiB <= 2048", label, rec.d_vmhwm_anon_estimate_kb))
    end
end

return function(t, args)
    local json = body(1000 * 1000)
    local path = U.tmp("mem.json")
    U.write_file(path, json)

    local light = args.light
    local ns, nf = 2000, 200
    if light then ns, nf = 20, 10 end

    loop(t, "1 MB string x" .. ns, ns, function() return rs.scan_string(json, { paths = PATHS }) end, light)
    loop(t, "1 MB file x" .. nf, nf, function() return rs.scan_file(path, { paths = PATHS }) end, light)
    local trailing = json .. "x"
    loop(t, "1 MB error path x" .. ns, ns, function()
        local _, err = rs.scan_string(trailing, { paths = PATHS })
        return err == "trailing_content" and true or nil
    end, light)
    trailing = nil

    if light then
        os.remove(path)
        return
    end

    -- residual RSS after a mix of sizes (informational)
    collectgarbage()
    local r0 = U.status().VmRSS
    for _, sz in ipairs({ 1000, 100000, 1000000, 8000000, 1000, 4000000, 1000 }) do
        local j = body(sz)
        local idx = rs.scan_string(j, { paths = PATHS })
        t:ok(idx ~= nil, "mixed size " .. sz)
        j = nil  -- luacheck: ignore 311
        collectgarbage()
    end
    collectgarbage()
    t:note({ case = "mixed sizes 1 KB..8 MB", residual_rss_kb = U.status().VmRSS - r0 })

    os.remove(path)
    json = nil
    collectgarbage()

    if args.heavy then
        local n = 50 * 1000 * 1000
        local big = body(n)
        local bpath = U.tmp("mem50.json")
        U.write_file(bpath, big)
        for _, mode in ipairs({ "strict", "shallow" }) do
            one(t, "50 MB base64 string " .. mode, function()
                return rs.scan_string(big, { paths = PATHS, validate = mode })
            end, n, false)
        end
        big = nil
        collectgarbage()
        collectgarbage()
        for _, mode in ipairs({ "strict", "shallow" }) do
            one(t, "50 MB base64 file " .. mode, function()
                return rs.scan_file(bpath, { paths = PATHS, validate = mode })
            end, n, true)
        end
        os.remove(bpath)
    end
end
