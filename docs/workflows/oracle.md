# Oracle consultation workflow

Read this workflow before any consultation, as required by [AGENTS.md](../../AGENTS.md#oracle). Oracle is advisory; its use and engine/consent policy are defined there.

## Prepare Chrome

Use an already signed-in Chrome and attach to a verified tab; do not use Oracle's launcher to navigate to the Project.

Prepare Chrome on demand, not for the entire working session. Reuse a suitable existing browser only when its owner permits control; otherwise launch an isolated Chrome with a dedicated CDP endpoint and a signed-in profile. A temporary copy of the signed-in Chrome user-data directory is permitted, but launch that copy outside Oracle: `--copy-profile` cannot be combined with attach-running. Never delete source-profile cookies or authentication files. If redirected to login, first verify the actual process/profile, then ask the user to sign in there if needed.

## Select and attach

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

## Evidence limits

[Issue #122](https://github.com/webkitvn/MouseMeld/issues/122) owns the historical Oracle 0.21.4 Project-root attachment and fixed-port recovery smoke receipts. They are bounded historical evidence, not certification of another version or every recovery path. Model-specific, attachment-based review, and long-history continuation remain unproven by those smoke tests.
