-- Offsets against lua-cjson on hand-written documents: empty/nested containers,
-- whitespace, Unicode, escapes, \u0000, duplicate detection through escapes.

local rs = require("resty.simdjson.root_scan")
local U  = require("rs_util")

local PATHS = { "model", "prompt_cache_key", "metadata.user_id", "stream", "stream_options", "service_tier" }

local DOCS = {
    '{}',
    ' {} ',
    '{"a":{}}',
    '{"a":[]}',
    '{"a":{"b":{"c":[[],{},[{}]]}}}',
    '{"a":1,"b":-2.5e-3,"c":0,"d":-0,"e":1E+2,"f":12345678901234567890}',
    '{"t":true,"f":false,"n":null}',
    '{ "a" : 1 , "b" :\t[ 1 ,\n2 ] ,\r\n"c" : { "d" : "e" } }',
    '\r\n\t {\r\n\t"a"\r\n\t:\r\n\t"b"\r\n\t}\r\n\t ',
    '{"中文":"值","😀":"😀😀","é":"\\u00e9"}',
    '{"k":"\\u0000","\\u0000":0}',
    '{"s":"\\"\\\\\\/\\b\\f\\n\\r\\t"}',
    '{"s":"\\ud83d\\ude00","e":"\\uD834\\uDD1E"}',
    '{"model":"gpt-4o","messages":[{"role":"system","content":"You are \\"helpful\\"."},' ..
        '{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image_url",' ..
        '"image_url":{"url":"data:image/png;base64,iVBORw0KGgo="}}]}],"stream":true,' ..
        '"stream_options":{"include_usage":true},"service_tier":"flex","prompt_cache_key":"s1",' ..
        '"metadata":{"user_id":"u-1","tag":"x"}}',
    '{"model":"claude","max_tokens":1024,"messages":[{"role":"user","content":"x"}],' ..
        '"metadata":{"user_id":"user_abc_account__session_123"}}',
    '{"a":"' .. string.rep("x", 5000) .. '","b":[' .. string.rep("1,", 2000) .. '1]}',
    '{"deep":' .. string.rep("[", 120) .. string.rep("]", 120) .. '}',
}

return function(t)
    for _, mode in ipairs({ "strict", "shallow" }) do
    for i, json in ipairs(DOCS) do
        local label = mode .. " doc#" .. i
        local idx, err = rs.scan_string(json, { paths = PATHS, validate = mode })
        if t:ok(idx, label .. ": scans (" .. tostring(err) .. ")") then
            U.check_index(t, json, idx, label)
            local doc = U.cjson.decode(json)
            for _, p in ipairs(PATHS) do
                t:deq(idx.map[p], U.cj_path(doc, p), label .. " map[" .. p .. "]")
            end
            -- raw slices of hits are exactly the text at their offsets
            for p, v in pairs(idx.values) do
                t:eq(v.raw, json:sub(v.value_start + 1, v.value_end), label .. " raw " .. p)
            end
            local fidx = rs.scan_string(json, { paths = PATHS, _force_copy = true, validate = mode })
            t:ok(fidx and require("rs_runner").deep_eq(fidx.members, idx.members)
                 and require("rs_runner").deep_eq(fidx.map, idx.map), label .. ": forced copy identical")
            t:ok(fidx and fidx.copied_bytes == #json, label .. ": forced copy reports copied bytes")
        end
    end
    end

    -- byte offsets with multi-byte content
    local j = '{"中":"文","b":1}'
    local idx = rs.scan_string(j)
    t:deq({ idx.members[1].key_start, idx.members[1].key_end, idx.members[1].value_start, idx.members[1].value_end },
          { 1, 6, 7, 12 }, "UTF-8 offsets are in bytes")
    t:eq(idx.members[2].key_start, 13, "second key after multi-byte value")

    -- surrogate-pair key equals the raw emoji key -> duplicate
    local _, err = rs.scan_string('{"\\ud83d\\ude00":1,"😀":2}')
    t:eq(err, "duplicate_key", "escaped emoji key duplicates the raw emoji key")
    -- \u0000 inside keys: distinct from the empty key
    idx = rs.scan_string('{"":1,"\\u0000":2}')
    t:ok(idx and idx.members[1].key == "" and idx.members[2].key == "\0", "empty key and NUL key distinct")
    -- keys differing only after an escape are distinct
    idx = rs.scan_string('{"a\\nb":1,"a\\rb":2}')
    t:ok(idx and not idx.has_duplicates, "different escapes are different keys")
    -- uppercase/lowercase hex escapes are the same key
    _, err = rs.scan_string('{"\\u00E9":1,"\\u00e9":2}')
    t:eq(err, "duplicate_key", "hex case does not matter")

    -- many members: dedupe table growth keeps order and detects a late duplicate
    local parts = {}
    for i = 1, 256 do parts[i] = '"k' .. i .. '":' .. i end
    local big = "{" .. table.concat(parts, ",") .. "}"
    idx = rs.scan_string(big)
    t:ok(idx and #idx.members == 256 and idx.members[256].key == "k256", "256 members in order")
    parts[256] = '"k7":0'
    _, err = rs.scan_string("{" .. table.concat(parts, ",") .. "}")
    t:eq(err, "duplicate_key", "late duplicate found after table growth")

    -- map shape matches gjson:get_many for the gateway's three fields
    local gjson = require("resty.simdjson.gjson")
    local g = gjson.new(true)
    local fields = { "model", "prompt_cache_key", "metadata.user_id" }
    for i = 14, 15 do
        local json = DOCS[i]
        local want = g:get_many(json, fields)
        local got = rs.scan_string(json, { paths = fields })
        t:deq(got.map, want, "doc#" .. i .. " map equals get_many")
    end
    g:destroy()
end
