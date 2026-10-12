-- ============================================================================
-- resty.simdjson.root_scan: top-level member index of a JSON object body.
--
-- One FFI call (one simdjson stage-1 pass) per scan, for a Lua string or for a
-- file path (mmap, read-only, no copy). Returns every top-level member with its
-- decoded key and 0-based [start, end) byte offsets, plus the bounded raw bytes
-- of the requested fields ("model", "metadata.user_id", ...). The body itself
-- never enters the Lua heap in file mode; in string mode only the bounded
-- extracted values and keys do.
--
-- Stateless: every call builds its own options and frees its own result, so
-- there is nothing to new/destroy and nothing shared between requests. The C
-- call is a single blocking call (it cannot yield); see README for timings.
--
-- Loading this module against an older libsimdjson_ffi.so fails (missing
-- symbol or ABI mismatch); callers should pcall(require, ...) and fall back.
-- ============================================================================

local ffi   = require("ffi")
local C     = require("resty.simdjson.cdefs")
local cjson = require("cjson.safe").new()   -- private instance: default decode settings

local type       = type
local pairs      = pairs
local pcall      = pcall
local tonumber   = tonumber
local tostring   = tostring
local error      = error
local str_find   = string.find
local str_sub    = string.sub
local ffi_new    = ffi.new
local ffi_gc     = ffi.gc
local ffi_string = ffi.string
local ffi_sizeof = ffi.sizeof
local bit_band   = require("bit").band
local cjson_decode = cjson.decode


if not pcall(ffi.typeof, "simdjson_ffi_rs_result_t") then
ffi.cdef([[
typedef struct {
    const char  *seg[2];
    uint32_t     seg_len[2];
    uint32_t     depth;
    uint32_t     reserved;
} simdjson_ffi_rs_path_t;

typedef struct {
    uint32_t                       max_depth;
    uint32_t                       max_members;
    uint32_t                       max_key_bytes;
    uint32_t                       max_extract_bytes;
    uint32_t                       flags;
    uint32_t                       path_count;
    const simdjson_ffi_rs_path_t  *paths;
} simdjson_ffi_rs_options_t;

typedef struct {
    uint64_t     key_start;
    uint64_t     key_end;
    uint64_t     value_start;
    uint64_t     value_end;
    uint32_t     key_off;
    uint32_t     key_len;
    uint32_t     type;
    uint32_t     flags;
} simdjson_ffi_rs_member_t;

typedef struct {
    uint64_t     value_start;
    uint64_t     value_end;
    uint32_t     raw_off;
    uint32_t     raw_len;
    uint32_t     type;
    uint32_t     flags;
} simdjson_ffi_rs_value_t;

typedef struct {
    int32_t                           status;
    int32_t                           sys_errno;
    const char                       *message;
    int64_t                           error_offset;
    uint64_t                          input_len;
    uint64_t                          copied_bytes;
    uint64_t                          root_start;
    uint64_t                          root_end;
    uint32_t                          member_count;
    uint32_t                          path_count;
    uint32_t                          duplicate_count;
    uint32_t                          max_depth_seen;
    const simdjson_ffi_rs_member_t   *members;
    const simdjson_ffi_rs_value_t    *values;
    const char                       *keys;
    const char                       *extract;
    uint64_t                          t_input_ns;
    uint64_t                          t_index_ns;
    uint64_t                          t_walk_ns;
    uint64_t                          t_total_ns;
    void                             *opaque;
} simdjson_ffi_rs_result_t;

uint32_t simdjson_ffi_root_scan_abi(uint32_t *sizes, uint32_t n);
int simdjson_ffi_root_scan_string(const char *buf, size_t len,
                                  const simdjson_ffi_rs_options_t *opts,
                                  simdjson_ffi_rs_result_t **out);
int simdjson_ffi_root_scan_file(const char *path, size_t path_len,
                                const simdjson_ffi_rs_options_t *opts,
                                simdjson_ffi_rs_result_t **out);
void simdjson_ffi_root_scan_free(simdjson_ffi_rs_result_t *res);
]])
end


local ABI_VERSION = 1

local T_OPTIONS = ffi.typeof("simdjson_ffi_rs_options_t")
local T_PATHS   = ffi.typeof("simdjson_ffi_rs_path_t[?]")
local T_OUT     = ffi.typeof("simdjson_ffi_rs_result_t *[1]")

-- ABI check at load time: version and every struct size must match this file.
do
    local sizes = ffi_new("uint32_t[5]")
    local v = C.simdjson_ffi_root_scan_abi(sizes, 5)
    local want = {
        ffi_sizeof("simdjson_ffi_rs_path_t"),
        ffi_sizeof("simdjson_ffi_rs_options_t"),
        ffi_sizeof("simdjson_ffi_rs_member_t"),
        ffi_sizeof("simdjson_ffi_rs_value_t"),
        ffi_sizeof("simdjson_ffi_rs_result_t"),
    }
    if v ~= ABI_VERSION then
        error("libsimdjson_ffi root-scan ABI " .. tostring(v) .. ", expected " .. ABI_VERSION, 2)
    end
    for i = 1, 5 do
        if sizes[i - 1] ~= want[i] then
            error("libsimdjson_ffi root-scan struct size mismatch at #" .. i, 2)
        end
    end
end


local F_SHALLOW    = 1
local F_FORCE_COPY = 2
local M_DUPLICATE  = 1
local M_FOUND      = 2
local MAX_PATHS    = 16
local MAX_SEG      = 256

local TYPES = { "object", "array", "string", "number", "boolean", "null" }

local CODES = {
    [0]   = "ok",
    [1]   = "duplicate_key",
    [-10] = "syntax",
    [-11] = "root_not_object",
    [-12] = "trailing_content",
    [-20] = "limit_depth",
    [-21] = "limit_members",
    [-22] = "limit_key",
    [-23] = "limit_extract",
    [-24] = "limit_input",
    [-30] = "io",
    [-40] = "nomem",
    [-41] = "bad_args",
    [-42] = "internal",
}


-- Default is scheme B ("shallow": top level strict, nested containers skipped by
-- bracket counting), chosen by the measured gates; "strict" (scheme A) stays
-- available per call. See README "Root scan" for the numbers and residual risk.
local DEFAULT_VALIDATE = "shallow"


local _M = {
    ABI_VERSION      = ABI_VERSION,
    DEFAULT_VALIDATE = DEFAULT_VALIDATE,
    -- informational copy of the C defaults (0 in options = these); not read by this module
    DEFAULT_LIMITS   = { max_depth = 128, max_members = 256, max_key_bytes = 1024,
                         max_extract_bytes = 65536 },
}


local function bad(msg)
    return nil, "bad_args", { status = -41, message = msg }
end


local function limit_opt(opts, name)
    local v = opts[name]
    if v == nil then
        return 0
    end
    if type(v) ~= "number" or v < 0 or v % 1 ~= 0 or v > 4294967295 then
        return nil
    end
    return v
end


-- Builds the C options. Returns options, anchors (Lua strings the C side
-- points into; must stay referenced until the call returns), path list.
local function build_opts(opts)
    if opts ~= nil and type(opts) ~= "table" then
        return nil, "opts must be a table"
    end
    opts = opts or {}

    local o = ffi_new(T_OPTIONS)
    for _, name in pairs({ "max_depth", "max_members", "max_key_bytes", "max_extract_bytes" }) do
        local v = limit_opt(opts, name)
        if v == nil then
            return nil, name .. " must be a non-negative integer"
        end
        o[name] = v
    end

    local validate = opts.validate or DEFAULT_VALIDATE
    if validate == "shallow" then
        o.flags = F_SHALLOW
    elseif validate ~= "strict" then
        return nil, "validate must be \"strict\" or \"shallow\""
    end
    if opts._force_copy then
        o.flags = o.flags + F_FORCE_COPY
    end

    local paths = opts.paths
    local anchors = {}
    if paths ~= nil then
        if type(paths) ~= "table" then
            return nil, "paths must be an array of strings"
        end
        local n = #paths
        if n > MAX_PATHS then
            return nil, "at most 16 paths"
        end
        if n > 0 then
            local arr = ffi_new(T_PATHS, n)
            for i = 1, n do
                local p = paths[i]
                if type(p) ~= "string" then
                    return nil, "paths must be an array of strings"
                end
                -- dotted syntax as in gjson:get_many, limited to 1-2 object keys:
                -- no array indexes, predicates or wildcards
                if str_find(p, "[#*?()]") then
                    return nil, "unsupported path syntax: " .. p
                end
                local dot = str_find(p, ".", 1, true)
                local segs
                if dot then
                    segs = { str_sub(p, 1, dot - 1), str_sub(p, dot + 1) }
                    if str_find(segs[2], ".", 1, true) then
                        return nil, "at most 2 path segments: " .. p
                    end
                else
                    segs = { p }
                end
                for s = 1, #segs do
                    local seg = segs[s]
                    if #seg == 0 or #seg > MAX_SEG then
                        return nil, "path segment must be 1..256 bytes: " .. p
                    end
                    if str_find(seg, "^%d+$") then
                        return nil, "array indexes are not supported: " .. p
                    end
                    anchors[#anchors + 1] = seg
                    arr[i - 1].seg[s - 1] = seg
                    arr[i - 1].seg_len[s - 1] = #seg
                end
                arr[i - 1].depth = #segs
            end
            anchors[#anchors + 1] = arr
            o.paths = arr
            o.path_count = n
        end
    end

    return o, anchors, paths
end


local function convert(res, mode, paths, decode_values)
    local status = res.status

    local members = {}
    local mptr, keys = res.members, res.keys
    for i = 0, res.member_count - 1 do
        local m = mptr[i]
        members[i + 1] = {
            key         = ffi_string(keys + m.key_off, m.key_len),
            key_start   = tonumber(m.key_start),
            key_end     = tonumber(m.key_end),
            value_start = tonumber(m.value_start),
            value_end   = tonumber(m.value_end),
            type        = TYPES[m.type],
            duplicate   = bit_band(m.flags, M_DUPLICATE) ~= 0,
        }
    end

    local values, map = {}, decode_values and {} or nil
    local vptr, extract = res.values, res.extract
    for i = 0, res.path_count - 1 do
        local v = vptr[i]
        if bit_band(v.flags, M_FOUND) ~= 0 then
            local path = paths[i + 1]
            local raw = ffi_string(extract + v.raw_off, v.raw_len)
            local item = {
                raw         = raw,
                type        = TYPES[v.type],
                value_start = tonumber(v.value_start),
                value_end   = tonumber(v.value_end),
                duplicate   = bit_band(v.flags, M_DUPLICATE) ~= 0,
            }
            if decode_values then
                local val, derr = cjson_decode(raw)
                if val == nil and derr then
                    return nil, "syntax", { status = -10, message = "value decode failed: " .. derr,
                                            offset = item.value_start }
                end
                item.value = val
                map[path] = val
            end
            values[path] = item
        end
    end

    return {
        mode           = mode,
        input_len      = tonumber(res.input_len),
        copied_bytes   = tonumber(res.copied_bytes),
        root_start     = tonumber(res.root_start),
        root_end       = tonumber(res.root_end),
        max_depth_seen = res.max_depth_seen,
        members        = members,
        values         = values,
        map            = map,
        has_duplicates = status == 1,
        timing = {
            input_ns = tonumber(res.t_input_ns),
            index_ns = tonumber(res.t_index_ns),
            walk_ns  = tonumber(res.t_walk_ns),
            total_ns = tonumber(res.t_total_ns),
        },
    }
end


local function detail_of(res)
    local d = {
        status  = res.status,
        message = res.message ~= nil and ffi_string(res.message) or nil,
    }
    local off = tonumber(res.error_offset)
    if off >= 0 then
        d.offset = off
    end
    if res.sys_errno ~= 0 then
        d.errno = res.sys_errno
    end
    d.timing = { total_ns = tonumber(res.t_total_ns) }
    return d
end


-- `anchors` is unused here: passing it keeps the path segment strings that the
-- C options point into referenced until after the FFI call has returned.
local function finish(res, mode, paths, opts, anchors) -- luacheck: ignore anchors
    local status = res.status
    local decode_values = opts == nil or opts.decode_values ~= false

    if status == 0 or status == 1 then
        local idx, code, detail = convert(res, mode, paths or {}, decode_values)
        if not idx then
            return nil, code, detail
        end
        if status == 1 and not (opts and opts.allow_duplicates) then
            local d = detail_of(res)
            d.index = idx
            return nil, "duplicate_key", d
        end
        return idx
    end

    return nil, CODES[status] or "internal", detail_of(res)
end


local function run(fn, input, mode, opts)
    local copts, anchors, paths = build_opts(opts)
    if not copts then
        return bad(anchors)
    end

    local out = ffi_new(T_OUT)
    local rc = fn(input, #input, copts, out)
    local res = out[0]
    if res == nil then
        return nil, CODES[rc] or "nomem", { status = rc, message = "result allocation failed" }
    end
    ffi_gc(res, C.simdjson_ffi_root_scan_free)

    local ok, a, b, c = pcall(finish, res, mode, paths, opts, anchors)

    C.simdjson_ffi_root_scan_free(ffi_gc(res, nil))

    if not ok then
        return nil, "internal", { status = -42, message = tostring(a) }
    end
    return a, b, c
end


-- idx, err, detail = scan_string(json, opts)
function _M.scan_string(json, opts)
    if type(json) ~= "string" then
        return bad("json must be a string")
    end
    return run(C.simdjson_ffi_root_scan_string, json, "string", opts)
end


-- idx, err, detail = scan_file(path, opts): path of a regular file that is not
-- truncated while the call runs (Nginx request-body temp file)
function _M.scan_file(path, opts)
    if type(path) ~= "string" then
        return bad("path must be a string")
    end
    return run(C.simdjson_ffi_root_scan_file, path, "file", opts)
end


return _M
