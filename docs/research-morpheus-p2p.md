# Morpheus over Logos Delivery / Mix: what the code does, what would change

2026-11-26. Source: `github.com/MorpheusAIs/Morpheus-Lumerin-Node` @ `1b0ce5f` (v7.20.0, 2026-11-18). The node
is `proxy-router/` (Go). Its contracts are in `smart-contracts/` (a diamond, ~1,900 lines of core Solidity).

**Chain correction (checked 2026-11-26):** Morpheus runs on **Base**, not Arbitrum.
- Mainnet: chain 8453, diamond `0x6aBE1d28…3030a`, MOR `0x7431aDa8…2b8e3`.
- **Testnet: Base Sepolia**, chain 84532, diamond `0xA328196f…c27c85`, MOR `0x5C80Ddd1…FfA3`.
- Their docs point to a Base Sepolia faucet for test ETH, but say nothing about getting test MOR.

## How a request travels today

```
AI Gateway ──HTTP──> api.mor.org (Morpheus API gateway, API key + credits)   ← what our preset uses
                       └─ runs consumer nodes ─┐
consumer node (C-node, proxy-router) ──TCP──> provider node (P-node, proxy-router) ──HTTP──> the provider's LLM
```

**1. Discovery and payment are on-chain (Base).**
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
  - **Base (EVM) calls** to discover bids and open/close sessions (an RPC endpoint, an MOR approve, a signed
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

Unverified: I read the code; I didn't run a C-node or P-node, or open a session on chain.

## Design round 2 (2026-11-26, with Václav)

**1. Connectors as Basecamp modules, not code inside AI Gateway.**
- A provider that needs its own protocol (Morpheus, later others) becomes its own core module that AI Gateway
  calls. `ai_gateway_core` stays a router with privacy rules, consent and UI.
- A connector module implements a small contract, **`ai-connector/1`**, the same shape as `ai-session/1`:
  - `describe()` → `{name, privacy, needsSetup, setupHints}`;
  - `models()`;
  - `chat(requestJson)` → `{jobId}`, then `job`, `jobDelta`, `cancel`.
- AI Gateway discovers connector modules by name (a module that `provides` a connector marker, or a list in
  settings). It calls them like Fileverse calls the gateway; Basecamp 0.3.2 allows calling an undeclared core.
- The built-in llama.cpp model planned from Basecamp Voice's code fits the same shape (`local_llm_core`), as do
  any future providers.
- `morpheus_core` options:
  - (a) supervise Morpheus's own Go proxy-router as a child process and talk to its local consumer API (fast to
    build, pinned binary, like the llama-server plan);
  - (b) later, speak MOR-RPC natively.
- The wallet should come from a wallet module (Keycard or a LEZ/EVM wallet module), not live inside the
  connector.

**2. A full loop on the testnet with our own model.**
- Run **our own provider**: a P-node in front of Ollama on a box we control, registered on Base Sepolia.
- Basecamp is the consumer. Inference is free, and only test tokens move.
- Test MOR: either ask Morpheus for a test MOR drip, or **redeploy their contracts** on Base Sepolia (or a
  local Anvil chain) with our own mintable MOR. The repo has the Hardhat deploy; the core Solidity is about
  1,900 lines (SessionRouter 561, Marketplace 161, registries, delegation).
  - Then point C-node and P-node at our diamond and MOR addresses (env `DIAMOND_CONTRACT_ADDRESS`,
    `MOR_TOKEN_ADDRESS`, `ETH_NODE_CHAIN_ID`).
  - That's the fastest path with zero dependence on them.
- **LEZ port:** the logic is small (registry, bids, staked sessions with claims). Porting it to LEZ programs
  (RISC0/Rust, a different account model) is a real but bounded project.
  - The catch: proxy-router speaks EVM through go-ethereum, so it would need a chain adapter too.
  - A good second track after the EVM-testnet loop works; not the first step.

**3. Control plane over Delivery, data plane direct.**
- **Control plane over Logos Delivery:** discovery hints, ping, capabilities, `session.request` / signed
  approval, key exchange.
  - A handful of messages per session, well inside an RLN budget.
- **Data plane, the prompt and the streamed answer, over a direct connection:**
  - **Public-IP providers already work:** today's registry `endpoint` is a public `host:port`, and the C-node
    dials it directly, so plain direct TCP needs no new transport.
  - **What libp2p adds:** NAT traversal (hole punching / DCUtR) for providers at home, Noise-encrypted
    connections bound to a peer id, and **circuit relays** when punching fails.
  - The Logos stack already ships a `libp2p_module` (delivery_module lists it as an optional dependency);
    its API is to be checked.
- **Relays:** libp2p circuit relay v2 defaults cap a relayed connection at 128 KiB / 2 min. That's the same
  limit that broke NAT↔NAT Storage transfers (memory `storage-relay-batch-limit`). So AI streams need
  **dedicated relays with raised limits**, run by us or by providers.
  - These are not Waku relays, so RLN doesn't apply.
- **This avoids RLN for the bulk traffic. Trade-off:**
  - a direct connection shows the consumer's and the provider's IPs to each other;
  - a relay hides them from each other but not from the relay.
  - Anonymity stays a Mix + payment-unlinkability question.

**Suggested order:**
1. `ai-connector/1` + `morpheus_core` supervising a pinned proxy-router.
2. Our own contracts + our own P-node on Base Sepolia or Anvil.
3. A control plane over Delivery with the p-bridge.
4. A direct libp2p data plane with dedicated relays.
5. A LEZ port, as research.

## Decisions (2026-11-26, Václav)

- **Connector modules are listed as `optional_dependencies` of `ai_gateway_core`** (the known ones). The user
  installs the ones they want; AI Gateway probes each with an async call (empty or error = not installed), like
  WhisperBox does with loam_core.
  - Calling undeclared modules works in Basecamp 0.3.2 but may be blocked later for security, so don't build
    on it.
- **"Our own Morpheus node"** means we run a Morpheus provider ourselves (a P-node in front of our own model)
  and, as needed, a consumer node: a full testnet marketplace loop we control. It does NOT mean reworking the
  Ollama/llama.cpp connectors.
- **Transport:**
  - for providers with a public IP, the direct TCP Morpheus uses today is enough: messages are already signed
    and encrypted, so libp2p adds little there;
  - libp2p (hole punching, relays) only matters for providers behind NAT;
  - Delivery for the control plane now; whether the data plane can also go over Delivery waits for the future
    RLN limits. The transport stays swappable.

## Positioning: what Delivery gives, even before RLN is settled (2026-11-26)

**Today's flow, and what each step reveals:**

| Step | How | Who learns what |
|---|---|---|
| Find providers | read the chain (Base): `ProviderRegistry` endpoints, `Marketplace` bids, via an RPC node or blockscout | the RPC/indexer operator sees what you look up |
| Check a provider | direct TCP to its `host:port`: `network.ping`, `network.capabilities` | the provider and any network observer see your IP probing it |
| Get an approval | direct TCP `session.request` (names your wallet) | the provider links your IP + wallet |
| Open a session | `SessionRouter.openSession` transaction | **public forever:** your wallet ↔ provider ↔ stake |
| Prompts / answers | direct TCP; answers ECIES-encrypted to you; prompts encrypted when the provider advertises `prompt-enc:ecies` | transport confidentiality varies per provider |

**Security note:** shared with Morpheus directly, not in this public document.

**With Delivery for the control plane only (data still direct):**

For Morpheus:
1. **Live discovery without gas:** providers announce models, prices, capacity, health and TEE attestations on
   a topic, signed by their on-chain key. Consumers browse by listening, which says nothing about them; there
   is no RPC query to log. The chain stays the source of truth for stakes and sessions.
2. **Private comparison shopping:** ping, capabilities and approval quotes go over Delivery, so the provider
   sees no IP until you choose it. You can probe ten providers and reveal nothing to the nine you don't pick.
3. **Encrypted by construction:** Delivery carries the ECIES-sealed, signed messages, so the control plane is
   encrypted end to end for every provider.
4. **Censorship resistance for the control plane:** there's no fixed endpoint list to block.

**What it does NOT give while the data plane is direct and payment is on-chain:**
- Once you use a provider, it sees your IP (direct connection).
- The chain links your wallet to it.

So control-plane Delivery protects browsing, not usage.

**What the full benefit needs** (the roadmap pitch to both):
- **The data plane over Delivery or dedicated relays:** NAT-ed providers can serve (home GPUs, a supply-side
  win for Morpheus), and the provider never sees the consumer's IP. Needs the RLN answer.
- **Payment unlinkability:**
  - Morpheus already has delegation (`_validateDelegatee`), but the session still names the user;
  - a pool/relay that opens sessions and is paid with blind tokens breaks the wallet↔provider link
    (`research-private-relay.md`).
- **Mix,** for sender anonymity once it carries bigger messages.

**For Logos:**
- a real, non-chat workload on Delivery (and later Mix) with paying users;
- concrete RLN sizing data for streaming;
- Basecamp as a first-class Morpheus client (via AI Gateway), and a privacy story ("private AI") that only
  the Logos stack can tell end to end.

## The contracts, and Morpheus on more than one chain (2026-11-26)

**What the contracts do** (`smart-contracts/contracts`, one diamond; ~1,000 lines of facet logic plus ~400
of storage and ~275 for `ProvidersDelegate`):
- `ProviderRegistry` (106 lines): register / deregister with a MOR stake, and the `endpoint` string.
- `ModelRegistry` (103): register models with a stake.
- `Marketplace` (161): providers post bids (price per second) per model; bid fees.
- `SessionRouter` (561), the heart:
  - `openSession` checks a **provider-signed approval** (ECDSA, `ecrecover`), which binds **bid id, chain id,
    user, timestamp**, so approvals can't be replayed on another chain;
  - `closeSession` with a provider-signed receipt (disputes put part of the reward on hold);
  - provider claims; user stake withdrawals.
- **Two payment modes:**
  - **direct:** the user's stake pays `pricePerSecond × duration` to the provider;
  - **stake-for-compute:** the user stakes MOR and gets a daily budget
    (`stakeToStipend = stake × computeBalance / (totalMORSupply × 100)`). The provider is paid from a
    **compute pool funded by MOR emissions** (`LinearDistributionIntervalDecrease`). The user's stake comes
    back (locked until the day's epoch ends).
- `ProvidersDelegate`: lets MOR holders stake behind a provider and share its rewards.

**Multi-chain today: one chain per deployment, one chain per node.**
- The node is configured with exactly one `ETH_NODE_CHAIN_ID`, one `ETH_NODE_ADDRESS` (RPC) and one
  `DIAMOND_CONTRACT_ADDRESS`. Mainnet (Base) and testnet (Base Sepolia) are separate deployments selected by
  config.
- Approvals carry the chain id, so the design already expects **parallel deployments, not one cross-chain
  market**. A provider registers, stakes and bids on each chain separately.
- A node serving two chains would need to run twice, or gain multi-chain config.
- All chain access in the node goes through go-ethereum (contract bindings, events, transactions). Any
  **EVM** chain is a redeploy plus config. A **non-EVM** chain is not.

**Porting to LEZ:**
- The logic is small and self-contained (registries, bids, sessions, claims, stake-for-compute arithmetic).
  As LEZ programs (RISC0 guests, Rust) it's a bounded job:
  - **Signatures:** provider approvals and receipts are secp256k1/ECDSA from Ethereum keys; verifying them in
    a RISC0 guest is fine (`k256`). LEZ accounts use BIP-340 keys, so a provider has both.
  - **MOR on LEZ:** a LEZ token, bridged or a test token. The **compute pool funded by emissions** is an
    economic/governance question for Morpheus (who funds the pool on LEZ?), not a code question. Direct
    payment mode needs no pool and is the natural first target.
- **The node is the real work.** It speaks EVM everywhere, so LEZ needs a chain-adapter layer in proxy-router:
  reads, transactions and events for the same operations. That's a meaningful change on their side, or ours as
  a fork.
- **Why LEZ could be worth it, the part transport privacy can't fix:** today `openSession` publicly links the
  user's wallet to the provider. If LEZ private execution can keep the session's user (and amount) private,
  that closes the on-chain link, the biggest remaining leak.
  - **To verify** against LEZ's current privacy model before pitching it; see memory `lez-token-gating-research`.

**Suggested order:**
1. EVM testnet loop first (Base Sepolia, our own deployment).
2. A LEZ port of **direct payment only** as a research spike: registries + bids + sessions + the approval
   check.
3. A chain-adapter interface proposal for proxy-router, a conversation with Morpheus.
