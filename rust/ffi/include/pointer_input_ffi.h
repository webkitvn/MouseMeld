#ifndef POINTER_INPUT_FFI_H
#define POINTER_INPUT_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define POINTER_INPUT_ABI_VERSION_V3 UINT32_C(3)

#define POINTER_INPUT_STATUS_SUCCESS_V3 UINT32_C(0)
#define POINTER_INPUT_STATUS_INVALID_ARGUMENT_V3 UINT32_C(1)
#define POINTER_INPUT_STATUS_EVALUATION_FAILED_V3 UINT32_C(2)
#define POINTER_INPUT_STATUS_PANIC_V3 UINT32_C(3)
#define POINTER_INPUT_STATUS_BUSY_V3 UINT32_C(4)

#define POINTER_INPUT_DECISION_PRESERVE_V3 UINT32_C(0)
#define POINTER_INPUT_DECISION_REPLACE_V3 UINT32_C(1)
#define POINTER_INPUT_DECISION_SUPPRESS_V3 UINT32_C(2)

#define POINTER_INPUT_DIRECTION_SYSTEM_V3 UINT32_C(0)
#define POINTER_INPUT_DIRECTION_REVERSE_V3 UINT32_C(1)

#define POINTER_INPUT_SOURCE_MOUSE_V3 UINT32_C(0)
#define POINTER_INPUT_SOURCE_TRACKPAD_V3 UINT32_C(1)
#define POINTER_INPUT_SOURCE_UNKNOWN_V3 UINT32_C(2)

#define POINTER_INPUT_GRANULARITY_LINE_BASED_V3 UINT32_C(0)
#define POINTER_INPUT_GRANULARITY_PIXEL_BASED_V3 UINT32_C(1)

#define POINTER_INPUT_EVENT_SCROLL_V3 UINT32_C(0)
#define POINTER_INPUT_EVENT_BUTTON_V3 UINT32_C(1)
#define POINTER_INPUT_BUTTON_DOWN_V3 UINT32_C(0)
#define POINTER_INPUT_BUTTON_UP_V3 UINT32_C(1)
#define POINTER_INPUT_BUTTON_DRAG_V3 UINT32_C(2)

#define POINTER_INPUT_CYCLE_CLOSED_V3 UINT32_C(0)
#define POINTER_INPUT_CYCLE_OPEN_V3 UINT32_C(1)
#define POINTER_INPUT_CYCLE_QUARANTINED_V3 UINT32_C(2)

typedef uint32_t pointer_input_status_v3;

typedef struct pointer_input_event_v3 {
    uint32_t version;
    uint32_t size;
    uint32_t event_kind;
    uint32_t source_class;
    uint32_t granularity;
    uint32_t button_phase;
    uint32_t button_number;
    uint32_t modifiers_held;
    int64_t horizontal_lines;
    int64_t vertical_lines;
    uint64_t event_number;
    uint64_t monotonic_time_ns;
    uint32_t reserved[2];
} pointer_input_event_v3;

typedef struct pointer_input_configuration_v3 {
    uint32_t version;
    uint32_t size;
    uint32_t direction;
    uint32_t amount_percent;
    uint32_t binding_present;
    uint32_t binding_enabled;
    uint32_t binding_button_number;
    uint32_t reserved;
} pointer_input_configuration_v3;

typedef struct pointer_input_decision_v3 {
    uint32_t version;
    uint32_t size;
    uint32_t decision;
    uint32_t request_back;
    uint32_t cycle_tag;
    uint32_t reserved[3];
    int64_t horizontal_hundredths;
    int64_t vertical_hundredths;
    uint32_t cycle_button_number;
    uint32_t cycle_reserved;
    uint64_t cycle_event_number;
    uint64_t cycle_deadline_monotonic_ns;
} pointer_input_decision_v3;

/* Owner/storage/lifetime/concurrency preconditions remain unchanged for this ABI. */
pointer_input_status_v3 pointer_input_engine_create_v3(void **out_engine);
pointer_input_status_v3 pointer_input_configuration_validate_v3(
    const pointer_input_configuration_v3 *configuration);
pointer_input_status_v3 pointer_input_engine_set_configuration_v3(
    void *handle, const pointer_input_configuration_v3 *configuration);

/* A non-null output is initialized to valid Preserve/closed before request validation.
 * A non-success status makes that fallback noncommittable: it is neither release/recovery
 * evidence nor a next cycle. The caller must gate commitment on status and inhibit admission
 * until a valid release or lifecycle recovery. `cycle` and `out_decision` may alias. */
pointer_input_status_v3 pointer_input_engine_evaluate_v3(
    void *handle, const pointer_input_event_v3 *event,
    const pointer_input_decision_v3 *cycle, pointer_input_decision_v3 *out_decision);
pointer_input_status_v3 pointer_input_engine_destroy_v3(void **in_out_handle);

#ifdef __cplusplus
}
#endif

#endif
