#![forbid(unsafe_code)]

//! Platform-neutral input evaluation.

use std::sync::atomic::{AtomicU64, Ordering};

const BUTTON_MIN: u32 = 3;
const BUTTON_MAX: u32 = 31;
const CYCLE_WINDOW_NS: u64 = 5_000_000_000;

/// A normalized input observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputEvent {
    /// A scroll observation.
    Scroll(ScrollEvent),
    /// A button observation.
    Button(ButtonEvent),
}

/// A normalized scroll observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScrollEvent {
    /// The event's explicit source.
    pub source: InputSource,
    /// The semantic unit of the movement.
    pub granularity: ScrollGranularity,
    /// Horizontal line movement.
    pub horizontal_lines: i64,
    /// Vertical line movement.
    pub vertical_lines: i64,
}

/// A normalized button observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ButtonEvent {
    /// The observable button number.
    pub button_number: u32,
    /// The observed button phase.
    pub phase: ButtonPhase,
    /// Whether a modifier was held for this event.
    pub modifiers_held: bool,
    /// Event-level correlation supplied by the adapter.
    pub event_number: u64,
    /// Caller-supplied monotonic time in nanoseconds.
    pub monotonic_time_ns: u64,
}

/// The phase of a button observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ButtonPhase {
    /// A button press.
    Down,
    /// A button release.
    Up,
    /// A drag observation.
    Drag,
}

/// The visible source of an input observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputSource {
    /// The source classification supplied by the adapter.
    pub source_class: SourceClass,
}

/// A semantic source classification.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SourceClass {
    /// A mouse source.
    Mouse,
    /// A trackpad source.
    Trackpad,
    /// A source whose class is unavailable.
    Unknown,
}

/// The semantic unit of a scroll observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScrollGranularity {
    /// Discrete line-based input.
    LineBased,
    /// Continuous pixel movement.
    PixelBased,
}

/// User-selected scroll behavior.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScrollConfiguration {
    direction: ScrollDirection,
    amount_percent: u32,
}

impl ScrollConfiguration {
    /// Preserves the platform's configured direction.
    #[must_use]
    pub const fn system() -> Self {
        Self {
            direction: ScrollDirection::System,
            amount_percent: 100,
        }
    }

    /// Reverses eligible line-based movement.
    #[must_use]
    pub const fn reverse() -> Self {
        Self {
            direction: ScrollDirection::Reverse,
            amount_percent: 100,
        }
    }

    /// Selects an exact integer Scroll Amount, rejecting values outside 25...400.
    #[must_use]
    pub const fn with_amount(self, amount_percent: u32) -> Option<Self> {
        if amount_percent < 25 || amount_percent > 400 {
            return None;
        }
        Some(Self {
            amount_percent,
            ..self
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ScrollDirection {
    System,
    Reverse,
}

/// One configured button Binding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    button_number: u32,
    enabled: bool,
}

impl Binding {
    /// Constructs a Binding only for the configured extra-button range.
    #[must_use]
    pub const fn new(button_number: u32, enabled: bool) -> Option<Self> {
        if button_number < BUTTON_MIN || button_number > BUTTON_MAX {
            return None;
        }
        Some(Self {
            button_number,
            enabled,
        })
    }

    /// Returns the configured extra-button number.
    #[must_use]
    pub const fn button_number(self) -> u32 {
        self.button_number
    }

    /// Returns whether the Binding may request Back.
    #[must_use]
    pub const fn enabled(self) -> bool {
        self.enabled
    }
}

/// Full engine configuration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Configuration {
    /// The independent scroll configuration.
    pub scroll: ScrollConfiguration,
    /// The optional Back Binding.
    pub binding: Option<Binding>,
}

impl From<ScrollConfiguration> for Configuration {
    fn from(scroll: ScrollConfiguration) -> Self {
        Self {
            scroll,
            binding: None,
        }
    }
}

impl Configuration {
    /// Creates configuration without a Binding.
    #[must_use]
    pub const fn system() -> Self {
        Self {
            scroll: ScrollConfiguration::system(),
            binding: None,
        }
    }

    fn snapshot(self) -> u64 {
        let direction = self.scroll.direction as u64;
        let amount = u64::from(self.scroll.amount_percent) << 1;
        let (button, enabled) = match self.binding {
            Some(binding) => (
                u64::from(binding.button_number()) << 10,
                u64::from(binding.enabled()) << 15,
            ),
            None => (0, 0),
        };
        direction | amount | button | enabled
    }

    fn from_snapshot(snapshot: u64) -> Self {
        let direction = if snapshot & 1 == ScrollDirection::Reverse as u64 {
            ScrollDirection::Reverse
        } else {
            ScrollDirection::System
        };
        let scroll = ScrollConfiguration {
            direction,
            amount_percent: ((snapshot >> 1) & 0x1ff) as u32,
        };
        let button_number = ((snapshot >> 10) & 0x1f) as u32;
        let binding = Binding::new(button_number, snapshot & (1 << 15) != 0);
        Self { scroll, binding }
    }
}

/// The cycle supplied to and returned from evaluation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Cycle {
    /// No incomplete button recognition exists.
    Closed,
    /// A matched down was recognized and may be continued.
    Open {
        /// Button that opened the cycle.
        button_number: u32,
        /// Event-level down correlation.
        event_number: u64,
        /// Nonrenewable liveness deadline.
        deadline_monotonic_ns: u64,
    },
    /// Recognition is invalid until a matching release or runtime recovery.
    Quarantined {
        /// Button whose release can close the quarantine.
        button_number: u32,
        /// Original event-level correlation for diagnostics only.
        event_number: u64,
    },
}

/// The result to apply to an input observation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputDecision {
    /// Leave the native observation unchanged.
    Preserve,
    /// Replace line-based movement with exact hundredths-of-a-line.
    Replace(LineBasedReplacement),
    /// Suppress the current native observation.
    Suppress,
}

/// Exact replacement movement; 100 hundredths equals one line.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LineBasedReplacement {
    /// Horizontal movement in hundredths-of-a-line.
    pub horizontal_hundredths: i64,
    /// Vertical movement in hundredths-of-a-line.
    pub vertical_hundredths: i64,
}

/// An evaluation status independent of the decision.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EvaluationStatus {
    /// Evaluation completed normally.
    Success,
    /// Evaluation could not safely produce a replacement.
    EvaluationFailed,
}

/// An evaluation status and native-safe decision.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Evaluation {
    /// The evaluation result code.
    pub status: EvaluationStatus,
    /// The decision that native code can safely apply.
    pub decision: InputDecision,
    /// Whether this observation requests one Back action.
    pub request_back: bool,
    /// The recognition state for the next observation.
    pub next_cycle: Cycle,
}

impl Evaluation {
    /// Creates a successful evaluation without a button request or open cycle.
    #[must_use]
    pub const fn success(decision: InputDecision) -> Self {
        Self {
            status: EvaluationStatus::Success,
            decision,
            request_back: false,
            next_cycle: Cycle::Closed,
        }
    }

    fn with(decision: InputDecision, request_back: bool, next_cycle: Cycle) -> Self {
        Self {
            status: EvaluationStatus::Success,
            decision,
            request_back,
            next_cycle,
        }
    }

    fn preserve(cycle: Cycle) -> Self {
        Self::with(InputDecision::Preserve, false, cycle)
    }

    fn failed(cycle: Cycle) -> Self {
        Self {
            status: EvaluationStatus::EvaluationFailed,
            decision: InputDecision::Preserve,
            request_back: false,
            next_cycle: cycle,
        }
    }
}

/// Evaluates platform-neutral input against an atomic configuration snapshot.
pub struct Engine {
    configuration: AtomicU64,
}

impl Engine {
    /// Creates an engine with the supplied configuration.
    #[must_use]
    pub fn new(configuration: impl Into<Configuration>) -> Self {
        Self {
            configuration: AtomicU64::new(configuration.into().snapshot()),
        }
    }

    /// Replaces the configuration observed by later evaluations.
    pub fn set_configuration(&self, configuration: impl Into<Configuration>) {
        self.configuration
            .store(configuration.into().snapshot(), Ordering::Release);
    }

    /// Evaluates one normalized observation without an outstanding button cycle.
    #[must_use]
    pub fn evaluate(&self, event: InputEvent) -> Evaluation {
        self.evaluate_with_cycle(event, Cycle::Closed)
    }

    /// Evaluates one normalized observation and one caller-owned cycle.
    #[must_use]
    pub fn evaluate_with_cycle(&self, event: InputEvent, cycle: Cycle) -> Evaluation {
        let configuration =
            Configuration::from_snapshot(self.configuration.load(Ordering::Acquire));
        match event {
            InputEvent::Scroll(scroll) => self.evaluate_scroll(scroll, cycle, configuration.scroll),
            InputEvent::Button(button) => {
                self.evaluate_button(button, cycle, configuration.binding)
            }
        }
    }

    fn evaluate_scroll(
        &self,
        scroll: ScrollEvent,
        cycle: Cycle,
        configuration: ScrollConfiguration,
    ) -> Evaluation {
        let amount = i64::from(configuration.amount_percent);
        let reverse = configuration.direction == ScrollDirection::Reverse;
        if scroll.granularity == ScrollGranularity::PixelBased
            || (!reverse && amount == 100)
            || (scroll.horizontal_lines == 0 && scroll.vertical_lines == 0)
        {
            return Evaluation::preserve(cycle);
        }

        let scale = |lines: i64| {
            let hundredths = lines.checked_mul(amount)?;
            if reverse {
                hundredths.checked_neg()
            } else {
                Some(hundredths)
            }
        };
        let Some(horizontal_hundredths) = scale(scroll.horizontal_lines) else {
            return Evaluation::failed(cycle);
        };
        let Some(vertical_hundredths) = scale(scroll.vertical_lines) else {
            return Evaluation::failed(cycle);
        };

        Evaluation::with(
            InputDecision::Replace(LineBasedReplacement {
                horizontal_hundredths,
                vertical_hundredths,
            }),
            false,
            cycle,
        )
    }

    fn evaluate_button(
        &self,
        event: ButtonEvent,
        cycle: Cycle,
        binding: Option<Binding>,
    ) -> Evaluation {
        match cycle {
            Cycle::Closed => {
                let Some(binding) = binding else {
                    return Evaluation::preserve(Cycle::Closed);
                };
                if !binding.enabled()
                    || event.modifiers_held
                    || event.phase != ButtonPhase::Down
                    || event.button_number != binding.button_number()
                {
                    return Evaluation::preserve(Cycle::Closed);
                }
                let Some(deadline_monotonic_ns) =
                    event.monotonic_time_ns.checked_add(CYCLE_WINDOW_NS)
                else {
                    return Evaluation::failed(Cycle::Closed);
                };
                Evaluation::with(
                    InputDecision::Suppress,
                    true,
                    Cycle::Open {
                        button_number: event.button_number,
                        event_number: event.event_number,
                        deadline_monotonic_ns,
                    },
                )
            }
            Cycle::Open {
                button_number,
                event_number,
                deadline_monotonic_ns,
            } => {
                let quarantine = Cycle::Quarantined {
                    button_number,
                    event_number,
                };
                if event.monotonic_time_ns >= deadline_monotonic_ns {
                    if event.phase == ButtonPhase::Up
                        && event.button_number == button_number
                        && event.event_number == event_number
                    {
                        return Evaluation::preserve(Cycle::Closed);
                    }
                    return Evaluation::preserve(quarantine);
                }
                if event.modifiers_held
                    || event.button_number != button_number
                    || event.phase == ButtonPhase::Drag
                {
                    return Evaluation::preserve(quarantine);
                }
                if event.phase == ButtonPhase::Down && event.event_number == event_number {
                    return Evaluation::with(
                        InputDecision::Suppress,
                        false,
                        Cycle::Open {
                            button_number,
                            event_number,
                            deadline_monotonic_ns,
                        },
                    );
                }
                if event.phase == ButtonPhase::Up && event.event_number == event_number {
                    return Evaluation::with(InputDecision::Suppress, false, Cycle::Closed);
                }
                Evaluation::preserve(quarantine)
            }
            Cycle::Quarantined {
                button_number,
                event_number,
            } => {
                if event.phase == ButtonPhase::Up && event.button_number == button_number {
                    Evaluation::preserve(Cycle::Closed)
                } else {
                    Evaluation::preserve(Cycle::Quarantined {
                        button_number,
                        event_number,
                    })
                }
            }
        }
    }
}
