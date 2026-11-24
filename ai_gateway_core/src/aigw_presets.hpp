#pragma once
// Built-in connector presets (ADR 0001): data, not code. A preset names a provider, where it lives,
// how to get a key and funds, and how private its models are. Facts and sources:
// docs/research-providers.md (2026-11-21). A connector the user adds starts from one of these.
//
// privacy tiers (worst -> best): standard < no-retention < tee < tee-e2ee < local
//   privacy          the connector's default tier for its models
//   privacyField     a dotted path in a /models entry whose value picks the tier via privacyMap
//   standardPrefixes model ids proxied elsewhere (no better than standard whatever the provider is), case-insensitive
//   teePrefixes      the only model ids that keep a TEE tier (case-insensitive); anything else is standard:
//                    a provider's names can't be trusted to be complete, so the list fails safe
//   skipPrefixes     model ids this version can't use (e.g. E2EE-only models: needs the E2EE protocol)
//   nameField        a /models field to show instead of the id (Morpheus ids are hex addresses)
//   experimental     built from the provider's docs but not yet tried with a real key: the view says so
//                    and asks for issue reports
namespace aigw {
inline const char* kPresets = R"json([
  {
    "id": "ollama", "name": "Ollama (this computer)", "kind": "local",
    "baseUrl": "http://localhost:11434/v1", "needsKey": false, "privacy": "local",
    "blurb": "Runs models on this computer. Nothing leaves your machine.",
    "links": { "home": "https://ollama.com", "download": "https://ollama.com/download", "models": "https://ollama.com/library" },
    "steps": ["Install Ollama from ollama.com/download and start it.", "Download a model, e.g. `ollama pull llama3.2` or `ollama pull qwen3`.", "Press Test: the models you pulled appear here."]
  },
  {
    "id": "llamacpp", "experimental": true, "name": "llama.cpp server (this computer)", "kind": "local",
    "baseUrl": "http://127.0.0.1:8080/v1", "needsKey": false, "privacy": "local",
    "blurb": "llama.cpp's llama-server running a GGUF model locally.",
    "links": { "home": "https://github.com/ggml-org/llama.cpp/tree/master/tools/server" },
    "steps": ["Start `llama-server -m your-model.gguf` (port 8080).", "Press Test."]
  },
  {
    "id": "lmstudio", "experimental": true, "name": "LM Studio (this computer)", "kind": "local",
    "baseUrl": "http://localhost:1234/v1", "needsKey": false, "privacy": "local",
    "blurb": "LM Studio's local server.",
    "links": { "home": "https://lmstudio.ai", "docs": "https://lmstudio.ai/docs/app/api/endpoints/openai" },
    "steps": ["In LM Studio, load a model and start the server (Developer tab).", "Press Test."]
  },
  {
    "id": "venice", "name": "Venice", "kind": "private",
    "baseUrl": "https://api.venice.ai/api/v1", "needsKey": true, "privacy": "standard",
    "privacyField": "model_spec.privacy", "privacyMap": { "private": "no-retention", "anonymized": "standard" },
    "skipPrefixes": ["e2ee-"], "privacyNote": "Per model: no retention (private) or standard (anonymized)", "balanceHeaders": ["x-venice-balance-usd", "x-venice-balance-diem"],
    "blurb": "Private models are not retained (Venice's promise); anonymized ones go to a third party with your identity hidden. TEE and end-to-end encrypted models come in a later version.",
    "links": { "home": "https://venice.ai", "signup": "https://venice.ai/sign-up", "keys": "https://venice.ai/settings/api", "pricing": "https://docs.venice.ai/pricing", "stake": "https://docs.venice.ai/overview/vvv-diem", "x402": "https://docs.venice.ai/guides/integrations/x402-venice-api" },
    "funding": ["USD credits (card or crypto), never expire", "Stake VVV, mint DIEM: each DIEM gives $1 of inference a day", "x402: top up a USDC balance from a wallet on Base or Solana"],
    "steps": ["Create an account at venice.ai.", "Add credit, or stake VVV for DIEM (daily allowance).", "Settings -> API: create an INFERENCE key (tip: limit it to private models and set a spend cap).", "Paste the key here and press Test."]
  },
  {
    "id": "nearai", "experimental": true, "name": "NEAR AI Cloud", "kind": "private",
    "baseUrl": "https://cloud-api.near.ai/v1", "needsKey": true, "privacy": "tee",
    "teePrefixes": ["deepseek-ai/", "deepseek", "qwen/", "qwen", "zai-org/", "glm", "openai/gpt-oss", "gpt-oss", "meta-llama/", "llama", "mistralai/", "mistral", "google/gemma", "gemma", "moonshotai/", "kimi", "nousresearch/", "hermes"],
    "standardPrefixes": ["openai/", "anthropic/", "google/", "azure", "gpt", "chatgpt", "o1", "o3", "o4", "claude", "gemini", "grok", "x-ai/", "xai/"], "privacyNote": "TEE for the open models it runs itself; standard for anything else (proxied OpenAI/Anthropic/Google and unknown names)",
    "blurb": "Open models run in confidential computing (Intel TDX + NVIDIA H200) behind a gateway that also runs in a TEE; attestation is public. Proxied frontier models (OpenAI, Anthropic, Google) are only as private as their provider.",
    "links": { "home": "https://near.ai", "signup": "https://cloud.near.ai", "docs": "https://docs.near.ai/cloud/", "stake": "https://docs.near.ai/cloud/staking-for-inference/overview.md", "attestation": "https://docs.near.ai/cloud/private-inference.md" },
    "funding": ["Credits (1 credit = $1)", "Stake NEAR: the staking rewards become inference credits"],
    "steps": ["Sign in at cloud.near.ai.", "Buy credits, or stake NEAR for inference credits.", "Create an API key in the dashboard.", "Paste it here and press Test."]
  },
  {
    "id": "nilai", "experimental": true, "name": "Nillion nilAI", "kind": "private",
    "baseUrl": "https://api.nilai.nillion.network/v1", "needsKey": true, "privacy": "tee",
    "blurb": "Models run in a TEE with NVIDIA confidential computing; every answer is signed. Few models.",
    "links": { "home": "https://nillion.com", "signup": "https://developer.nillion.com/nilai", "docs": "https://docs.nillion.com/blind-computer/build/llms/overview" },
    "funding": ["Credits (card via Stripe)"],
    "steps": ["Open the Nillion developer portal and create an account.", "Buy credits and create a nilAI API key.", "Paste it here and press Test."]
  },
  {
    "id": "morpheus", "experimental": true, "name": "Morpheus", "kind": "decentralised",
    "baseUrl": "https://api.mor.org/api/v1", "needsKey": true, "privacy": "standard", "nameField": "name",
    "blurb": "A gateway to the Morpheus inference marketplace (independent providers). No privacy claims at the gateway yet.",
    "links": { "home": "https://mor.org", "signup": "https://app.mor.org", "docs": "https://apidocs.mor.org", "credits": "https://apidocs.mor.org/documentation/getting-started/credits.md" },
    "funding": ["Credits (card or crypto), never expire", "Stake MOR in the API builder subnet for a daily allowance"],
    "steps": ["Create an account at app.mor.org.", "Buy credits or stake MOR; turn on automation.", "Create an API key (shown once).", "Paste it here and press Test."]
  },
  {
    "id": "akashml", "experimental": true, "name": "AkashML (Akash)", "kind": "decentralised",
    "baseUrl": "https://api.akashml.com/v1", "needsKey": true, "privacy": "standard",
    "blurb": "Open models on Akash's decentralised GPU cloud. No privacy claims. (Replaces the Akash Chat API.)",
    "links": { "home": "https://akashml.com", "docs": "https://akashml.com/docs", "pricing": "https://akashml.com/docs/guides/pricing" },
    "funding": ["Credits (card), manual or automatic top-up"],
    "steps": ["Sign up at akashml.com.", "Add credit (an API key needs credit).", "Create an API key.", "Paste it here and press Test."]
  },
  {
    "id": "custom", "name": "Custom (OpenAI-compatible)", "kind": "custom",
    "baseUrl": "", "needsKey": false, "privacy": "standard",
    "blurb": "Any OpenAI-compatible endpoint. Set its privacy tier honestly.",
    "links": {}, "steps": ["Enter the base URL (ending in /v1) and a key if it needs one.", "Press Test."]
  }
])json";
}  // namespace aigw
