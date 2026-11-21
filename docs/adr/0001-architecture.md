# ADR 0001: An AI gateway for Basecamp: a core module, a view, two ways in

Status: proposed, 0.1.0 (2026-11-21)

## Context

Václav (2026-11-21) wants one Basecamp module through which every Logos app reaches AI:
- local inference first, then private or decentralised providers (Venice, Morpheus, NEAR AI,
  Nillion nilAI, Akash);
- OpenAI-compatible;
- onboarding help for each provider (keys, funds, staking), using Basecamp and Logos infrastructure
  where it exists;
- intents, so an app's "Analyze this with AI" works if the gateway is installed, and Basecamp offers
  to install it if it isn't.

Later, a relay over Logos could make the providers more private (`research-private-relay.md`).

Basecamp facts that shape this (`logos-basecamp/docs/app-to-app-intents.md`, 2026-11):
- Intent providers are `ui_qml` apps, by design. Every request is confirmed by the user, and a
  provider answers within 10 minutes.
- Payloads are plain data: strings ≤ 64 KB, ≤ 1000 nodes, ≤ 8 levels deep.
- Core modules call each other directly by name (LogosAPI), with no chooser.
- Basecamp ships Qt Network and the OpenSSL TLS backend (checked in the 0.3.2 AppImage), so a core
  module can make HTTPS calls. Qt HttpServer isn't shipped.

## Decision

**Two packages:**
- `ai_gateway_core`, a core module: connectors, routing, jobs, keys, usage, and an optional local
  OpenAI endpoint.
- `ai_gateway`, a view: chat, connector onboarding, settings, and the intent provider.

Built with logos-module-builder 0.3.3 for Basecamp 0.3.2, for three platforms (amd64, arm64,
darwin-arm64).

**Connectors.** One kind, OpenAI-compatible: a base URL, an optional Bearer key, and extra headers.
Built-in presets (`research-providers.md`) carry the provider's name, URLs for signup, keys and
funds, onboarding steps, privacy tier per model, balance headers and model-name fixes (Morpheus hex
ids). They are:
- local: Ollama, llama.cpp, LM Studio;
- Venice, NEAR AI, Nillion nilAI, Morpheus and AkashML;
- any custom endpoint.

A preset is data, so adding a provider is a JSON entry, not code.

**Privacy tiers**, per (connector, model), worst to best:
- `standard`: no claims;
- `no-retention`: a contractual promise;
- `tee`: attested, encrypted to the gateway;
- `tee-e2ee`: attested and end-to-end encrypted;
- `local`: never leaves the device.

The tier is shown in every model picker and on every answer. A caller may ask for a minimum
(`minPrivacy`); the gateway never routes below it. In 0.1 the tiers come from the presets; attestation
checks are a later step.

**Two ways in:**
1. **Core API** for other core modules (direct calls, no prompt):
   - `chat(request)` returns a job id at once. The result arrives as an `aiEvent` (chunks, then done
     or error); `job(id)` polls.
   - Never blocking: an IPC call has a 20 s timeout, and inference takes longer.
   - Every call names its caller, so the user can see per-app usage. (The name is self-declared,
     as everything in Basecamp is until signing lands.)
2. **Intents** for apps, served by the view:
   - `ai.chat`: OpenAI-style `messages` plus optional model, `minPrivacy`, `temperature`,
     `maxTokens`.
   - `ai.ask`: `{ prompt, content?, system? }`, the "Analyze this with AI" button.

   The view shows who asks and exactly what will be sent. The user picks or confirms the model,
   which shows its privacy tier. The view runs the job and answers `{ text, model, connector, privacy,
   usage }`. An app that declares `uses: ai.ask` gets Basecamp's install offer when the gateway isn't
   installed.

**Local OpenAI endpoint (optional, off by default).** A minimal HTTP/1.1 server on `127.0.0.1` with a
random token: `/v1/models` and `/v1/chat/completions`, streaming included. Tools outside Basecamp can
then use the gateway as an OpenAI endpoint: editors, agents, scripts.

**Keys.**
- Stored in the module's data folder as a private file (mode 0600). Never sent anywhere but their own
  provider, never shown back in full, and never returned to callers.
- Sealing them under a passphrase or Keycard comes later (the WhisperBox vault pattern).

**Onboarding in 0.1** is guided links and checks, not account automation:
- open the signup, key and funding pages;
- paste the key and test it with `GET /models`;
- show the balance where the provider gives one (Venice headers);
- explain staking with links (DIEM, MOR, NEAR).

Creating limited keys through the API (Venice ADMIN `POST /api_keys` with PRIVATE_ONLY and a spend
cap) and x402 top-ups come later.

## Consequences

- Apps get AI with one `uses` line and no SDK. Core modules get it with one dependency.
- Every intent request is a consent dialog. Fine for a button press; bulk or background use goes
  through the core API instead.
- Each provider's privacy claim is its own. The gateway labels it honestly and lets callers require a
  minimum. Making the claims stronger is the relay work (ADR 0003, later).
