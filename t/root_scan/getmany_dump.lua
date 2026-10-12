-- resty t/root_scan/getmany_dump.lua [--n=N] [--seed=S]
-- Prints one canonical JSON line per case for the EXISTING APIs only
-- (gjson:get / get_many, full decoder), so the output of an old and a new
-- libsimdjson_ffi.so can be compared byte for byte (`cmp`). Does not load
-- resty.simdjson.root_scan.

package.path = "t/root_scan/?.lua;lib/?.lua;lib/?/init.lua;" .. package.path

local U        = require("rs_util")
local gjson    = require("resty.simdjson.gjson")
local simdjson = require("resty.simdjson")

local n, seed = 3000, 20261012
for i = 1, #arg do
    local k, v = arg[i]:match("^%-%-(%w+)=(%d+)$")
    if k == "n" then n = tonumber(v) elseif k == "seed" then seed = tonumber(v) end
end

-- canonical encoding: sorted keys, %.17g numbers, explicit null marker
local function canon(v)
    local tv = type(v)
    if v == nil then return "nil" end
    if v == U.null then return "null" end
    if tv == "number" then return string.format("%.17g", v) end
    if tv == "boolean" then return tostring(v) end
    if tv == "string" then return string.format("%q", v) end
    if tv == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = canon(k) .. "=" .. canon(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "<" .. tv .. ">"
end

local FIELDS = { "model", "prompt_cache_key", "metadata.user_id" }
local PATHS = { "messages.0.role", "messages.#(role==user).content", "metadata", "stream" }

local fixtures = {
    '{"model":"a","messages":[{"role":"user","content":"x"}]}',
    '{"mo\\u0064el":"esc","model":"plain"}',
    '{"model":"first","model":"second"}',
    '{"messages":[{"model":"nested"}],"model":"top"}',
    '{"model":1e400}', '{"model":-0}', '{"model":[false,true,null]}', '{"model":{}}',
    '{"model":"m","metadata":{"user_id":"u"},"prompt_cache_key":"p"}',
    '[1,2]', '"s"', '', '{', '{"a":1} x', '{"a":[1}', '{"model":"m",}',
}

local gen = U.gen(seed)
local cases = {}
for i = 1, #fixtures do cases[#cases + 1] = fixtures[i] end
for _ = 1, n do
    local d = gen:document(gen:rand(4) > 1)
    cases[#cases + 1] = d
    cases[#cases + 1] = gen:mutate(d)
end

for i, json in ipairs(cases) do
    local g = gjson.new(true)
    local ok1, many, merr = pcall(g.get_many, g, json, FIELDS)
    local gets = {}
    for _, p in ipairs(PATHS) do
        local ok2, v, e = pcall(g.get, g, json, p)
        gets[#gets + 1] = ok2 and (canon(v) .. "|" .. tostring(e)) or ("pcall:" .. tostring(v))
    end
    g:destroy()
    local dec = simdjson.new()
    local ok3, full, derr = pcall(dec.decode, dec, json)
    dec:destroy()
    print(string.format("%d\t%s\t%s\t%s", i,
        ok1 and (canon(many) .. "|" .. tostring(merr)) or ("pcall:" .. tostring(many)),
        table.concat(gets, ";"),
        ok3 and (canon(full) .. "|" .. tostring(derr)) or ("pcall:" .. tostring(full))))
end
