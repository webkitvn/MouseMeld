#include <assert.h>
#include <stddef.h>

#include "pointer_input_ffi.h"

_Static_assert(POINTER_INPUT_STATUS_BUSY_V3 == UINT32_C(4), "Busy status must remain 4");
_Static_assert(POINTER_INPUT_ABI_VERSION_V3 == 3, "ABI version");
_Static_assert(sizeof(pointer_input_event_v3) == 72, "event layout");
_Static_assert(offsetof(pointer_input_event_v3, event_number) == 48, "event number offset");
_Static_assert(sizeof(pointer_input_configuration_v3) == 32, "configuration layout");
_Static_assert(offsetof(pointer_input_configuration_v3, binding_button_number) == 24, "binding offset");
_Static_assert(sizeof(pointer_input_decision_v3) == 72, "decision layout");
_Static_assert(offsetof(pointer_input_decision_v3, horizontal_hundredths) == 32, "horizontal offset");
_Static_assert(offsetof(pointer_input_decision_v3, cycle_event_number) == 56, "cycle event offset");

static pointer_input_event_v3 scroll_event(int64_t horizontal, int64_t vertical) {
    return (pointer_input_event_v3){
        .version = POINTER_INPUT_ABI_VERSION_V3,
        .size = sizeof(pointer_input_event_v3),
        .event_kind = POINTER_INPUT_EVENT_SCROLL_V3,
        .source_class = POINTER_INPUT_SOURCE_UNKNOWN_V3,
        .granularity = POINTER_INPUT_GRANULARITY_LINE_BASED_V3,
        .horizontal_lines = horizontal,
        .vertical_lines = vertical,
    };
}

static pointer_input_event_v3 button_event(uint32_t phase, uint32_t button, uint64_t number, uint64_t time) {
    return (pointer_input_event_v3){
        .version = POINTER_INPUT_ABI_VERSION_V3,
        .size = sizeof(pointer_input_event_v3),
        .event_kind = POINTER_INPUT_EVENT_BUTTON_V3,
        .button_phase = phase,
        .button_number = button,
        .event_number = number,
        .monotonic_time_ns = time,
    };
}

static pointer_input_decision_v3 closed_cycle(void) {
    return (pointer_input_decision_v3){
        .version = POINTER_INPUT_ABI_VERSION_V3,
        .size = sizeof(pointer_input_decision_v3),
        .decision = POINTER_INPUT_DECISION_PRESERVE_V3,
        .cycle_tag = POINTER_INPUT_CYCLE_CLOSED_V3,
    };
}

int main(void) {
    void *engine = NULL;
    pointer_input_configuration_v3 configuration = {
        .version = POINTER_INPUT_ABI_VERSION_V3,
        .size = sizeof(pointer_input_configuration_v3),
        .direction = POINTER_INPUT_DIRECTION_REVERSE_V3,
        .amount_percent = 100,
        .binding_present = 1,
        .binding_enabled = 1,
        .binding_button_number = 3,
    };
    pointer_input_decision_v3 cycle = closed_cycle();
    pointer_input_decision_v3 output = closed_cycle();
    pointer_input_event_v3 event = scroll_event(0, 3);

    assert(pointer_input_configuration_validate_v3(&configuration) == POINTER_INPUT_STATUS_SUCCESS_V3);
    configuration.reserved = 1;
    assert(pointer_input_configuration_validate_v3(&configuration) == POINTER_INPUT_STATUS_INVALID_ARGUMENT_V3);
    configuration.reserved = 0;
    assert(pointer_input_engine_create_v3(&engine) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(engine != NULL);
    assert(pointer_input_engine_set_configuration_v3(engine, &configuration) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(pointer_input_engine_evaluate_v3(engine, &event, &cycle, &output) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(output.decision == POINTER_INPUT_DECISION_REPLACE_V3);
    assert(output.vertical_hundredths == -300);

    event = button_event(POINTER_INPUT_BUTTON_DOWN_V3, 3, 7, 100);
    assert(pointer_input_engine_evaluate_v3(engine, &event, &cycle, &output) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(output.decision == POINTER_INPUT_DECISION_SUPPRESS_V3);
    assert(output.request_back == 1);
    assert(output.cycle_tag == POINTER_INPUT_CYCLE_OPEN_V3);
    cycle = output;
    event = button_event(POINTER_INPUT_BUTTON_UP_V3, 3, 7, 200);
    assert(pointer_input_engine_evaluate_v3(engine, &event, &cycle, &output) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(output.decision == POINTER_INPUT_DECISION_SUPPRESS_V3);
    assert(output.request_back == 0);
    assert(output.cycle_tag == POINTER_INPUT_CYCLE_CLOSED_V3);

    event.size--;
    output.decision = POINTER_INPUT_DECISION_SUPPRESS_V3;
    assert(pointer_input_engine_evaluate_v3(engine, &event, &cycle, &output) == POINTER_INPUT_STATUS_INVALID_ARGUMENT_V3);
    assert(output.decision == POINTER_INPUT_DECISION_PRESERVE_V3);
    assert(output.request_back == 0);

    assert(pointer_input_engine_destroy_v3(&engine) == POINTER_INPUT_STATUS_SUCCESS_V3);
    assert(engine == NULL);
    assert(pointer_input_engine_destroy_v3(&engine) == POINTER_INPUT_STATUS_SUCCESS_V3);
    return 0;
}
