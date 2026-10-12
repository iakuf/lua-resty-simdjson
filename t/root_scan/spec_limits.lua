-- Resource limits (defaults, custom, hard caps), nesting, truncation,
-- trailing content and root types.

local rs = require("resty.simdjson.root_scan")
local U  = require("rs_util")

-- strict unless the caller picks a mode: these are scheme A's guarantees
local function code(json, opts)
    opts = opts or {}
    if opts.validate == nil then opts.validate = "strict" end
    local idx, err = rs.scan_string(json, opts)
    return idx and "ok" or err
end

local function scan(json, opts)
    opts = opts or {}
    if opts.validate == nil then opts.validate = "strict" end
    return rs.scan_string(json, opts)
end

-- document whose total container depth is n (root object = 1)
local function nest(n)
    return '{"a":' .. string.rep("[", n - 1) .. string.rep("]", n - 1) .. "}"
end

return function(t)
    -- depth ----------------------------------------------------------------
    t:eq(code(nest(128)), "ok", "depth 128 passes")
    t:eq(code(nest(129)), "limit_depth", "depth 129 fails")
    local idx = scan(nest(128))
    t:eq(idx and idx.max_depth_seen, 128, "max_depth_seen 128")
    t:eq(code(nest(4), { max_depth = 4 }), "ok", "custom depth 4 passes")
    t:eq(code(nest(5), { max_depth = 4 }), "limit_depth", "custom depth 5 fails")
    t:eq(code('{"a":{"b":{"c":{}}}}', { max_depth = 3 }), "limit_depth", "object nesting counts")
    t:eq(code(nest(1024), { max_depth = 1024 }), "ok", "hard cap 1024 passes")
    t:eq(code("{}", { max_depth = 1025 }), "bad_args", "max_depth above hard cap")
    local _, err, d = scan(nest(129))
    t:eq(d and d.offset, 5 + 127, "limit_depth offset at the 129th opener")

    local deep = '{"a":' .. string.rep("[", 100000) .. string.rep("]", 100000) .. "}"
    local t0 = U.now_ns()
    t:eq(code(deep), "limit_depth", "100000 levels fail fast")
    t:eq(code(deep, { max_depth = 1024 }), "limit_depth", "100000 levels with max_depth 1024")
    local dt = (U.now_ns() - t0) / 1e6
    t:ok(dt < 1000, "100000 levels: two scans in " .. string.format("%.1f", dt) .. " ms")
    t:note({ case = "100000-level nesting", strict = code(deep), shallow = code(deep, { validate = "shallow" }) })

    -- scheme B (the module default): depth is only enforced on the levels it walks
    t:eq(code(nest(129), { validate = "shallow" }), "ok", "shallow: nested depth not enforced (residual risk)")
    t:eq(code(deep, { validate = "shallow" }), "ok", "shallow: 100000 levels pass (residual risk)")
    t:eq(code('{"metadata":' .. string.rep("[", 200) .. string.rep("]", 200) .. "}",
              { validate = "shallow", paths = { "metadata.user_id" } }), "ok",
         "shallow: wanted parent that is an array is skipped")
    t:eq(code('{"metadata":{"a":' .. string.rep("[", 200) .. string.rep("]", 200) .. "}}",
              { validate = "shallow", paths = { "metadata.user_id" }, max_depth = 2 }), "limit_depth",
         "shallow: a wanted parent's direct children still count against max_depth")
    local unclosed = '{"a":' .. string.rep("[", 100000) .. "}"
    t:eq(code(unclosed), "limit_depth", "100000 unclosed levels")

    -- members --------------------------------------------------------------
    local function members(n)
        local p = {}
        for i = 1, n do p[i] = '"k' .. i .. '":0' end
        return "{" .. table.concat(p, ",") .. "}"
    end
    t:eq(code(members(256)), "ok", "256 members pass")
    t:eq(code(members(257)), "limit_members", "257 members fail")
    t:eq(code(members(257), { validate = "shallow" }), "limit_members", "shallow: 257 members fail")
    t:eq(code('{"' .. string.rep("k", 1025) .. '":1}', { validate = "shallow" }), "limit_key",
         "shallow: 1025-byte key fails")
    t:eq(code('{"model":"' .. string.rep("m", 65536) .. '"}', { validate = "shallow", paths = { "model" } }),
         "limit_extract", "shallow: extract limit")
    t:eq(code(members(3), { max_members = 2 }), "limit_members", "custom max_members")
    t:eq(code(members(3000), { max_members = 65536 }), "ok", "3000 members under the hard cap")
    t:eq(code("{}", { max_members = 65537 }), "bad_args", "max_members above hard cap")
    t:eq(code('{"a":[' .. string.rep("1,", 5000) .. '1],"b":{' .. members(400):sub(2, -2) .. '}}'), "ok",
         "nested members are not counted")

    -- key length (decoded bytes, top level only) ---------------------------
    t:eq(code('{"' .. string.rep("k", 1024) .. '":1}'), "ok", "1024-byte key passes")
    t:eq(code('{"' .. string.rep("k", 1025) .. '":1}'), "limit_key", "1025-byte key fails")
    t:eq(code('{"' .. string.rep("\\u0061", 1024) .. '":1}'), "ok", "escaped key decoding to 1024 bytes")
    t:eq(code('{"' .. string.rep("\\u0061", 1025) .. '":1}'), "limit_key", "escaped key decoding to 1025 bytes")
    t:eq(code('{"' .. string.rep("中", 342) .. '":1}'), "limit_key", "multi-byte key 1026 bytes")
    t:eq(code('{"' .. string.rep("\\u4e2d", 341) .. '":1}'), "ok", "escaped multi-byte key 1023 bytes")
    t:eq(code('{"' .. string.rep("k", 9) .. '":1}', { max_key_bytes = 8 }), "limit_key", "custom max_key_bytes")
    t:eq(code('{"o":{"' .. string.rep("k", 5000) .. '":1}}'), "ok", "nested keys are not limited")
    t:eq(code("{}", { max_key_bytes = 65537 }), "bad_args", "max_key_bytes above hard cap")
    t:eq(code('{"' .. string.rep("k", 65536) .. '":1}', { max_key_bytes = 65536 }), "ok", "key at hard cap")

    -- extracted bytes ------------------------------------------------------
    local function model(rawlen)  -- raw value length including quotes
        return '{"model":"' .. string.rep("m", rawlen - 2) .. '"}'
    end
    t:eq(code(model(65536), { paths = { "model" } }), "ok", "extract 65536 bytes passes")
    t:eq(code(model(65537), { paths = { "model" } }), "limit_extract", "extract 65537 bytes fails")
    t:eq(code(model(65537)), "ok", "no limit without paths")
    t:eq(code('{"model":"' .. string.rep("m", 40000) .. '","stream_options":"' .. string.rep("s", 30000) .. '"}',
              { paths = { "model", "stream_options" } }), "limit_extract", "limit is the sum over paths")
    t:eq(code('{"model":"aaaa","model":"bbbb"}', { paths = { "model" }, max_extract_bytes = 8,
              allow_duplicates = true }), "limit_extract", "duplicates count toward the limit")
    t:eq(code("{}", { max_extract_bytes = 16 * 1024 * 1024 + 1 }), "bad_args", "max_extract above hard cap")
    local huge = '{"model":"' .. string.rep("x", 50 * 1000 * 1000) .. '","stream":true}'
    local h_idx, h_err, h_d = scan(huge, { paths = { "model", "stream" } })
    t:eq(h_err, "limit_extract", "50 MB model value -> limit_extract")
    t:eq(h_d and h_d.offset, 9, "limit_extract offset at the value")
    t:ok(h_idx == nil, "no index on fatal limit")
    t:eq(code(huge, { paths = { "stream" } }), "ok", "50 MB value not extracted passes")
    huge = nil

    -- truncation: every proper prefix of a valid document is a syntax error -
    local doc = '{"model":"gpt","messages":[{"role":"user","content":"hi \\"x\\" \\u00e9"}],' ..
                '"stream":true,"n":-1.5e3,"metadata":{"user_id":"u"},"z":null}'
    t:eq(code(doc), "ok", "base document")
    local bad = 0
    for n = 1, #doc - 1 do
        local c = code(doc:sub(1, n))
        if c ~= "syntax" then
            bad = bad + 1
            t:ok(false, "prefix " .. n .. " -> " .. c)
        end
    end
    t:eq(bad, 0, "all " .. (#doc - 1) .. " proper prefixes are syntax errors")

    -- trailing content -----------------------------------------------------
    for _, s in ipairs({ '{} {}', '{}x', '{"a":1} x', '{"a":1}}', '{}\0', '{}]', '{} 1', '{} "s"',
                         '{} null', '{}\n{}\n', '{},', '{}\255' }) do
        t:eq(code(s), "trailing_content", "trailing " .. U.hex(s))
    end
    t:eq(code('{"a":1} \n\t\r '), "ok", "trailing whitespace is fine")
    local _, e2, d2 = scan('{"a":1}}', { paths = { "a" } })
    t:eq(e2, "trailing_content", "trailing after a valid object")
    t:eq(d2 and d2.offset, 7, "trailing offset")
    -- a limit inside the prefix wins over the trailing bytes (document order)
    t:eq(code('{"' .. string.rep("k", 1025) .. '":1} x'), "limit_key", "limit before trailing")

    -- root types -----------------------------------------------------------
    for _, s in ipairs({ "[1]", "[]", '"s"', "0", "-1", "true", "false", "null", " [", "\n12" }) do
        t:eq(code(s), "root_not_object", "root " .. U.hex(s))
    end
    for _, s in ipairs({ "}", "x", "\239\187\191{}", "\0{}", "/", "'{}'" }) do
        t:eq(code(s), "syntax", "first byte " .. U.hex(s))
    end
end
