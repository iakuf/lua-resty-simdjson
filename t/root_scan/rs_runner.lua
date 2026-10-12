-- Minimal assertion runner for the root-scan specs (no external dependencies).
-- A spec is a module returning function(t, args); the runner prints one
-- summary line per spec: {"spec":"<name>","passed":N,"failed":M}.

local cjson = require("cjson.safe").new()

local R = {}
local T = {}
T.__index = T

local MAX_FAILS_PRINTED = 50


function R.parse_args(argv)
    local a = { specs = {}, fuzz_n = 2000, seed = 20261012, heavy = false }
    for i = 1, #argv do
        local v = argv[i]
        local k, val = v:match("^%-%-([%w_-]+)=(.*)$")
        if k == "fuzz-n" then
            a.fuzz_n = tonumber(val)
        elseif k == "seed" then
            a.seed = tonumber(val)
        elseif v == "--heavy" then
            a.heavy = true
        elseif v:sub(1, 2) == "--" then
            error("unknown option " .. v)
        else
            a.specs[#a.specs + 1] = v
        end
    end
    return a
end


function R.new(name)
    return setmetatable({ name = name, passed = 0, failed = 0, notes = {} }, T)
end


local function show(v)
    if type(v) == "string" then
        if #v > 120 then
            return string.format("%q", v:sub(1, 120)) .. "...(" .. #v .. " bytes)"
        end
        return string.format("%q", v)
    end
    if type(v) == "table" then
        local s = cjson.encode(v)
        if s and #s > 240 then s = s:sub(1, 240) .. "..." end
        return s or tostring(v)
    end
    return tostring(v)
end
R.show = show


function T:ok(cond, msg)
    if cond then
        self.passed = self.passed + 1
        return true
    end
    self.failed = self.failed + 1
    if self.failed <= MAX_FAILS_PRINTED then
        print("FAIL [" .. self.name .. "] " .. tostring(msg))
    end
    return false
end


function T:eq(got, want, msg)
    return self:ok(got == want, tostring(msg) .. ": got " .. show(got) .. ", want " .. show(want))
end


local function deep_eq(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end
R.deep_eq = deep_eq


function T:deq(got, want, msg)
    return self:ok(deep_eq(got, want), tostring(msg) .. ": got " .. show(got) .. ", want " .. show(want))
end


-- runs fn inside pcall; an error counts as one failure
function T:case(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        self:ok(false, label .. ": error: " .. tostring(err))
    end
end


-- informational line (not an assertion), kept in the log
function T:note(obj)
    print("NOTE " .. (cjson.encode(obj) or tostring(obj)))
end


function T:summary()
    -- fixed key order so shell scripts can grep it
    print(string.format('{"spec":"%s","passed":%d,"failed":%d}', self.name, self.passed, self.failed))
end


return R
