# Open questions for Václav

Work continues on sensible defaults; each question says which default is in use. Answer any time.

1. **Name.** ANSWERED 2026-11-24: keep "AI Gateway" / `ai_gateway_core` / `ai_gateway`; the repo is vpavlin/ai-gateway-basecamp.
   Original question: The working names are `ai_gateway_core` / `ai_gateway` ("AI Gateway") with intents
   `ai.chat` / `ai.ask`. Do you want a product name, like WhisperBox or Zine Press? Renaming before
   the first public release is cheap; afterwards it breaks `uses`.
2. **Intent names.** `ai.chat` (OpenAI messages) and `ai.ask` (prompt + content) are in. Do you also
   want task-shaped intents such as `ai.summarize`, `ai.translate`, `ai.describe_image`, or should apps
   build those from `ai.ask`? Default: the two generic ones.
3. **Images and embeddings.** 0.1 does chat only. Next would be embeddings (for search in
   apps), then images. Default: chat, then embeddings.
4. **Which providers are you talking to,** and is there a contact for each? Venice and NEAR have
   attestation and E2EE APIs we could verify inside the gateway. Partner terms, such as a referral
   code, a Logos-specific key or credits, would change the onboarding. Default: public signup links.
5. **Keys at rest.** A private 0600 file in 0.1. Should the gateway reuse a Basecamp-wide secret store
   if one is coming, or Keycard? Default: the file now, the WhisperBox-style passphrase vault next.
6. **The relay (part two).** Do you want a first experiment now, or design only?
   - Stage A (an exit node forwards with its own key, paid with prepaid tokens) works today over
     delivery.
   - Stage B (E2EE to the provider's TEE through the exit) needs the Venice/NEAR E2EE protocols
     implemented in C++.
   - Real sender anonymity needs Mix, which you said waits.

   Default: design only, plus the `tee-e2ee` direct path once attestation checks are in.
7. **Who runs exits?** Users of the module ("contribute your key or balance"), or a few operators
   (Logos, partners)? This changes the payment design: user exits need unlinkable tokens; operator
   exits can start with a plain prepaid account.
8. **Local endpoint.** Off by default, `127.0.0.1` only, random token. OK, or do you want it on by
   default, or reachable from the LAN (for a home inference box)?
9. **Platforms.** The usual three (amd64, arm64, darwin-arm64), plus an Android app later? Default:
   Basecamp only for 0.1.
10. **Repository and publishing.** ANSWERED 2026-11-24: https://github.com/vpavlin/ai-gateway-basecamp (atlas pushes with a deploy key; CI builds arm64 and darwin).
    Original question: The code is local in `~/ai-gateway` on atlas (2 commits). atlas can
    only push with a per-repo deploy key and can't create repos. Could you (or jimmy-crib/vpavlin)
    create the GitHub repo and add the atlas deploy key? It's needed for:
    - the arm64 and darwin CI builds (the always-three-platforms rule);
    - publishing 0.1.0 to lan03 for testing.

    Default: wait. Nothing is published, and amd64 builds and tests are done locally.
