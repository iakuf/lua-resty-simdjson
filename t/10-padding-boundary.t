# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * blocks() * 5;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?/init.lua;$pwd/lib/?.lua;;";
    lua_package_cpath "$pwd/?.so;;";
};

no_long_string();
no_diff();

run_tests();

__DATA__

=== TEST 1: input ending right before an unreadable page is parsed without reading past it
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local ffi = require("ffi")
            local C = require("resty.simdjson.cdefs")
            local errmsg = require("resty.core.base").get_errmsg_ptr()

            if ffi.os ~= "Linux" then
                ngx.say("ok")
                return
            end

            -- Declared one by one so a declaration made elsewhere does not
            -- stop the remaining ones from being declared.
            for _, decl in ipairs({
                "int getpagesize(void);",
                "void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);",
                "int mprotect(void *addr, size_t len, int prot);",
                "int munmap(void *addr, size_t length);",
            }) do
                pcall(ffi.cdef, decl)
            end

            local PROT_NONE, PROT_RW = 0, 3
            local MAP_PRIVATE_ANON = 0x22
            local PADDING = 64

            -- Two pages: the first holds the JSON, the second is PROT_NONE so
            -- any read past the end of the input faults immediately.
            local P = ffi.C.getpagesize()
            local region = ffi.C.mmap(nil, 2 * P, PROT_RW, MAP_PRIVATE_ANON, -1, 0)
            assert(ffi.cast("intptr_t", region) ~= -1, "mmap failed")
            local base = ffi.cast("char *", region)
            assert(ffi.C.mprotect(base + P, P, PROT_NONE) == 0, "mprotect failed")

            local cases = {
                { json = [[{"model":"m","messages":[{"role":"user","content":"hi"}],"user":"abc"}]],
                  pointer = "/user", want = "abc" },
                { json = [[{"a":[1,2.5,-3e2,true,false,null],"s":"x\u00e9\"y"}]],
                  pointer = "/s", want = "x\195\169\"y" },
                { json = [[{"n":12345}]], pointer = "/n", number = 12345 },
            }

            local state = C.simdjson_ffi_state_new()
            assert(state ~= nil)
            local ops = C.simdjson_ffi_state_get_ops(state)

            local function check_op(n, case, what)
                assert(n == 1, what .. ": expected 1 op, got " .. tostring(n))
                if case.number then
                    assert(ops[0].opcode == C.SIMDJSON_FFI_OPCODE_NUMBER, what .. ": not a number")
                    assert(ops[0].val.number == case.number, what .. ": wrong number")
                else
                    assert(ops[0].opcode == C.SIMDJSON_FFI_OPCODE_STRING, what .. ": not a string")
                    assert(ffi.string(ops[0].val.str, ops[0].size) == case.want, what .. ": wrong string")
                end
            end

            -- k = distance from the last input byte to the end of the page.
            for _, case in ipairs(cases) do
                local len = #case.json
                for k = 0, 2 * PADDING + 8 do
                    local dst = base + P - k - len
                    ffi.copy(dst, case.json, len)
                    local what = case.pointer .. " k=" .. k

                    -- iterate + at_pointer (the gjson:get path)
                    assert(C.simdjson_ffi_iterate(state, dst, len, errmsg) == 0, what .. ": iterate")
                    check_op(C.simdjson_ffi_at_pointer(state, case.pointer, #case.pointer, errmsg),
                             case, what .. " at_pointer")

                    -- one-shot get_pointer
                    check_op(C.simdjson_ffi_get_pointer(state, dst, len, case.pointer, #case.pointer, errmsg),
                             case, what .. " get_pointer")

                    -- full decode (the decoder:process path)
                    assert(C.simdjson_ffi_parse(state, dst, len, errmsg) == 1, what .. ": parse")
                    assert(ops[0].opcode == C.SIMDJSON_FFI_OPCODE_OBJECT, what .. ": root not object")
                    repeat
                        local n = C.simdjson_ffi_next(state, errmsg)
                        assert(n >= 0, what .. ": next failed")
                    until n == 0
                    assert(C.simdjson_ffi_is_eof(state) == 1, what .. ": not at eof")
                end
            end

            C.simdjson_ffi_state_free(state)
            assert(ffi.C.munmap(region, 2 * P) == 0)

            ngx.say("ok")
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
[warn]
[crit]
