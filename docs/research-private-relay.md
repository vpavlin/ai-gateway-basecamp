# Research: relaying inference privately, and paying for it (2026-11-21)

The question: can this module make private or "private-ish" AI providers more private by routing a
user's request through other users' nodes, so the provider can't tell who asked? And who pays, when
an API key can't travel with the request?

## 1. Why not just forward a key

A key that travels in the request can be read by every hop and reused, or simply stolen. So the
options are:

- **(a) the exit pays:** the last node uses its own key or balance and is paid back somehow;
- **(b) the payment travels:** a per-request payment bound so that hops can't misuse it;
- **(c) the payment is an anonymous token:** prepaid, unlinkable to whoever bought it.

## 2. x402: what it binds and what a relay can do

Sources: the x402 v2 spec (2025-12-09),
https://github.com/coinbase/x402/blob/main/specs/x402-specification-v2.md; the HTTP transport,
https://github.com/coinbase/x402/blob/main/specs/transports-v2/http.md; the exact EVM scheme,
https://github.com/coinbase/x402/blob/main/specs/schemes/exact/scheme_exact_evm.md.

- **Flow:**
  1. The server answers 402 with `PAYMENT-REQUIRED`: `accepts[]` with scheme, network, amount,
     asset, payTo and timeout.
  2. The client retries with `PAYMENT-SIGNATURE`. On EVM this is EIP-3009
     `transferWithAuthorization` signed with EIP-712; on Solana, a partially signed transaction.
  3. The server calls the facilitator to verify, runs the handler, then settles.
- **What the signature covers:** token, chain, from, **to (payTo)**, value, validity window, and a
  client-chosen nonce. It does **not** cover the request body, method or URL.
- **What a relay that can read the header can and can't do:**

  | Attack | Possible? |
  |---|---|
  | Redirect the funds to itself | **No** (payTo is signed) |
  | Double-spend | **No** (the nonce is single-use, the window short) |
  | Attach your payment to its own prompt | **Yes**: LLM requests share one URL and nothing binds the payment to the prompt |
  | Grief (burn the nonce first; you pay and get nothing) | **Yes** on EVM `exact` |

- **Metered schemes exist:**
  - `upto`: sign a maximum, settle the actual token cost after the reply. It names "paying for
    LLM token generation" as a use case and binds payTo and the facilitator.
    https://github.com/coinbase/x402/blob/main/specs/schemes/upto/scheme_upto.md
  - Batch settlement, payment channels and auth-capture are also specified.
- **Who accepts it today:**
  - Venice: x402 only tops up a prepaid balance, and every request is signed by the wallet, so
    requests are linkable to it.
  - Cloudflare AI Gateway (`upto`, four open models):
    https://developers.cloudflare.com/ai-gateway/features/machine-payments/
  - Several x402 routers (Daydreams, BlockRun) and Secret Network's confidential LLMs.
  - Not found for Morpheus, NEAR AI, Nillion or AkashML.
- **Verdict.** x402 alone is safe against theft but not against **substitution**. It works for
  relaying only if:
  - the hops can't read the payment, because the whole request is end-to-end encrypted to the
    provider or its TEE gateway (the next section); or
  - the nonce is set to `H(request ‖ salt)` and the provider checks it (a convention no provider
    implements yet).

## 3. Hiding who asks: prior art

- **Oblivious HTTP** (RFC 9458, https://www.rfc-editor.org/rfc/rfc9458):
  - the client HPKE-encrypts the whole inner HTTP request, headers included, to a *gateway* key;
  - a *relay* sees the client's IP and only ciphertext;
  - the gateway sees the plaintext and only the relay's IP.

  That split is exactly the property wanted here, and it also hides a payment header from the relay.
- **Deployed for AI:**
  - Apple Private Cloud Compute: third-party OHTTP relays, attested nodes, RSA blind-signed
    single-use request tokens. https://security.apple.com/blog/private-cloud-compute/
  - Azure confidential inferencing: an OHTTP proxy in front of confidential GPUs.
  - Brave Leo: OHTTP into a NEAR AI TEE.
  - OpenGradient: OHTTP into a gateway inside the TEE.
- **Limit** (Tinfoil, https://tinfoil.sh/blog/2025-05-10-ohttp): OHTTP hides *who* asks; *what* is
  asked is protected only by the provider's TEE and attestation.
- **Unlinkable payment:** pay once (x402, card, staking) for N **blind-signed tokens** (Privacy Pass,
  RFC 9576/9578), then spend one per request. The provider can't link a request to the purchase.
  Amount and timing still leak a little.

## 4. Logos building blocks (logos-delivery source at 7a3a064b, 2026-07, and the LIP specs)

**Mix (LIP-99, https://lip.logos.co/ift-ts/raw/mix.html; still "raw").**
- Sphinx packets are a fixed 4608 bytes, with **3962 bytes of payload** each; 3-hop routes.
- Replies use SURBs (734 bytes each), but **one reply packet per request**: the first reply deletes the
  other SURBs. So a round trip carries about 3.2 KB up and about 3.9 KB back. There is no
  reassembly; that is left to the application.
- The **exit is the destination** (the server must run Mix), and Mix nodes are IPv4 only.
- Latency: about 100 ms mean per hop with mixing on, plus an RLN proof per hop (LIP-144).
- In logos-delivery, Mix carries Lightpush behind an experimental flag. The reply is the push status
  only.

**Delivery / Waku.**
- Messages up to 150 KiB, so an LLM request and reply fit.
- There is **no request/response protocol to a chosen peer**. The pattern is a request topic plus a
  per-request reply topic, encrypted to an ephemeral key.
- That hides the *content* from everyone but the exit. It does **not** hide the sender's IP from the
  relay peers it publishes through, or the reader's IP from the Filter or Store node that serves the
  reply.
- Every message counts against RLN (about 100 per 10 min per node, shared by every app).

**Paying services anonymously in Logos.**
- Waku service incentivisation is a PoC; its txid proofs link users.
- The ZK-ticket design for Store (https://forum.vac.dev/t/zk-based-ticket-system-for-store-service-incentivization-mvp/565)
  is the right model, but it isn't shipped.

**Prior art.**
- Nym "Pay as You Go" for AI agents: zk-nym tickets plus a 5-hop mixnet, early R&D,
  https://nym.com/blog/nym-private-agent-access
- HOPR RPCh (RPC over a mixnet, the same shape): https://hoprnet.org/rpch
- Research: funion (https://arxiv.org/abs/2505.18398) and PlanetServe
  (https://arxiv.org/pdf/2504.20101).

**What this means.**
- *Today:* an exit relay over delivery, with app-level encryption to the exit and the reply on a
  per-request topic. It hides who asks from the **provider** and the content from everyone but the
  exit. It doesn't hide the user's IP from nearby relay peers.
- *With Mix:* small prompts (≤ 3 KB) to an exit that runs Mix, with one reply packet. Longer replies
  need multi-SURB replies, which means upstream work in `libp2p_mix`.
- *Payment:* exit-issued blind tokens (Privacy Pass style) bought with x402 or tokens. Logos'
  ZK-ticket work is the long-term fit.

## 5. A design sketch for later (not v1)

Two stages, each useful on its own.

- **Stage A, "exit relay" over Logos (no provider changes):**
  1. The user's gateway encrypts the request to an **exit node's** key and sends it through Logos
     (Mix when it's deployable; for now delivery with a per-request ephemeral identity).
  2. The exit forwards it to the provider with **its own** key or balance, encrypts the reply back,
     and is paid by the user.
  - What each party learns:
    - the provider sees the exit, never the user;
    - the exit sees the prompt (unless the provider does E2EE to its TEE: Venice `e2ee-*`, NEAR),
      but not who sent it (behind Mix);
    - hops see ciphertext.
  - **Paying the exit:** prepaid blind tokens the exit issues (Privacy Pass style), bought with x402
    or tokens.
  - **The exit is a trusted party.** It can read prompts unless E2EE, log them, or overcharge. That is
    why stage B matters.
- **Stage B, E2EE through the exit:**
  - The gateway encrypts the inference payload to the provider's TEE key, which it verifies first by
    attestation (Venice and NEAR already publish both the report and the key). The exit then only
    attaches *its* payment or key and forwards ciphertext. It can't read the prompt or the answer.
  - With x402 `upto` or exit tokens, nobody in the path ever holds the user's key.
  - This is the OHTTP + TEE pattern (Apple PCC, Brave Leo), with the exit as the OHTTP relay and
    Logos in front of it hiding the user's IP even from the exit.
