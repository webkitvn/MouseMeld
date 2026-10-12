# AI Agent Rules

Read this file before changing code, tests, build files, documentation, or planning artifacts.

## Source of truth

Use sources by responsibility:

- `AGENTS.md`: stable repository-wide workflow rules.
- GitHub Issues: current work, decisions, milestones, hierarchy, dependencies, release gates, and artifact pointers.
- `CONTEXT.md`: canonical domain language.
- `docs/adr/`: hard-to-reverse architecture decisions.
- `docs/research/`: research evidence.
- `docs/guardrails/registry.yaml`: canonical entry point for active design guardrails.
- Code, tests, and build files: implementation truth.

Do not treat chat history as project truth. If canonical sources conflict, report the drift in the active Issue and resolve only the material conflict before continuing.

## Tools

Use the smallest tool that can resolve the current task.

- GitHub and `gh`: canonical interface for Issues, milestones, relationships, dependencies, claiming, and work status.
- `just frontier`: show open, unblocked, unclaimed claimable work under the current context.
- `just next`: select the highest-priority frontier Issue; never claims it.
- `CONTEXT.md`: resolve canonical domain terminology.
- ADRs: record hard-to-reverse or surprising architecture decisions.
- Research: resolve material uncertainty that cannot be answered from current code, contracts, or reliable precedent.
- Reference implementations: reduce rediscovery; adapt known-good behavior without copying external expression.
- Wayfinder: planning escalation for large, vague, cross-cutting, or roadmap work; not routine implementation.
- Domain modeling: use when domain semantics or boundaries are genuinely unclear.
- Prototype: use for unresolved feasibility; prototypes are disposable evidence, not production foundations.
- TDD, tests, and mocking: use established public seams; mock only established system boundaries. Do not invent production abstractions solely for testability.

### Computer use

Computer-use tools may inspect and control macOS apps and browsers when needed for the active task. Prefer CLI/API tools when sufficient. Verify the target window/tab before acting and confirm the result afterward. Reuse user-owned sessions only with permission; do not disrupt another agent's session. Ask before destructive or out-of-scope actions. Oracle-specific browser rules still apply.

### Oracle

Use Oracle only for material second-model review, architecture/design uncertainty, or an explicit review requirement. Treat its output as advisory and verify material conclusions against repository evidence and tests.

Use `--engine browser` explicitly and the dedicated ChatGPT Project. API mode requires explicit user consent. Use an already signed-in Chrome and attach to a verified tab; do not use Oracle's launcher to navigate to the Project.

Prepare Chrome on demand, not for the entire working session. Reuse a suitable existing browser only when its owner permits control; otherwise launch an isolated Chrome with a dedicated CDP endpoint and a signed-in profile. A temporary copy of the signed-in Chrome user-data directory is permitted, but launch that copy outside Oracle: `--copy-profile` cannot be combined with attach-running. Never delete source-profile cookies or authentication files. If redirected to login, first verify the actual process/profile, then ask the user to sign in there if needed.

Each consultation has two steps:

1. Open and verify the intended tab outside Oracle:
   - **Fresh:** open a new tab at `https://chatgpt.com/g/g-p-6a8825fba8a88191b61159104f8bf9f8-mac-mouse-flow/project`. Wait for the exact `/project` URL and the `New chat in Mac Mouse Flow` composer. Obtain that tab's current CDP target ID; do not reuse a tab that has already become a conversation.
   - **Continue:** when the user supplies a conversation URL, open that exact URL, wait for prior turns to finish loading, and verify its conversation ID has not changed. Obtain that tab's target ID. Do not navigate to `/project` or create a replacement chat. For a conversation linked to a saved Oracle session, prefer Oracle's `--followup <session-id>` recovery-aware continuation instead; inspect its inherited browser configuration before running it.
   - Verify the endpoint belongs to the intended Chrome. If a particular model/effort is required, verify it in the UI before sending; `current` and Oracle's printed requested model name do not prove selection. Missing verification is a blocker, not permission to substitute.
2. Attach to the verified target and capture the answer:

```bash
oracle \
  --engine browser \
  --browser-attach-running \
  --remote-chrome "<verified-host:port>" \
  --browser-tab "<verified-target-id>" \
  --browser-model-strategy current \
  --browser-archive never \
  --slug "<unique-slug>" \
  --timeout 10m \
  --write-output "/tmp/<unique-slug>.md" \
  -p "<prompt>" \
  --file "<relevant-file>"
```

Do not add launcher-only flags (`--browser-manual-login`, `--browser-port`, or `--copy-profile`) to this attach command. `--chatgpt-url` alone does not guarantee a fresh conversation. Never archive a user-supplied conversation.

Accept completion only after retrieving the answer and verifying the resulting conversation is in the intended Project: a fresh run has a new conversation ID; continuation retains the supplied ID. On timeout or ambiguous submission, inspect the session and conversation before retrying; do not blindly resend, use `--force`, or delete session metadata to bypass duplicate protection. `promptSubmitted: true` alone is not proof the user turn committed.

After successful capture, close only Chrome/tabs created for this consultation and remove any temporary copied profile after Chrome exits. Leave reused browsers untouched. Preserve owned browsers and temporary profiles for recovery on incomplete runs; do not interrupt a peer's Oracle process or Chrome.

Verified on Oracle 0.21.4: a fresh Project-root attachment created a new Project conversation and returned `ORACLE_ROOT_ATTACH_OK`; fixed-port recovery verified `http://127.0.0.1:9223/json/version` before an attached Project-root consultation returned `ORACLE_RECOVERY_ATTACH_OK`. Model-specific, attachment-based review, and long-history continuation remain unproven by these smoke tests.

## Start work

Use `gh` as the default project interface.

There must be exactly one open `work:current` context during normal work. During implementation or dogfood it must be the current execution context; during planning it is the current planning context. If none or multiple exist, stop and report the tracker inconsistency.

Use:

```text
just frontier
just next
```

Claim the selected Issue by assigning it before changing repository artifacts.

Work from an explicit GitHub Issue for planned work. Check its dependencies, acceptance criteria, declared target environment, and direct pointers before expanding context.

Native GitHub milestone, parent/sub-issue, blocked-by/blocking, labels, assignees, and state are canonical when supported. Use Markdown/body relationship fallback only when native mutation is unavailable.

For direct canonical-domain lookup through GitHub, use:

```bash
gh api repos/OWNER/REPO/contents/CONTEXT.md -H 'Accept: application/vnd.github.raw+json'
```

Follow pointers to ADRs, research, and guardrails only when relevant to the active work. For guardrail-relevant work, start at `docs/guardrails/registry.yaml`.

## Delivery

Keep changes small and vertical around an observable outcome.

Prefer the fast path:

`claim → inspect direct context and precedent → minimal adaptation → targeted verification and independent review → bounded dogfood when needed → diagnose with existing bounded logs → iterate → ship`

Planning readiness is decision readiness for the bounded release: settle necessary product, domain, architecture, ABI, persistence, and safety choices before execution. Targeted checks, live checks, and dogfood supply runtime evidence during execution; this does not bypass the execution-instantiation hierarchy or the sole current-context requirement.

Independent technical review covers the exact change and relevant checks. Changes made while iterating must go through relevant verification and independent review before ship. Computer-use review can establish observable UI and interactions where needed; physical input and perceived smoothness require relevant user evidence. Diagnose dogfood failures with existing bounded diagnostics and tools first. Scoped non-critical limitations may be disclosed and iterated, but do not knowingly ship wrong-target outcomes, unintended input suppression or stuck input, data or configuration corruption, or without a safe disable/recovery path.

Stop when the Issue acceptance criteria are met. Do not add compatibility work, abstractions, diagnostics, benchmarks, documentation, or tests that the Issue does not require.

Use reference implementations to reduce rediscovery. Reuse ideas and observable behavior, not code expression. Do not copy or mechanically transform external code, comments, documentation, tests, distinctive naming, module structure, or control flow. A routine reference comparison does not require a standalone artifact or tracker comment when it finds no material difference or blocker; record only findings that change implementation, acceptance, or later-agent context.

Before proposing behavior or design, inspect applicable reference precedent. When applicable, locate the optional local `Repo X` input at `/Users/cuongpham/Projects/repo-x` and search or inspect relevant portions when available. If it is unavailable, report that before proceeding without cloning or hunting; if inspection is unnecessary, state why. Delegations include relevant observations in independent language or the reason for skipping or being unable to inspect; references inform decisions, not replace independent rationale.

Do not block implementation to prove speculative details.

Enter the deep path only when uncertainty materially involves one or more of:

- undocumented or private platform behavior;
- conflict with an established repository contract;
- failure in the active Issue's target environment;
- a hard-to-reverse architecture, ABI, persistence, or process-boundary decision;
- material fail-open, safety, correctness, or hot-path risk that existing seams cannot bound.

Wayfinder, research, prototype, domain modeling, and additional architecture work are escalation tools, not mandatory ceremony.

Timebox exploratory research for normal implementation work. If no deep-path trigger appears within 30 minutes, use the simplest reversible approach supported by current contracts and the best available precedent.

Use the compatibility target declared by the active Issue. Do not expand support to additional architectures, OS versions, toolchains, or compatibility matrices without an explicit requirement or demonstrated production failure.

Use domain terms from `CONTEXT.md`. Do not invent competing vocabulary.

Update the active Issue only when a material fact or decision changes what later agents need to know.

## Architecture guardrails

These are stable defaults unless explicitly superseded by a newer Issue decision, ADR, or active guardrail.

- Use one SwiftUI/AppKit process with a native input adapter and platform-neutral Rust engine.
- Swift/AppKit owns macOS lifecycle, permissions, `CGEventTap`, native event extraction/application, and platform I/O outside the input callback.
- Rust owns platform-neutral normalization, domain semantics, configuration evaluation, and `Input Decision`.
- Swift ↔ Rust uses a narrow manual C ABI with fixed-layout hot-path values.
- The input callback must not perform UI/MainActor work, disk/network I/O, synchronous logging, config parsing, or unbounded blocking/locking.
- Bridge or engine failure must fail open and preserve original input.
- Never infer physical `Device Identity` from `Scroll Granularity`, timestamps, or undocumented correlation.
- Do not introduce new process boundaries, IPC, HID takeover, or similarly hard-to-reverse architecture without an explicit decision and ADR.

## Verification

Canonical commands are the single source of verification behavior:

```text
just check
just test
just ci
just benchmark
just smoke
just hooks-install
just frontier
just next
```

Git hooks and GitHub Actions must call canonical commands instead of duplicating their logic.

Use the smallest verification set that proves the active Issue's acceptance criteria. Do not split suites, add caches, or add path-specific verification complexity without measurement showing a repeated bottleneck worth fixing.

Test through established public seams. If a test requires a new production interface, trait, protocol, adapter, provider, gateway, repository, mock, or fake solely for testability, stop TDD and resolve the boundary first.

Strict latency evidence must come from the target/reference environment declared by the active Issue, not unrelated hosted CI timing.

Hot-path diagnostics must use bounded enqueue/buffering; prefer dropping diagnostic data over blocking input.

## Planning

Discover planning context through `work:current`. Strategic maps are not current execution work unless explicitly marked current.

Milestones represent releases. Labels represent work type. Parent/sub-issue represents decomposition. Blocked-by/blocking represents dependencies.

Prefer native GitHub relationships. Use body fallback only when the tracker cannot represent the relationship natively.

Keep decision details in their resolution comments or canonical artifacts instead of duplicating them into planning maps.

Resolve at most one non-research Wayfinder ticket per planning session.

Keep this file short and stable. Store workflow invariants and tool routing here; keep release-specific scope, compatibility matrices, frontier state, dependency graphs, Issue numbers, and full decision bodies in their canonical locations.
