//! Fixed-layout C ABI for the platform-neutral input engine.

use std::{
    any::Any,
    cell::Cell,
    ffi::c_void,
    mem,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::Mutex,
};

use pointer_input_engine as engine;

#[cfg(panic = "abort")]
compile_error!("pointer-input-ffi requires panic = \"unwind\"");

thread_local! {
    static EVALUATING: Cell<bool> = const { Cell::new(false) };
}

const HOOK_UNINSTALLED: u8 = 0;
const HOOK_INSTALLING: u8 = 1;
const HOOK_INSTALLED: u8 = 2;
static PANIC_HOOK_STATE: Mutex<u8> = Mutex::new(HOOK_UNINSTALLED);
type PanicPayload = Box<dyn Any + Send + 'static>;

/// The fixed-layout ABI version implemented by this library.
pub const POINTER_INPUT_ABI_VERSION_V3: u32 = 3;
pub const POINTER_INPUT_DECISION_PRESERVE_V3: u32 = 0;
pub const POINTER_INPUT_DECISION_REPLACE_V3: u32 = 1;
pub const POINTER_INPUT_DECISION_SUPPRESS_V3: u32 = 2;
pub const POINTER_INPUT_DIRECTION_SYSTEM_V3: u32 = 0;
pub const POINTER_INPUT_DIRECTION_REVERSE_V3: u32 = 1;
pub const POINTER_INPUT_SOURCE_MOUSE_V3: u32 = 0;
pub const POINTER_INPUT_SOURCE_TRACKPAD_V3: u32 = 1;
pub const POINTER_INPUT_SOURCE_UNKNOWN_V3: u32 = 2;
pub const POINTER_INPUT_GRANULARITY_LINE_BASED_V3: u32 = 0;
pub const POINTER_INPUT_GRANULARITY_PIXEL_BASED_V3: u32 = 1;
pub const POINTER_INPUT_EVENT_SCROLL_V3: u32 = 0;
pub const POINTER_INPUT_EVENT_BUTTON_V3: u32 = 1;
pub const POINTER_INPUT_BUTTON_DOWN_V3: u32 = 0;
pub const POINTER_INPUT_BUTTON_UP_V3: u32 = 1;
pub const POINTER_INPUT_BUTTON_DRAG_V3: u32 = 2;
pub const POINTER_INPUT_CYCLE_CLOSED_V3: u32 = 0;
pub const POINTER_INPUT_CYCLE_OPEN_V3: u32 = 1;
pub const POINTER_INPUT_CYCLE_QUARANTINED_V3: u32 = 2;

/// Status returned by each ABI operation.
#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PointerInputStatusV3 {
    Success = 0,
    InvalidArgument = 1,
    EvaluationFailed = 2,
    Panic = 3,
    Busy = 4,
}

/// C input event. Exact version, size, and zero reserved fields are required.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PointerInputEventV3 {
    pub version: u32,
    pub size: u32,
    pub event_kind: u32,
    pub source_class: u32,
    pub granularity: u32,
    pub button_phase: u32,
    pub button_number: u32,
    pub modifiers_held: u32,
    pub horizontal_lines: i64,
    pub vertical_lines: i64,
    pub event_number: u64,
    pub monotonic_time_ns: u64,
    pub reserved: [u32; 2],
}

/// C configuration. Binding is canonical absent (`binding_present == 0`, other Binding fields 0)
/// or present with a 3...31 button and boolean enabled tag.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PointerInputConfigurationV3 {
    pub version: u32,
    pub size: u32,
    pub direction: u32,
    pub amount_percent: u32,
    pub binding_present: u32,
    pub binding_enabled: u32,
    pub binding_button_number: u32,
    pub reserved: u32,
}

/// C evaluation output. A non-null output is initialized to valid Preserve/closed before input use.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PointerInputDecisionV3 {
    pub version: u32,
    pub size: u32,
    pub decision: u32,
    pub request_back: u32,
    pub cycle_tag: u32,
    pub reserved: [u32; 3],
    pub horizontal_hundredths: i64,
    pub vertical_hundredths: i64,
    pub cycle_button_number: u32,
    pub cycle_reserved: u32,
    pub cycle_event_number: u64,
    pub cycle_deadline_monotonic_ns: u64,
}

struct EvaluationScope(bool);
impl EvaluationScope {
    fn enter() -> Option<Self> {
        EVALUATING
            .try_with(|evaluating| {
                let prior = evaluating.get();
                evaluating.set(true);
                Self(prior)
            })
            .ok()
    }
}
impl Drop for EvaluationScope {
    fn drop(&mut self) {
        let _ = EVALUATING.try_with(|evaluating| evaluating.set(self.0));
    }
}

fn discard_panic_payload(payload: PanicPayload) {
    if let Err(secondary_payload) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
        mem::forget(secondary_payload);
    }
}
fn panic_status(payload: PanicPayload) -> PointerInputStatusV3 {
    discard_panic_payload(payload);
    PointerInputStatusV3::Panic
}
fn install_panic_hook() -> Result<(), PointerInputStatusV3> {
    {
        let mut state = PANIC_HOOK_STATE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match *state {
            HOOK_INSTALLED => return Ok(()),
            HOOK_UNINSTALLED if std::thread::panicking() => {
                return Err(PointerInputStatusV3::Panic);
            }
            HOOK_UNINSTALLED => *state = HOOK_INSTALLING,
            HOOK_INSTALLING => return Err(PointerInputStatusV3::Busy),
            _ => return Err(PointerInputStatusV3::Panic),
        }
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        #[cfg(test)]
        if PANIC_HOOK_INSTALL_FAILURE.swap(false, std::sync::atomic::Ordering::Relaxed) {
            panic!("test-only hook installation failure");
        }
        let previous_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !EVALUATING.try_with(Cell::get).unwrap_or(false) {
                previous_hook(info);
            }
        }));
    }));
    let mut state = PANIC_HOOK_STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match result {
        Ok(()) => {
            *state = HOOK_INSTALLED;
            Ok(())
        }
        Err(payload) => {
            *state = HOOK_UNINSTALLED;
            discard_panic_payload(payload);
            Err(PointerInputStatusV3::Panic)
        }
    }
}

fn preserve_output() -> PointerInputDecisionV3 {
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
fn valid_layout(version: u32, size: u32, expected_size: usize) -> bool {
    version == POINTER_INPUT_ABI_VERSION_V3 && size == expected_size as u32
}
fn valid_bool(value: u32) -> bool {
    value <= 1
}

fn configuration_from(value: PointerInputConfigurationV3) -> Option<engine::Configuration> {
    if !valid_layout(
        value.version,
        value.size,
        size_of::<PointerInputConfigurationV3>(),
    ) || value.reserved != 0
        || !valid_bool(value.binding_present)
        || !valid_bool(value.binding_enabled)
    {
        return None;
    }
    let scroll = match value.direction {
        POINTER_INPUT_DIRECTION_SYSTEM_V3 => engine::ScrollConfiguration::system(),
        POINTER_INPUT_DIRECTION_REVERSE_V3 => engine::ScrollConfiguration::reverse(),
        _ => return None,
    }
    .with_amount(value.amount_percent)?;
    let binding = if value.binding_present == 0 {
        if value.binding_enabled != 0 || value.binding_button_number != 0 {
            return None;
        }
        None
    } else {
        Some(engine::Binding::new(
            value.binding_button_number,
            value.binding_enabled == 1,
        )?)
    };
    Some(engine::Configuration { scroll, binding })
}

fn event_from(value: PointerInputEventV3) -> Option<engine::InputEvent> {
    if !valid_layout(value.version, value.size, size_of::<PointerInputEventV3>())
        || value.reserved != [0; 2]
        || !valid_bool(value.modifiers_held)
    {
        return None;
    }
    match value.event_kind {
        POINTER_INPUT_EVENT_SCROLL_V3 => {
            if value.button_phase != 0
                || value.button_number != 0
                || value.event_number != 0
                || value.monotonic_time_ns != 0
            {
                return None;
            }
            let source_class = match value.source_class {
                POINTER_INPUT_SOURCE_MOUSE_V3 => engine::SourceClass::Mouse,
                POINTER_INPUT_SOURCE_TRACKPAD_V3 => engine::SourceClass::Trackpad,
                POINTER_INPUT_SOURCE_UNKNOWN_V3 => engine::SourceClass::Unknown,
                _ => return None,
            };
            let granularity = match value.granularity {
                POINTER_INPUT_GRANULARITY_LINE_BASED_V3 => engine::ScrollGranularity::LineBased,
                POINTER_INPUT_GRANULARITY_PIXEL_BASED_V3 => engine::ScrollGranularity::PixelBased,
                _ => return None,
            };
            Some(engine::InputEvent::Scroll(engine::ScrollEvent {
                source: engine::InputSource { source_class },
                granularity,
                horizontal_lines: value.horizontal_lines,
                vertical_lines: value.vertical_lines,
            }))
        }
        POINTER_INPUT_EVENT_BUTTON_V3 => {
            if value.source_class != 0
                || value.granularity != 0
                || value.horizontal_lines != 0
                || value.vertical_lines != 0
            {
                return None;
            }
            let phase = match value.button_phase {
                POINTER_INPUT_BUTTON_DOWN_V3 => engine::ButtonPhase::Down,
                POINTER_INPUT_BUTTON_UP_V3 => engine::ButtonPhase::Up,
                POINTER_INPUT_BUTTON_DRAG_V3 => engine::ButtonPhase::Drag,
                _ => return None,
            };
            Some(engine::InputEvent::Button(engine::ButtonEvent {
                button_number: value.button_number,
                phase,
                modifiers_held: value.modifiers_held == 1,
                event_number: value.event_number,
                monotonic_time_ns: value.monotonic_time_ns,
            }))
        }
        _ => None,
    }
}
fn cycle_from(value: PointerInputDecisionV3) -> Option<engine::Cycle> {
    if !valid_layout(
        value.version,
        value.size,
        size_of::<PointerInputDecisionV3>(),
    ) || value.reserved != [0; 3]
        || value.cycle_reserved != 0
        || !valid_bool(value.request_back)
        || value.decision > POINTER_INPUT_DECISION_SUPPRESS_V3
        || (value.request_back == 1
            && (value.decision != POINTER_INPUT_DECISION_SUPPRESS_V3
                || value.cycle_tag != POINTER_INPUT_CYCLE_OPEN_V3))
    {
        return None;
    }
    match value.cycle_tag {
        POINTER_INPUT_CYCLE_CLOSED_V3
            if value.cycle_button_number == 0
                && value.cycle_event_number == 0
                && value.cycle_deadline_monotonic_ns == 0 =>
        {
            Some(engine::Cycle::Closed)
        }
        POINTER_INPUT_CYCLE_OPEN_V3
            if engine::Binding::new(value.cycle_button_number, false).is_some()
                && value.cycle_deadline_monotonic_ns != 0 =>
        {
            Some(engine::Cycle::Open {
                button_number: value.cycle_button_number,
                event_number: value.cycle_event_number,
                deadline_monotonic_ns: value.cycle_deadline_monotonic_ns,
            })
        }
        POINTER_INPUT_CYCLE_QUARANTINED_V3
            if engine::Binding::new(value.cycle_button_number, false).is_some()
                && value.cycle_deadline_monotonic_ns == 0 =>
        {
            Some(engine::Cycle::Quarantined {
                button_number: value.cycle_button_number,
                event_number: value.cycle_event_number,
            })
        }
        _ => None,
    }
}
fn output_from(evaluation: engine::Evaluation) -> PointerInputDecisionV3 {
    let (decision, horizontal_hundredths, vertical_hundredths) = match evaluation.decision {
        engine::InputDecision::Preserve => (POINTER_INPUT_DECISION_PRESERVE_V3, 0, 0),
        engine::InputDecision::Replace(scroll) => (
            POINTER_INPUT_DECISION_REPLACE_V3,
            scroll.horizontal_hundredths,
            scroll.vertical_hundredths,
        ),
        engine::InputDecision::Suppress => (POINTER_INPUT_DECISION_SUPPRESS_V3, 0, 0),
    };
    let (cycle_tag, cycle_button_number, cycle_event_number, cycle_deadline_monotonic_ns) =
        match evaluation.next_cycle {
            engine::Cycle::Closed => (POINTER_INPUT_CYCLE_CLOSED_V3, 0, 0, 0),
            engine::Cycle::Open {
                button_number,
                event_number,
                deadline_monotonic_ns,
            } => (
                POINTER_INPUT_CYCLE_OPEN_V3,
                button_number,
                event_number,
                deadline_monotonic_ns,
            ),
            engine::Cycle::Quarantined {
                button_number,
                event_number,
            } => (
                POINTER_INPUT_CYCLE_QUARANTINED_V3,
                button_number,
                event_number,
                0,
            ),
        };
    PointerInputDecisionV3 {
        decision,
        request_back: u32::from(evaluation.request_back),
        cycle_tag,
        horizontal_hundredths,
        vertical_hundredths,
        cycle_button_number,
        cycle_event_number,
        cycle_deadline_monotonic_ns,
        ..preserve_output()
    }
}
unsafe fn engine_from<'a>(handle: *mut c_void) -> &'a engine::Engine {
    // SAFETY: callers guarantee the allocation remains live for this call.
    unsafe { &*handle.cast::<engine::Engine>() }
}

/// Allocates an opaque engine with the default configuration.
///
/// # Safety
/// `out_engine` must point to writable, initially null storage for one owner handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pointer_input_engine_create_v3(
    out_engine: *mut *mut c_void,
) -> PointerInputStatusV3 {
    if out_engine.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    // SAFETY: validated pointer to caller-owned handle storage.
    if !unsafe { out_engine.read() }.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        install_panic_hook()?;
        let engine = Box::new(engine::Engine::new(engine::Configuration::system()));
        // SAFETY: validated non-null caller storage.
        unsafe { out_engine.write(Box::into_raw(engine).cast()) };
        Ok(PointerInputStatusV3::Success)
    })) {
        Ok(Ok(status) | Err(status)) => status,
        Err(payload) => panic_status(payload),
    }
}

/// Validates a configuration without an engine or state mutation.
///
/// # Safety
/// `configuration` must point to a readable fixed-layout value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pointer_input_configuration_validate_v3(
    configuration: *const PointerInputConfigurationV3,
) -> PointerInputStatusV3 {
    if configuration.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: validated non-null pointer to a caller-owned POD value.
        if configuration_from(unsafe { configuration.read() }).is_some() {
            PointerInputStatusV3::Success
        } else {
            PointerInputStatusV3::InvalidArgument
        }
    })) {
        Ok(status) => status,
        Err(payload) => panic_status(payload),
    }
}

/// Replaces the configuration observed by later evaluations.
///
/// # Safety
/// The caller must retain a live created handle and provide readable fixed-layout configuration.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pointer_input_engine_set_configuration_v3(
    handle: *mut c_void,
    configuration: *const PointerInputConfigurationV3,
) -> PointerInputStatusV3 {
    if handle.is_null() || configuration.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: validated non-null pointer to a caller-owned POD value.
        let Some(configuration) = configuration_from(unsafe { configuration.read() }) else {
            return PointerInputStatusV3::InvalidArgument;
        };
        // SAFETY: documented caller ownership contract for `handle`.
        unsafe { engine_from(handle) }.set_configuration(configuration);
        PointerInputStatusV3::Success
    })) {
        Ok(status) => status,
        Err(payload) => panic_status(payload),
    }
}

/// Evaluates one normalized event and writes a fail-open decision and next cycle.
///
/// # Safety
/// The caller must retain a live created handle and provide readable event/cycle and writable output.
/// `cycle` and `out_decision` may point to the same caller-owned POD storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pointer_input_engine_evaluate_v3(
    handle: *mut c_void,
    event: *const PointerInputEventV3,
    cycle: *const PointerInputDecisionV3,
    out_decision: *mut PointerInputDecisionV3,
) -> PointerInputStatusV3 {
    if out_decision.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    // SAFETY: snapshot the caller's readable cycle before output initialization so the two
    // pointers may designate the same POD storage.
    let cycle_value = if cycle.is_null() {
        None
    } else {
        Some(unsafe { cycle.read() })
    };
    // SAFETY: validated non-null caller output storage; write fail-open data before semantic use.
    unsafe { out_decision.write(preserve_output()) };
    if handle.is_null() || event.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    let Some(cycle_value) = cycle_value else {
        return PointerInputStatusV3::InvalidArgument;
    };
    let Some(_scope) = EvaluationScope::enter() else {
        return PointerInputStatusV3::Panic;
    };
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: all pointers were checked non-null and point to caller-owned POD values.
        let Some(event) = event_from(unsafe { event.read() }) else {
            return PointerInputStatusV3::InvalidArgument;
        };
        let Some(cycle) = cycle_from(cycle_value) else {
            return PointerInputStatusV3::InvalidArgument;
        };
        maybe_inject_evaluation_panic();
        // SAFETY: documented caller ownership contract for `handle`.
        let evaluation = unsafe { engine_from(handle) }.evaluate_with_cycle(event, cycle);
        if evaluation.status == engine::EvaluationStatus::EvaluationFailed {
            return PointerInputStatusV3::EvaluationFailed;
        }
        // SAFETY: output was initialized before validation and evaluation.
        unsafe { out_decision.write(output_from(evaluation)) };
        PointerInputStatusV3::Success
    })) {
        Ok(status) => status,
        Err(payload) => panic_status(payload),
    }
}

#[cfg(test)]
static PANIC_ON_EVALUATE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(test)]
static PANIC_ON_DROP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(test)]
static PANIC_HOOK_INSTALL_FAILURE: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(test)]
struct PanicOnDrop;
#[cfg(test)]
impl Drop for PanicOnDrop {
    fn drop(&mut self) {
        panic!("test-only panic payload drop");
    }
}
#[cfg(test)]
fn maybe_inject_evaluation_panic() {
    use std::sync::atomic::Ordering;
    if PANIC_ON_DROP.swap(false, Ordering::Relaxed) {
        std::panic::panic_any(PanicOnDrop);
    }
    if PANIC_ON_EVALUATE.swap(false, Ordering::Relaxed) {
        panic!("test-only evaluation panic");
    }
}
#[cfg(not(test))]
fn maybe_inject_evaluation_panic() {}

/// Nulls and releases an opaque engine handle.
///
/// # Safety
/// The caller must own the live handle variable and quiesce all copied-handle uses first.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pointer_input_engine_destroy_v3(
    in_out_handle: *mut *mut c_void,
) -> PointerInputStatusV3 {
    if in_out_handle.is_null() {
        return PointerInputStatusV3::InvalidArgument;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: validated pointer to caller-owned handle storage.
        let handle = unsafe { in_out_handle.read() };
        if handle.is_null() {
            return PointerInputStatusV3::Success;
        }
        // SAFETY: null the caller variable before releasing the owned allocation.
        unsafe { in_out_handle.write(ptr::null_mut()) };
        // SAFETY: documented caller ownership contract guarantees allocation from create.
        drop(unsafe { Box::from_raw(handle.cast::<engine::Engine>()) });
        PointerInputStatusV3::Success
    })) {
        Ok(status) => status,
        Err(payload) => panic_status(payload),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        panic::catch_unwind,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
    };

    fn event() -> PointerInputEventV3 {
        PointerInputEventV3 {
            version: POINTER_INPUT_ABI_VERSION_V3,
            size: size_of::<PointerInputEventV3>() as u32,
            event_kind: POINTER_INPUT_EVENT_SCROLL_V3,
            source_class: POINTER_INPUT_SOURCE_UNKNOWN_V3,
            granularity: POINTER_INPUT_GRANULARITY_LINE_BASED_V3,
            button_phase: 0,
            button_number: 0,
            modifiers_held: 0,
            horizontal_lines: 0,
            vertical_lines: 3,
            event_number: 0,
            monotonic_time_ns: 0,
            reserved: [0; 2],
        }
    }

    #[test]
    fn evaluation_panics_preserve_output_and_do_not_delegate_to_the_previous_hook() {
        // ponytail: this sole hook-touching unit test retains the wrapper until process exit.
        let _previous_hook = std::panic::take_hook();
        let delegated = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&delegated);
        std::panic::set_hook(Box::new(move |_| {
            counter.fetch_add(1, Ordering::Relaxed);
        }));
        let mut owner = ptr::null_mut();
        assert_eq!(
            unsafe { pointer_input_engine_create_v3(&mut owner) },
            PointerInputStatusV3::Success
        );
        let input = event();
        let cycle = preserve_output();
        let mut output = preserve_output();
        for trigger in [&PANIC_ON_EVALUATE, &PANIC_ON_DROP] {
            trigger.store(true, Ordering::Relaxed);
            let before = delegated.load(Ordering::Relaxed);
            assert_eq!(
                unsafe { pointer_input_engine_evaluate_v3(owner, &input, &cycle, &mut output) },
                PointerInputStatusV3::Panic
            );
            let preserved = preserve_output();
            assert_eq!(output.version, preserved.version);
            assert_eq!(output.size, preserved.size);
            assert_eq!(output.decision, preserved.decision);
            assert_eq!(output.request_back, preserved.request_back);
            assert_eq!(output.cycle_tag, preserved.cycle_tag);
            assert_eq!(delegated.load(Ordering::Relaxed), before);
        }
        let before = delegated.load(Ordering::Relaxed);
        let _ = catch_unwind(|| panic!("unrelated test panic"));
        assert_eq!(delegated.load(Ordering::Relaxed), before + 1);
        assert_eq!(
            unsafe { pointer_input_engine_destroy_v3(&mut owner) },
            PointerInputStatusV3::Success
        );
    }
}
