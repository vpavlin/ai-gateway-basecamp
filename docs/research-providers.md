# Research: private and decentralised inference providers (2026-11-21)

Collected from the providers' official docs on 2026-11-21. Each claim carries its source. "Unclear"
means the docs didn't say, not that the feature is missing. Re-check before relying on any one of
them; these APIs change monthly.

## Summary

| Provider | Base URL | OpenAI-compatible | Key | Pay | Privacy | Attestation | x402 |
|---|---|---|---|---|---|---|---|
| Local (Ollama / llama.cpp / LM Studio) | `http://localhost:11434/v1`, `:8080/v1`, `:1234/v1` | yes | none | free | on the device | n/a | n/a |
| Venice | `https://api.venice.ai/api/v1` | yes, plus `venice_parameters` | Bearer; API, or headless wallet path | card or crypto credits, staked DIEM, x402 USDC | per model: `private` (no retention) / `anonymized`; TEE + E2EE models (`e2ee-*`) | `GET /tee/attestation?model&nonce` | **yes** (top-up + SIWX per request) |
| NEAR AI Cloud | `https://cloud-api.near.ai/v1` | yes | Bearer (dashboard) | credits; NEAR staking rewards | TDX + H200 TEE, gateway in a TEE, E2EE; frontier models only via a TEE gateway | `GET /v1/attestation/report` (no key), per-response signatures | no |
| Nillion nilAI | `https://api.nilai.nillion.network/v1` | chat/responses/models | Bearer, or NUC tokens | credits (Stripe) | TEE, signed responses | `/v1/attestation/report` | no |
| Morpheus | `https://api.mor.org/api/v1` | yes (chat, embeddings, tools) | Bearer `sk-…` (email signup) | card or crypto credits; MOR staking allowance | none claimed (trusted gateway) | no | proposed (MRC64) |
| AkashML (was Akash Chat API) | `https://api.akashml.com/v1` | yes (+ Anthropic messages) | Bearer | card credits | none claimed | no | no |

## Venice
- API spec, the OpenAI-compatible surface and `venice_parameters`: https://docs.venice.ai/api-reference/api-spec
- Keys can be created through the API (`POST /api_keys` with an ADMIN key: limits, expiry,
  `modelPrivacy` PRIVATE_ONLY, IP allow-list). Headless: `GET /api_keys/generate_web3_key`, signed by
  the staking wallet. https://docs.venice.ai/api-reference/endpoint/api_keys/create.md and
  https://docs.venice.ai/overview/vvv-diem
- Pricing, DIEM ($1/day per staked DIEM) and the order credits are spent in:
  https://docs.venice.ai/pricing.md
- x402: prepaid USDC balance on Base or Solana. `POST /x402/top-up` answers 402, then
  `PAYMENT-SIGNATURE`. Each request carries a single-use `SIGN-IN-WITH-X` wallet signature, so the
  wallet *is* the account and requests are linkable.
  https://docs.venice.ai/guides/integrations/x402-venice-api.md
- Privacy:
  - Every model lists `model_spec.privacy`. Venice keeps the IP, key id and token counts.
    https://docs.venice.ai/overview/privacy
  - TEE + E2EE: secp256k1 ECDH + HKDF + AES-GCM, using the `X-Venice-TEE-*` headers. Text only; web
    search is off, and tool definitions are not encrypted.
    https://docs.venice.ai/overview/guides/tee-e2ee-models
- Responses carry balance headers (`x-venice-balance-usd`, `-diem`), so the UI can show what's left
  without an ADMIN key.

## NEAR AI Cloud
- OpenAI compatibility: https://docs.near.ai/cloud/guides/openai-compatibility.md
- Private inference:
  - TDX + H200, and the gateway runs in a TEE: https://docs.near.ai/cloud/private-inference.md
  - The attestation report needs no key: `GET /v1/attestation/report?model&nonce&signing_algo`.
  - E2EE: Ed25519→X25519 + HKDF + XChaCha20-Poly1305, `X-Encryption-Version: 2`.
    https://docs.near.ai/cloud/guides/e2ee-chat-completions.md
- Staking NEAR: the rewards become inference credits.
  https://docs.near.ai/cloud/staking-for-inference/overview.md
- **Caveats:**
  - The OpenAI, Anthropic and Gemini models in its catalogue are confidential only up to NEAR's
    gateway, so trust it only for `provider=near` models.
  - An RCE that exposed two customers' keys through logs was disclosed on 2026-11-09 (secondary
    source).

## Nillion nilAI
- Overview and key concepts (API key or NUC; TEE; every response signed):
  https://docs.nillion.com/blind-computer/build/llms/overview
- Quickstart and base URL: https://docs.nillion.com/blind-computer/build/llms/quickstart
- Two models (gemma-4-26B-A4B, Qwen3.6-35B-A3B). No embeddings or images. Credits since 2026-04.
- nilGPT is Nillion's own chat app on nilAI, in beta.

## Morpheus
- Gateway docs: https://apidocs.mor.org (index https://apidocs.mor.org/llms.txt, OpenAPI
  https://apidocs.mor.org/api-reference/openapi.json)
- Account and key: https://apidocs.mor.org/documentation/guides/setting-up-your-account.md. The key is
  shown once, and "automation" must be enabled on the account.
- Credits and MOR staking allowance (refreshed daily; overages off by default):
  https://apidocs.mor.org/documentation/getting-started/credits.md
- Model ids are hex blockchain addresses; the UI must show names.
- No privacy claims at the gateway. TEE work at the provider level is unofficial.

## AkashML
- The Akash Chat API redirects to akashml.com: https://akashml.com/docs/guides/akash-chat
- Docs and pricing: https://akashml.com/docs and https://akashml.com/docs/guides/pricing
- The free tier is playground only; an API key needs credit.

## Local runtimes
- Ollama (OpenAI compatibility): https://docs.ollama.com/api/openai-compatibility
- llama.cpp server: https://github.com/ggml-org/llama.cpp/tree/master/tools/server
- LM Studio: https://lmstudio.ai/docs/app/api/endpoints/openai

## What this means for the gateway
- **One connector kind covers every provider:** an OpenAI-compatible base URL plus a Bearer key.
  Per-provider extras are presets, not code: Venice's `venice_parameters` and balance headers,
  Morpheus's hex ids, NEAR's and Venice's attestation endpoints.
- **A privacy tier per (provider, model)**, shown to the user and requestable by callers:
  - `local`: on this device;
  - `tee-e2ee`: attested and end-to-end encrypted (NEAR `provider=near`, Venice `e2ee-*`);
  - `tee`: attested, encrypted only to the gateway (nilAI, NEAR gateway);
  - `no-retention`: a contractual promise only (Venice `private`);
  - `standard`: no claims (Morpheus, AkashML, Venice `anonymized`).
- **Onboarding is links and checks, not account automation** (v1):
  - open the provider's signup and key pages;
  - paste the key, test it with `GET /models`, show the balance where an API or header gives it;
  - explain staking options (DIEM, MOR, NEAR) with links;
  - Venice's API-created limited keys (PRIVATE_ONLY, spend cap) are a later step.
