# deepseek-harness-railway

Railway wrapper images for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`), DeepSeek's open-source agent harness (MIT).

Two flavors, same harness and same access gate:

| Directory | Image | Base |
| --- | --- | --- |
| `ubuntu/` | `ghcr.io/bon5co/deepseek-harness-railway` | `ubuntu:24.04` + Node 24 |
| `nixos/` | `ghcr.io/bon5co/deepseek-harness-nixos-railway` | digest-pinned `nixos/nix` |

## What the wrapper adds

DeepSeek Harness ships **no authentication**. Upstream states this in
`packages/host/webserver/README.md` — "No TLS, auth, or origin policy — binding a non-loopback
address exposes the server to that network" — and its CLI refuses to bind a public address:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code
execution to the network; use 127.0.0.1 instead
```

An agent with a shell tool on an open URL is remote code execution on the host account, so these
images do **not** patch around that refusal, even though the webserver schema would still accept
`0.0.0.0` via a `--patch` overlay. Instead:

```
internet ──> Caddy on $PORT   (HTTP basic auth — the only public surface)
                  │
                  └──> dsh web on 127.0.0.1:3080   (never reachable from outside)
```

Caddy rewrites `Host` and `Origin` to the loopback authority so DSH's own anti-DNS-rebinding trust
fence keeps passing through the proxy — without that, the UI loads and every API call fails.

Auth cannot be disabled. An empty password is treated as "not supplied", not "no auth": the
entrypoint generates one, persists it on the volume at `$DSH_HOME/.dashboard-password`, and prints
it once to the container log.

The wrapper also honours Railway's injected `PORT`, answers an unauthenticated `/healthz` at
the proxy (Railway's health prober cannot present credentials), and supervises both processes so a
dead agent takes the container down instead of sitting behind a green healthcheck.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | — | Model access |
| `DSH_USERNAME` | `admin` | Basic-auth user |
| `DSH_PASSWORD` | generated | Basic-auth password |
| `DEEPSEEK_BASE_URL` | DeepSeek API | Alternate endpoint or gateway |

Mount a volume at `/home/dsh` — it covers `.dsh/` (profiles, sessions, storages, settings,
credentials) and `workspace/` (the agent's files).

On the nix flavor, a `/home` volume does **not** fully persist packages the agent installs:
`nix profile add` writes a manifest onto the volume but the package into `/nix/store` in the image
layer. Re-running the add after a redeploy repairs it as a binary-cache copy in seconds; mount
`/nix` too if durable installs matter.

## Build notes

- `node-pty` compiles at install time — both images need a toolchain or `npm install -g` fails with
  `gyp ERR! not ok`.
- Both launch as `node --expose-internals "$(command -v dsh)" web ...`. DSH's loader otherwise falls
  back to the native addon `node-addon-require-builtin`, which does not load on the nix userland
  ("Error: --expose-internals is required for HMR service"). `NODE_OPTIONS` cannot carry the flag.
- The nix image puts both `/home/dsh/.nix-profile/bin` and `/root/.nix-profile/bin` on `PATH`.
  Build-time installs land in the former's root equivalent, runtime installs in the latter's home
  equivalent; with only one on PATH, `nix profile add` reports success and leaves the binary missing.

Upstream is in developer preview and warns of compatibility-breaking changes, so
`@deepseek-ai/dsh` is pinned rather than floating.

## License

Wrapper: MIT. DeepSeek Harness: MIT, © 2026 DeepSeek.
