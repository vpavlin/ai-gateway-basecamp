# Morpheus × Logos: a private, peer-to-peer transport for decentralised inference

*A proposal from the Logos Basecamp AI Gateway project, November 2026.*

## In one paragraph

Morpheus already has what a decentralised inference market needs: on-chain providers and bids, staked
sessions, signed messages and encrypted answers. What it lacks is a **network layer that matches**. Today a
consumer finds providers through a chain indexer, then connects straight to each provider's public `host:port`
over plain TCP, which leaves three gaps:
- every provider it merely checks learns its IP;
- only machines with a public IP can be providers;
- confidentiality depends on per-provider capabilities.

**Logos Delivery** is a peer-to-peer messaging network: encrypted, relay-based and censorship-resistant. **Logos
Mix** adds sender anonymity on top. Together they can carry Morpheus's existing messages unchanged, and **Logos
Basecamp**, the Logos desktop app platform, brings Morpheus to its users through the AI Gateway.

## How Morpheus works today (from `Morpheus-Lumerin-Node`)

| Step | Today | What it reveals |
|---|---|---|
| Discover providers | read the Base chain (registry, bids) via an RPC node or indexer | the indexer sees what you look for |
| Compare providers | direct TCP to each `host:port`: ping, capabilities | every provider you check sees your IP |
| Get a session approval | direct TCP `session.request` | the provider links your IP to your wallet |
| Open the session | on-chain transaction, MOR staked | wallet ↔ provider, public |
| Prompts and answers | direct TCP; signed messages, answers encrypted to the consumer, prompts encrypted when the provider supports it | the provider sees your IP; transport confidentiality varies per provider |

**The good news:** Morpheus messages are self-contained. They are signed with on-chain keys, encrypted with
ECIES, and identified by addresses, not by the socket. So they can travel over any transport with nothing lost.

## Why Logos Delivery is the right transport

1. **It matches Morpheus's trust model.** Morpheus already authenticates and encrypts at the message level.
   Delivery is built for exactly such messages: no server to trust, no TLS certificates, no fixed endpoints.
2. **Live, gas-free provider discovery.** Providers announce models, prices, capacity, health and TEE
   attestations on a Delivery topic, signed with their on-chain key. The chain stays the source of truth for
   stakes and sessions; Delivery carries what changes by the minute, without a transaction per update.
3. **Private comparison shopping.** Consumers find providers by *listening*, which reveals nothing. Pings,
   capability checks and approval quotes go over Delivery, so a provider learns who you are only when you choose
   it. Check ten providers, and the nine you skip learn nothing.
4. **Confidential by construction.** Over Delivery every request is sealed to the provider's key. Prompt
   encryption becomes the default for every provider, never a per-provider option.
5. **Providers without a public IP.** When answers stream over Delivery (or over dedicated relays), a provider
   needs no open port. **Home GPUs and machines behind NAT can join the market:** more supply, more
   decentralisation.
6. **Censorship resistance.** There's no public list of provider IPs to block or attack.
7. **A path to real anonymity.** Logos Mix hides *who is asking* from the network itself. Combined with
   payments the consumer's wallet doesn't make directly (pooled or delegated sessions paid with blind tokens),
   it can break the on-chain link between a user and the provider they use. Morpheus's existing delegation is
   a starting point.

## What Logos brings to Morpheus

- **A transport and anonymity layer** (Delivery, then Mix) that Morpheus doesn't have to build or run.
- **Users:** Logos Basecamp's AI Gateway lists Morpheus next to local models and other private providers.
  - Any Basecamp app (documents, forms, voice assistant) can use it through one consented interface.
  - Each request is labelled with its privacy tier, and the user's own privacy floor is enforced.
- **Supply:** NAT-ed and home providers, once answers stream peer-to-peer.
- **A credible privacy story:** "private AI" end to end, from the client app through transport to payment.

## What Morpheus brings to Logos

- A real, paying, non-chat workload on Delivery and Mix, which shapes their design (message sizes, streaming,
  rate limits).
- A decentralised inference market for every Basecamp user, without central API keys.

## Roadmap

1. **A bridge, no Morpheus changes.**
   - A small sidecar next to a provider node listens on the provider's Delivery topic, derived from its
     address, and passes the exact Morpheus messages to the local node. It can't read them; they stay signed
     and encrypted.
   - The consumer side runs inside Basecamp.
   - Proven first on the Base Sepolia testnet with our own provider.
2. **The control plane on Delivery:** discovery announcements, ping, capabilities and session approvals.
   Answers still stream directly from public-IP providers.
3. **The data plane on Delivery or dedicated relays:** NAT-ed providers can serve, and consumers' IPs stay
   hidden from providers.
4. **Mix plus payment unlinkability:** anonymity for consumers.

**Small asks of Morpheus along the way:**
- an endpoint convention in the provider registry for peer-to-peer providers (for example `logos://…`), so
  consumer nodes can reach them natively;
- prompt encryption as the default for every provider;
- a test-MOR drip on Base Sepolia, so the prototype runs without mainnet tokens.

## Contact

Václav Pavlín, Logos. The prototype code is open source: `github.com/vpavlin/ai-gateway-basecamp`. The detailed
technical research is in `docs/research-morpheus-p2p.md` there.
