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
static bool need_allocation(const char *buf, size_t len) {
    if (PAGESIZE == 0) {
        PAGESIZE = getpagesize();
    }

    SIMDJSON_DEVELOPMENT_ASSERT(PAGESIZE > 0);

    return ((reinterpret_cast<uintptr_t>(buf + len - 1) % PAGESIZE) <
            SIMDJSON_PADDING);
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
