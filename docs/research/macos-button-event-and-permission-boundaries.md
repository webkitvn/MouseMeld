# macOS extra-button event and permission boundaries

## Question

Trên baseline macOS 14+ và single-process event-level topology (cấu trúc một tiến trình cấp sự kiện) hiện có, public API contract (hợp đồng API công khai) nào document việc nhận press/release/drag của extra button (nút bổ sung), preserve hoặc suppress native delivery (việc giao sự kiện gốc), và permission boundary (ranh giới quyền) nào thực sự được tài liệu hóa?

Artifact này là evidence cho Phase 2 `Binding`/`Action` planning. Nó không chọn product policy cho press/release/pass-through, Action, schema, UI, hay implementation.

## Evidence status

- **DOCUMENTED**: Apple public documentation hoặc Xcode SDK header được trích nguyên văn bên dưới.
- **INFERENCE**: hệ quả kỹ thuật hẹp từ DOCUMENTED evidence; không phải product decision.
- **NOT_PROVEN**: tài liệu đã xác minh không đủ để khẳng định.

Nguồn chính là Apple. Gemini 3.8 Flash chỉ là research input; mọi finding material dưới đây đã được kiểm tra lại với Apple links và installed SDK, không coi output của model là authority.

## Findings

### 1. Quartz có event type và field công khai cho `other` mouse button — DOCUMENTED

`CGEventType` liệt kê `otherMouseDown`, `otherMouseUp`, và `otherMouseDragged`. `CGEventField.mouseEventButtonNumber` là integer field chứa mouse button number.

> `kCGEventOtherMouseDown = NX_OMOUSEDOWN`
> `kCGEventOtherMouseUp = NX_OMOUSEUP`
> `kCGEventOtherMouseDragged = NX_OMOUSEDRAGGED`
>
> `Key to access an integer field that contains the mouse button number.`

Sources:

- [Apple `CGEventType.otherMouseDown`](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedown)
- [Apple `CGEventType.otherMouseUp`](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermouseup)
- [Apple `CGEventType.otherMouseDragged`](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedragged)
- [Apple `CGEventField.mouseEventButtonNumber`](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventbuttonnumber)
- Installed SDK provenance: `CoreGraphics.framework/.../Headers/CGEventTypes.h`, lines 101–158, captured at `/tmp/work-147-sdk-excerpts.log` (SHA-256 `2067f5ce72361a1301239f93e00f265f410d7a035214e96c85dcf060dcf01ec6`).

`CGEventCreateMouseEvent` additionally documents its current event-system button range and naming:

> `The current implemementation of the event system supports a maximum of thirty-two buttons. Mouse button 0 is the primary button on the mouse. Mouse button 1 is the secondary mouse button (right). Mouse button 2 is the center button, and the remaining buttons are in USB device order.`

Thus the documented creation surface currently accommodates button numbers `0...31`; the buttons beyond primary/secondary are `2...31` in that API’s current implementation. The `mouseButton` argument is used for the three `otherMouse*` types.

> ``mouseButton' is ignored unless `mouseType' is one of `kCGEventOtherMouseDown', `kCGEventOtherMouseDragged', or `kCGEventOtherMouseUp'.`

Source and SDK provenance:

- [Apple `CGEventCreateMouseEvent`](https://developer.apple.com/documentation/coregraphics/cgevent/init(mouseeventsource:mousetype:mousecursorposition:mousebutton:))
- Installed SDK `CGEvent.h`, lines 46–61, captured at `/tmp/work-147-sdk-button-excerpts.log` (SHA-256 `ba8f2ee15579a8f86384a7327e073a256f518f8ebb53c51c1805939e149fc779`).

**Boundary:** this is explicitly scoped to the *current implementation of the event system* and that creation API. USB order is not a universal hardware mapping, a stable physical `Device Identity`, or proof that equal button numbers originated from the same Pointing Device. The public `mouseEventButtonNumber` contract itself says only “button number.”

### 2. `mouseEventNumber` can link a matching down/up pair, not prove delivery integrity — DOCUMENTED / NOT_PROVEN

The SDK documents `mouseEventNumber` as an integer mouse-button event number and says:

> `Matching mouse-down and mouse-up events will have the same event number.`

Sources:

- [Apple `CGEventField.mouseEventNumber`](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventnumber)
- Installed SDK `CGEventTypes.h`, lines 137–142; same provenance as finding 1.

**INFERENCE:** where both events are delivered to the callback, the field is a documented candidate to associate a matching down/up pair.

**NOT_PROVEN:** this wording does not promise that every physical press yields a delivered down, drag, and up; that a tap sees all of them across permission change, disable, or device disconnect; or that preserving/suppressing one member leaves a system/application gesture in a specified state. It cannot establish `Device Identity`.

### 3. Active tap may preserve, modify, replace, or delete; `listenOnly` is observation only — DOCUMENTED

Apple documents both tap modes and the callback’s return contract:

> `Taps may be passive event listeners, or active filters. An active filter may pass an event through unmodified, modify an event, or discard an event.`
>
> `The function should return the (possibly modified) passed-in event, a newly constructed event, or NULL if the event is to be deleted.`

Sources:

- [Apple `CGEventTapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple `CGEventTapCallBack`](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)
- Installed SDK `CGEvent.h`, lines 254–300 and `CGEventTypes.h`, lines 415–452; captured in `/tmp/work-147-sdk-{button-,}excerpts.log` with the hashes above.

**INFERENCE:** a mask containing `otherMouseDown` and/or `otherMouseUp` is the documented event-level mechanism to observe those selected events. An active (default-option) tap is the documented mechanism that can return the input event to preserve it or `NULL` to suppress it. A passive `listenOnly` tap is not a mutation/suppression mechanism.

This does **not** choose whether a future `Binding` preserves or suppresses a press, release, or drag. That is an Action/product decision and must separately specify down/up/drag integrity.

### 4. Posting has documented ordering, but no documented recursion or delivery guarantee — DOCUMENTED / NOT_PROVEN

`CGEventTapPostEvent` posts from the tap callback at the point where its returned event would be posted:

> `The new event enters the system before the event returned by the callback enters the system. Events posted into the system will be seen by all taps placed after the tap posting the event.`

`CGEventPost` posts before all taps at the requested location:

> `This function posts the specified event immediately before any event taps instantiated for that location, and the event passes through any such taps.`

Sources:

- [Apple `CGEvent.tapPostEvent(_:)`](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:))
- [Apple `CGEvent.post(tap:)`](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))
- Installed SDK `CGEvent.h`, lines 335–354; provenance in finding 1.

**INFERENCE:** `CGEventPost` can potentially revisit a tap at the selected location, so any future reposting design needs an explicit loop-ownership rule.

**NOT_PROVEN:** Apple’s quoted contract does not promise synchronous recursion, a particular callback nesting/order for the posting tap itself, exactly-once delivery, or a complete loop-prevention mechanism. Reposting is not needed merely to preserve, modify, or delete the callback’s incoming event.

### 5. Tap disable notifications and re-enable exist; recovery bounds do not — DOCUMENTED / NOT_PROVEN

`tapDisabledByTimeout` and `tapDisabledByUserInput` are documented as out-of-band callback event types for unusual conditions that disable a tap. Apple documents:

> `If a tap becomes unresponsive or a user requests taps be disabled, an appropriate `kCGEventTapDisabled...' event is passed to the registered CGEventTapCallBack function. An event tap may be re-enabled by calling this function.`

Sources:

- [Apple `CGEvent.tapEnable(tap:enable:)`](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:))
- Installed SDK `CGEventTypes.h`, lines 128–132 and `CGEvent.h`, lines 320–333; provenance in finding 1.

**NOT_PROVEN:** no verified source gives a numeric timeout, guarantees that re-enabling succeeds or remains continuously enabled, or defines permanent-teardown behavior. A future runtime must not claim a recovery/readiness guarantee from these APIs alone.

### 6. Keyboard authorization documentation is unresolved; mouse-only sufficiency is NOT_PROVEN

The installed Xcode SDK’s `CGEvent.h` uses a more specific, legacy-style formulation:

> `Taps placed at `kCGHIDEventTap', `kCGSessionEventTap', `kCGAnnotatedSessionEventTap', or on a specific process may only receive key up and down events if access for assistive devices is enabled (Preferences Accessibility panel, Keyboard view) or the caller is enabled for assistive device access, as by `AXMakeProcessTrusted'. If the tap is not permitted to monitor these events when the tap is created, then the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned.`

Installed-SDK source: `CGEvent.h`, lines 272–279. This is SDK-header wording, not a quotation from the current web reference.

Separately, the current Apple `CGEventTapCreate` web reference’s Discussion says:

> `Event taps receive key up and key down events if one of the following conditions is true:`
>
> `The current process is running as the root user.`
>
> `Access for assistive devices is enabled. In OS X v10.4, you can enable this feature using System Preferences, Universal Access panel, Keyboard view.`

The same web reference separately limits an HID-entry tap location to root:

> `Only processes running as the root user may locate an event tap at the point where HID events enter the window server; for other users, this function returns NULL.`

Web source: [Apple `CGEventTapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), checked directly against Apple’s current documentation data. Its quoted Discussion does not contain the SDK header’s `AXMakeProcessTrusted` wording.

Apple’s WWDC 2019 keyboard-monitoring sample also uses `CGEventTapCreate` for key press/release events. At 19:56–20:58, the transcript says the first call can return `nil` while a dialog directs the user to approve background keyboard monitoring; it then identifies `IOHIDCheckAccess(..., kIOHIDRequestTypeListenEvent)` as the no-prompt status check.

At 35:32–36:29, Apple changes that sample’s `listenOnly` parameter to `defaultTap` and states (including the transcript’s wording):

> `If I change the listenOnly parameter to defaultTap, like that, CGEventTapCreate now creates a modifying event tab, where the callback can alter the event stream.`
>
> `And this means now your app has a way to influence what events are delivered to the rest of the system, where a listen-only event requires authorization for input monitoring, a modifying event app requires authorization for accessibility features.`

Source: [Apple WWDC 2019, “Advances in macOS Security”](https://developer.apple.com/videos/play/wwdc2019/701/) (transcript timestamps 19:56–20:58 and 35:32–36:29).

**DOCUMENTED:** the installed SDK header and current web reference are both Apple statements about keyboard event taps, but their quoted formulations differ: the web reference gives a root-or-assistive-devices condition with explicit OS X v10.4 context, while the installed header includes `AXMakeProcessTrusted`. The HID-entry root restriction is a separate tap-location statement. The WWDC sample describes a `listenOnly`/Input Monitoring versus `defaultTap` modifying-tap/Accessibility split.

**UNRESOLVED DOCUMENTATION DRIFT:** neither source explicitly supersedes the other, reconciles the two formulations, or proves that their named permission states are mutually exclusive or simultaneously required. This artifact therefore makes no exclusivity, override, or keyboard-permission-sufficiency claim.

Core Graphics separately exposes current-process checks and prompt-capable requests:

> `Checks whether the current process already has event listening access`
>
> `Requests event listening access if absent, potentially prompting`
>
> `Checks whether the current process already has event synthesizing access`
>
> `Requests event synthesizing access if absent, potentially prompting`

Sources:

- [Apple `CGPreflightListenEventAccess()`](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())
- [Apple `CGRequestListenEventAccess()`](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())
- [Apple `CGPreflightPostEventAccess()`](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())
- [Apple `CGRequestPostEventAccess()`](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())
- Installed SDK `CGEvent.h`, lines 398–408.

Accessibility exposes trusted-client checks; with the prompt option, the SDK says:

> `Returns whether the current process is a trusted accessibility client.`
>
> `Prompting occurs asynchronously and does not affect the return value.`

Source and SDK provenance:

- [Apple `AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- Installed SDK `AXUIElement.h`, lines 55–74, captured at `/tmp/work-147-sdk-excerpts.log` (SHA-256 `2067f5ce72361a1301239f93e00f265f410d7a035214e96c85dcf060dcf01ec6`).

The WWDC session separately uses `IOHIDCheckAccess(..., kIOHIDRequestTypePostEvent)` to test approval to synthesize input. The listen/post APIs and `AXIsProcessTrusted...` retain their documented purposes; Apple does not document them as equivalent checks or as a convenience-wrapper mapping.

**NOT_PROVEN:** this 2019 keyboard evidence is not an actual macOS 14 mouse-only test. Operational sufficiency for a mouse-only passive tap, an active `otherMouse*` modification/suppression tap, delivery, permission revocation/recovery, and device mapping on macOS 14 remains unproven. The documented purpose of a listen/post preflight is also not a complete operational-readiness verdict for a particular mouse event-tap configuration.

### 7. Compatibility and current repository boundary — DOCUMENTED / code observation

Confirmed SDK availability metadata:

| Surface | Installed SDK availability evidence |
| --- | --- |
| `CGEventTapCreate`, `CGEventTapEnable`, `CGEventTapPostEvent`, `CGEventPost`, `CGEventCreateMouseEvent` | `API_AVAILABLE(macos(10.4))` |
| listen/post preflight and request APIs | `API_AVAILABLE(macos(10.15))` |
| `AXIsProcessTrustedWithOptions` | `CF_AVAILABLE_MAC(10_9)` |

The installed SDK is `/Applications/Xcode.app/.../MacOSX26.5.sdk`; this is compile-time/header evidence that the above APIs are compatible with the macOS 14+ baseline, **not** an actual macOS 14 runtime test. Individual `otherMouse*` enum members have no separate availability annotation in the inspected enum declaration.

Current repository observation (not Apple proof): `macos/Platform/Sources/Platform/ScrollRuntime.swift` creates one default active `cgSessionEventTap`, head-inserted, whose mask contains only `.scrollWheel`; its callback only processes `.scrollWheel`. `InputRuntime` currently gates that scroll runtime using `AXIsProcessTrusted()`/`AXIsProcessTrustedWithOptions`, not the Core Graphics listen/post preflight APIs. Therefore its existing AX-only check proves neither extra-button permission sufficiency nor an event mask that includes `otherMouse*`.

No current trace or System Settings receipt inspected here proves granted permission, post-revocation behavior, or extra-button delivery. Those remain **NOT_PROVEN**.

## Bounded prototype questions

No prototype was run for this research. The following require bounded macOS 14+ target evidence before an implementation can claim them; obtain it through an integrated implementation/live check, or use a narrow, explicitly authorized disposable prototype only for a material feasibility blocker:

1. For the declared signing/distribution context, which permission state(s) are sufficient for a passive button-only tap, and independently for an active button-only tap that preserves or returns `NULL`; record behavior after grant/revocation. Test the WWDC `listenOnly`/Input Monitoring versus `defaultTap`/Accessibility split as a hypothesis, not as a replacement for this question or proof that the states are exclusive.
2. Which observed vendor/device button presses are delivered as `otherMouseDown`/`otherMouseUp`/`otherMouseDragged`, and what `mouseEventButtonNumber` values arrive? Record that as observed device behavior, not a universal mapping or `Device Identity` rule.
3. Under preserve versus suppress of down/up/drag, what delivery sequence reaches a target application, including unmatched members and tap-disable/re-enable boundaries?

These are feasibility observations, not permission policy or product-action choices. If a planner needs a universal permission/readiness or sequence-integrity guarantee before bounded target evidence, that is **NEEDS_LEAD_DECISION**, not a reason to expand research or infer a new HID/process architecture.

## Decision inputs unlocked

1. A future planner may treat `otherMouseDown`/`otherMouseUp`/`otherMouseDragged` plus `mouseEventButtonNumber` as documented event-level data, while retaining Unknown `Device Identity`.
2. A future Action decision may choose preserve/modify/delete only after it defines its own press/release/drag semantics; Apple’s callback contract supports those primitives but does not choose the policy.
3. Any plan involving synthetic reposting must own loop behavior explicitly; direct callback return is the documented alternative for pass-through, mutation, and suppression.
4. A future planner must treat the conflicting keyboard authorization documentation as unresolved rather than infer an override, exclusive permission modes, or simultaneous requirements. Mouse-only permission UI/readiness and runtime behavior remain conditional until bounded target evidence resolves the stated macOS 14+ facts; this artifact makes no UI or runtime decision.

## Primary-source index

- [Other mouse down](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedown)
- [Other mouse up](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermouseup)
- [Other mouse dragged](https://developer.apple.com/documentation/coregraphics/cgeventtype/othermousedragged)
- [Mouse button number](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventbuttonnumber)
- [Mouse event number](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventnumber)
- [Event-tap callback](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)
- [Create event tap](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Post from event tap](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:))
- [Post event](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))
- [Enable event tap](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:))
- [Preflight listen access](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())
- [Request listen access](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())
- [Preflight post access](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess())
- [Request post access](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())
- [Trusted Accessibility client with options](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [WWDC 2019: Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/) (keyboard-monitoring sample, transcript timestamps 19:56–20:58 and 35:32–36:29)
