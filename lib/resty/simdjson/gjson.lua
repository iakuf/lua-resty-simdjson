-- ============================================================================
-- gjson 风格通用 JSON 路径提取（路线 A）
-- 单入口 get(json, path)，路径语法子集：
--   a.b.c              嵌套对象
--   a.0.b              数组下标
--   a.#(k==v).b        数组按字段值查首个匹配元素，再下钻
-- 值比较目前支持字符串：#(role==system)
--
-- 依赖库内新增的 FFI 原语：
--   simdjson_ffi_iterate / at_pointer / find_index / next / get_ops / state_free
-- 复用 decoder 的 _build 把命中值构建成 Lua 值。
--
-- 设计：一次 iterate，后续多段 at_pointer/find_index 都在同一 document 上
--       rewind 复用，不重复 stage-1 扫描。
-- ============================================================================

local ffi     = require("ffi")
local C       = require("resty.simdjson.cdefs")
local decoder = require("resty.simdjson.decoder")

local ffi_string = ffi.string
local sub        = string.sub
local find       = string.find

local SIMDJSON_FFI_ERROR    = -1
local SIMDJSON_FFI_NOTFOUND = -2

local errmsg = require("resty.core.base").get_errmsg_ptr()


local _M  = {}
local _MT = { __index = _M }


function _M.new(yieldable)
    local dec, err = decoder.new(yieldable)
    if not dec then
        return nil, err
    end
    return setmetatable({ dec = dec }, _MT)
end


function _M:destroy()
    if self.dec then
        self.dec:destroy()
        self.dec = nil
    end
end


-- ---- 路径解析：把 gjson path 拆成 segment 序列 ----------------------------
-- 返回数组，每个元素：
--   { kind = "key",  name = "messages" }         普通对象键
--   { kind = "index", n = 0 }                      数组下标
--   { kind = "pred", field = "role", value = "system" }  谓词
local function parse_path(path)
    local segs = {}
    local i = 1
    local len = #path
    local buf = {}

    local function flush_key()
        if #buf > 0 then
            local s = table.concat(buf)
            buf = {}
            -- 纯数字 -> 下标
            if find(s, "^%d+$") then
                segs[#segs+1] = { kind = "index", n = tonumber(s) }
            else
                segs[#segs+1] = { kind = "key", name = s }
            end
        end
    end

    while i <= len do
        local c = sub(path, i, i)

        if c == "." then
            flush_key()
            i = i + 1

        elseif c == "#" and sub(path, i+1, i+1) == "(" then
            -- 谓词 #(field==value)
            flush_key()
            local close = find(path, ")", i+2, true)
            if not close then
                return nil, "unclosed predicate in path: " .. path
            end
            local inner = sub(path, i+2, close-1)          -- field==value
            local f, v = inner:match("^(.-)==(.*)$")
            if not f then
                return nil, "bad predicate (expect field==value): " .. inner
            end
            segs[#segs+1] = { kind = "pred", field = f, value = v }
            i = close + 1

        else
            buf[#buf+1] = c
            i = i + 1
        end
    end

    flush_key()
    return segs
end


-- ---- 内部：命中一个值后，用 decoder._build 构建 Lua 值 --------------------
local function build_hit(dec, n)
    dec.ops_index = 1
    dec.ops_size  = n
    return dec:_build(dec.ops[0])
end


-- 单入口：get(json, path)
-- 命中返回值；路径不存在返回 nil（无 err）；解析出错返回 nil, err
function _M:get(json, path)
    local dec = self.dec
    if not dec then error("already destroyed", 2) end
    assert(type(json) == "string", "json must be string")
    assert(type(path) == "string", "path must be string")

    local state = dec.state
    if not state then error("decoder destroyed", 2) end

    local segs, perr = parse_path(path)
    if not segs then
        return nil, perr
    end

    dec.ops = assert(C.simdjson_ffi_state_get_ops(state))
    dec.decoding = true

    -- 一次 iterate，后续在同一 document 上 rewind 复用
    local rc = C.simdjson_ffi_iterate(state, json, #json, errmsg)
    if rc == SIMDJSON_FFI_ERROR then
        dec.decoding = false
        return nil, "simdjson: " .. ffi_string(errmsg[0])
    end

    -- 逐段构造 JSON Pointer；遇到谓词就先 find_index 解析成具体下标
    -- 转义按 RFC6901（~ -> ~0, / -> ~1）
    local function esc(s)
        s = s:gsub("~", "~0"):gsub("/", "~1")
        return s
    end

    local ptr = {}    -- 已确定的 pointer 片段

    local function cur_pointer()
        if #ptr == 0 then return "" end
        return "/" .. table.concat(ptr, "/")
    end

    for si = 1, #segs do
        local seg = segs[si]

        if seg.kind == "key" then
            ptr[#ptr+1] = esc(seg.name)

        elseif seg.kind == "index" then
            ptr[#ptr+1] = tostring(seg.n)

        elseif seg.kind == "pred" then
            -- 对当前 pointer 指向的数组，查 field==value 的首个下标
            local ap = cur_pointer()
            local idx = C.simdjson_ffi_find_index(
                state,
                ap, #ap,
                seg.field, #seg.field,
                seg.value, #seg.value,
                errmsg)
            if idx == SIMDJSON_FFI_ERROR then
                dec.decoding = false
                return nil, "simdjson: " .. ffi_string(errmsg[0])
            end
            if idx == SIMDJSON_FFI_NOTFOUND then
                dec.decoding = false
                return nil   -- 谓词无匹配 -> 路径不存在
            end
            ptr[#ptr+1] = tostring(idx)
        end
    end

    -- 最终 pointer 取值
    local final_ptr = cur_pointer()
    local n = C.simdjson_ffi_at_pointer(state, final_ptr, #final_ptr, errmsg)

    if n == SIMDJSON_FFI_NOTFOUND then
        dec.decoding = false
        return nil
    end
    if n == SIMDJSON_FFI_ERROR then
        dec.decoding = false
        return nil, "simdjson: " .. ffi_string(errmsg[0])
    end

    local res, berr = build_hit(dec, n)
    dec.decoding = false
    if berr then return nil, berr end
    return res
end


-- 多路径：各自独立求值（简单正确版；共享前缀的优化留待实测有瓶颈再做）
function _M:get_many(json, paths)
    local out = {}
    for i = 1, #paths do
        local v, err = self:get(json, paths[i])
        if err then return nil, err end
        if v ~= nil then out[paths[i]] = v end
    end
    return out
end


return _M
