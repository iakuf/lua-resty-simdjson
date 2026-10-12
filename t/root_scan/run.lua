-- resty t/root_scan/run.lua <spec...> [--fuzz-n=N] [--seed=S] [--heavy] [--light]
-- --light (also implied by TEST_NGINX_USE_VALGRIND): small inputs, no
-- timing/RSS/heap assertions, fuzz capped at 100 documents.
-- Run from the repository root; every spec should run in its own process
-- (rs-test.sh does that) so memory numbers do not leak between specs.

package.path = "t/root_scan/?.lua;lib/?.lua;lib/?/init.lua;" .. package.path

local R = require("rs_runner")
local args = R.parse_args(arg)

local failed = 0
for _, name in ipairs(args.specs) do
    local t = R.new(name)
    local ok, err = pcall(function()
        require(name)(t, args)
    end)
    if not ok then
        t:ok(false, "spec aborted: " .. tostring(err))
    end
    t:summary()
    failed = failed + t.failed
end

if failed > 0 then
    os.exit(1)
end
