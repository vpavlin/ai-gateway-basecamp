# ADR 0003: What the 2026-11-24 security review changed

Status: accepted, 2026-11-24 (core 0.1.4, view 0.1.6). Review: proteus/auditor, 20 findings (3 high, 7 medium,
6 low, 4 info) against core 0.1.2 / view 0.1.4, each with a loopback probe.

## The rule behind the fixes

Basecamp 0.3 does not tell a core module **which module is calling it**, and module events are visible to
**every** module. The core can't tell its own view from another app. So:
- nothing a caller can read may be a secret it shouldn't hold;
- no secret may travel in an event;
- whatever any caller can change must not be able to move the user's keys.

## Fixed

| ID | What changed |
|---|---|
| AIGW-1 (high) | A stored API key is bound to the **origin** (scheme, host, port) it was saved for. Moving a connector to another origin forgets the key unless a new key comes with the move (`keyCleared` in the answer; the view tells the user). |
| AIGW-2 (high) | `sessions()` returns a 12-character **handle**, never the session id. A handle can only close a session (the user's End button), never read or continue it. |
| AIGW-3 (high) | `jobUpdate` carries only `{id: watchId, state}`. The answer is read with `job(jobId)`. The job id is 128 random bits and goes only to the caller, which also gets a public `watchId`. The view polls `job()` while a job runs (400 ms) and at once on an event. |
| AIGW-4 | Token counts from a provider are read as integers in [0, 10⁹]; anything else counts as 0. No more `type_error` abort. |
| AIGW-5 | The local endpoint reads `stream` only as a real boolean, and every request is handled inside a try/catch (a 500, not an abort). |
| AIGW-6 (part) | "On this device" (`local`) is only true for a loopback URL. A custom connector elsewhere can't claim it, and a preset local runtime pointed at another host is standard. |
| AIGW-7 | Limits: `/models` body 8 MiB, 5,000 models, ids and names up to 256; chat body on the wire 16 MiB; the assembled answer 8 MiB; an SSE line 1 MiB; a whole answer 15 minutes. SSE is parsed with an offset (no O(n²)). |
| AIGW-8 | Model-name rules are case-insensitive. NEAR keeps the TEE tier only for a **positive list** of open models it runs itself (`teePrefixes`); everything else, including unknown names, is standard. |
| AIGW-9 | The `ai.session` consent shows the **whole** document (scrolling), exactly what is sent. |
| AIGW-10 | Every `Text` in the view is `Text.PlainText`: provider model names, errors, balance headers and app names can't render rich text or fetch images. |
| AIGW-11 | Local endpoint: `Host` must be 127.0.0.1/localhost on its port; any `Origin` is refused; the request must arrive within 30 s; at most 32 connections. |
| AIGW-12 | A stream that ends without `[DONE]` or a `finish_reason`, or with a network error, is an error ("the answer was cut off"), not `done`. |
| AIGW-13 | A chat request is capped at 4 MB and a session turn at 1 MB. History trimming may drop every old turn. |
| AIGW-14 | `load()` validates every connector and setting field: bad entries are dropped, an unknown tier becomes standard, and the port must be 1024-65535. |
| AIGW-15 | The key mask shows only the last 4 characters, and only for keys of 20 or more characters. |
| AIGW-16 | The temp file is created 0600 with `O_EXCL` before any byte is written. The data dir is 0700 on every path, including `AIGW_CORE_DATA`. |
| AIGW-17 | Random ids, capabilities and tokens come from `QRandomGenerator::system()`. |
| AIGW-18 | The view opens preset links only if they are http(s). |
| AIGW-20 | A local-endpoint request with tools is answered whole, even if it asked to stream. |

Each fix has a test in `ai_gateway_core/test/core_test.cpp` ("security (review 2026-11-24)") or in the view
harness.

## Accepted, documented limits

- **Any module can change settings and connectors** (AIGW-6, the remainder). It can lower the global privacy
  floor, add a remote custom connector with a declared tier (not `local`), remove connectors, and turn on or
  rotate the local endpoint.
  - It can no longer move a stored key (AIGW-1) or fake "on this device".
  - The real fix is platform caller identity, so that configuration is accepted only from AI Gateway's own
    view. This is an upstream ask.
- **The session is consent once, not per turn** (ADR 0002). The session's app can send any message, and
  replace the document, until the session ends.
- **TEE tiers are the provider's claim** until attestation checks exist.
