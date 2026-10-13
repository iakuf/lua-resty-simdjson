# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(1);

plan tests => repeat_each() * blocks() * 3;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?/init.lua;$pwd/lib/?.lua;$pwd/t/root_scan/?.lua;;";
    lua_package_cpath "$pwd/?.so;;";
};

# Pass TEST_NGINX_USE_VALGRIND through to the workers: rs_runner then runs the
# specs in light mode (no large inputs, no timing/RSS/heap assertions).
add_block_preprocessor(sub {
    my $block = shift;
    if (!defined $block->main_config) {
        $block->set_value("main_config", "env TEST_NGINX_USE_VALGRIND;");
    }
});

no_long_string();
no_diff();

run_tests();

__DATA__

=== TEST 1: spec_smoke
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_smoke")
            require("spec_smoke")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 120



=== TEST 2: spec_basic
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_basic")
            require("spec_basic")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 120



=== TEST 3: spec_strict
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_strict")
            require("spec_strict")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 120



=== TEST 4: spec_limits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_limits")
            require("spec_limits")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 300



=== TEST 5: spec_file
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_file")
            require("spec_file")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 120



=== TEST 6: spec_guard
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_guard")
            require("spec_guard")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 120



=== TEST 7: spec_fuzz
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_fuzz")
            require("spec_fuzz")(t, R.parse_args({ "--fuzz-n=1000" }))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 300



=== TEST 8: spec_memory
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local R = require("rs_runner")
            local t = R.new("spec_memory")
            require("spec_memory")(t, R.parse_args({}))
            t:summary()
            ngx.say(t.failed == 0 and "ok" or ("failed " .. t.failed))
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]
--- timeout: 300



=== TEST 9: scan_file on the nginx request-body temp file
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        client_body_in_file_only clean;
        client_max_body_size 8m;
        content_by_lua_block {
            ngx.req.read_body()
            local path = ngx.req.get_body_file()
            local rs = require("resty.simdjson.root_scan")
            local idx, err = rs.scan_file(path, { paths = { "model", "metadata.user_id", "stream" } })
            if not idx then
                ngx.say("error ", err)
                return
            end
            ngx.say(path and "file" or "nofile", " ", idx.map.model, " ", idx.map["metadata.user_id"], " ",
                    tostring(idx.map.stream), " ", #idx.members, " ", idx.copied_bytes, " ",
                    tostring(idx.input_len == tonumber(ngx.var.content_length)))
        }
    }
--- request eval
"POST /t\n" . '{"model":"gpt-x","metadata":{"user_id":"u1"},"messages":[{"role":"user","content":"' . ("x" x 300000) . '"}],"stream":false}'
--- response_body
file gpt-x u1 false 4 0 true
--- no_error_log
[error]
