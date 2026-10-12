-- File input: sizes around page multiples, equality with string mode and
-- lua-cjson, and I/O errors.

local rs = require("resty.simdjson.root_scan")
local R  = require("rs_runner")
local U  = require("rs_util")

local PATHS = { "model", "metadata.user_id", "stream" }

-- valid document of exactly `size` bytes; `tail` selects how it ends
local MODES = { "strict", "shallow" }

local function doc_of(size, tail)
    local head = '{"model":"m","metadata":{"user_id":"u"},"stream":false,"pad":"'
    local close = tail == "ws" and '"}\n' or (tail == "trail" and '"}x' or '"}')
    local n = size - #head - #close
    assert(n >= 0, "size too small")
    return head .. string.rep("p", n) .. close
end

local function same(t, label, a, ea, b, eb)
    if not t:eq(ea, eb, label .. ": same verdict") then return end
    if a and b then
        t:ok(R.deep_eq(a.members, b.members), label .. ": same members")
        t:ok(R.deep_eq(a.map, b.map), label .. ": same values")
        t:eq(a.root_end, b.root_end, label .. ": same root_end")
    end
end

return function(t)
    local P = U.page_size()
    t:eq(P, 4096, "page size")
    local path = U.tmp("file.json")

    for _, k in ipairs({ 1, 2, 3, 16 }) do
        for _, dlt in ipairs({ -65, -64, -63, -1, 0, 1, 63, 64 }) do
            for _, tail in ipairs({ "plain", "ws", "trail" }) do
              for _, mode in ipairs(MODES) do
                local size = k * P + dlt
                local json = doc_of(size, tail)
                assert(#json == size)
                U.write_file(path, json)
                local label = string.format("%s size %d*P%+d %s", mode, k, dlt, tail)
                local fi, fe = rs.scan_file(path, { paths = PATHS, validate = mode })
                local si, se = rs.scan_string(json, { paths = PATHS, validate = mode })
                same(t, label, fi, fe, si, se)
                if tail == "trail" then
                    t:eq(fe, "trailing_content", label .. ": trailing")
                elseif t:ok(fi, label .. ": file scans (" .. tostring(fe) .. ")") then
                    t:eq(fi.input_len, size, label .. ": input_len")
                    t:eq(fi.copied_bytes, 0, label .. ": no copy")
                    U.check_index(t, json, fi, label)
                    t:eq(fi.map["metadata.user_id"], "u", label .. ": second-level value")
                end
              end
            end
        end
    end

    -- larger file with structure spread over many pages
    local parts = {}
    for i = 1, 3000 do
        parts[i] = '{"role":"user","content":"' .. i .. ':' .. string.rep("x", 300) .. '"}'
    end
    local big = '{"model":"big","messages":[' .. table.concat(parts, ",") .. '],"prompt_cache_key":"pk"}'
    U.write_file(path, big)
    local fi, fe = rs.scan_file(path, { paths = { "model", "prompt_cache_key" } })
    local si, se = rs.scan_string(big, { paths = { "model", "prompt_cache_key" } })
    same(t, "1 MB file", fi, fe, si, se)
    t:ok(fi and fi.map.prompt_cache_key == "pk", "key after 1 MB of messages")

    -- I/O errors
    U.write_file(path, "")
    local _, err, d = rs.scan_file(path)
    t:eq(err, "syntax", "empty file")
    U.write_file(path, "  \n ")
    _, err = rs.scan_file(path)
    t:eq(err, "syntax", "whitespace-only file")
    U.write_file(path, "[1]")
    _, err = rs.scan_file(path)
    t:eq(err, "root_not_object", "array file")
    os.remove(path)
    _, err, d = rs.scan_file(path)
    t:eq(err, "io", "missing file")
    t:eq(d and d.errno, 2, "ENOENT")
    _, err, d = rs.scan_file("/tmp")
    t:eq(err, "io", "directory")
    t:eq(d and d.errno, 21, "EISDIR")
    _, err, d = rs.scan_file("/dev/null")
    t:eq(err, "io", "character device")
    t:eq(d and d.errno, 22, "not a regular file -> EINVAL")

    U.write_file(path, '{"a":1}')
    os.execute("chmod 000 " .. path)
    local uid = io.popen("id -u"):read("*l")
    _, err, d = rs.scan_file(path)
    if uid ~= "0" then
        t:eq(err, "io", "chmod 000 as uid " .. uid)
        t:eq(d and d.errno, 13, "EACCES")
    else
        t:note({ skip = "chmod 000 check runs as root" })
    end
    os.execute("chmod 600 " .. path)
    os.remove(path)
end
