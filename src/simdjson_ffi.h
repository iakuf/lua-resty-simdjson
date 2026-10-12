#ifndef SIMDJSON_FFI_H
#define SIMDJSON_FFI_H


#include <unistd.h>
#include <stack>
#include <vector>
#include <limits>


#define SIMDJSON_FFI_BATCH_SIZE 2048
#define SIMDJSON_FFI_ERROR      -1


extern "C" {
    typedef enum {
        SIMDJSON_FFI_OPCODE_ARRAY = 0,
        SIMDJSON_FFI_OPCODE_OBJECT,
        SIMDJSON_FFI_OPCODE_NUMBER,
        SIMDJSON_FFI_OPCODE_STRING,
        SIMDJSON_FFI_OPCODE_BOOLEAN,
        SIMDJSON_FFI_OPCODE_NULL,
        SIMDJSON_FFI_OPCODE_RETURN
    } simdjson_ffi_opcode_e;


    typedef struct {
        simdjson_ffi_opcode_e      opcode;
        uint32_t                   size;

        union {
            const char            *str;
            double                 number;
            uint32_t               boolean;
        }                          val;
    } simdjson_ffi_op_t;
}


static_assert(sizeof(uintptr_t) == 8,
              "uintptr_t should be 8 bytes");

// We assume this enum takes 4 bytes,
// so we could utilize the alignment rules to save 4 bytes for `simdjson_ffi_op_t`.
static_assert(sizeof(simdjson_ffi_opcode_e) <= 4,
              "simdjson_ffi_opcode_e should be less than 4 bytes");

// This struct was designed carefully for minimal memory usage,
// asserting it here to avoid breaking this design unintentionally.
static_assert(sizeof(simdjson_ffi_op_t) == 16,
              "simdjson_ffi_op_t should be 16 bytes");

// If the `SIMDJSON_FFI_BATCH_SIZE` is larger than 2^32,
// we might get a float number in LuaJIT.
// The design goal of this library doesn't need such a large batch,
// so this assertion is just in case.
static_assert(SIMDJSON_FFI_BATCH_SIZE <= std::numeric_limits<uint32_t>::max(),
              "SIMDJSON_FFI_BATCH_SIZE should be less than 2^32");


enum class simdjson_ffi_resume_state : unsigned char {
    array,
    object
};


struct simdjson_ffi_stack_frame {
    simdjson_ffi_resume_state       state;
    bool                            processing = false;

    union it {
        template<typename Iter>
        struct range {
            Iter current;
            Iter end;

            range(Iter current, Iter end) : current(current), end(end) {}
        };

        range<simdjson::ondemand::array_iterator>  array;
        range<simdjson::ondemand::object_iterator> object;

        it(simdjson::ondemand::array &v): array(v.begin(), v.end()) {}
        it(simdjson::ondemand::object &v): object(v.begin(), v.end()) {}
    } it;

    simdjson_ffi_stack_frame(simdjson::ondemand::array &v):
        state(simdjson_ffi_resume_state::array), it(v) {}

    simdjson_ffi_stack_frame(simdjson::ondemand::object &v):
        state(simdjson_ffi_resume_state::object), it(v) {}
};


struct simdjson_ffi_state_t {
    simdjson::ondemand::parser            parser;
    simdjson::ondemand::document          document;
    std::vector<simdjson_ffi_op_t>        ops;
    size_t                                ops_n;
    std::stack<simdjson_ffi_stack_frame>  frames;
    simdjson::padded_string               json;
};


typedef struct simdjson_ffi_state_t simdjson_ffi_state;


// ===========================================================================
// Root scan (ABI version 1): one stage-1 pass over a JSON object body that
// returns every top-level member (decoded key + byte offsets) and the bounded
// raw bytes of caller-selected top-level / second-level fields.
//
// Purely additive: nothing above this block changes. Offsets are 0-based
// byte offsets into the input, ranges are [start, end). See README
// "Root scan (top-level member index)".
// ===========================================================================

extern "C" {
    typedef enum {
        SIMDJSON_FFI_RS_OK                  = 0,
        SIMDJSON_FFI_RS_DUPLICATE_KEY       = 1,   /* non-fatal: fully validated, index complete */
        SIMDJSON_FFI_RS_ERR_SYNTAX          = -10,
        SIMDJSON_FFI_RS_ERR_ROOT_NOT_OBJECT = -11,
        SIMDJSON_FFI_RS_ERR_TRAILING        = -12,
        SIMDJSON_FFI_RS_ERR_LIMIT_DEPTH     = -20,
        SIMDJSON_FFI_RS_ERR_LIMIT_MEMBERS   = -21,
        SIMDJSON_FFI_RS_ERR_LIMIT_KEY       = -22,
        SIMDJSON_FFI_RS_ERR_LIMIT_EXTRACT   = -23,
        SIMDJSON_FFI_RS_ERR_LIMIT_INPUT     = -24,
        SIMDJSON_FFI_RS_ERR_IO              = -30,
        SIMDJSON_FFI_RS_ERR_NOMEM           = -40,
        SIMDJSON_FFI_RS_ERR_BAD_ARGS        = -41,
        SIMDJSON_FFI_RS_ERR_INTERNAL        = -42
    } simdjson_ffi_rs_status_e;

    typedef enum {
        SIMDJSON_FFI_RS_T_OBJECT = 1,
        SIMDJSON_FFI_RS_T_ARRAY,
        SIMDJSON_FFI_RS_T_STRING,
        SIMDJSON_FFI_RS_T_NUMBER,
        SIMDJSON_FFI_RS_T_BOOLEAN,
        SIMDJSON_FFI_RS_T_NULL
    } simdjson_ffi_rs_type_e;

    typedef enum {
        SIMDJSON_FFI_RS_F_SHALLOW    = 1,   /* scheme B: only the top level is strictly validated */
        SIMDJSON_FFI_RS_F_FORCE_COPY = 2    /* tests: string input always takes the padded-copy path */
    } simdjson_ffi_rs_flag_e;

    typedef enum {
        SIMDJSON_FFI_RS_M_DUPLICATE = 1,
        SIMDJSON_FFI_RS_M_FOUND     = 2
    } simdjson_ffi_rs_mark_e;

    /* depth = 1: top-level key seg[0]; depth = 2: direct child seg[1] of top-level object seg[0] */
    typedef struct {
        const char  *seg[2];
        uint32_t     seg_len[2];
        uint32_t     depth;
        uint32_t     reserved;
    } simdjson_ffi_rs_path_t;

    /* every limit: 0 = default */
    typedef struct {
        uint32_t                       max_depth;
        uint32_t                       max_members;
        uint32_t                       max_key_bytes;
        uint32_t                       max_extract_bytes;
        uint32_t                       flags;
        uint32_t                       path_count;
        const simdjson_ffi_rs_path_t  *paths;
    } simdjson_ffi_rs_options_t;

    /* key_start/key_end include the quotes; key_off/key_len index the decoded key in result->keys */
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

    /* one entry per options->paths[i]; raw_off/raw_len index result->extract */
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
        const char                       *message;       /* static string, never input bytes */
        int64_t                           error_offset;  /* -1 = unknown */
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

    /* returns the ABI version (1); writes up to n struct sizes:
       path, options, member, value, result */
    uint32_t simdjson_ffi_root_scan_abi(uint32_t *sizes, uint32_t n);

    /* both return result->status; *out is NULL only if out == NULL or the result
       itself could not be allocated (NOMEM). Otherwise the caller must free *out. */
    int simdjson_ffi_root_scan_string(const char *buf, size_t len,
                                      const simdjson_ffi_rs_options_t *opts,
                                      simdjson_ffi_rs_result_t **out);
    int simdjson_ffi_root_scan_file(const char *path, size_t path_len,
                                    const simdjson_ffi_rs_options_t *opts,
                                    simdjson_ffi_rs_result_t **out);

    /* NULL-safe */
    void simdjson_ffi_root_scan_free(simdjson_ffi_rs_result_t *res);
}


static_assert(sizeof(simdjson_ffi_rs_path_t) == 32,
              "simdjson_ffi_rs_path_t should be 32 bytes");
static_assert(sizeof(simdjson_ffi_rs_options_t) == 32,
              "simdjson_ffi_rs_options_t should be 32 bytes");
static_assert(sizeof(simdjson_ffi_rs_member_t) == 48,
              "simdjson_ffi_rs_member_t should be 48 bytes");
static_assert(sizeof(simdjson_ffi_rs_value_t) == 32,
              "simdjson_ffi_rs_value_t should be 32 bytes");
static_assert(sizeof(simdjson_ffi_rs_result_t) == 144,
              "simdjson_ffi_rs_result_t should be 144 bytes");


#endif /* !SIMDJSON_FFI_H */
