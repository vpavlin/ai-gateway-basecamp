# ADR 0002: Chat sessions (ai.session + sessionChat)

Status: accepted, 2026-11-22 (core 0.1.2, view 0.1.3). Asked for by Fileverse's AI chat panel.

## Problem

An app's chat about a document (Fileverse) sent through `ai.chat` costs, every turn:
- Basecamp's own confirmation. The broker confirms every intent dispatch, even with one
  provider installed, and has no "always allow" or scoped grants yet (app-to-app-intents.md §2, §7).
- AI Gateway raising itself and asking for Run.
- The whole history and the whole document again, each string capped at 64 KB.

## Decision

1. **`ai.session` intent** `{title*, purpose, system, document, minPrivacy, model}`.
   - The user allows it once. Basecamp confirms, then AI Gateway shows the title, purpose, system
     prompt and document, and the user picks the model.
   - The gateway answers `{sessionId, model, connector, privacy}`.
   - `sessionId` is a 128-bit random capability: only the app that received the answer knows it.
2. **Turns go core to core, with no dialog:** `ai_gateway_core.sessionChat(sessionId, turnJson)`.
   - The app's core lists `ai_gateway_core` under `optional_dependencies`. It probes with an async
     call (an empty answer or an error means "not installed"), as WhisperBox does for loam_core.
   - A turn is `{message | messages, document?, temperature?, maxTokens?}`. It returns
     `{ok, jobId}`; the answer streams as `jobUpdate` (with `sessionId`) or comes from `job()`.
3. **The gateway keeps the state.**
   - It keeps the system prompt, the latest full document (a `document` field in a turn replaces
     it) and the history.
   - A successful turn appends the user message(s) and the answer. A failed turn appends nothing.
   - What the model sees: `system` = the system prompt + "The document (latest version)" + the
     document, then the history, then the new turn.
   - The model and privacy floor are fixed when the session opens; the user's global floor still
     applies.
4. **Limits.**
   - History: 200 messages and 400 000 characters; the oldest turns drop first.
   - Document: 1 MB. System prompt: 100 KB.
   - At most 50 sessions. A session ends after 12 h idle, and on a core restart (memory only; the
     app re-asks, and sessionChat says `code: "no_session"`).
   - A turn while one is answering is refused with `code: "busy"`.
5. **The user stays in control.** Apps & usage lists open chats (app, title, model, turns, document
   size), refreshed every 4 s, with an End button (`closeSession`, which also stops a running answer).

## Consequences and honest limits

- **Consent is UX, not enforcement.** Basecamp 0.3 doesn't authenticate core-to-core callers, so
  any module could already call `chat()` or `openSession()` directly with no dialog. The session
  makes the well-behaved path the comfortable one. It does not stop a hostile module. The fix
  belongs in the platform (caller identity on core calls, scoped grants).
- **The document sits before the history.** A changed document invalidates the provider's prefix
  cache for that turn. That is acceptable: correctness first, and the answer always sees the latest
  text. Apps that prefer diffs can send them as user messages and never resend `document`.
- **History is per process.** It is not written to disk, so a chat about a private document leaves
  nothing in the gateway's files.
