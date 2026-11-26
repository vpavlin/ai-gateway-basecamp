# Morpheus over Logos Delivery / Mix: what the code does, what would change

2026-11-26. Source: `github.com/MorpheusAIs/Morpheus-Lumerin-Node` @ `1b0ce5f` (v7.20.0, 2026-11-18). The node
is `proxy-router/` (Go). Its contracts are in `smart-contracts/` (Arbitrum, diamond facets).

## How a request travels today

```
AI Gateway ──HTTP──> api.mor.org (Morpheus API gateway, API key + credits)   ← what our preset uses
                       └─ runs consumer nodes ─┐
consumer node (C-node, proxy-router) ──TCP──> provider node (P-node, proxy-router) ──HTTP──> the provider's LLM
```

**1. Discovery and payment are on-chain (Arbitrum).**
- `ProviderRegistry.providerRegister(provider, amount, endpoint)`: the provider stakes MOR and publishes an
  `endpoint`, a free-form string (`host:port` today).
- `ModelRegistry` and `Marketplace` hold models and bids (price per second).
- `SessionRouter.openSession(user, amount, isDirectPayment, approvalEncoded, signature)`: the user stakes MOR
  for a session, using an approval the **provider signed** (fetched over the wire, see 2). The provider
  claims payment from the session later.

**2. The wire (C-node ↔ P-node) is a small message protocol, not HTTP.**
- `proxyapi/proxy_sender.go`: `net.Dialer.Dial("tcp", endpoint)`. Plain TCP, **no TLS**.
- Messages are JSON objects `{id, method, params}`, decoded with a `json.Decoder` from the stream.
- Methods (`controller_morrpc.go`):
  - `network.ping`, `network.capabilities`;
  - `session.request`: returns the provider's signed approval, used for `openSession`;
  - `session.prompt`, `session.prompt.stream.start` / `.chunk` / `.end`;
  - `session.report`, `agent.call_tool`, `agent.get_tools`, `session.video.create` / `.status`.
- **Integrity and confidentiality come from the messages, not the socket:**
  - every message is signed with the sender's secp256k1 (Ethereum) key, and responses are checked against the
    provider's on-chain address (`VerifySignatureAddr`);
  - responses are ECIES-encrypted to the user's key (`lib.DecryptBytes(message, prKey)`);
  - prompts are ECIES-encrypted to the provider's key when it advertises `prompt-enc:ecies` (a capability).
- **Streaming:** the provider writes chunk messages back on the same TCP connection. The C-node retries,
  fails over to another bid, and keeps TTFT and token stats.
- **Optional TEE attestation** of the provider (`attestation/`).

**3. Ends of the chain:**
- The P-node calls the provider's own OpenAI-compatible backend (`aiengine/`). It is an ordinary local HTTP
  call; the provider sees the plaintext prompt unless the model runs in a TEE.
- The C-node offers consumers a local OpenAI-style HTTP API: it opens sessions, sends prompts, streams back.

## What this means for a P2P transport

**The good news:** the protocol is already **transport-agnostic in spirit**.
- Messages are self-contained, signed, mostly end-to-end encrypted, and identified by on-chain addresses,
  not by the socket.
- TLS was never relied on. Carrying the same bytes over Logos Delivery loses nothing they have today.

**What changes with Delivery** (pub/sub with relays, not a socket):

| Need | TCP today | Over Delivery |
|---|---|---|
| Addressing | `endpoint` host:port from the registry | a content topic per provider, derived from its address (e.g. `/morpheus/1/p-<addr>/proto`); no registry change needed |
| Request ↔ response | one connection | a request id + the consumer's reply topic in each frame |
| Streaming | many small writes | chunks **batched** (~0.5-1 s) into one message each; ordered by a sequence number |
| Size | unbounded stream | 150 KiB per message: fine for chat; long answers are split |
| Rate | none | **RLN: ~100 messages / 10 min per node** on logos.test. One streamed answer ≈ 10-30 messages, so a provider serving many users needs RLN-off (dev) or several memberships (see `logos-rln-budget`) |
| Reachability | the provider needs a public IP and an open port | **none needed**: NAT-ed providers become reachable, which is a real win for home GPUs |
| Latency | ms | relay hops add ~0.2-1 s TTFT; fine for chat |

**Privacy, honestly:**
- **Delivery hides IPs from each other only partly** (relays see them), and the **on-chain session already
  links the user's wallet to the provider**. Transport privacy alone gains little while payment is per-user
  on-chain.
- Real unlinkability needs the payer to differ from the user: a pool or relay that opens sessions, plus
  blind-signed tokens. This is the x402 / exit discussion in `research-private-relay.md`.
- **Mix:** one packet each way (~3.2 KB up, ~3.9 KB back). Fine for `network.ping` / `session.request` and
  small prompts, but **not** for long prompts or streamed answers until Mix supports multi-packet replies
  (SURBs). You said Mix waits; this agrees.

## The cheapest path: a bridge, no Morpheus code changes

**Provider side, a sidecar ("p-bridge")** next to an unmodified P-node:
1. Subscribes to `/morpheus/1/p-<provider addr>/proto` on Logos Delivery.
2. For each request frame `{reqId, replyTopic, seq, bytes}`, it opens (or reuses) a TCP connection to the local
   P-node and writes the exact MOR-RPC bytes.
3. It reads the response messages and publishes them to `replyTopic`, batched, with sequence numbers.

Its parts:
- the P-node's own signatures and encryption pass through untouched; the bridge can't read encrypted prompts
  or answers;
- run on a provider's box: a Go or C++ process; liblogosdelivery has a C API, so Go via cgo, or a headless
  logosctl module;
- the provider keeps its TCP endpoint too, so normal consumers are unaffected.

**Consumer side**, either:
- **(a) A "c-bridge" for an unmodified C-node:** a local TCP listener per provider that forwards over Delivery.
  The C-node dials the registry's `endpoint`, so it would need an endpoint override (a hosts entry or a small
  patch: `logos://` endpoints → the local bridge). That's simple, but the user still runs the Go C-node with
  an Arbitrum wallet holding MOR and ETH.
- **(b) AI Gateway speaks MOR-RPC itself:** a Morpheus P2P connector in `ai_gateway_core` (C++), which would
  need:
  - secp256k1 signing (we have it in WhisperBox and loam);
  - ECIES as go-ethereum implements it (`crypto/ecies`: secp256k1, AES-128-CTR + HMAC-SHA256);
  - the message set above;
  - **Arbitrum calls** to discover bids and open/close sessions (an RPC endpoint, an MOR approve, a signed
    `openSession` transaction).

  It's the bigger job (weeks), and puts a wallet in the gateway.

## What would need to change, by party

- **Morpheus (nothing required for the bridge).** Nice-to-haves:
  - a registry convention for P2P endpoints (`logos://…`), so C-nodes can dial them natively;
  - making `prompt-enc:ecies` mandatory, so relays never see prompts;
  - a chunk-batching option for streaming.
- **Providers:** run the p-bridge next to their P-node, and opt in by announcing it.
- **Us:**
  - the p-bridge (small; the reusable part);
  - a consumer route: (a) bridge + a local C-node behind AI Gateway's Custom connector (prototype in days), or
    (b) native MOR-RPC in the core (weeks; needs wallet decisions);
  - a test network with RLN off for development.

## Recommendation

1. **Prototype (a)** on a private Delivery network: one P-node + p-bridge; a C-node with a `logos://` endpoint
   override + c-bridge; AI Gateway pointed at the C-node's local API. This proves streaming, retries, latency
   and NAT-ed providers.
2. **Talk to Morpheus** about the `logos://` endpoint convention and mandatory prompt encryption. Both are small
   on their side.
3. **Privacy beyond transport waits for payment unlinkability and Mix.** Without those, P2P transport buys
   reachability and censorship-resistance, not anonymity.

Unverified: I read the code; I didn't run a C-node or P-node, or open a session on Arbitrum.
