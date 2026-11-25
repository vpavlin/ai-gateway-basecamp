# The `ai.session` contract (`ai-session/1`), for any provider

Apps like Fileverse and Basecamp Voice shouldn't depend on AI Gateway by name: any app may provide
`ai.ask`, `ai.chat` and `ai.session`. Basecamp's intents confirm every request with the user and have no
follow-up requests bound to an earlier one, so a chat can't send one intent per message. The contract:

1. **Open, through the intent (one confirmation):**
   `logos.request("ai.session", {title, purpose, system?, document?, minPrivacy?, model?})`.
   The answer's `data` must carry:
   - `sessionId`: a secret (≥ 128 random bits), the only credential for the session;
   - `provider`: the name of the **core module** that serves the turns, e.g. `"ai_gateway_core"`;
   - `api`: `"ai-session/1"` (this document; a caller refuses an api it doesn't know);
   - `model`, `connector`, `privacy`: for display.
2. **Turns, core to core, on the module named in `provider`** (each returns a JSON string):

   | Method | Arguments | Answer |
   |---|---|---|
   | `sessionChat(sessionId, turnJson)` | turn: `{message \| messages, context?, document?, responseFormat?, tools?, toolChoice?, historyChars?, resetHistory?, temperature?, maxTokens?}` | `{ok, jobId, watchId, model, privacy}` or `{ok:false, error, code?: busy \| no_session \| unsupported}` |
   | `job(jobId)` | — | `{ok, state: running \| done \| error \| cancelled, text, message?, model, connector, privacy, usage?, stats?, error?}` |
   | `jobDelta(jobId, since)` | `since`: the previous answer's `length` (UTF-8 bytes), `"0"` first | `{ok, state, done, offset, delta, length, …}` |
   | `cancel(jobId)` | — | `{ok}` |
   | `closeSession(sessionId)` | — | `{ok}` |

   - `jobDelta` is optional for providers: a caller falls back to `job()` when it is missing.
   - `no_session` means ask `ai.session` again.
3. **Privacy:**
   - the provider enforces the privacy floor it was given and shows the user what the session sends;
   - the caller keeps `sessionId` to itself;
   - events, if any, carry no content.

**How a caller reaches the provider:** the provider's name is known only at run time. Call it through the
SDK's generic client (the name as a string), not a generated wrapper, so there is no build-time dependency.

**Not verified yet:** that Basecamp 0.3.2 lets a core call a module it didn't declare. The module is loaded,
because the provider's view brought it up to answer the intent.

**The upstream asks that would make this unnecessary:**
- follow-up intents bound to an approved request (session-scoped routing, no chooser);
- scoped, revocable grants ("this app, this intent, until I end it").

`docs/app-to-app-intents.md` §7 lists both as future work; "always use this app" was pulled before release.

AI Gateway answers `provider: "ai_gateway_core", api: "ai-session/1"` from view 0.1.13.
