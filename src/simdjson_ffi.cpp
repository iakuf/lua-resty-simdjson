#include "simdjson.h"
#include "simdjson_ffi.h"


using namespace simdjson;


// we will initialize it only once
static long PAGESIZE = 0;


// An optimization from https://github.com/simdjson/simdjson/blob/master/doc/performance.md#free-padding
// If ending of `buf` is at least `SIMDJSON_PADDING` away from the end of the current page,
// then we technically don't need to copy the string and can safely let simdjson process
// on the original buffer directly as `padded_string_view`.
// This is because reading within the boundary of a mapped memory page is guaranteed
// not to fail, even if these area might contain garbage data, simdjson will work correctly.
//
// A copy is needed when the last padding byte (buf + len - 1 + SIMDJSON_PADDING) would
// fall on a later page than the last input byte, i.e. when
// offset_in_page(buf + len - 1) + SIMDJSON_PADDING >= PAGESIZE.
// The earlier upstream example compared the offset with SIMDJSON_PADDING instead, which
// skipped the copy exactly when the input ends in the last SIMDJSON_PADDING bytes of a
// page. Fixed upstream in simdjson/simdjson#2271 (#2273, #2477).
static bool need_allocation(const char *buf, size_t len) {
    if (PAGESIZE == 0) {
        PAGESIZE = getpagesize();
    }

    SIMDJSON_DEVELOPMENT_ASSERT(PAGESIZE > 0);

    return ((reinterpret_cast<uintptr_t>(buf + len - 1) % PAGESIZE) +
            SIMDJSON_PADDING >= static_cast<uintptr_t>(PAGESIZE));
}


static padded_string_view get_padded_string_view(
    const char *buf, size_t len, padded_string &jsonbuffer) {

    // unlikely case
    if (simdjson_unlikely(need_allocation(buf, len))) {
      jsonbuffer = padded_string(buf, len);
      return jsonbuffer;
    }

    // no reallcation needed (very likely)
    return padded_string_view(buf, len, len + SIMDJSON_PADDING);
}


// T may be ondemand::value or state->document
template<typename T>
static bool simdjson_process_value(simdjson_ffi_state &state, T&& value) {
    bool go_deeper = false;

    switch (value.type()) {
    case ondemand::json_type::array: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_ARRAY;

        ondemand::array a = value;
        state.frames.emplace(a);

        go_deeper = true;

        break;
    }

    case ondemand::json_type::object: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_OBJECT;

        ondemand::object o = value;
        state.frames.emplace(o);

        go_deeper = true;

        break;
    }

    case ondemand::json_type::number: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NUMBER;
        state.ops[state.ops_n].val.number = double(value);

        break;
    }

    case ondemand::json_type::string: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
        std::string_view str = value;

        state.ops[state.ops_n].size = str.size();
        state.ops[state.ops_n].val.str = str.data();

        break;
    }

    case ondemand::json_type::boolean: {
        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_BOOLEAN;
        state.ops[state.ops_n].val.boolean = bool(value);

        break;
    }

    case ondemand::json_type::null: {
        SIMDJSON_DEVELOPMENT_ASSERT(value.is_null());

        state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_NULL;

        break;
    }

    case ondemand::json_type::unknown:
        // simdjson >=4.x returns json_type::unknown for values whose leading
        // byte isn't a valid JSON start char (e.g. `.9`, `'x'`, `True`).
        // Surface this as a normal parse error instead of UB.
        throw simdjson_error(TAPE_ERROR);

    default:
        SIMDJSON_UNREACHABLE();
    }

    state.ops_n++;

    return go_deeper;
}


template<>
bool simdjson_process_value(simdjson_ffi_state &state, simdjson_result<std::string_view>&& key) {
    state.ops[state.ops_n].opcode = SIMDJSON_FFI_OPCODE_STRING;
    std::string_view str = key.value();

    state.ops[state.ops_n].size = str.size();
    state.ops[state.ops_n].val.str = str.data();

    state.ops_n++;

    return false;
}


extern "C"
simdjson_ffi_state *simdjson_ffi_state_new() {
    auto state = new(std::nothrow) simdjson_ffi_state();

    SIMDJSON_DEVELOPMENT_ASSERT(state);

    return state;
}


extern "C"
simdjson_ffi_op_t *simdjson_ffi_state_get_ops(simdjson_ffi_state *state) {
    SIMDJSON_DEVELOPMENT_ASSERT(state);

    state->ops.resize(SIMDJSON_FFI_BATCH_SIZE);

    SIMDJSON_DEVELOPMENT_ASSERT(state->ops.size() == SIMDJSON_FFI_BATCH_SIZE);

    return state->ops.data();
}


extern "C"
void simdjson_ffi_state_free(simdjson_ffi_state *state) {
    SIMDJSON_DEVELOPMENT_ASSERT(state);

    delete state;
}


extern "C"
int simdjson_ffi_parse(simdjson_ffi_state *state,
    const char *json, size_t len, const char **errmsg) try {

    SIMDJSON_DEVELOPMENT_ASSERT(state);
    SIMDJSON_DEVELOPMENT_ASSERT(json);
    SIMDJSON_DEVELOPMENT_ASSERT(errmsg);

    state->document = state->parser.iterate(
                          get_padded_string_view(json, len, state->json));
    state->ops_n = 0;

    // the return value is intentionally ignored
    // because JSON could be either a bare scalar or
    // array/object at top level
    simdjson_process_value(*state, state->document);

    SIMDJSON_DEVELOPMENT_ASSERT(state->ops_n == 1);

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();

    // clean up tmp string on error to save memory
    state->json = padded_string();

    return SIMDJSON_FFI_ERROR;
}


extern "C"
int simdjson_ffi_is_eof(simdjson_ffi_state *state) {
    SIMDJSON_DEVELOPMENT_ASSERT(state);

    return state->document.at_end();
}


extern "C"
int simdjson_ffi_next(simdjson_ffi_state *state, const char **errmsg) try {
    SIMDJSON_DEVELOPMENT_ASSERT(state);
    SIMDJSON_DEVELOPMENT_ASSERT(errmsg);
    SIMDJSON_DEVELOPMENT_ASSERT(state->ops.size() == SIMDJSON_FFI_BATCH_SIZE);

    state->ops_n = 0;

    while (!state->frames.empty()) {

        if (state->ops_n >= state->ops.size() - 1) {
            // -1 for key value pair which requires 2 ops
            return state->ops_n;
        }

        auto &frame = state->frames.top();

        switch (frame.state) {
            case simdjson_ffi_resume_state::array: {
                auto &it = frame.it.array.current;

                if (frame.processing) {
                    ++it;
                    frame.processing = false;
                }

                // resume array iteration
                for (; it != frame.it.array.end; ++it) {
                    auto value = *it;

                    if (simdjson_process_value(*state, value)) {
                        // save state, go deeper
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= state->ops.size()) {
                        // array can use the last of the slots, no need to
                        // reserve two slots like object below
                        frame.processing = true;

                        return state->ops_n;
                    }
                }

                break;
            }

            case simdjson_ffi_resume_state::object: {
                auto &it = frame.it.object.current;

                if (frame.processing) {
                    ++it;
                    frame.processing = false;
                }

                // resume object iteration
                for (; it != frame.it.object.end; ++it) {
                    auto field = *it;

#if SIMDJSON_DEVELOPMENT_CHECKS
                    SIMDJSON_DEVELOPMENT_ASSERT(!simdjson_process_value(*state, field.unescaped_key()));
#else
                    // the return value is intentionally ignored
                    // because the key must be a string
                    simdjson_process_value(*state, field.unescaped_key());
#endif

                    // this can not overflow, because we checked to make sure
                    // ops has at least 2 empty slots above

                    if (simdjson_process_value(*state, field.value())) {
                        // save state, go deeper
                        frame.processing = true;

                        break;
                    }

                    if (state->ops_n >= state->ops.size() - 1) {
                        frame.processing = true;

                        return state->ops_n;
                    }
                }

                break;
            }

            default:
                SIMDJSON_UNREACHABLE();
        }

        if (!frame.processing) {
            state->frames.pop();

            state->ops[state->ops_n++].opcode = SIMDJSON_FFI_OPCODE_RETURN;
        }
    }

    SIMDJSON_DEVELOPMENT_ASSERT(state->frames.empty());

    // we are done! clean up the tmp string to save memory
    state->json = padded_string();

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();

    // clean up tmp string on error to save memory
    state->json = padded_string();

    return SIMDJSON_FFI_ERROR;
}


// ===========================================================================
// Path-based extraction primitives (gjson-style, built on On-Demand)
//
// These are generic JSON primitives with no business logic. They let the Lua
// side pull individual values by path without materializing the whole document.
//
// Return-value convention (in addition to the existing SIMDJSON_FFI_ERROR):
//   SIMDJSON_FFI_NOTFOUND (-2) means "the requested path/element is absent",
//   which is NOT treated as a hard error so callers can distinguish
//   "missing" from "malformed JSON".
//
// Lifetime note: after simdjson_ffi_iterate(), the document may reference the
// input `json` buffer directly (zero-copy). The caller MUST keep the Lua
// string alive until all at_pointer / find_index calls on that document are
// done.
// ===========================================================================

#ifndef SIMDJSON_FFI_NOTFOUND
#define SIMDJSON_FFI_NOTFOUND -2
#endif


// Treat these On-Demand errors as "value is simply absent" rather than a
// hard parse error, so lookups on optional fields return NOTFOUND.
static inline bool simdjson_ffi_is_absent(error_code err) {
    return err == NO_SUCH_FIELD
        || err == INDEX_OUT_OF_BOUNDS
        || err == INCORRECT_TYPE
        || err == INVALID_JSON_POINTER;
}


// Perform a single stage-1 SIMD structural scan and build the document.
// Emits no opcodes. Follow up with at_pointer / find_index on the same state.
extern "C"
int simdjson_ffi_iterate(simdjson_ffi_state *state,
    const char *json, size_t len, const char **errmsg) try {

    SIMDJSON_DEVELOPMENT_ASSERT(state);
    SIMDJSON_DEVELOPMENT_ASSERT(json);
    SIMDJSON_DEVELOPMENT_ASSERT(errmsg);

    while (!state->frames.empty()) {
        state->frames.pop();
    }

    state->ops_n = 0;
    state->document = state->parser.iterate(
                          get_padded_string_view(json, len, state->json));

    return 0;

} catch (simdjson_error &e) {
    *errmsg = e.what();
    state->json = simdjson::padded_string();
    return SIMDJSON_FFI_ERROR;
}


// Resolve an RFC 6901 JSON Pointer on an already-iterated document.
// document::at_pointer auto-rewinds between calls, so this may be called
// repeatedly for different pointers on the same document.
// On a hit, emits the value's opcode(s) and returns ops_n (1 for a scalar;
// object/array push a frame to be drained via simdjson_ffi_next).
extern "C"
int simdjson_ffi_at_pointer(simdjson_ffi_state *state,
    const char *pointer, size_t plen, const char **errmsg) try {

    SIMDJSON_DEVELOPMENT_ASSERT(state);
    SIMDJSON_DEVELOPMENT_ASSERT(pointer);
    SIMDJSON_DEVELOPMENT_ASSERT(errmsg);

    while (!state->frames.empty()) {
        state->frames.pop();
    }
    state->ops_n = 0;

    auto result = state->document.at_pointer(std::string_view(pointer, plen));

    ondemand::value value;
    auto err = result.get(value);
    if (err) {
        if (simdjson_ffi_is_absent(err)) {
            return SIMDJSON_FFI_NOTFOUND;
        }
        throw simdjson_error(err);
    }

    simdjson_process_value(*state, value);

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();
    return SIMDJSON_FFI_ERROR;
}


// Convenience: iterate + at_pointer in a single call, for a one-shot lookup.
extern "C"
int simdjson_ffi_get_pointer(simdjson_ffi_state *state,
    const char *json, size_t len,
    const char *pointer, size_t plen,
    const char **errmsg) try {

    while (!state->frames.empty()) {
        state->frames.pop();
    }
    state->ops_n = 0;

    state->document = state->parser.iterate(
                          get_padded_string_view(json, len, state->json));

    auto result = state->document.at_pointer(std::string_view(pointer, plen));

    ondemand::value value;
    auto err = result.get(value);
    if (err) {
        state->json = simdjson::padded_string();
        if (simdjson_ffi_is_absent(err)) {
            return SIMDJSON_FFI_NOTFOUND;
        }
        throw simdjson_error(err);
    }

    simdjson_process_value(*state, value);

    return state->ops_n;

} catch (simdjson_error &e) {
    *errmsg = e.what();
    state->json = simdjson::padded_string();
    return SIMDJSON_FFI_ERROR;
}


// On the array at `array_pointer`, return the index of the first element that
// is an object whose string field `field` equals `value`. Returns
// SIMDJSON_FFI_NOTFOUND if the array has no such element (or the pointer does
// not resolve to an array). Field/value are supplied by the caller, so this
// primitive stays fully generic (e.g. the Lua path engine uses it to resolve
// gjson predicates like `messages.#(role==system)`).
extern "C"
int simdjson_ffi_find_index(simdjson_ffi_state *state,
    const char *array_pointer, size_t aplen,
    const char *field, size_t flen,
    const char *value, size_t vlen,
    const char **errmsg) try {

    SIMDJSON_DEVELOPMENT_ASSERT(state);
    SIMDJSON_DEVELOPMENT_ASSERT(array_pointer);
    SIMDJSON_DEVELOPMENT_ASSERT(field);
    SIMDJSON_DEVELOPMENT_ASSERT(value);
    SIMDJSON_DEVELOPMENT_ASSERT(errmsg);

    while (!state->frames.empty()) {
        state->frames.pop();
    }

    auto target = state->document.at_pointer(
                      std::string_view(array_pointer, aplen));

    ondemand::array arr;
    auto err = target.get_array().get(arr);
    if (err) {
        if (simdjson_ffi_is_absent(err)) {
            return SIMDJSON_FFI_NOTFOUND;
        }
        throw simdjson_error(err);
    }

    std::string_view want_field(field, flen);
    std::string_view want_value(value, vlen);

    int idx = 0;
    for (auto element : arr) {
        // Non-object elements can't match a field predicate; skip them.
        ondemand::object obj;
        if (element.get_object().get(obj)) {
            idx++;
            continue;
        }

        // Unordered lookup so we don't depend on key order within the object.
        auto fv = obj.find_field_unordered(want_field);
        std::string_view sv;
        if (!fv.get_string().get(sv)) {
            if (sv == want_value) {
                return idx;
            }
        }
        // field missing / not a string / value mismatch -> keep scanning

        idx++;
    }

    return SIMDJSON_FFI_NOTFOUND;

} catch (simdjson_error &e) {
    *errmsg = e.what();
    return SIMDJSON_FFI_ERROR;
}


// ===========================================================================
// Root scan: top-level member index (ABI 1). Types and prototypes live in
// simdjson_ffi.h. This section is additive; nothing above it is changed.
//
// One call = one local ondemand::parser = one stage-1 pass. Stage 1 already
// validates UTF-8, unescaped control characters and string closure for the
// whole input. Strict mode (scheme A) then walks every value with the
// On-Demand iterator, which rejects missing commas/colons, trailing commas,
// non-string keys and bracket mismatches, and checks without writing the
// parser's string buffer:
//   * string values and nested keys: escapes on the raw bytes (rs_string_body)
//   * numbers: RFC 8259 grammar on the raw token (no value conversion)
//   * true / false / null: simdjson get_bool() / is_null()
// Shallow mode (scheme B, SIMDJSON_FFI_RS_F_SHALLOW) validates only the top
// level and skips nested containers by bracket counting (raw_json()).
// Defaults: at this C level flags = 0 means strict; the Lua wrapper
// (lib/resty/simdjson/root_scan.lua) defaults to shallow and sets the flag.
// No state survives a call except the read-only page-size caches.
// ===========================================================================

#include <cerrno>
#include <cstring>
#include <ctime>
#include <new>
#include <string>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#if defined(__SSE2__)
#include <emmintrin.h>
#endif


namespace {

const uint32_t RS_ABI_VERSION    = 1;

const uint32_t RS_DEF_DEPTH      = 128;
const uint32_t RS_CAP_DEPTH      = 1024;
const uint32_t RS_DEF_MEMBERS    = 256;
const uint32_t RS_CAP_MEMBERS    = 65536;
const uint32_t RS_DEF_KEY        = 1024;
const uint32_t RS_CAP_KEY        = 65536;
const uint32_t RS_DEF_EXTRACT    = 65536;
const uint32_t RS_CAP_EXTRACT    = 16u * 1024 * 1024;
const uint32_t RS_CAP_PATHS      = 16;
const uint32_t RS_CAP_SEG        = 256;
const uint64_t RS_CAP_INPUT      = 0xFFFFFFFFull;    // simdjson's own input limit
const size_t   RS_CAP_PATH_BYTES = 4095;

const uint32_t RS_KNOWN_FLAGS = SIMDJSON_FFI_RS_F_SHALLOW | SIMDJSON_FFI_RS_F_FORCE_COPY;


// read-only after the first call (same nature as PAGESIZE above)
long rs_pagesize = 0;

long rs_page() {
    if (rs_pagesize <= 0) {
        long p = sysconf(_SC_PAGESIZE);
        rs_pagesize = p > 0 ? p : 4096;
    }
    return rs_pagesize;
}


uint64_t rs_now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return uint64_t(ts.tv_sec) * 1000000000ull + uint64_t(ts.tv_nsec);
}


inline bool rs_ws(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}


inline bool rs_digit(uint8_t c) {
    return c >= '0' && c <= '9';
}


// length of [p, p + n) without trailing JSON whitespace
inline size_t rs_rtrim(const uint8_t *p, size_t n) {
    while (n > 0 && rs_ws(p[n - 1])) {
        n--;
    }
    return n;
}


struct rs_impl {
    simdjson_ffi_rs_result_t                pub;
    std::vector<simdjson_ffi_rs_member_t>   members;
    std::vector<simdjson_ffi_rs_value_t>    values;
    std::string                             keys;
    std::string                             extract;
    std::vector<uint32_t>                   slots;     // key table: member index + 1

    rs_impl() {
        memset(&pub, 0, sizeof(pub));
        pub.message = "ok";
        pub.error_offset = -1;
        pub.opaque = this;
    }
};


struct rs_cfg {
    uint32_t                       max_depth;
    uint32_t                       max_members;
    uint32_t                       max_key;
    uint32_t                       max_extract;
    uint32_t                       flags;
    uint32_t                       path_count;
    const simdjson_ffi_rs_path_t  *paths;
};


int rs_set(rs_impl &r, int st, const char *msg, int64_t off) {
    r.pub.status = st;
    r.pub.message = msg;
    r.pub.error_offset = off;
    return st;
}


bool rs_limit(uint32_t v, uint32_t def, uint32_t cap, uint32_t *out) {
    if (v == 0) {
        *out = def;
        return true;
    }
    *out = v;
    return v <= cap;
}


int rs_load_opts(const simdjson_ffi_rs_options_t *o, rs_cfg &c, rs_impl &r) {
    simdjson_ffi_rs_options_t zero;
    memset(&zero, 0, sizeof(zero));
    if (o == nullptr) {
        o = &zero;
    }

    if (!rs_limit(o->max_depth, RS_DEF_DEPTH, RS_CAP_DEPTH, &c.max_depth)
        || !rs_limit(o->max_members, RS_DEF_MEMBERS, RS_CAP_MEMBERS, &c.max_members)
        || !rs_limit(o->max_key_bytes, RS_DEF_KEY, RS_CAP_KEY, &c.max_key)
        || !rs_limit(o->max_extract_bytes, RS_DEF_EXTRACT, RS_CAP_EXTRACT, &c.max_extract))
    {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "limit above hard cap", -1);
    }

    if (o->flags & ~RS_KNOWN_FLAGS) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "unknown flags", -1);
    }

    if (o->path_count > RS_CAP_PATHS) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "more than 16 paths", -1);
    }

    if (o->path_count > 0 && o->paths == nullptr) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "paths is NULL", -1);
    }

    for (uint32_t i = 0; i < o->path_count; i++) {
        const simdjson_ffi_rs_path_t &p = o->paths[i];
        if (p.depth < 1 || p.depth > 2) {
            return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "path depth must be 1 or 2", -1);
        }
        for (uint32_t s = 0; s < p.depth; s++) {
            if (p.seg[s] == nullptr || p.seg_len[s] == 0 || p.seg_len[s] > RS_CAP_SEG) {
                return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "path segment must be 1..256 bytes", -1);
            }
        }
    }

    c.flags = o->flags;
    c.path_count = o->path_count;
    c.paths = o->paths;

    simdjson_ffi_rs_value_t none;
    memset(&none, 0, sizeof(none));
    r.values.assign(c.path_count, none);

    return SIMDJSON_FFI_RS_OK;
}


int rs_finish(rs_impl &r, int st, uint64_t t0) {
    r.pub.status = st;
    r.pub.member_count = uint32_t(r.members.size());
    r.pub.path_count = uint32_t(r.values.size());
    r.pub.members = r.members.empty() ? nullptr : r.members.data();
    r.pub.values = r.values.empty() ? nullptr : r.values.data();
    r.pub.keys = r.keys.data();
    r.pub.extract = r.extract.data();
    r.pub.t_total_ns = rs_now_ns() - t0;
    return st;
}


inline size_t rs_utf8(uint32_t cp, uint8_t *u) {
    if (cp < 0x80) {
        u[0] = uint8_t(cp);
        return 1;
    }
    if (cp < 0x800) {
        u[0] = uint8_t(0xC0 | (cp >> 6));
        u[1] = uint8_t(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        u[0] = uint8_t(0xE0 | (cp >> 12));
        u[1] = uint8_t(0x80 | ((cp >> 6) & 0x3F));
        u[2] = uint8_t(0x80 | (cp & 0x3F));
        return 3;
    }
    u[0] = uint8_t(0xF0 | (cp >> 18));
    u[1] = uint8_t(0x80 | ((cp >> 12) & 0x3F));
    u[2] = uint8_t(0x80 | ((cp >> 6) & 0x3F));
    u[3] = uint8_t(0x80 | (cp & 0x3F));
    return 4;
}


inline bool rs_hex4(const uint8_t *p, const uint8_t *end, uint32_t *cp) {
    if (end - p < 4) {
        return false;
    }
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t c = p[i];
        uint32_t d;
        if (c >= '0' && c <= '9') {
            d = uint32_t(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            d = uint32_t(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            d = uint32_t(c - 'A' + 10);
        } else {
            return false;
        }
        v = (v << 4) | d;
    }
    *cp = v;
    return true;
}


// Output sinks for rs_string_body (validation-only callers use rs_check_string)
struct rs_str_sink {            // append to a std::string, at most `cap` bytes
    std::string &s;
    size_t       start;
    size_t       cap;

    bool put(const uint8_t *p, size_t n) {
        if (s.size() - start + n > cap) {
            return false;
        }
        s.append(reinterpret_cast<const char *>(p), n);
        return true;
    }
};


struct rs_buf_sink {            // fixed-size buffer
    uint8_t     *b;
    size_t       n;
    size_t       cap;

    bool put(const uint8_t *p, size_t k) {
        if (n + k > cap) {
            return false;
        }
        memcpy(b + n, p, k);
        n += k;
        return true;
    }
};


enum { RS_STR_OK = 0, RS_STR_BAD = 1, RS_STR_FULL = 2 };


// Checks a JSON string body (the bytes between the quotes) and, through the
// sink, decodes it. Stage 1 already rejected bad UTF-8 and raw control
// characters, so only escapes are left: \" \\ \/ \b \f \n \r \t and \uXXXX,
// where a high surrogate must be followed by a \u low surrogate and a lone
// low surrogate is rejected (the same rules as lua-cjson).
template <typename Sink>
int rs_string_body(const uint8_t *p, size_t n, Sink &sink, const uint8_t **at) {
    const uint8_t *end = p + n;

    while (p < end) {
        const uint8_t *bs = static_cast<const uint8_t *>(memchr(p, '\\', size_t(end - p)));
        const uint8_t *stop = bs ? bs : end;

        if (!sink.put(p, size_t(stop - p))) {
            *at = p;
            return RS_STR_FULL;
        }

        if (bs == nullptr) {
            break;
        }

        *at = bs;
        if (end - bs < 2) {
            return RS_STR_BAD;
        }

        uint8_t ch;
        p = bs + 2;

        switch (bs[1]) {
        case '"':  ch = '"';  break;
        case '\\': ch = '\\'; break;
        case '/':  ch = '/';  break;
        case 'b':  ch = '\b'; break;
        case 'f':  ch = '\f'; break;
        case 'n':  ch = '\n'; break;
        case 'r':  ch = '\r'; break;
        case 't':  ch = '\t'; break;

        case 'u': {
            uint32_t cp;
            if (!rs_hex4(p, end, &cp)) {
                return RS_STR_BAD;
            }
            p += 4;

            if (cp >= 0xD800 && cp <= 0xDBFF) {
                uint32_t lo;
                if (end - p < 6 || p[0] != '\\' || p[1] != 'u'
                    || !rs_hex4(p + 2, end, &lo) || lo < 0xDC00 || lo > 0xDFFF)
                {
                    return RS_STR_BAD;
                }
                p += 6;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);

            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                return RS_STR_BAD;
            }

            uint8_t u[4];
            if (!sink.put(u, rs_utf8(cp, u))) {
                return RS_STR_FULL;
            }
            continue;
        }

        default:
            return RS_STR_BAD;
        }

        if (!sink.put(&ch, 1)) {
            return RS_STR_FULL;
        }
    }

    return RS_STR_OK;
}


// Escape classes for rs_check_string: 1 = one-character escape, 2 = \u, 0 = invalid.
struct rs_tables {
    uint8_t esc[256];
    uint8_t hex[256];      // nibble value, or 0xFF

    rs_tables() {
        memset(esc, 0, sizeof(esc));
        memset(hex, 0xFF, sizeof(hex));
        const char *simple = "\"\\/bfnrt";
        for (const char *c = simple; *c; c++) {
            esc[uint8_t(*c)] = 1;
        }
        esc[uint8_t('u')] = 2;
        for (int i = 0; i < 10; i++) {
            hex['0' + i] = uint8_t(i);
        }
        for (int i = 0; i < 6; i++) {
            hex['a' + i] = uint8_t(10 + i);
            hex['A' + i] = uint8_t(10 + i);
        }
    }
};

const rs_tables RS_T;      // constant tables, built at load time


inline bool rs_hex4_fast(const uint8_t *p, uint32_t *cp) {
    uint32_t a = RS_T.hex[p[0]], b = RS_T.hex[p[1]], c = RS_T.hex[p[2]], d = RS_T.hex[p[3]];
    if ((a | b | c | d) & 0xF0) {
        return false;
    }
    *cp = (a << 12) | (b << 8) | (c << 4) | d;
    return true;
}


// One escape sequence starting at the backslash q: returns the first byte after
// it, or nullptr if invalid. Same rules as rs_string_body.
inline const uint8_t *rs_escape(const uint8_t *q, const uint8_t *end) {
    if (end - q < 2) {
        return nullptr;
    }
    uint8_t cls = RS_T.esc[q[1]];
    if (cls == 1) {
        return q + 2;
    }
    uint32_t cp, lo;
    if (cls == 0 || end - q < 6 || !rs_hex4_fast(q + 2, &cp)) {
        return nullptr;
    }
    if ((cp & 0xF800) != 0xD800) {
        return q + 6;
    }
    // surrogate: a high one must be followed by \u + low one
    if (cp >= 0xDC00 || end - q < 12 || q[6] != '\\' || q[7] != 'u'
        || !rs_hex4_fast(q + 8, &lo) || (lo & 0xFC00) != 0xDC00)
    {
        return nullptr;
    }
    return q + 12;
}


// Validation-only twin of rs_string_body (same rules, nothing written).
// Returns true if the body is valid; otherwise *at is the offending backslash.
// Backslash positions come from a 64-byte bitmask (SSE2), so text without
// escapes costs one compare per 64 bytes and each escape is visited once;
// backslashes already consumed by the previous escape ("\\\\", "\\uD83D\\uDE00")
// are skipped through `next`. Reads stay inside [p, p + n).
#if defined(__SSE2__)
// Visits the backslashes of one block (bit i of m = byte p[i]).
inline bool rs_mask_escapes(const uint8_t *p, uint64_t m, const uint8_t *end,
                            const uint8_t **next, const uint8_t **at)
{
    while (m != 0) {
        const uint8_t *q = p + __builtin_ctzll(m);
        m &= m - 1;
        if (q < *next) {
            continue;
        }
        *next = rs_escape(q, end);
        if (*next == nullptr) {
            *at = q;
            return false;
        }
    }
    return true;
}


inline uint64_t rs_bs16(const uint8_t *p, __m128i bs) {
    return uint64_t(uint32_t(_mm_movemask_epi8(
               _mm_cmpeq_epi8(_mm_loadu_si128(reinterpret_cast<const __m128i *>(p)), bs))));
}
#endif


bool rs_check_string(const uint8_t *p, size_t n, const uint8_t **at) {
    const uint8_t *end = p + n;
    const uint8_t *next = p;            // first byte not consumed by an escape

#if defined(__SSE2__)
    const __m128i bs = _mm_set1_epi8('\\');
    for (; end - p >= 64; p += 64) {
        uint64_t m = rs_bs16(p, bs) | (rs_bs16(p + 16, bs) << 16)
                     | (rs_bs16(p + 32, bs) << 32) | (rs_bs16(p + 48, bs) << 48);
        if (m != 0 && !rs_mask_escapes(p, m, end, &next, at)) {
            return false;
        }
    }
    for (; end - p >= 16; p += 16) {
        uint64_t m = rs_bs16(p, bs);
        if (m != 0 && !rs_mask_escapes(p, m, end, &next, at)) {
            return false;
        }
    }
#endif

    if (p < next) {
        p = next;
    }
    while (p < end) {
        if (*p != '\\') {
            p++;
            continue;
        }
        const uint8_t *e = rs_escape(p, end);
        if (e == nullptr) {
            *at = p;
            return false;
        }
        p = e;
    }
    return true;
}


// RFC 8259 section 6 number grammar on the raw token. No value conversion, so
// syntactically valid numbers such as 1e400 or 30-digit integers pass, exactly
// as lua-cjson and upstream JSON parsers accept them.
bool rs_number(const uint8_t *p, size_t n) {
    const uint8_t *e = p + n;

    if (p < e && *p == '-') {
        p++;
    }
    if (p >= e) {
        return false;
    }
    if (*p == '0') {
        p++;
    } else if (*p >= '1' && *p <= '9') {
        while (p < e && rs_digit(*p)) { p++; }
    } else {
        return false;
    }

    if (p < e && *p == '.') {
        p++;
        if (p >= e || !rs_digit(*p)) {
            return false;
        }
        while (p < e && rs_digit(*p)) { p++; }
    }

    if (p < e && (*p == 'e' || *p == 'E')) {
        p++;
        if (p < e && (*p == '+' || *p == '-')) {
            p++;
        }
        if (p >= e || !rs_digit(*p)) {
            return false;
        }
        while (p < e && rs_digit(*p)) { p++; }
    }

    return p == e;
}


inline uint64_t rs_hash(const char *p, size_t n) {
    uint64_t h = 1469598103934665603ull;       // FNV-1a
    for (size_t i = 0; i < n; i++) {
        h ^= uint8_t(p[i]);
        h *= 1099511628211ull;
    }
    return h;
}


struct rs_walker {
    const uint8_t          *base;
    size_t                  len;
    const rs_cfg           &cfg;
    rs_impl                &r;
    ondemand::document     *doc;
    bool                    shallow;
    bool                    dup;
    int                     status;

    rs_walker(const uint8_t *b, size_t n, const rs_cfg &c, rs_impl &impl)
        : base(b), len(n), cfg(c), r(impl), doc(nullptr),
          shallow((c.flags & SIMDJSON_FFI_RS_F_SHALLOW) != 0),
          dup(false), status(SIMDJSON_FFI_RS_OK) {}

    bool fail(int st, const char *msg, const uint8_t *at) {
        int64_t off = -1;
        if (at != nullptr && at >= base && at <= base + len) {
            off = int64_t(at - base);
        }
        status = rs_set(r, st, msg, off);
        return false;
    }

    bool fail_sj(error_code e, const uint8_t *at) {
        int st;

        switch (e) {
        case MEMALLOC:
        case OUT_OF_CAPACITY:
            st = SIMDJSON_FFI_RS_ERR_NOMEM;
            break;

        case CAPACITY:
            st = SIMDJSON_FFI_RS_ERR_LIMIT_INPUT;
            break;

        case DEPTH_ERROR:
            st = SIMDJSON_FFI_RS_ERR_LIMIT_DEPTH;
            break;

        case TAPE_ERROR:
        case STRING_ERROR:
        case T_ATOM_ERROR:
        case F_ATOM_ERROR:
        case N_ATOM_ERROR:
        case NUMBER_ERROR:
        case BIGINT_ERROR:
        case UTF8_ERROR:
        case EMPTY:
        case UNESCAPED_CHARS:
        case UNCLOSED_STRING:
        case INCORRECT_TYPE:
        case NUMBER_OUT_OF_RANGE:
        case INCOMPLETE_ARRAY_OR_OBJECT:
        case SCALAR_DOCUMENT_AS_VALUE:
        case OUT_OF_BOUNDS:
        case TRAILING_CONTENT:
            st = SIMDJSON_FFI_RS_ERR_SYNTAX;
            break;

        default:    // INSUFFICIENT_PADDING, OUT_OF_ORDER_ITERATION, unknown
            st = SIMDJSON_FFI_RS_ERR_INTERNAL;
            break;
        }

        if (at == nullptr && doc != nullptr) {
            const char *loc;
            if (doc->current_location().get(loc) == SUCCESS) {
                at = reinterpret_cast<const uint8_t *>(loc);
            }
        }

        return fail(st, error_message(e), at);
    }

    // End offset of a container whose first token is at `s`, once the
    // iterator has consumed its closing bracket.
    uint64_t end_after(const uint8_t *s) {
        const char *loc;
        const uint8_t *p = base + len;
        if (doc->current_location().get(loc) == SUCCESS) {
            p = reinterpret_cast<const uint8_t *>(loc);
        }
        while (p > s && rs_ws(p[-1])) {
            p--;
        }
        return uint64_t(p - base);
    }

    // Paths (bitmask over cfg.paths) whose second segment equals the child key.
    uint32_t match_child(const uint8_t *kp, size_t n, uint32_t mask) {
        const uint8_t *key = kp;
        size_t klen = n;
        uint8_t buf[RS_CAP_SEG];

        if (memchr(kp, '\\', n) != nullptr) {
            rs_buf_sink sink = { buf, 0, RS_CAP_SEG };
            const uint8_t *at = kp;
            if (rs_string_body(kp, n, sink, &at) != RS_STR_OK) {
                return 0;   // longer than any segment (or invalid, already rejected)
            }
            key = buf;
            klen = sink.n;
        }

        uint32_t hit = 0;
        for (uint32_t i = 0; i < cfg.path_count; i++) {
            const simdjson_ffi_rs_path_t &p = cfg.paths[i];
            if ((mask & (1u << i)) && p.seg_len[1] == klen
                && memcmp(p.seg[1], key, klen) == 0)
            {
                hit |= 1u << i;
            }
        }
        return hit;
    }

    // Records the raw bytes of a hit for every path in `mask` (last one wins).
    bool record(uint32_t mask, uint64_t vs, uint64_t ve, uint32_t vt, bool nested) {
        for (uint32_t i = 0; i < cfg.path_count; i++) {
            if (!(mask & (1u << i))) {
                continue;
            }

            simdjson_ffi_rs_value_t &val = r.values[i];
            uint64_t n = ve - vs;

            if (uint64_t(r.extract.size()) + n > cfg.max_extract) {
                return fail(SIMDJSON_FFI_RS_ERR_LIMIT_EXTRACT,
                            "extracted bytes above max_extract_bytes", base + vs);
            }

            if (val.flags & SIMDJSON_FFI_RS_M_FOUND) {
                val.flags |= SIMDJSON_FFI_RS_M_DUPLICATE;
                if (nested) {           // top-level repeats are counted per member
                    dup = true;
                    r.pub.duplicate_count++;
                }
            }

            val.flags |= SIMDJSON_FFI_RS_M_FOUND;
            val.value_start = vs;
            val.value_end = ve;
            val.type = vt;
            val.raw_off = uint32_t(r.extract.size());
            val.raw_len = uint32_t(n);
            r.extract.append(reinterpret_cast<const char *>(base + vs), size_t(n));
        }
        return true;
    }

    // Returns true if an earlier top-level member has the same decoded key
    // (and marks it); otherwise inserts member `idx`.
    bool dedupe(uint32_t idx, size_t koff, uint32_t klen) {
        if (r.slots.size() < 2 * (size_t(idx) + 1)) {
            size_t n = r.slots.empty() ? 64 : r.slots.size() * 2;
            std::vector<uint32_t> table(n, 0);
            for (uint32_t s : r.slots) {
                if (s == 0) {
                    continue;
                }
                const simdjson_ffi_rs_member_t &m = r.members[s - 1];
                size_t h = size_t(rs_hash(r.keys.data() + m.key_off, m.key_len)) & (n - 1);
                while (table[h] != 0) {
                    h = (h + 1) & (n - 1);
                }
                table[h] = s;
            }
            r.slots.swap(table);
        }

        const char *key = r.keys.data() + koff;
        size_t mask = r.slots.size() - 1;
        size_t h = size_t(rs_hash(key, klen)) & mask;

        while (r.slots[h] != 0) {
            simdjson_ffi_rs_member_t &m = r.members[r.slots[h] - 1];
            if (m.key_len == klen && memcmp(r.keys.data() + m.key_off, key, klen) == 0) {
                m.flags |= SIMDJSON_FFI_RS_M_DUPLICATE;
                return true;
            }
            h = (h + 1) & mask;
        }

        r.slots[h] = idx + 1;
        return false;
    }

    bool value(ondemand::value &v, uint32_t parent_depth, uint32_t child_mask,
               uint64_t &vs, uint64_t &ve, uint32_t &vt)
    {
        std::string_view tok = v.raw_json_token();
        const uint8_t *s = reinterpret_cast<const uint8_t *>(tok.data());
        vs = uint64_t(s - base);

        ondemand::json_type t;
        error_code e = v.type().get(t);
        if (e) {
            return fail_sj(e, s);
        }

        switch (t) {
        case ondemand::json_type::object:
            vt = SIMDJSON_FFI_RS_T_OBJECT;
            return container(v, true, parent_depth + 1, child_mask, s, ve);

        case ondemand::json_type::array:
            vt = SIMDJSON_FFI_RS_T_ARRAY;
            return container(v, false, parent_depth + 1, 0, s, ve);

        case ondemand::json_type::string: {
            size_t n = rs_rtrim(s, tok.size());
            if (n < 2 || s[n - 1] != '"') {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid string", s);
            }
            const uint8_t *at = s;
            if (!rs_check_string(s + 1, n - 2, &at)) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid string escape", at);
            }
            // Consume the token (no unescaping, no string buffer). An unread
            // string is skipped by json_iterator::skip_child(), which treats
            // `"x" :` as a key and would accept `["x":1}` style structures.
            ondemand::raw_json_string raw;
            if (v.get_raw_json_string().get(raw) != SUCCESS) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid string", s);
            }
            vt = SIMDJSON_FFI_RS_T_STRING;
            ve = vs + n;
            return true;
        }

        case ondemand::json_type::number: {
            size_t n = rs_rtrim(s, tok.size());
            if (!rs_number(s, n)) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid number", s);
            }
            vt = SIMDJSON_FFI_RS_T_NUMBER;
            ve = vs + n;
            return true;
        }

        case ondemand::json_type::boolean: {
            bool b = false;
            if (v.get_bool().get(b) != SUCCESS) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid literal", s);
            }
            vt = SIMDJSON_FFI_RS_T_BOOLEAN;
            ve = vs + (b ? 4 : 5);
            return true;
        }

        case ondemand::json_type::null: {
            bool is_null = false;
            if (v.is_null().get(is_null) != SUCCESS || !is_null) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid literal", s);
            }
            vt = SIMDJSON_FFI_RS_T_NULL;
            ve = vs + 4;
            return true;
        }

        default:    // json_type::unknown
            return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "unexpected character", s);
        }
    }

    bool container(ondemand::value &v, bool is_obj, uint32_t depth, uint32_t child_mask,
                   const uint8_t *s, uint64_t &ve)
    {
        if (depth > cfg.max_depth) {
            return fail(SIMDJSON_FFI_RS_ERR_LIMIT_DEPTH, "nesting above max_depth", s);
        }
        if (depth > r.pub.max_depth_seen) {
            r.pub.max_depth_seen = depth;
        }

        error_code e;

        if (shallow && !(is_obj && child_mask)) {
            std::string_view raw;
            if ((e = v.raw_json().get(raw))) {
                return fail_sj(e, s);
            }
            ve = uint64_t(s - base) + rs_rtrim(s, raw.size());
            return true;
        }

        if (is_obj) {
            ondemand::object o;
            if ((e = v.get_object().get(o))) {
                return fail_sj(e, s);
            }

            for (auto fr : o) {
                ondemand::field f;
                if ((e = std::move(fr).get(f))) {
                    return fail_sj(e, nullptr);
                }

                std::string_view ek = f.escaped_key();
                const uint8_t *kp = reinterpret_cast<const uint8_t *>(ek.data());
                const uint8_t *at = kp;
                if (!rs_check_string(kp, ek.size(), &at)) {
                    return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid string escape", at);
                }

                uint32_t hit = child_mask ? match_child(kp, ek.size(), child_mask) : 0;

                // shallow mode reaches here only for a wanted parent: its children are
                // read one level deep (scalars checked, containers skipped by value())
                uint64_t cs = 0, ce = 0;
                uint32_t ct = 0;
                if (!value(f.value(), depth, 0, cs, ce, ct)) {
                    return false;
                }
                if (hit && !record(hit, cs, ce, ct, true)) {
                    return false;
                }
            }

        } else {
            ondemand::array a;
            if ((e = v.get_array().get(a))) {
                return fail_sj(e, s);
            }

            for (auto er : a) {
                ondemand::value ev;
                if ((e = std::move(er).get(ev))) {
                    return fail_sj(e, nullptr);
                }

                uint64_t cs = 0, ce = 0;
                uint32_t ct = 0;
                if (!value(ev, depth, 0, cs, ce, ct)) {
                    return false;
                }
            }
        }

        ve = end_after(s);
        return true;
    }

    bool walk_root(ondemand::document &d, const uint8_t *s) {
        doc = &d;

        ondemand::object o;
        error_code e = d.get_object().get(o);
        if (e) {
            return fail_sj(e, s);
        }

        r.pub.max_depth_seen = 1;

        for (auto fr : o) {
            ondemand::field f;
            if ((e = std::move(fr).get(f))) {
                return fail_sj(e, nullptr);
            }

            std::string_view ek = f.escaped_key();
            const uint8_t *kp = reinterpret_cast<const uint8_t *>(ek.data());

            if (r.members.size() >= cfg.max_members) {
                return fail(SIMDJSON_FFI_RS_ERR_LIMIT_MEMBERS,
                            "top-level members above max_members", kp - 1);
            }

            simdjson_ffi_rs_member_t m;
            memset(&m, 0, sizeof(m));
            m.key_start = uint64_t(kp - 1 - base);
            m.key_end = m.key_start + ek.size() + 2;

            size_t koff = r.keys.size();
            rs_str_sink sink = { r.keys, koff, cfg.max_key };
            const uint8_t *at = kp;
            int kr = rs_string_body(kp, ek.size(), sink, &at);
            if (kr == RS_STR_BAD) {
                return fail(SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid string escape", at);
            }
            if (kr == RS_STR_FULL) {
                return fail(SIMDJSON_FFI_RS_ERR_LIMIT_KEY,
                            "top-level key above max_key_bytes", kp - 1);
            }
            m.key_off = uint32_t(koff);
            m.key_len = uint32_t(r.keys.size() - koff);

            uint32_t idx = uint32_t(r.members.size());
            bool repeated = dedupe(idx, koff, m.key_len);

            const char *key = r.keys.data() + koff;
            uint32_t mask1 = 0, mask2 = 0;
            for (uint32_t i = 0; i < cfg.path_count; i++) {
                const simdjson_ffi_rs_path_t &p = cfg.paths[i];
                if (p.seg_len[0] == m.key_len && memcmp(p.seg[0], key, m.key_len) == 0) {
                    if (p.depth == 1) {
                        mask1 |= 1u << i;
                    } else {
                        mask2 |= 1u << i;
                    }
                }
            }

            if (repeated) {
                m.flags |= SIMDJSON_FFI_RS_M_DUPLICATE;
                dup = true;
                r.pub.duplicate_count++;
                // the later parent object replaces the earlier one (lua-cjson semantics)
                for (uint32_t i = 0; i < cfg.path_count; i++) {
                    if (mask2 & (1u << i)) {
                        r.values[i].flags = (r.values[i].flags & ~uint32_t(SIMDJSON_FFI_RS_M_FOUND))
                                            | SIMDJSON_FFI_RS_M_DUPLICATE;
                    }
                }
            }

            uint64_t vs = 0, ve = 0;
            uint32_t vt = 0;
            if (!value(f.value(), 1, mask2, vs, ve, vt)) {
                return false;
            }

            m.value_start = vs;
            m.value_end = ve;
            m.type = vt;
            r.members.push_back(m);

            if (mask1 && !record(mask1, vs, ve, vt, false)) {
                return false;
            }
        }

        return true;
    }
};


// Scans buf[0, len). The caller guarantees len + SIMDJSON_PADDING readable bytes.
int rs_scan(const uint8_t *buf, size_t len, const rs_cfg &cfg, rs_impl &r) {
    size_t i = 0;
    while (i < len && rs_ws(buf[i])) {
        i++;
    }
    if (i == len) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_SYNTAX, "empty input", int64_t(len));
    }

    uint8_t c = buf[i];
    if (c != '{') {
        if (c == '[' || c == '"' || c == '-' || rs_digit(c) || c == 't' || c == 'f' || c == 'n') {
            return rs_set(r, SIMDJSON_FFI_RS_ERR_ROOT_NOT_OBJECT, "root is not an object", int64_t(i));
        }
        return rs_set(r, SIMDJSON_FFI_RS_ERR_SYNTAX, "invalid first byte", int64_t(i));
    }
    r.pub.root_start = i;

    size_t j = len;                     // end of the last non-whitespace byte
    while (j > i && rs_ws(buf[j - 1])) {
        j--;
    }

    // simdjson requires the last structural of a root object to be '}' and
    // cannot tell trailing content from truncation otherwise; scan only the
    // prefix up to the last '}' and report what follows it as trailing.
    size_t scan_len = len;
    size_t trailing_at = 0;
    bool prefix = false;
    if (buf[j - 1] != '}') {
        size_t p = j - 1;
        while (p > i && buf[p] != '}') {
            p--;
        }
        if (buf[p] != '}') {
            return rs_set(r, SIMDJSON_FFI_RS_ERR_SYNTAX, "missing } at end", int64_t(j));
        }
        scan_len = p + 1;
        trailing_at = scan_len;
        while (trailing_at < len && rs_ws(buf[trailing_at])) {
            trailing_at++;
        }
        prefix = true;
    }

    ondemand::parser parser;
    ondemand::document d;
    rs_walker w(buf, len, cfg, r);

    uint64_t t1 = rs_now_ns();
    // The walk never descends past max_depth containers, so the iterator's
    // own depth (document level + containers) stays below max_depth + 2.
    error_code e = parser.allocate(scan_len, size_t(cfg.max_depth) + 2);
    if (e == SUCCESS) {
        e = parser.iterate(
                padded_string_view(reinterpret_cast<const char *>(buf), scan_len,
                                   len + SIMDJSON_PADDING)).get(d);
    }
    uint64_t t2 = rs_now_ns();
    r.pub.t_index_ns = t2 - t1;

    if (e) {
        w.fail_sj(e, nullptr);
        return w.status;
    }

    bool ok = w.walk_root(d, buf + i);

    if (ok) {
        if (prefix) {
            r.pub.root_end = scan_len;
            ok = w.fail(SIMDJSON_FFI_RS_ERR_TRAILING, "trailing content after the root object",
                        buf + trailing_at);
        } else if (!d.at_end()) {
            const char *loc;
            const uint8_t *at = nullptr;
            if (d.current_location().get(loc) == SUCCESS) {
                at = reinterpret_cast<const uint8_t *>(loc);
                r.pub.root_end = w.end_after(buf + i);
            }
            ok = w.fail(SIMDJSON_FFI_RS_ERR_TRAILING, "trailing content after the root object", at);
        } else {
            r.pub.root_end = j;
        }
    }

    r.pub.t_walk_ns = rs_now_ns() - t2;

    if (!ok) {
        return w.status;
    }
    return w.dup ? rs_set(r, SIMDJSON_FFI_RS_DUPLICATE_KEY, "duplicate key", -1)
                 : SIMDJSON_FFI_RS_OK;
}


int rs_from_string(const char *buf, size_t len, const simdjson_ffi_rs_options_t *opts,
                   rs_impl &r, uint64_t t0)
{
    rs_cfg cfg;
    int st = rs_load_opts(opts, cfg, r);
    if (st) {
        return st;
    }

    if (buf == nullptr && len > 0) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "buf is NULL", -1);
    }

    r.pub.input_len = len;
    if (len == 0) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_SYNTAX, "empty input", 0);
    }
    if (uint64_t(len) > RS_CAP_INPUT) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_LIMIT_INPUT, "input above 4294967295 bytes", -1);
    }

    // Same copy decision as parse/iterate/get_pointer: get_padded_string_view()
    // (need_allocation(), fixed in 2722c49) copies only when the SIMDJSON_PADDING
    // bytes after the input would cross into the next page. F_FORCE_COPY (tests)
    // always copies.
    padded_string copy;
    const char *data;

    if (cfg.flags & SIMDJSON_FFI_RS_F_FORCE_COPY) {
        copy = padded_string(buf, len);
        data = copy.data();
    } else {
        data = get_padded_string_view(buf, len, copy).data();
    }
    if (data == nullptr) {      // the padded copy could not be allocated
        return rs_set(r, SIMDJSON_FFI_RS_ERR_NOMEM, "out of memory", -1);
    }
    if (data != buf) {
        r.pub.copied_bytes = len;
    }
    const uint8_t *base = reinterpret_cast<const uint8_t *>(data);

    r.pub.t_input_ns = rs_now_ns() - t0;

    return rs_scan(base, len, cfg, r);
}


struct rs_file_guard {
    int      fd;
    void    *map;
    size_t   map_len;

    rs_file_guard() : fd(-1), map(MAP_FAILED), map_len(0) {}

    ~rs_file_guard() {
        if (fd >= 0) {
            close(fd);
        }
        if (map != MAP_FAILED) {
            munmap(map, map_len);
        }
    }
};


int rs_io(rs_impl &r, int err, const char *msg) {
    r.pub.sys_errno = err;
    return rs_set(r, SIMDJSON_FFI_RS_ERR_IO, msg, -1);
}


// Maps the file read-only without copying. A PROT_READ anonymous reservation
// of roundup(size + SIMDJSON_PADDING, page) bytes comes first, then the file
// is mapped over its start with MAP_FIXED: bytes past EOF in the last file
// page are zero-filled by the kernel and the rest of the reservation reads as
// zero, so simdjson's padding is always present and always zero.
int rs_from_file(const char *path, size_t path_len, const simdjson_ffi_rs_options_t *opts,
                 rs_impl &r, uint64_t t0)
{
    rs_cfg cfg;
    int st = rs_load_opts(opts, cfg, r);
    if (st) {
        return st;
    }

    if (path == nullptr || path_len == 0 || path_len > RS_CAP_PATH_BYTES
        || memchr(path, '\0', path_len) != nullptr)
    {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_BAD_ARGS, "path must be 1..4095 bytes without NUL", -1);
    }

    char cpath[RS_CAP_PATH_BYTES + 1];
    memcpy(cpath, path, path_len);
    cpath[path_len] = '\0';

    rs_file_guard g;

    g.fd = open(cpath, O_RDONLY | O_CLOEXEC);
    if (g.fd < 0) {
        return rs_io(r, errno, "open failed");
    }

    struct stat sb;
    if (fstat(g.fd, &sb) != 0) {
        return rs_io(r, errno, "fstat failed");
    }
    if (!S_ISREG(sb.st_mode)) {
        return rs_io(r, S_ISDIR(sb.st_mode) ? EISDIR : EINVAL, "not a regular file");
    }

    r.pub.input_len = uint64_t(sb.st_size);
    if (sb.st_size == 0) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_SYNTAX, "empty input", 0);
    }
    if (uint64_t(sb.st_size) > RS_CAP_INPUT) {
        return rs_set(r, SIMDJSON_FFI_RS_ERR_LIMIT_INPUT, "input above 4294967295 bytes", -1);
    }

    size_t size = size_t(sb.st_size);
    size_t page = size_t(rs_page());
    size_t total = ((size + SIMDJSON_PADDING + page - 1) / page) * page;

    int reserve_flags = MAP_PRIVATE | MAP_ANONYMOUS;
#ifdef MAP_NORESERVE
    reserve_flags |= MAP_NORESERVE;
#endif

    g.map = mmap(nullptr, total, PROT_READ, reserve_flags, -1, 0);
    if (g.map == MAP_FAILED) {
        return rs_io(r, errno, "mmap reserve failed");
    }
    g.map_len = total;

    if (mmap(g.map, size, PROT_READ, MAP_PRIVATE | MAP_FIXED, g.fd, 0) == MAP_FAILED) {
        return rs_io(r, errno, "mmap file failed");
    }

    close(g.fd);
    g.fd = -1;

    r.pub.t_input_ns = rs_now_ns() - t0;

    return rs_scan(static_cast<const uint8_t *>(g.map), size, cfg, r);
}

}   // namespace


extern "C"
uint32_t simdjson_ffi_root_scan_abi(uint32_t *sizes, uint32_t n) {
    const uint32_t s[5] = {
        uint32_t(sizeof(simdjson_ffi_rs_path_t)),
        uint32_t(sizeof(simdjson_ffi_rs_options_t)),
        uint32_t(sizeof(simdjson_ffi_rs_member_t)),
        uint32_t(sizeof(simdjson_ffi_rs_value_t)),
        uint32_t(sizeof(simdjson_ffi_rs_result_t)),
    };

    for (uint32_t i = 0; sizes != nullptr && i < n && i < 5; i++) {
        sizes[i] = s[i];
    }

    return RS_ABI_VERSION;
}


extern "C"
int simdjson_ffi_root_scan_string(const char *buf, size_t len,
    const simdjson_ffi_rs_options_t *opts, simdjson_ffi_rs_result_t **out)
{
    uint64_t t0 = rs_now_ns();

    if (out == nullptr) {
        return SIMDJSON_FFI_RS_ERR_BAD_ARGS;
    }
    *out = nullptr;

    rs_impl *r = new (std::nothrow) rs_impl();
    if (r == nullptr) {
        return SIMDJSON_FFI_RS_ERR_NOMEM;
    }
    *out = &r->pub;

    int st;
    try {
        st = rs_from_string(buf, len, opts, *r, t0);
    } catch (std::bad_alloc &) {
        st = rs_set(*r, SIMDJSON_FFI_RS_ERR_NOMEM, "out of memory", -1);
    } catch (...) {
        st = rs_set(*r, SIMDJSON_FFI_RS_ERR_INTERNAL, "internal error", -1);
    }

    return rs_finish(*r, st, t0);
}


extern "C"
int simdjson_ffi_root_scan_file(const char *path, size_t path_len,
    const simdjson_ffi_rs_options_t *opts, simdjson_ffi_rs_result_t **out)
{
    uint64_t t0 = rs_now_ns();

    if (out == nullptr) {
        return SIMDJSON_FFI_RS_ERR_BAD_ARGS;
    }
    *out = nullptr;

    rs_impl *r = new (std::nothrow) rs_impl();
    if (r == nullptr) {
        return SIMDJSON_FFI_RS_ERR_NOMEM;
    }
    *out = &r->pub;

    int st;
    try {
        st = rs_from_file(path, path_len, opts, *r, t0);
    } catch (std::bad_alloc &) {
        st = rs_set(*r, SIMDJSON_FFI_RS_ERR_NOMEM, "out of memory", -1);
    } catch (...) {
        st = rs_set(*r, SIMDJSON_FFI_RS_ERR_INTERNAL, "internal error", -1);
    }

    return rs_finish(*r, st, t0);
}


extern "C"
void simdjson_ffi_root_scan_free(simdjson_ffi_rs_result_t *res) {
    if (res == nullptr) {
        return;
    }
    delete static_cast<rs_impl *>(res->opaque);
}
