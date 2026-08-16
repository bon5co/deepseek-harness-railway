# DeepSeek Harness on nix — recorded proof that the control surface is closed

Companion to `../deepseek-harness/SECURITY-PROOF.md`, which holds the full reasoning, the upstream
quotes, and the explanation of what each check proves. This file records the nix flavor's run of
the same suite plus the two checks that only apply here.

Re-run with `scripts/verify-deepseek-harness.sh dsh-nixos:test dshv-nixos 18892` before any
republish that changes the image.

## Result — nix flavor, 16/16

Run 2026-08-16 against `dsh-nixos:test`, container capped at 1 GB (Railway Trial).

```
  container: status=running oom=false exit=0
  memory:    135.2MiB / 1GiB
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
  ---- dsh-nixos:test: 16 passed, 0 failed ----
```

Lighter than the Ubuntu flavor at rest (135.2 MiB vs 164.4 MiB) because the nix userland is
smaller than an Ubuntu base. Both are far inside Trial's 1 GB.

## Two findings specific to this flavor

**The nix flavor crash-looped on boot until `--expose-internals` was passed.** DSH's loader takes
Node's internal module loader from `process.execArgv` when the flag is present, and otherwise falls
back to the native addon `node-addon-require-builtin`
(`cordis-plugin-loader/src/internal.ts`, `requireInternal`). That addon loads on the Ubuntu
userland but not on the nix one, so the fallback returned undefined and startup died with:

```
Error: --expose-internals is required for HMR service
```

Both flavors now launch as `node --expose-internals "$(command -v dsh)" web ...`, so neither
depends on that addon resolving. `NODE_OPTIONS` cannot carry the flag — it is not in the allowlist.

**Runtime `nix profile add` silently did nothing until PATH was fixed.** The baked-in packages are
installed at build time, when `HOME` is still `/root`, so they live in `/root/.nix-profile`. At
runtime `HOME=/home/dsh`, so anything the *agent* installs goes to `/home/dsh/.nix-profile`
instead. With only the build-time profile on PATH, `nix profile add nixpkgs#cowsay` reported
success and left `cowsay` not found — this flavor's entire selling point failing quietly. Both
profiles are now on PATH, runtime first.

Verified after the fix, running as the agent would:

```
$ nix profile add nixpkgs#cowsay
copying path '/nix/store/3cf1ig3kz5nn27f2zs1mw4pmrcv2m62p-cowsay-3.8.4' from 'https://cache.nixos.org'...
$ cowsay "installed at runtime, on PATH"
 _______________________________
< installed at runtime, on PATH >
 -------------------------------
```

Unprivileged, no sandbox flags, straight from the binary cache — consistent with the measured
finding in `references/nixos-agent-base.md` that only source builds need `sandbox = false`.

## Persistence caveat this flavor must state, and does

A `/home` volume persists sessions, config, credentials and the agent's files. It does **not**
fully persist installed packages, and the reason is worth stating precisely because it looks like
it should: `nix profile add` writes a manifest under `$HOME/.nix-profile` (on the volume, survives)
and the package itself under `/nix/store` (in the image layer, does not). After a redeploy the
manifest points at store paths that are gone; re-running `nix profile add` repairs it as a
binary-cache copy in seconds. A deployer who wants installs to survive redeploys mounts `/nix` too.

The listing says this rather than claiming "packages persist".
