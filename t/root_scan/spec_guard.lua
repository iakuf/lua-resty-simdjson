-- Zero-copy safety for string input: the JSON's last byte is placed k bytes
-- before a PROT_NONE guard page (k = 0..80). Reading past the end would
-- SIGSEGV the process; the scan must copy exactly when k <= 63.

local ffi = require("ffi")
local rs  = require("resty.simdjson.root_scan")
local R   = require("rs_runner")
local U   = require("rs_util")
local C   = require("resty.simdjson.cdefs")

local DOCS = {
    '{"model":"guard","messages":[{"role":"user","content":"x"}],"stream":true}',
    '{"a":1}   ',
    '{"a":"tail \\u00e9"}x',
    '{"n":-12.5e3}',
    '{}',
}

return function(t)
    local P = U.page_size()
    local base = ffi.C.mmap(nil, 2 * P, U.PROT_READ + U.PROT_WRITE, U.MAP_PRIVATE + U.MAP_ANONYMOUS, -1, 0)
    assert(base ~= U.MAP_FAILED, "mmap")
    base = ffi.cast("char *", base)
    assert(ffi.C.mprotect(base + P, P, U.PROT_NONE) == 0, "mprotect")

    local out = ffi.new("simdjson_ffi_rs_result_t *[1]")
    for di, json in ipairs(DOCS) do
        local want_idx, want_err = rs.scan_string(json)
        for k = 0, 80 do
            local L = #json
            local p = base + P - k - L
            ffi.fill(base, P, 0x41)     -- non-zero garbage around the document
            ffi.copy(p, json, L)
            local rc = C.simdjson_ffi_root_scan_string(p, L, nil, out)
            local res = out[0]
            local label = "doc#" .. di .. " k=" .. k
            t:ok(res ~= nil, label .. ": result")
            if res ~= nil then
                local copied = tonumber(res.copied_bytes)
                t:eq(copied > 0, k <= 63, label .. ": copies iff within 63 bytes of the guard page")
                t:eq(rc, want_err and ({ trailing_content = -12 })[want_err] or 0, label .. ": status")
                if rc == 0 then
                    t:eq(res.member_count, #want_idx.members, label .. ": member count")
                    local m = res.members[0]
                    if res.member_count > 0 then
                        t:eq(tonumber(m.value_end), want_idx.members[1].value_end, label .. ": first member offsets")
                    end
                    t:eq(tonumber(res.root_end), want_idx.root_end, label .. ": root_end")
                end
                C.simdjson_ffi_root_scan_free(res)
            end
        end
        -- forced copy gives the same index as the zero-copy path
        local fi, fe = rs.scan_string(json, { _force_copy = true })
        t:eq(fe, want_err, "doc#" .. di .. ": forced copy verdict")
        if fi and want_idx then
            t:ok(R.deep_eq(fi.members, want_idx.members), "doc#" .. di .. ": forced copy members")
            t:eq(fi.copied_bytes, #json, "doc#" .. di .. ": forced copy bytes")
        end
    end

    ffi.C.munmap(base, 2 * P)
end
