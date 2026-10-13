-- Randomised differential test (fixed seed): generated documents and byte
-- mutations of them. Properties:
--   P1  strict accepts  =>  lua-cjson accepts, offsets/keys/values agree
--   P2  strict accepts  =>  shallow accepts with the same index
--   P3  no duplicates and no escaped keys  =>  map == gjson:get_many(3 fields)
--   P4  string and file mode agree (sampled)
--   P5  no "internal" verdict
-- On failure the seed, case number and a bounded hex dump are printed.

local rs    = require("resty.simdjson.root_scan")
local R     = require("rs_runner")
local U     = require("rs_util")
local gjson = require("resty.simdjson.gjson")

local PATHS  = { "model", "prompt_cache_key", "metadata.user_id", "stream", "stream_options", "service_tier" }
local FIELDS = { "model", "prompt_cache_key", "metadata.user_id" }

return function(t, args)
    local n = args.fuzz_n
    local gen = U.gen(args.seed)
    local cj = U.cjson
    local g = gjson.new(true)
    local fpath = U.tmp("fuzz.json")
    local stats = { docs = 0, mutations = 0, strict_ok = 0, cjson_ok = 0, cjson_only = 0,
                    shallow_only = 0, getmany_checked = 0, file_checked = 0, codes = {} }

    local function fail_ctx(kind, i, json)
        return string.format("%s seed=%d case=%d hex=%s", kind, args.seed, i, U.hex(json, 128))
    end

    local function check(kind, i, json)
        local idx, err, d = rs.scan_string(json, { paths = PATHS, allow_duplicates = true, validate = "strict" })
        local verdict = idx and "ok" or err
        stats.codes[verdict] = (stats.codes[verdict] or 0) + 1
        t:ok(verdict ~= "internal", fail_ctx(kind, i, json) .. " internal: " .. tostring(d and d.message))

        local doc = cj.decode(json)
        local cjson_ok = type(doc) == "table" and json:match("^%s*{") ~= nil
        if cjson_ok then stats.cjson_ok = stats.cjson_ok + 1 end

        local sidx, serr = rs.scan_string(json, { paths = PATHS, allow_duplicates = true, validate = "shallow" })
        if sidx and not idx then stats.shallow_only = stats.shallow_only + 1 end

        if not idx then
            if cjson_ok then stats.cjson_only = stats.cjson_only + 1 end
            return
        end
        stats.strict_ok = stats.strict_ok + 1
        local ctx = fail_ctx(kind, i, json)

        -- P1
        if not t:ok(cjson_ok, ctx .. " P1: strict accepted, cjson rejected") then return end
        if not U.check_index(t, json, idx, ctx .. " P1") then return end
        for _, p in ipairs(PATHS) do
            t:deq(idx.map[p], U.cj_path(doc, p), ctx .. " P1 map[" .. p .. "]")
        end

        -- P2
        if t:ok(sidx, ctx .. " P2: shallow rejected (" .. tostring(serr) .. ")") then
            t:ok(R.deep_eq(sidx.members, idx.members), ctx .. " P2 members")
            t:ok(R.deep_eq(sidx.map, idx.map), ctx .. " P2 map")
        end

        -- P3: get_many compares raw (escaped) keys and takes the first duplicate,
        -- so only documents without either are comparable
        local comparable = not idx.has_duplicates
        for _, m in ipairs(idx.members) do
            local ktext = json:sub(m.key_start + 1, m.key_end)
            if ktext:find("\\", 1, true) then comparable = false end
            if m.key == "metadata" and m.type == "object"
               and json:sub(m.value_start + 1, m.value_end):find("\\", 1, true) then
                comparable = false
            end
        end
        if comparable then
            stats.getmany_checked = stats.getmany_checked + 1
            local want, gerr = g:get_many(json, FIELDS)
            if t:ok(want, ctx .. " P3 get_many failed: " .. tostring(gerr)) then
                local got = {}
                for _, f in ipairs(FIELDS) do got[f] = idx.map[f] end
                t:deq(got, want, ctx .. " P3 map vs get_many")
            end
        end

        -- P4
        if i % 10 == 0 then
            stats.file_checked = stats.file_checked + 1
            U.write_file(fpath, json)
            local fidx, ferr = rs.scan_file(fpath, { paths = PATHS, allow_duplicates = true, validate = "strict" })
            t:eq(ferr, err, ctx .. " P4 file verdict")
            if fidx then
                t:ok(R.deep_eq(fidx.members, idx.members) and R.deep_eq(fidx.map, idx.map), ctx .. " P4 file index")
            end
            local bfidx, bferr = rs.scan_file(fpath, { paths = PATHS, allow_duplicates = true, validate = "shallow" })
            t:eq(bferr, serr, ctx .. " P4 shallow file verdict")
            if bfidx and sidx then
                t:ok(R.deep_eq(bfidx.members, sidx.members), ctx .. " P4 shallow file index")
            end
        end
    end

    for i = 1, n do
        local json = gen:document(gen:rand(4) > 1)
        stats.docs = stats.docs + 1
        check("doc", i, json)
        local m = gen:mutate(json)
        stats.mutations = stats.mutations + 1
        check("mut", i, m)
        -- file-mode verdicts on mutated documents too (sampled)
        if i % 10 == 5 then
            U.write_file(fpath, m)
            for _, mode in ipairs({ "strict", "shallow" }) do
                local _, se = rs.scan_string(m, { validate = mode })
                local _, fe = rs.scan_file(fpath, { validate = mode })
                t:eq(fe, se, fail_ctx("mut", i, m) .. " P4 " .. mode .. " file verdict on mutation")
            end
        end
    end

    g:destroy()
    os.remove(fpath)
    t:note(stats)
end
