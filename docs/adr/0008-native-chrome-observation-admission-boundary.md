# Keep Chrome observation ownership native and separate from admission

**Status:** Accepted

## Context

The Chrome Back Binding needs an original-point receiver observation without adding accessibility work to the event-tap callback. The native adapter already owns platform lifecycle and Core Graphics input handling; Rust owns only platform-neutral Binding evaluation and its fixed-layout ABI values. An accessibility object cannot cross that boundary or be dereferenced in the callback.

## Decision

- One native worker prepares a single preallocated slot with the state order `Empty → Preparing → Eligible → Reserved → Ready → Executing → Empty`. This increment implements preparation and callback reservation/abort only; it does not connect live button extraction, Rust button-cycle evaluation, suppression, event construction, or posting.
- The worker alone retains, releases, and dereferences an AX window reference. CAS with acquire/release ordering transfers slot ownership. The worker claims `Empty` or `Eligible` as `Preparing` before replacing or releasing payload; the callback can claim only `Eligible` as `Reserved`. No owner reads plain payload without its state ownership, and neither owner overwrites `Reserved` or `Executing`.
- Capability requires lock-free slot atomics. The worker samples an original global point before the AX query, refreshes at a provisional 50 ms cadence, and rejects an observation older than 100 ms, a slow query, or a changed current point. The system-wide public AX hit test must resolve an `AXWindow` role directly or through the documented `AXWindow` attribute, then validate its AX type, PID, Chrome identity, and a bracketing `proc_pidinfo(PROC_PIDTBSDINFO)` status/start witness. The witness is not a universal PID-reuse or atomic-routing guarantee.
- `NSRunningApplication` identity uses the fixed Chrome bundle identifier and supported process instance comparison. Its time-varying termination result is cached from the main run loop; `launchDate` is not required. AX messaging timeouts are positive bounded parameters, not hard-realtime guarantees.
- Revision retirement, disable, capture, remove, and shutdown disable admissions and advance the epoch, then quiesce the callback before stopping and draining the worker. The worker alone releases retained payload before slot disposal or engine disposal. Any unknown, stale, changed, or ambiguous observation preserves input.
- Rust remains a pure cycle evaluator over the whole-bundle ABI v3. Native target metadata and AX references do not enter that ABI. In the next increment, native reserve → pure Rust evaluation → output/epoch validation → cycle commit/`Ready` is the sole commit boundary.
- The selected future transport is one public, per-runtime-tagged Back mouse pair using application convention button index 3 and session posting. Both events are built before either is posted. The tag is ownership metadata, not device identity or a routing receipt. Posting has no retry, restoration, navigation-completion claim, or guarantee that the original window remains the delivery target; the remaining validation-to-delivery race is explicit.

## Consequences

The callback stays bounded and has no AX/AppKit access, blocking wait, allocation, or I/O. A retained original window means the later requested Back applies to that window's active tab at handling time, not a frozen tab. A changed or closed target is abandoned without retargeting, activation, raising, or fallback.

This decision adds no process, IPC, HID takeover, generic observer framework, or parallel ABI. Live Chrome/AX equality, target routing, tagged-event re-entry, user-visible Back behavior, and physical latency remain runtime evidence, not claims of this ADR.
