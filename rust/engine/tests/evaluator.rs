use pointer_input_engine::{
    Binding, ButtonEvent, ButtonPhase, Configuration, Cycle, EvaluationStatus, InputDecision,
    InputEvent, InputSource, LineBasedReplacement, ScrollConfiguration, ScrollEvent,
    ScrollGranularity, SourceClass,
};

fn line_event(horizontal_lines: i64, vertical_lines: i64, source_class: SourceClass) -> InputEvent {
    InputEvent::Scroll(ScrollEvent {
        source: InputSource { source_class },
        granularity: ScrollGranularity::LineBased,
        horizontal_lines,
        vertical_lines,
    })
}

#[test]
fn reverse_accepts_unknown_source_without_changing_behavior() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());

    let unknown = engine.evaluate(line_event(0, 3, SourceClass::Unknown));
    let mouse = engine.evaluate(line_event(0, 3, SourceClass::Mouse));

    assert_eq!(unknown.status, mouse.status);
    assert_eq!(
        unknown.decision,
        InputDecision::Replace(LineBasedReplacement {
            horizontal_hundredths: 0,
            vertical_hundredths: -3 * 100,
        })
    );
    assert_eq!(
        mouse.decision,
        InputDecision::Replace(LineBasedReplacement {
            horizontal_hundredths: 0,
            vertical_hundredths: -3 * 100,
        })
    );
}

#[test]
fn system_direction_preserves_line_scroll() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::system());

    let result = engine.evaluate(line_event(2, -3, SourceClass::Trackpad));

    assert_eq!(
        result,
        pointer_input_engine::Evaluation::success(InputDecision::Preserve)
    );
}

#[test]
fn reverse_replaces_one_axis_line_scroll() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());

    let result = engine.evaluate(line_event(0, 3, SourceClass::Unknown));

    assert_eq!(
        result,
        pointer_input_engine::Evaluation::success(InputDecision::Replace(LineBasedReplacement {
            horizontal_hundredths: 0,
            vertical_hundredths: -3 * 100,
        }))
    );
}

#[test]
fn reverse_preserves_both_zero_line_scroll() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());

    let result = engine.evaluate(line_event(0, 0, SourceClass::Unknown));

    assert_eq!(
        result,
        pointer_input_engine::Evaluation::success(InputDecision::Preserve)
    );
}

#[test]
fn reverse_overflow_fails_open() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());

    let result = engine.evaluate(line_event(i64::MIN, 1, SourceClass::Unknown));

    assert_eq!(result.status, EvaluationStatus::EvaluationFailed);
    assert_eq!(result.decision, InputDecision::Preserve);
}

#[test]
fn reverse_negates_literal_two_axis_line_scroll_cases() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());

    for (horizontal_lines, vertical_lines, expected_horizontal, expected_vertical) in
        [(17, 3, -17, -3), (-17, -3, 17, 3), (17, -3, -17, 3)]
    {
        let result = engine.evaluate(line_event(
            horizontal_lines,
            vertical_lines,
            SourceClass::Unknown,
        ));

        assert_eq!(result.status, EvaluationStatus::Success);
        assert_eq!(
            result.decision,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: expected_horizontal * 100,
                vertical_hundredths: expected_vertical * 100,
            })
        );
    }
}

#[test]
fn pixel_scroll_preserves_under_reverse_configuration() {
    let engine = pointer_input_engine::Engine::new(ScrollConfiguration::reverse());
    let event = InputEvent::Scroll(ScrollEvent {
        source: InputSource {
            source_class: SourceClass::Unknown,
        },
        granularity: ScrollGranularity::PixelBased,
        horizontal_lines: 4,
        vertical_lines: -7,
    });

    let result = engine.evaluate(event);

    assert_eq!(
        result,
        pointer_input_engine::Evaluation::success(InputDecision::Preserve)
    );
}

#[test]
fn amount_is_exact_stateless_and_orthogonal_to_direction() {
    for (configuration, amount, expected) in [
        (ScrollConfiguration::system(), 25, 25),
        (ScrollConfiguration::system(), 50, 50),
        (ScrollConfiguration::system(), 137, 137),
        (ScrollConfiguration::system(), 400, 400),
        (ScrollConfiguration::reverse(), 100, -100),
        (ScrollConfiguration::reverse(), 50, -50),
    ] {
        let engine = pointer_input_engine::Engine::new(configuration.with_amount(amount).unwrap());
        for _ in 0..2 {
            assert_eq!(
                engine.evaluate(line_event(1, -1, SourceClass::Unknown)),
                pointer_input_engine::Evaluation::success(InputDecision::Replace(
                    LineBasedReplacement {
                        horizontal_hundredths: expected,
                        vertical_hundredths: -expected,
                    }
                ))
            );
        }
        assert_eq!(
            engine
                .evaluate(line_event(0, 0, SourceClass::Unknown))
                .decision,
            InputDecision::Preserve
        );
    }
    assert!(ScrollConfiguration::system().with_amount(24).is_none());
    assert!(ScrollConfiguration::reverse().with_amount(401).is_none());
}

#[test]
fn scroll_amount_literal_acceptance_matrix() {
    for (configuration, amount, horizontal_lines, expected) in [
        (
            ScrollConfiguration::system(),
            25,
            4,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: 100,
                vertical_hundredths: 0,
            }),
        ),
        (
            ScrollConfiguration::system(),
            50,
            4,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: 200,
                vertical_hundredths: 0,
            }),
        ),
        (
            ScrollConfiguration::system(),
            100,
            4,
            InputDecision::Preserve,
        ),
        (
            ScrollConfiguration::system(),
            200,
            4,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: 800,
                vertical_hundredths: 0,
            }),
        ),
        (
            ScrollConfiguration::system(),
            400,
            4,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: 1600,
                vertical_hundredths: 0,
            }),
        ),
        (
            ScrollConfiguration::reverse(),
            50,
            4,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: -200,
                vertical_hundredths: 0,
            }),
        ),
        (
            ScrollConfiguration::system(),
            137,
            100,
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths: 13700,
                vertical_hundredths: 0,
            }),
        ),
    ] {
        let engine = pointer_input_engine::Engine::new(configuration.with_amount(amount).unwrap());
        assert_eq!(
            engine.evaluate(line_event(horizontal_lines, 0, SourceClass::Unknown)),
            pointer_input_engine::Evaluation::success(expected)
        );
    }

    let engine =
        pointer_input_engine::Engine::new(ScrollConfiguration::reverse().with_amount(400).unwrap());
    let event = InputEvent::Scroll(ScrollEvent {
        source: InputSource {
            source_class: SourceClass::Unknown,
        },
        granularity: ScrollGranularity::PixelBased,
        horizontal_lines: 4,
        vertical_lines: 0,
    });
    assert_eq!(
        engine.evaluate(event),
        pointer_input_engine::Evaluation::success(InputDecision::Preserve)
    );
}

#[test]
fn multiplication_and_negation_overflow_preserve_the_whole_event() {
    for (configuration, amount, horizontal, vertical) in [
        (ScrollConfiguration::system(), 400, 1, i64::MAX),
        (ScrollConfiguration::system(), 25, i64::MIN, 1),
        (ScrollConfiguration::reverse(), 256, i64::MIN / 256, 1),
    ] {
        let engine = pointer_input_engine::Engine::new(configuration.with_amount(amount).unwrap());
        let result = engine.evaluate(line_event(horizontal, vertical, SourceClass::Unknown));
        assert_eq!(result.status, EvaluationStatus::EvaluationFailed);
        assert_eq!(result.decision, InputDecision::Preserve);
    }
}

#[test]
fn binding_rejects_out_of_range_button_without_aliasing() {
    assert!(Binding::new(2, true).is_none());
    assert!(Binding::new(32, true).is_none());
    assert!(Binding::new(35, true).is_none());

    let engine = pointer_input_engine::Engine::new(Configuration {
        scroll: ScrollConfiguration::system(),
        binding: Binding::new(3, true),
    });
    let result = engine.evaluate(InputEvent::Button(ButtonEvent {
        button_number: 3,
        phase: ButtonPhase::Down,
        modifiers_held: false,
        event_number: 7,
        monotonic_time_ns: 100,
    }));
    assert_eq!(result.decision, InputDecision::Suppress);
    assert!(result.request_back);
}

#[test]
fn matching_release_at_deadline_closes_without_rearming_expired_duplicate() {
    let engine = pointer_input_engine::Engine::new(Configuration {
        scroll: ScrollConfiguration::system(),
        binding: Binding::new(3, true),
    });
    let down = InputEvent::Button(ButtonEvent {
        button_number: 3,
        phase: ButtonPhase::Down,
        modifiers_held: false,
        event_number: 7,
        monotonic_time_ns: 100,
    });
    let opened = engine.evaluate(down);
    let Cycle::Open {
        deadline_monotonic_ns,
        ..
    } = opened.next_cycle
    else {
        panic!("down must open a cycle")
    };

    let expired_duplicate = engine.evaluate_with_cycle(
        InputEvent::Button(ButtonEvent {
            monotonic_time_ns: deadline_monotonic_ns,
            ..match down {
                InputEvent::Button(button) => button,
                _ => unreachable!(),
            }
        }),
        opened.next_cycle,
    );
    assert_eq!(expired_duplicate.decision, InputDecision::Preserve);
    assert!(!expired_duplicate.request_back);
    assert!(matches!(
        expired_duplicate.next_cycle,
        Cycle::Quarantined { .. }
    ));

    let released = engine.evaluate_with_cycle(
        InputEvent::Button(ButtonEvent {
            button_number: 3,
            phase: ButtonPhase::Up,
            modifiers_held: false,
            event_number: 7,
            monotonic_time_ns: deadline_monotonic_ns,
        }),
        opened.next_cycle,
    );
    assert_eq!(released.decision, InputDecision::Preserve);
    assert_eq!(released.next_cycle, Cycle::Closed);
    let next = engine.evaluate_with_cycle(
        InputEvent::Button(ButtonEvent {
            button_number: 3,
            phase: ButtonPhase::Down,
            modifiers_held: false,
            event_number: 8,
            monotonic_time_ns: deadline_monotonic_ns + 1,
        }),
        released.next_cycle,
    );
    assert_eq!(next.decision, InputDecision::Suppress);
    assert!(next.request_back);
}

#[test]
fn direction_and_amount_are_one_atomic_snapshot() {
    use std::sync::Arc;
    let system = ScrollConfiguration::system().with_amount(25).unwrap();
    let reverse = ScrollConfiguration::reverse().with_amount(137).unwrap();
    let engine = Arc::new(pointer_input_engine::Engine::new(system));
    let writer = Arc::clone(&engine);
    let thread = std::thread::spawn(move || {
        for _ in 0..10_000 {
            writer.set_configuration(reverse);
            writer.set_configuration(system);
        }
    });
    for _ in 0..10_000 {
        let InputDecision::Replace(value) = engine
            .evaluate(line_event(1, 1, SourceClass::Unknown))
            .decision
        else {
            panic!("expected replacement")
        };
        assert!(value.horizontal_hundredths == 25 || value.horizontal_hundredths == -137);
        assert_eq!(value.horizontal_hundredths, value.vertical_hundredths);
    }
    thread.join().unwrap();
}
