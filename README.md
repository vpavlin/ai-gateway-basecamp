# AI Gateway (Logos Basecamp)

One way in to AI for every Logos app: local models first, then private and decentralised providers.
It is OpenAI-compatible, the user is in control of what is sent, and the privacy of every model is
labelled.

- **`ai_gateway_core`** (core module): connectors, routing, streaming jobs, keys, per-app usage, and
  an optional local OpenAI endpoint.
- **`ai_gateway`** (view): chat, connector onboarding, settings, and the **`ai.ask` / `ai.chat`
  intents** other apps call.

Status: **0.1.0**. Not yet in any package repository. Design: `docs/adr/0001-architecture.md`;
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
    else console.log("no AI:", res.error)        // unavailable | cancelled | failed | ...
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
- The answer streams as `jobUpdate(jobId, json)` events: `{state, delta}`, then
  `{state: done|error, text, usage}`.
- Or poll `job(jobId)`.

Never wait for an answer inside a single call: inference outlives the 20 s IPC timeout.

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
- Not yet: Basecamp GUI with a real provider key, and arm64/darwin builds (that needs a GitHub repo
  for CI).
