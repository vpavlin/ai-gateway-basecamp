# AI Gateway (Logos Basecamp)

One way in to AI for every Logos app: local models first, then private and decentralised providers.
It is OpenAI-compatible, the user is in control of what is sent, and the privacy of every model is
labelled.

- **`ai_gateway_core`** (core module): connectors, routing, streaming jobs, keys, per-app usage, and
  an optional local OpenAI endpoint.
- **`ai_gateway`** (view): chat, connector onboarding, settings, and the **`ai.ask` / `ai.chat`
  intents** other apps call.

Status: **core 0.1.5, view 0.1.7**. Remote providers are hidden until the user acknowledges a warning (ADR 0003 covers the security review). Source: https://github.com/vpavlin/ai-gateway-basecamp. Issues: https://github.com/vpavlin/ai-gateway-basecamp/issues
Design: `docs/adr/0001-architecture.md`;
research: `docs/research-providers.md`, `docs/research-private-relay.md`; open questions:
`QUESTIONS.md`.

## Connectors (presets)

| Preset | Where | Privacy tier |
|---|---|---|
| Ollama, llama.cpp server, LM Studio | this computer | On this device |
| Venice | api.venice.ai | per model: No retention (private) / Standard (anonymized) |
| NEAR AI Cloud | cloud-api.near.ai | TEE (open models); Standard (proxied OpenAI/Anthropic/Google) |
| Nillion nilAI | api.nilai.nillion.network | TEE |
| Morpheus | api.mor.org | Standard |
| AkashML | api.akashml.com | Standard |
| Custom | any OpenAI-compatible URL | the user declares it |

**Local first.** "Add a connector" shows the runtimes on this computer. The remote providers (Venice, NEAR
AI, Nillion, Morpheus, AkashML, or a custom URL elsewhere) appear only after the user reads and accepts this,
once: *These run the model on someone else's computer. Each provider makes privacy promises, but none can
guarantee full privacy: your prompts leave this computer, and your IP address, timing, account and payment
can identify you.* Connectors already added stay visible with a "Remote" badge. An app's request says so
when the chosen model is remote.

**Tested with real accounts:** Venice and Ollama. The others (llama.cpp, LM Studio, NEAR AI, nilAI,
Morpheus, AkashML) follow each provider's documentation and are marked **Experimental: report issues!** in
the app until someone has tried them. Please do, and open an issue with what happened.

Tiers, worst to best: `standard` < `no-retention` < `tee` < `tee-e2ee` < `local`.
- TEE tiers are the provider's claim. Attestation checks come later.
- A caller can require a minimum, and the user sets a floor for every app. The gateway never routes
  below either.

## Using it from your app

**From a view (QML): intents.** Declare the intent in your `metadata.json`:

```json
"uses": [ { "intent": "ai.ask" } ]
```

Then call it:

```js
logos.request("ai.ask", { prompt: "Summarize this in three bullet points", content: text, minPrivacy: "no-retention" }, function (res) {
    if (res.ok) show(res.data.text)              // also res.data.model, .connector, .privacy, .usage
    else console.log("no AI:", res.error, res.data && res.data.message)  // unavailable | cancelled | failed | ...; on failed a short reason
})
```

- If AI Gateway isn't installed, Basecamp answers `unavailable` and offers to install it.
- The user sees your app's name and exactly what will be sent, picks the model, and the answer comes
  back to you.
- `ai.chat` takes OpenAI `messages` (plus `minPrivacy`, `model`, `temperature`, `maxTokens`).
- Strings are limited to 64 KB per field (Basecamp's intent rules).

**From a core module: the core API** (no dialog). Declare `ai_gateway_core` as a dependency, then:

- `chat(caller, requestJson)` → `{ok, jobId, model, privacy}`. `requestJson` is an OpenAI chat request
  plus optional `connector` and `minPrivacy`.
- Read the answer with `job(jobId)`: `{state: running|done|error|cancelled, text, usage}`.
  - Keep `jobId` to yourself: it is what lets you read the answer.
  - `jobUpdate(watchId, {id, state})` events only say that something changed. Every module can see events,
    so they carry no text; react to one by calling `job(jobId)`.

Never wait for an answer inside a single call: inference outlives the 20 s IPC timeout.

**A conversation (chat panel): `ai.session`, then core calls.** Every intent is confirmed by
Basecamp, so a per-message `ai.chat` means a dialog per message. Instead (ADR 0002):

0. Declare it in your view's `metadata.json` (`"uses": [{ "intent": "ai.session" }]`), or Basecamp
   refuses the request with `not_declared`.
1. Ask once with `logos.request("ai.session", { title, purpose, system, document, minPrivacy }, cb)`.
   The user allows it and picks the model; `res.data` is `{sessionId, model, connector, privacy}`.
2. Send each turn from your **core**. Declare `"optional_dependencies": ["ai_gateway_core"]`, then
   call `sessionChat(sessionId, {"message": "…", "document": "<only when it changed>"})` →
   `{ok, jobId}`.
   - The gateway keeps the history and the latest document. Send only what is new.
   - Read the answer with `job(jobId)` (poll it; a `jobUpdate` event for your `watchId` means "look now").
   - `code: "no_session"` means ask again; `code: "busy"` means wait for the answer.
3. `closeSession(sessionId)` when the panel closes. The user can also end it in Apps & usage.

The document can be up to 1 MB through `sessionChat`, but only 64 KB through the intent.

**From outside Basecamp: the local endpoint.** Enable it in Settings. Point any OpenAI client at
`http://127.0.0.1:11500/v1` with the token shown there. It supports `/v1/models` and
`/v1/chat/completions`, streaming included.

## Build and test

```sh
scripts/test.sh                                   # core vs a fake provider + the view rendered offscreen
(cd ai_gateway_core && nix build .#lgx-portable)  # Basecamp packages (builder 0.3.3, Basecamp 0.3.2)
(cd module && nix build .#lgx-portable)
```

- Verified so far:
  - the core in a real `logosctl` runtime (HTTPS to Venice, a streamed job, and `jobUpdate` events
    as `{arg0, arg1}`);
  - the view in the render harness (an intent round trip and the event path).
  - the Basecamp GUI with Venice, and Fileverse's ai.ask / ai.session integration in Basecamp 0.3.2.
- linux-arm64 and darwin-arm64 are built by GitHub Actions (tags `arm64-*`, `darwin-*`) and merged into one
  `.lgx` per module.
