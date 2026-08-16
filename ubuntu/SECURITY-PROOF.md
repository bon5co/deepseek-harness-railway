# DeepSeek Harness — recorded proof that the control surface is closed

The house rule for shipping an agent image (`railway-template` skill,
`references/nixos-agent-base.md`) is:

> Any agent whose control surface can run shell commands, drive a browser, or control a device
> turns a public Railway URL into remote code execution on the deployer's account. [...] the auth
> proxy is not an optional differentiator on these images; it is the thing that makes them
> publishable at all. Prove it with a recorded unauthenticated request that gets refused, and keep
> the proof next to the template.

This file is that proof. Re-run it with `scripts/verify-deepseek-harness.sh <image> <name> <port>`
before any republish that changes the image.

## Why this template needs it more than most

DeepSeek Harness has **no authentication at all**, and upstream says so itself —
`packages/host/webserver/README.md`, Known Limitations:

> No TLS, auth, or origin policy — binding a non-loopback address exposes the server to that
> network; deployment hardening (or fronting it with a real reverse proxy) is deliberately out of
> scope for the dev-facing v1.

The `/api` "trust fence" (`packages/client/connection/src/api-request-trust.ts`) is a
DNS-rebinding defense, not a gate, and disclaims the role in its own comments:

> Network reachability and authentication stay out of scope: binding policy belongs to the
> webserver config, and this fence is not an auth layer.

Accordingly the CLI refuses to bind the world:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code
execution to the network; use 127.0.0.1 instead
```

That refusal **is defeatable** — the webserver's own schema still accepts `0.0.0.0`, so a
`--patch` overlay would bind it. This template deliberately does not do that. `dsh` stays on
loopback and Caddy owns the public port.

## Result — Ubuntu flavor, 16/16

Run 2026-08-16 against `dsh-ubuntu:test`, container capped at 1 GB (Railway Trial).

```
  container: status=running oom=false exit=0
  memory:    164.4MiB / 1GiB
-- auth gate (the release condition) --
  PASS  unauthenticated GET /                          401
  PASS  unauthenticated GET /api/session.export        401
  PASS  unauthenticated GET /api/users                 401
  PASS  forged loopback Host header                    401
  PASS  wrong password                                 401
  PASS  empty password                                 401
  PASS  unauthenticated WebSocket upgrade              401
-- function through the proxy --
  PASS  authenticated GET / (UI)                       200
  PASS  healthcheck path, unauthenticated              200
  PASS  authenticated API w/ public Origin             400
  PASS  authenticated WebSocket upgrade                101
-- dsh must not be reachable off loopback --
  PASS  dsh bound to 127.0.0.1:3080 only               yes
  PASS  dsh NOT bound to 0.0.0.0:3080                  0
-- persistence + shell tool prerequisites --
  PASS  bash present (bash tool contract)              yes
  PASS  DSH_HOME under /home/dsh                       yes
  PASS  sessions dir on the volume path                yes
  ---- dsh-ubuntu:test: 16 passed, 0 failed ----
```

The nix flavor returns the same 16/16 at 135.2 MiB; see `../deepseek-harness-nixos/SECURITY-PROOF.md`.

## The three checks that carry the weight

**"forged loopback Host header" → 401.** An attacker spoofing `Host: 127.0.0.1:3080` to satisfy
DSH's fence still never reaches DSH, because Caddy authenticates before proxying.

**"authenticated API w/ public Origin" → 400, not 403.** This is the positive control, and it is
the reason the Host/Origin rewrite exists. `400 missing or invalid sessionId query parameter` is
DSH's *own handler* running and validating input, reached with a browser-style
`Origin: https://dsh-demo.up.railway.app`. Without the rewrite the trust fence would reject the
call and the UI would load but do nothing. A 401 here would mean the gate is closed; a 403 would
mean the fence blocked us; 400 means the request went all the way through, authenticated.

**"dsh NOT bound to 0.0.0.0:3080" → 0.** Read from `/proc/net/tcp` inside the container, not from
config. `dsh` is listening on `0100007F:0C08` (127.0.0.1:3080) and on nothing else, so even if
Caddy were removed the agent would not be exposed — it would simply be unreachable.

## Credential handling, recorded

```
credential minted on first boot : yes
credential logged for the deployer: 1
generated credential authenticates: 200
a wrong credential is rejected     : 401
--- after restart ---
credential unchanged               : yes
credential still authenticates     : 200
workspace file survived            : agent-made-this
session log survived               : s1.log
not regenerated on second boot     : 1
```

Auth cannot be switched off. An empty `DSH_PASSWORD` is treated as "not supplied", not as "no
auth" — the entrypoint mints one instead. On a surface that runs arbitrary bash, failing open is
not a setting a deployer should be able to select by accident.

## Residual risk the listing must state, and does

The gate is a single shared password over Railway's TLS. That is appropriate for one operator
running their own agent box; it is not multi-user access control, and it is not protection against
someone who already has the password. A deployer putting anything sensitive in the workspace
should put Cloudflare Access or a VPN in front as well. The `README-marketplace.md` says this in
those words rather than implying the box is hardened.
