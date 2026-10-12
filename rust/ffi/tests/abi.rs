use pointer_input_ffi::{
    POINTER_INPUT_ABI_VERSION_V3, POINTER_INPUT_BUTTON_DOWN_V3, POINTER_INPUT_BUTTON_DRAG_V3,
    POINTER_INPUT_BUTTON_UP_V3, POINTER_INPUT_CYCLE_CLOSED_V3, POINTER_INPUT_CYCLE_OPEN_V3,
    POINTER_INPUT_CYCLE_QUARANTINED_V3, POINTER_INPUT_DECISION_PRESERVE_V3,
    POINTER_INPUT_DECISION_REPLACE_V3, POINTER_INPUT_DECISION_SUPPRESS_V3,
    POINTER_INPUT_DIRECTION_REVERSE_V3, POINTER_INPUT_EVENT_BUTTON_V3,
    POINTER_INPUT_EVENT_SCROLL_V3, POINTER_INPUT_GRANULARITY_LINE_BASED_V3,
    POINTER_INPUT_GRANULARITY_PIXEL_BASED_V3, POINTER_INPUT_SOURCE_UNKNOWN_V3,
    PointerInputConfigurationV3, PointerInputDecisionV3, PointerInputEventV3, PointerInputStatusV3,
    pointer_input_configuration_validate_v3, pointer_input_engine_create_v3,
    pointer_input_engine_destroy_v3, pointer_input_engine_evaluate_v3,
    pointer_input_engine_set_configuration_v3,
};

fn scroll(horizontal_lines: i64, vertical_lines: i64) -> PointerInputEventV3 {
    PointerInputEventV3 {
        version: POINTER_INPUT_ABI_VERSION_V3,
        size: size_of::<PointerInputEventV3>() as u32,
        event_kind: POINTER_INPUT_EVENT_SCROLL_V3,
        source_class: POINTER_INPUT_SOURCE_UNKNOWN_V3,
        granularity: POINTER_INPUT_GRANULARITY_LINE_BASED_V3,
        button_phase: 0,
        button_number: 0,
        modifiers_held: 0,
        horizontal_lines,
        vertical_lines,
        event_number: 0,
        monotonic_time_ns: 0,
        reserved: [0; 2],
    }
}
fn button(
    phase: u32,
    button_number: u32,
    event_number: u64,
    monotonic_time_ns: u64,
) -> PointerInputEventV3 {
    PointerInputEventV3 {
        version: POINTER_INPUT_ABI_VERSION_V3,
        size: size_of::<PointerInputEventV3>() as u32,
        event_kind: POINTER_INPUT_EVENT_BUTTON_V3,
        source_class: 0,
        granularity: 0,
        button_phase: phase,
        button_number,
        modifiers_held: 0,
        horizontal_lines: 0,
        vertical_lines: 0,
        event_number,
        monotonic_time_ns,
        reserved: [0; 2],
    }
}
fn closed_cycle() -> PointerInputDecisionV3 {
    PointerInputDecisionV3 {
        version: POINTER_INPUT_ABI_VERSION_V3,
        size: size_of::<PointerInputDecisionV3>() as u32,
        decision: POINTER_INPUT_DECISION_PRESERVE_V3,
        request_back: 0,
        cycle_tag: POINTER_INPUT_CYCLE_CLOSED_V3,
        reserved: [0; 3],
        horizontal_hundredths: 0,
        vertical_hundredths: 0,
        cycle_button_number: 0,
        cycle_reserved: 0,
        cycle_event_number: 0,
        cycle_deadline_monotonic_ns: 0,
    }
}
fn configuration(
    binding_present: u32,
    binding_enabled: u32,
    binding_button_number: u32,
) -> PointerInputConfigurationV3 {
    PointerInputConfigurationV3 {
        version: POINTER_INPUT_ABI_VERSION_V3,
        size: size_of::<PointerInputConfigurationV3>() as u32,
        direction: POINTER_INPUT_DIRECTION_REVERSE_V3,
        amount_percent: 100,
        binding_present,
        binding_enabled,
        binding_button_number,
        reserved: 0,
    }
}
fn create(owner: &mut *mut core::ffi::c_void) -> PointerInputStatusV3 {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
    loop {
        let status = unsafe { pointer_input_engine_create_v3(owner) };
        if status != PointerInputStatusV3::Busy
            || !owner.is_null()
            || std::time::Instant::now() >= deadline
        {
            return status;
        }
        std::thread::yield_now();
    }
}
fn evaluate(
    owner: *mut core::ffi::c_void,
    event: &PointerInputEventV3,
    cycle: &PointerInputDecisionV3,
    output: &mut PointerInputDecisionV3,
) -> PointerInputStatusV3 {
    unsafe { pointer_input_engine_evaluate_v3(owner, event, cycle, output) }
}

#[test]
fn rejects_invalid_layout_tags_and_cycle_with_initialized_fail_open_output() {
    let mut owner = core::ptr::null_mut();
    let valid_event = scroll(0, 3);
    let valid_cycle = closed_cycle();
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    for (event, cycle) in [
        (
            PointerInputEventV3 {
                size: valid_event.size - 1,
                ..valid_event
            },
            valid_cycle,
        ),
        (
            PointerInputEventV3 {
                event_kind: u32::MAX,
                ..valid_event
            },
            valid_cycle,
        ),
        (
            PointerInputEventV3 {
                reserved: [0, 1],
                ..valid_event
            },
            valid_cycle,
        ),
        (
            valid_event,
            PointerInputDecisionV3 {
                cycle_tag: POINTER_INPUT_CYCLE_OPEN_V3,
                cycle_button_number: 3,
                cycle_deadline_monotonic_ns: 0,
                ..valid_cycle
            },
        ),
        (
            valid_event,
            PointerInputDecisionV3 {
                reserved: [0, 0, 1],
                ..valid_cycle
            },
        ),
    ] {
        let mut output = PointerInputDecisionV3 {
            decision: u32::MAX,
            request_back: 1,
            ..closed_cycle()
        };
        assert_eq!(
            evaluate(owner, &event, &cycle, &mut output),
            PointerInputStatusV3::InvalidArgument
        );
        assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
        assert_eq!(output.request_back, 0);
        assert_eq!(output.cycle_tag, POINTER_INPUT_CYCLE_CLOSED_V3);
    }
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn configuration_validation_requires_canonical_absent_or_valid_present_binding() {
    let valid = configuration(1, 1, 3);
    assert_eq!(
        unsafe { pointer_input_configuration_validate_v3(&valid) },
        PointerInputStatusV3::Success
    );
    for invalid in [
        configuration(0, 1, 0),
        configuration(0, 0, 3),
        configuration(1, 0, 2),
        configuration(1, 2, 3),
        PointerInputConfigurationV3 {
            reserved: 1,
            ..valid
        },
    ] {
        assert_eq!(
            unsafe { pointer_input_configuration_validate_v3(&invalid) },
            PointerInputStatusV3::InvalidArgument
        );
    }
}

#[test]
fn invalid_configuration_does_not_change_scroll_or_binding() {
    let mut owner = core::ptr::null_mut();
    let valid = configuration(1, 1, 3);
    let event = scroll(0, 3);
    let cycle = closed_cycle();
    let mut output = closed_cycle();
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &valid) },
        PointerInputStatusV3::Success
    );
    let invalid = PointerInputConfigurationV3 {
        binding_button_number: 2,
        ..valid
    };
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &invalid) },
        PointerInputStatusV3::InvalidArgument
    );
    assert_eq!(
        evaluate(owner, &event, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_REPLACE_V3);
    let down = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 7, 100);
    assert_eq!(
        evaluate(owner, &down, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_SUPPRESS_V3);
    assert_eq!(output.request_back, 1);
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn button_cycle_is_pure_initial_only_nonrenewable_and_quarantines() {
    let mut owner = core::ptr::null_mut();
    let config = configuration(1, 1, 3);
    let mut output = closed_cycle();
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &config) },
        PointerInputStatusV3::Success
    );
    let down = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 9, 100);
    assert_eq!(
        evaluate(owner, &down, &closed_cycle(), &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (output.decision, output.request_back, output.cycle_tag),
        (
            POINTER_INPUT_DECISION_SUPPRESS_V3,
            1,
            POINTER_INPUT_CYCLE_OPEN_V3
        )
    );
    let opened = output;
    let duplicate = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 9, 200);
    assert_eq!(
        evaluate(owner, &duplicate, &opened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (
            output.decision,
            output.request_back,
            output.cycle_tag,
            output.cycle_deadline_monotonic_ns
        ),
        (
            POINTER_INPUT_DECISION_SUPPRESS_V3,
            0,
            POINTER_INPUT_CYCLE_OPEN_V3,
            opened.cycle_deadline_monotonic_ns
        )
    );
    let up = button(POINTER_INPUT_BUTTON_UP_V3, 3, 9, 300);
    let duplicate_open = output;
    assert_eq!(
        evaluate(owner, &up, &duplicate_open, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (output.decision, output.request_back, output.cycle_tag),
        (
            POINTER_INPUT_DECISION_SUPPRESS_V3,
            0,
            POINTER_INPUT_CYCLE_CLOSED_V3
        )
    );
    let reopened = opened;
    let mismatch = button(POINTER_INPUT_BUTTON_UP_V3, 4, 9, 300);
    assert_eq!(
        evaluate(owner, &mismatch, &reopened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (output.decision, output.request_back, output.cycle_tag),
        (
            POINTER_INPUT_DECISION_PRESERVE_V3,
            0,
            POINTER_INPUT_CYCLE_QUARANTINED_V3
        )
    );
    let drag = button(POINTER_INPUT_BUTTON_DRAG_V3, 3, 9, 300);
    assert_eq!(
        evaluate(owner, &drag, &reopened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
    let expired = button(
        POINTER_INPUT_BUTTON_DOWN_V3,
        3,
        9,
        reopened.cycle_deadline_monotonic_ns,
    );
    assert_eq!(
        evaluate(owner, &expired, &reopened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (output.decision, output.request_back, output.cycle_tag),
        (
            POINTER_INPUT_DECISION_PRESERVE_V3,
            0,
            POINTER_INPUT_CYCLE_QUARANTINED_V3
        )
    );
    let release = button(
        POINTER_INPUT_BUTTON_UP_V3,
        3,
        9,
        reopened.cycle_deadline_monotonic_ns + 1,
    );
    let quarantined = output;
    assert_eq!(
        evaluate(owner, &release, &quarantined, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.cycle_tag, POINTER_INPUT_CYCLE_CLOSED_V3);
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn aliased_cycle_and_output_do_not_repeat_back() {
    let mut owner = core::ptr::null_mut();
    let config = configuration(1, 1, 3);
    let mut state = closed_cycle();
    let mut down = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 7, 100);
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &config) },
        PointerInputStatusV3::Success
    );
    assert_eq!(
        unsafe { pointer_input_engine_evaluate_v3(owner, &down, &state, &mut state) },
        PointerInputStatusV3::Success
    );
    assert_eq!(state.request_back, 1);
    down.monotonic_time_ns = 200;
    assert_eq!(
        unsafe { pointer_input_engine_evaluate_v3(owner, &down, &state, &mut state) },
        PointerInputStatusV3::Success
    );
    assert_eq!(state.decision, POINTER_INPUT_DECISION_SUPPRESS_V3);
    assert_eq!(state.request_back, 0);
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn matching_release_at_expiry_closes_before_the_next_distinct_down() {
    let mut owner = core::ptr::null_mut();
    let config = configuration(1, 1, 3);
    let mut output = closed_cycle();
    let down = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 7, 100);
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &config) },
        PointerInputStatusV3::Success
    );
    assert_eq!(
        evaluate(owner, &down, &closed_cycle(), &mut output),
        PointerInputStatusV3::Success
    );
    let opened = output;
    let expired_duplicate = button(
        POINTER_INPUT_BUTTON_DOWN_V3,
        3,
        7,
        opened.cycle_deadline_monotonic_ns,
    );
    assert_eq!(
        evaluate(owner, &expired_duplicate, &opened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.request_back, 0);
    assert_eq!(output.cycle_tag, POINTER_INPUT_CYCLE_QUARANTINED_V3);
    let release = button(
        POINTER_INPUT_BUTTON_UP_V3,
        3,
        7,
        opened.cycle_deadline_monotonic_ns,
    );
    assert_eq!(
        evaluate(owner, &release, &opened, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
    assert_eq!(output.cycle_tag, POINTER_INPUT_CYCLE_CLOSED_V3);
    let next = button(
        POINTER_INPUT_BUTTON_DOWN_V3,
        3,
        8,
        opened.cycle_deadline_monotonic_ns + 1,
    );
    let closed = output;
    assert_eq!(
        evaluate(owner, &next, &closed, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.request_back, 1);
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn disabled_modifier_orphan_and_null_inputs_preserve_without_request() {
    let mut owner = core::ptr::null_mut();
    let cycle = closed_cycle();
    let mut output = closed_cycle();
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    let disabled = configuration(1, 0, 3);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &disabled) },
        PointerInputStatusV3::Success
    );
    let down = button(POINTER_INPUT_BUTTON_DOWN_V3, 3, 1, 1);
    assert_eq!(
        evaluate(owner, &down, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (output.decision, output.request_back),
        (POINTER_INPUT_DECISION_PRESERVE_V3, 0)
    );
    let enabled = configuration(1, 1, 3);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &enabled) },
        PointerInputStatusV3::Success
    );
    let modifier = PointerInputEventV3 {
        modifiers_held: 1,
        ..down
    };
    assert_eq!(
        evaluate(owner, &modifier, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
    let orphan = button(POINTER_INPUT_BUTTON_UP_V3, 3, 1, 2);
    assert_eq!(
        evaluate(owner, &orphan, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
    assert_eq!(
        unsafe { pointer_input_engine_evaluate_v3(owner, core::ptr::null(), &cycle, &mut output) },
        PointerInputStatusV3::InvalidArgument
    );
    assert_eq!(
        (output.decision, output.request_back),
        (POINTER_INPUT_DECISION_PRESERVE_V3, 0)
    );
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}

#[test]
fn scroll_behavior_and_pixel_preservation_remain_unchanged() {
    let mut owner = core::ptr::null_mut();
    let config = configuration(0, 0, 0);
    let cycle = closed_cycle();
    let mut output = closed_cycle();
    assert_eq!(create(&mut owner), PointerInputStatusV3::Success);
    assert_eq!(
        unsafe { pointer_input_engine_set_configuration_v3(owner, &config) },
        PointerInputStatusV3::Success
    );
    assert_eq!(
        evaluate(owner, &scroll(1, -1), &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(
        (
            output.decision,
            output.horizontal_hundredths,
            output.vertical_hundredths
        ),
        (POINTER_INPUT_DECISION_REPLACE_V3, -100, 100)
    );
    let pixel = PointerInputEventV3 {
        granularity: POINTER_INPUT_GRANULARITY_PIXEL_BASED_V3,
        ..scroll(1, -1)
    };
    assert_eq!(
        evaluate(owner, &pixel, &cycle, &mut output),
        PointerInputStatusV3::Success
    );
    assert_eq!(output.decision, POINTER_INPUT_DECISION_PRESERVE_V3);
    assert_eq!(
        unsafe { pointer_input_engine_destroy_v3(&mut owner) },
        PointerInputStatusV3::Success
    );
}
