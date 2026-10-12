-- Strictness: every fixture at three positions (top-level value, nested value,
-- deep array element). Assertions are on strict mode (scheme A); lua-cjson,
-- shallow mode (scheme B) and the existing simdjson decoder are recorded as
-- NOTE lines for the report.

local rs = require("resty.simdjson.root_scan")
local U  = require("rs_util")

local ACCEPT = {
    "-0", "0", "1E+2", "1e-2", "-1.5e+300", "1e400", "-1e400", "123456789012345678901234567890",
    "0.000001", '"\\/"', '"\\ud83d\\ude00"', '"\\u0000"', '"\\u00e9\\u4e2d"', '""', "[]", "{}",
    "true", "false", "null", '[1,"a",{"b":[null]}]',
}

local REJECT = {
    "01", "-01", "1.", ".1", "+1", "0x10", "1e", "1e+", "-", "--1", "1.2.3", "NaN", "Infinity", "-Infinity",
    "tru", "nul", "fals", "truex", "nulll", "True", "'a'",
    '"\\x"', '"\\u12G4"', '"\\u12"', '"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '"\\ud800x"',
    '"a\1b"', '"a\tb"', '"\255"', '"\192\175"', '"\237\160\128"', '"\244\144\128\128"',
    "[1,]", "[,1]", "[1 2]", '{"a" 1}', "{a:1}", '{"a":1,}', '{,}', '{"a":}', "/*c*/1", "1/*c*/", "[1}", '{"a":1]',
    '["a""b"]', '[1"a"]', '{"a":1 "b":2}', "[",
    -- an unread string followed by ':' looks like a key to simdjson's skip_child();
    -- found by spec_fuzz (seed 20261012, e.g. mutation 19045)
    '"b":"c"', '"b":1', '["a":1]', '{"a":"b":"c"}', '["x",{"k":"v"},"y":2]',
}

local function wrap(x)
    return {
        top    = '{"model":"m","v":' .. x .. '}',
        nested = '{"model":"m","o":{"p":{"v":' .. x .. '}}}',
        deep   = '{"model":"m","a":[[[' .. x .. ']]]}',
    }
end

local function verdict(json, validate)
    local idx, err = rs.scan_string(json, { validate = validate, paths = { "model", "v" }, allow_duplicates = true })
    return idx and "ok" or err
end

return function(t)
    local cj = U.cjson
    local simdjson = require("resty.simdjson")

    for _, x in ipairs(ACCEPT) do
        for pos, json in pairs(wrap(x)) do
            local a = verdict(json, "strict")
            t:eq(a, "ok", "accept " .. x .. " @" .. pos)
            local b = verdict(json, "shallow")
            t:eq(b, "ok", "shallow accepts " .. x .. " @" .. pos)
            local cv = cj.decode(json)
            if pos == "top" then
                -- fresh decoder per document, as a request would use it
                local dec = simdjson.new()
                local ok, sv, serr = pcall(dec.decode, dec, json)
                dec:destroy()
                t:note({ fixture = x, class = "accept", cjson = cv ~= nil and "ok" or "reject",
                         simdjson_decoder = (ok and sv ~= nil) and "ok" or tostring(serr or sv) })
            end
        end
    end

    -- key position: invalid escapes in a top-level key and in a nested key
    for _, k in ipairs({ '"\\x"', '"\\u12G4"', '"\\ud800"', '"\\udc00"' }) do
        t:eq(verdict("{" .. k .. ":1}", "strict"), "syntax", "top-level key " .. k)
        t:eq(verdict('{"o":{' .. k .. ':1}}', "strict"), "syntax", "nested key " .. k)
        t:eq(verdict("{" .. k .. ":1}", "shallow"), "syntax", "shallow top-level key " .. k)
    end

    local b_nested_accepts = {}
    for _, x in ipairs(REJECT) do
        for pos, json in pairs(wrap(x)) do
            local a = verdict(json, "strict")
            t:ok(a == "syntax", "reject " .. x .. " @" .. pos .. ": got " .. a)
            local b = verdict(json, "shallow")
            local cv = cj.decode(json)
            t:note({ fixture = x, class = "reject", pos = pos, strict = a, shallow = b,
                     cjson = cv ~= nil and "ok" or "reject" })
            if pos == "top" and not x:match("^[%[{]") then
                -- scheme B still validates top-level scalars strictly
                t:ok(b ~= "ok", "shallow rejects top-level scalar " .. x)
            elseif b == "ok" then
                b_nested_accepts[#b_nested_accepts + 1] = x .. "@" .. pos
            end
        end
    end
    t:note({ shallow_accepts_nested_invalid = b_nested_accepts })

    -- escapes at every offset around the 16/64-byte blocks of the string check,
    -- strict verdict and decoded value must equal lua-cjson's
    local ESC = { '\\"', '\\\\', '\\/', '\\n', '\\u00e9', '\\ud83d\\ude00', '\\\\\\\\', '\\\\\\"',
                  '\\x', '\\u12G4', '\\ud800', '\\udc00', '\\ud800\\u0041', '\\ud83d\\\\', '\\' .. 'u' }
    local mism = 0
    for _, L in ipairs({ 0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 79, 80, 127, 128, 129, 191, 192, 200 }) do
        for i = 0, L do
            for _, e in ipairs(ESC) do
                local body = string.rep("a", i) .. e .. string.rep("b", L - i)
                for _, json in ipairs({ '{"v":"' .. body .. '"}', '{"o":["x","' .. body .. '"]}' }) do
                    local idx = rs.scan_string(json, { paths = { "v" }, validate = "strict" })
                    local cv = cj.decode(json)
                    local same = (idx ~= nil) == (cv ~= nil)
                    if same and idx and cv.v ~= nil then
                        same = idx.map.v == cv.v
                    end
                    if not same then
                        mism = mism + 1
                        t:ok(false, "block-boundary escape " .. U.hex(json, 96) .. ": strict "
                             .. tostring(idx ~= nil) .. ", cjson " .. tostring(cv ~= nil))
                    end
                end
            end
        end
    end
    t:eq(mism, 0, "escapes around block boundaries agree with cjson")

    -- 1e400 and big integers through the existing paths (informational)
    local gjson = require("resty.simdjson.gjson")
    local g = gjson.new(true)
    for _, x in ipairs({ "1e400", "123456789012345678901234567890", "-0", "18446744073709551616" }) do
        local json = '{"model":' .. x .. '}'
        local gv, gerr = g:get_many(json, { "model" })
        local cv = cj.decode(json)
        local idx = rs.scan_string(json, { paths = { "model" }, validate = "strict" })
        t:note({ number = x, cjson = cv and tostring(cv.model) or "reject",
                 get_many = gv and tostring(gv.model) or tostring(gerr),
                 root_scan = idx and tostring(idx.map.model) or "reject" })
        t:ok(idx ~= nil, "root-scan accepts number " .. x)
    end
    g:destroy()
end
