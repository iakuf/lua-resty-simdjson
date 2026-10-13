-- Smoke and exact fixtures: ABI, argument errors, offsets, escaped and
-- duplicate keys, nested names, second-level extraction, trailing/truncated.

local ffi = require("ffi")
local rs  = require("resty.simdjson.root_scan")
local U   = require("rs_util")

return function(t)
    -- ABI ------------------------------------------------------------------
    t:eq(rs.ABI_VERSION, 1, "ABI_VERSION")
    t:eq(rs.DEFAULT_VALIDATE, "shallow", "DEFAULT_VALIDATE (scheme B by the measured gates)")
    -- the default skips nested containers by bracket counting; strict walks them
    t:ok(rs.scan_string('{"a":[1}}') ~= nil, "default (shallow) accepts a nested bracket mismatch")
    t:eq(select(2, rs.scan_string('{"a":[1}}', { validate = "strict" })), "syntax", "strict rejects it")
    t:eq(select(2, rs.scan_string('{"a":01}')), "syntax", "default still validates top-level scalars")
    local C = require("resty.simdjson.cdefs")
    local sizes = ffi.new("uint32_t[5]")
    t:eq(C.simdjson_ffi_root_scan_abi(sizes, 5), 1, "abi() version")
    t:deq({ sizes[0], sizes[1], sizes[2], sizes[3], sizes[4] }, { 32, 32, 48, 32, 144 }, "abi() sizes")
    C.simdjson_ffi_root_scan_free(nil)
    t:ok(true, "free(NULL) is safe")

    -- argument and input errors -----------------------------------------------
    local function code(json, opts)
        local idx, err = rs.scan_string(json, opts)
        return idx and "ok" or err
    end
    t:eq(code(""), "syntax", "empty input")
    t:eq(code(" \t\r\n "), "syntax", "whitespace only")
    t:eq(code("[1]"), "root_not_object", "array root")
    t:eq(code('"x"'), "root_not_object", "string root")
    t:eq(code("12"), "root_not_object", "number root")
    t:eq(code("null"), "root_not_object", "null root")
    t:eq(code("true"), "root_not_object", "true root")
    t:eq(code("\239\187\191{}"), "syntax", "UTF-8 BOM")
    t:eq(code("x{}"), "syntax", "garbage first byte")
    t:eq(code("{}"), "ok", "empty object")

    local _, err, d = rs.scan_string(123)
    t:eq(err, "bad_args", "non-string json")
    t:eq(d.status, -41, "bad_args status")
    _, err = rs.scan_file(nil)
    t:eq(err, "bad_args", "non-string path")
    _, err = rs.scan_string("{}", "x")
    t:eq(err, "bad_args", "non-table opts")
    t:eq(code("{}", { paths = { "a.b.c" } }), "bad_args", "3-segment path")
    t:eq(code("{}", { paths = { "a..b" } }), "bad_args", "empty segment")
    t:eq(code("{}", { paths = { "" } }), "bad_args", "empty path")
    t:eq(code("{}", { paths = { ".a" } }), "bad_args", "leading dot")
    t:eq(code("{}", { paths = { "messages.0" } }), "bad_args", "array index segment")
    t:eq(code("{}", { paths = { "messages.#(role==system)" } }), "bad_args", "predicate")
    t:eq(code("{}", { paths = { string.rep("k", 257) } }), "bad_args", "segment > 256 bytes")
    t:eq(code("{}", { paths = { string.rep("k", 256) } }), "ok", "segment = 256 bytes")
    local many = {}
    for i = 1, 17 do many[i] = "k" .. i end
    t:eq(code("{}", { paths = many }), "bad_args", "17 paths")
    many[17] = nil
    t:eq(code("{}", { paths = many }), "ok", "16 paths")
    t:eq(code("{}", { paths = { 1 } }), "bad_args", "non-string path entry")
    t:eq(code("{}", { validate = "lax" }), "bad_args", "unknown validate")
    t:eq(code("{}", { max_depth = -1 }), "bad_args", "negative limit")
    t:eq(code("{}", { max_depth = 1.5 }), "bad_args", "fractional limit")

    local nofile = "/tmp/rs-smoke-does-not-exist.json"
    os.remove(nofile)
    _, err, d = rs.scan_file(nofile)
    t:eq(err, "io", "missing file")
    t:eq(d.errno, 2, "missing file errno ENOENT")
    t:ok(not (d.message or ""):find(nofile, 1, true), "message does not contain the path")
    _, err, d = rs.scan_file("/tmp")
    t:eq(err, "io", "directory")
    t:eq(d.errno, 21, "directory errno EISDIR")
    _, err = rs.scan_file("")
    t:eq(err, "bad_args", "empty path")
    _, err = rs.scan_file("/tmp/a\0b")
    t:eq(err, "bad_args", "path with NUL")
    _, err = rs.scan_file("/" .. string.rep("a", 4095))
    t:eq(err, "bad_args", "path > 4095 bytes")

    -- exact offsets -------------------------------------------------------------
    local j = '{"model":"a","messages":[1],"stream":true}'
    local idx, e2 = rs.scan_string(j, { paths = { "model", "stream", "missing" } })
    t:ok(idx, "fixture parses: " .. tostring(e2))
    if idx then
        t:eq(#idx.members, 3, "member count")
        local m = idx.members
        t:deq({ m[1].key, m[1].key_start, m[1].key_end, m[1].value_start, m[1].value_end, m[1].type },
              { "model", 1, 8, 9, 12, "string" }, "model member")
        t:deq({ m[2].key, m[2].key_start, m[2].key_end, m[2].value_start, m[2].value_end, m[2].type },
              { "messages", 13, 23, 24, 27, "array" }, "messages member")
        t:deq({ m[3].key, m[3].key_start, m[3].key_end, m[3].value_start, m[3].value_end, m[3].type },
              { "stream", 28, 36, 37, 41, "boolean" }, "stream member")
        t:eq(idx.root_start, 0, "root_start")
        t:eq(idx.root_end, #j, "root_end")
        t:eq(idx.values.model.raw, '"a"', "model raw")
        t:eq(idx.map.model, "a", "model value")
        t:eq(idx.map.stream, true, "stream value")
        t:eq(idx.values.missing, nil, "missing path absent")
        t:eq(idx.mode, "string", "mode")
        t:eq(idx.input_len, #j, "input_len")
        t:eq(idx.max_depth_seen, 2, "max_depth_seen")
        t:ok(idx.timing.total_ns > 0, "timing present")
        U.check_index(t, j, idx, "fixture")
    end

    -- whitespace around everything
    j = ' \n{ "model" :\t"a" ,\r\n "n" : [ 1 , 2 ] }\n '
    idx = rs.scan_string(j)
    t:ok(idx, "whitespace fixture parses")
    if idx then
        t:deq({ idx.members[1].key_start, idx.members[1].key_end, idx.members[1].value_start, idx.members[1].value_end },
              { 4, 11, 14, 17 }, "model offsets with whitespace")
        t:deq({ idx.members[2].value_start, idx.members[2].value_end }, { 28, 37 }, "array offsets with whitespace")
        t:eq(idx.root_start, 2, "root_start after whitespace")
        t:eq(idx.root_end, #j - 2, "root_end before whitespace")
    end

    -- escaped key equals "model"
    j = '{"mo\\u0064el":"x","messages":[]}'
    idx = rs.scan_string(j, { paths = { "model" } })
    t:ok(idx and idx.map.model == "x", "escaped key matches model")
    t:eq(idx and idx.members[1].key, "model", "escaped key decoded")
    t:eq(idx and idx.members[1].key_end, 13, "escaped key_end covers the escaped text")

    -- duplicate key
    j = '{"model":"a","x":1,"mo\\u0064el":"b"}'
    local _, derr, dd = rs.scan_string(j, { paths = { "model" } })
    t:eq(derr, "duplicate_key", "duplicate default is an error")
    t:ok(dd and dd.index and dd.index.map.model == "b", "duplicate detail carries the index, last wins")
    idx = rs.scan_string(j, { paths = { "model" }, allow_duplicates = true })
    t:ok(idx and idx.has_duplicates, "allow_duplicates returns the index")
    if idx then
        t:deq({ idx.members[1].duplicate, idx.members[2].duplicate, idx.members[3].duplicate },
              { true, false, true }, "every occurrence marked")
        t:eq(idx.values.model.duplicate, true, "path marked duplicate")
        t:eq(idx.map.model, "b", "last occurrence wins")
    end

    -- nested same name is not top level
    j = '{"messages":[{"model":"x"}],"model":"y","stream_options":{"stream":true}}'
    idx = rs.scan_string(j, { paths = { "model", "stream" } })
    t:ok(idx and idx.map.model == "y", "top-level model, not messages[0].model")
    t:ok(idx and idx.map.stream == nil, "stream_options.stream is not top-level stream")
    idx = rs.scan_string('{"messages":[{"model":"x"}]}', { paths = { "model" } })
    t:ok(idx and idx.map.model == nil, "nested-only model not found")

    -- second-level extraction
    j = '{"metadata":{"inner":{"user_id":"deep"},"user_id":"u1"},"model":"m"}'
    idx = rs.scan_string(j, { paths = { "metadata.user_id", "model", "metadata" } })
    t:ok(idx and idx.map["metadata.user_id"] == "u1", "metadata.user_id")
    t:ok(idx and type(idx.map.metadata) == "table" and idx.map.metadata.inner.user_id == "deep",
         "metadata object decoded")
    idx = rs.scan_string('{"metadata":{"inner":{"user_id":"deep"}}}', { paths = { "metadata.user_id" } })
    t:ok(idx and idx.map["metadata.user_id"] == nil, "metadata.inner.user_id does not match")
    idx = rs.scan_string('{"metadata":["user_id"]}', { paths = { "metadata.user_id" } })
    t:ok(idx and idx.map["metadata.user_id"] == nil, "array parent does not match")
    idx = rs.scan_string('{"metadata":{"user\\u005fid":"esc"}}', { paths = { "metadata.user_id" } })
    t:ok(idx and idx.map["metadata.user_id"] == "esc", "escaped child key matches")
    _, derr = rs.scan_string('{"metadata":{"user_id":"a","user_id":"b"}}', { paths = { "metadata.user_id" } })
    t:eq(derr, "duplicate_key", "duplicate wanted child key")
    idx = rs.scan_string('{"metadata":{"x":1,"x":2}}', { paths = { "metadata.user_id" } })
    t:ok(idx ~= nil, "non-wanted nested duplicate passes")

    -- trailing and truncated
    t:eq(code('{"a":1} x'), "trailing_content", "trailing garbage")
    t:eq(code('{} {}'), "trailing_content", "two objects")
    t:eq(code('{"a":1}}'), "trailing_content", "extra brace")
    t:eq(code('{}\0'), "trailing_content", "trailing NUL")
    t:eq(code('{"a":1'), "syntax", "truncated")
    t:eq(code('{"a":'), "syntax", "truncated after colon")
    t:eq(code('{"a"'), "syntax", "truncated after key")
    t:eq(code('{'), "syntax", "lone brace")
    local _, terr, td = rs.scan_string('{"a":1}  xy')
    t:eq(terr, "trailing_content", "trailing code")
    t:eq(td and td.offset, 9, "trailing offset is the first trailing byte")

    -- file mode equals string mode on the fixture
    local path = U.tmp("smoke.json")
    j = '{"model":"a","messages":[1],"stream":true}'
    U.write_file(path, j)
    local fi = rs.scan_file(path, { paths = { "model" } })
    local si = rs.scan_string(j, { paths = { "model" } })
    t:ok(fi and fi.mode == "file", "file scan")
    t:ok(fi and si and require("rs_runner").deep_eq(fi.members, si.members), "file members equal string members")
    t:eq(fi and fi.copied_bytes, 0, "file mode never copies")
    os.remove(path)
end
