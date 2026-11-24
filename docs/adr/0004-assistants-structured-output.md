# ADR 0004: Assistants on sessions: structured output, tools, ephemeral context, history policy

Status: accepted, 2026-11-24 (core 0.1.6). Asked for by Basecamp Voice: a planner that makes 1-4 calls per
spoken request, needs valid JSON plans from small models, and keeps a conversation.

## Decision

- **Structured output.**
  - `chat()` passes OpenAI's `response_format` and `tools` through (it always did).
  - Both `chat()` and `sessionChat()` also accept `responseFormat`. It must be
    `{type: json_schema, json_schema: {...}}` or `{type: json_object|text}`; the gateway sends it as
    `response_format`.
  - `sessionChat()` also takes `tools` (64 KB at most) and `toolChoice`.
- **What a model can do:** `models()` gives `jsonSchema`, `tools` and `contextTokens` per model.
  - Values come from the preset (the local runtimes support both), from the provider's model list (Venice
    `model_spec.capabilities` and `availableContextTokens`), or from generic fields (`context_length`,
    `meta.n_ctx_train`).
  - `null` means unknown: the request goes through and a provider error comes back as the job's error.
  - A known `false` is refused up front with `code: "unsupported"`.
- **Ephemeral context:** `sessionChat({context})` sends up to 256 KB as a system message for that call only.
  It is never stored, so a fresh 3-5k-token state block per turn doesn't pile up in history.
- **History policy:**
  - `historyChars` (0-400,000, persisted for the session) caps stored and sent history.
  - `resetHistory: true` starts over.
  - Where the model's context window is known, history that doesn't fit is left out of the request (oldest
    first), leaving room for the system prompt, context, turn and answer (~3 characters a token).
- **Visibility:** `sessions()` shows `sentChars` per session, and `usage()` shows `sentChars` per app (what
  went to models). The user ends a session with End.

## Identity (unchanged; ADR 0002 and 0003)

Basecamp 0.3 gives a core no caller identity.
- The `caller` of a session is fixed when the user allows `ai.session`: it is Basecamp's requester name for
  the view that asked.
- After that, the 128-bit session id is the only credential. It is never listed or sent in events, so the
  app must keep it secret.
- The real fix is platform caller identity, an upstream ask.
