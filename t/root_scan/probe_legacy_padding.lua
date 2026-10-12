-- resty t/root_scan/probe_legacy_padding.lua <k> <doc>
-- Probe (report only, not a gate) for the EXISTING need_allocation() check
-- used by simdjson_ffi_parse / iterate / get_pointer: the input's last byte is
-- placed k bytes before a PROT_NONE page and simdjson_ffi_get_pointer() is
-- called once. A read past the end shows up as SIGSEGV (exit by signal 11).
-- Run one (k, doc) per process.

package.path = "t/root_scan/?.lua;lib/?.lua;lib/?/init.lua;" .. package.path

local ffi = require("ffi")
local U   = require("rs_util")
local C   = require("resty.simdjson.cdefs")

local k = tonumber(arg[1])
local DOCS = {
    str = '{"n":0,"model":"probe-model"}',
    num = '{"s":"x","model":12345678}',
}
local json = assert(DOCS[arg[2]], "doc must be str or num")

local P = U.page_size()
local base = ffi.C.mmap(nil, 2 * P, U.PROT_READ + U.PROT_WRITE, U.MAP_PRIVATE + U.MAP_ANONYMOUS, -1, 0)
assert(base ~= U.MAP_FAILED)
base = ffi.cast("char *", base)
ffi.fill(base, P, 0x20)
assert(ffi.C.mprotect(base + P, P, U.PROT_NONE) == 0)

local L = #json
local p = base + P - k - L
ffi.copy(p, json, L)

local state = C.simdjson_ffi_state_new()
local ops = C.simdjson_ffi_state_get_ops(state)
local errmsg = ffi.new("const char *[1]")
local n = C.simdjson_ffi_get_pointer(state, p, L, "/model", 6, ffi.cast("char **", errmsg))
local val
if n == 1 then
    local op = ops[0]
    val = op.opcode == C.SIMDJSON_FFI_OPCODE_STRING and ffi.string(op.val.str, op.size) or tostring(op.val.number)
end
-- last-byte offset inside its page; the existing check copies only when this is < 64
local in_page = P - 1 - k
print(string.format('{"k":%d,"doc":"%s","rc":%d,"value":"%s","last_byte_page_offset":%d,"legacy_copies":%s}',
      k, arg[2], n, tostring(val), in_page, tostring(in_page < 64)))
C.simdjson_ffi_state_free(state)
