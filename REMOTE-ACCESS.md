# Running DeepSeek Harness remotely, without exposing remote code execution

If you tried to reach `dsh web` from another machine, you hit this:

```
error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code
execution to the network; use 127.0.0.1 instead
```

That refusal is correct and you should not patch around it. This page is the working answer:
what the constraint actually is, the proxy pattern that satisfies it, and the two mistakes that
make a naive proxy fail.

Nothing here is specific to any host. It is a Caddy config and a shell script; it works on a VPS,
a homelab box, a Raspberry Pi, or a container platform.

## Why the refusal is not paranoia

DeepSeek Harness is an agent with a shell tool. Anyone who can load the web UI can run commands as
the account the harness runs under. So an open port is not "a dashboard someone might poke at" —
it is a shell.

Upstream is explicit that no protection ships in the box. From
`packages/host/webserver/README.md`:

> No TLS, auth, or origin policy — binding a non-loopback address exposes the server to that
> network.

There *is* a check on `/api`, and it is easy to mistake for authentication. It is not. It is a
DNS-rebinding defence: it requires the request's `Host` to be a loopback authority and the `Origin`
to match. Its own comments disclaim the auth role. It stops a malicious web page in your browser
from driving your local harness; it does nothing about a stranger who simply opens the port.

Worth knowing, since people find it and stop looking: the CLI's refusal is defeatable — the
webserver schema still accepts `0.0.0.0` through a `--patch` overlay. Don't. The refusal is the
only thing standing between the port and a shell.

## The pattern

Leave the harness on loopback exactly as upstream intends, and put an authenticating reverse proxy
in front of it. The proxy owns the public port; the harness is never reachable from outside.

```
internet ──> Caddy on :8080     (HTTP basic auth — the only public surface)
                  │
                  └──> dsh web on 127.0.0.1:3080   (never bound to a public interface)
```

### Caddyfile

```caddyfile
{
	admin off
	auto_https off
	persist_config off
}

:8080 {
	# Unauthenticated, so an external health prober can reach it. It reveals nothing.
	handle /healthz {
		respond "ok" 200
	}

	handle {
		basic_auth {
			admin $2a$14$REPLACE_WITH_A_REAL_BCRYPT_HASH
		}

		reverse_proxy 127.0.0.1:3080 {
			header_up Host 127.0.0.1:3080
			header_up Origin http://127.0.0.1:3080
			header_up -Referer
			header_up -Authorization
		}
	}
}
```

Generate the hash with `caddy hash-password --plaintext 'your-password'`. Put a real TLS
certificate in front of this, or terminate TLS at your platform's edge — basic auth over plain HTTP
sends the password in clear on every request.

### Starting both processes

```bash
#!/usr/bin/env bash
set -euo pipefail

node --expose-internals "$(command -v dsh)" web --host 127.0.0.1 --port 3080 &
DSH_PID=$!

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# If either process dies, take the whole thing down rather than leaving a half-dead service
# behind a green healthcheck.
wait -n "$DSH_PID" "$CADDY_PID"
```

## The two things that break a naive proxy

**1. The `Host` and `Origin` rewrites are load-bearing.** Without them, the UI loads, looks
completely normal, and every single API call fails — because the harness's rebinding fence sees a
public `Host` and rejects the request. A proxy that only forwards traffic produces a dead UI that
looks like a bug in the harness. `header_up Host` and `header_up Origin` must both point at the
loopback authority the harness is bound to.

**2. `--expose-internals` is required, and `NODE_OPTIONS` cannot carry it.** Without the flag,
the harness's plugin loader falls back to a native addon (`node-addon-require-builtin`) to reach
Node internals. On some userlands that addon loads and you never notice; on others you get:

```
Error: --expose-internals is required for HMR service
```

and the process exits at startup. The flag is not on Node's `NODE_OPTIONS` allowlist, so it has to
be passed on the command line — hence `node --expose-internals "$(command -v dsh)" web ...` rather
than launching the `dsh` bin directly.

A third one, if you are building a container image: `node-pty` compiles at install time, so
`npm install -g @deepseek-ai/dsh` fails with `gyp ERR! not ok` unless a C toolchain is present.

## The one the proxy does not fix by itself: settings silently stop persisting

Get the proxy right and the harness works — but your settings quietly revert on every reload, and
the Settings → Plugins configuration tab comes up empty. No error is shown. This is the same
symptom reported in upstream discussions #849 and #2403.

The cause is client-side, and the proxy cannot reach it. In
`@deepseek-ai/dsh-client-ui-settings/lib/client.js`:

```js
const controller = new SettingsScopeController(
  connection.api, spec, connection.isLoopback ? "host" : "memory"
);
```

(0.1.0-rc.6 shape. From 0.2.0 the same decision is `const persistence = ctx.remote.$host.isLoopback
? "host" : "memory";` in the same file, and the Ubuntu image patches that. In 0.2.0-rc.2 a changed
setting lands in `$DSH_HOME/profiles/web/cordis.patch.yml` on the volume, not `settings.yaml`.
The nix image stays on 0.1.0-rc.6 and its patch.)

`connection.isLoopback` comes from `isLoopbackHostname()` applied to the **browser's** URL
hostname. Header rewriting changes what the *server* sees; it cannot change `location.hostname`.
So behind any reverse proxy, every settings namespace is constructed with `persistence: "memory"`
— process-local, gone on reload.

The client is predicting that the host will refuse settings RPCs from a non-loopback browser. In
this topology that prediction is simply wrong, and it is measurable:

```
# through the proxy (Host/Origin rewritten to loopback)
settings.mutate  ui-theme.preference=dark   -> HTTP 200  {"ok":true,...,"revision":1}
                                            -> lands in ~/.dsh/settings.yaml

# same call direct to 127.0.0.1:3080 with a non-loopback Host/Origin
settings.mutate                             -> HTTP 403  forbidden
```

The fence is real, the rewrites are what satisfy it, and the client-side gate is therefore
redundant *when a rewriting proxy is in front*. Forcing host persistence is the fix:

```dockerfile
RUN node -e '...replace `connection.isLoopback ? "host" : "memory"` with `"host"`...' \
 && ! grep -rq 'isLoopback ? "host"' <patched files>   # fail the build if the pattern moved
```

Patch it in exactly two places — `dsh-client-ui-settings` (settings scopes) and
`dsh-client-ui-settings-models` (`WelcomeNoticeStore`). Do **not** patch the equivalent gates in
`dsh-client-ui-settings-general` or `dsh-client-ui-deliverables`: those gate host-desktop file
opening, which genuinely does not work in a container. The server serves
`/plugins/<pkg>/client.js` straight from `node_modules`, so patching the installed files is enough
— no separate bundle to rebuild.

**Make the patch fail the build if the pattern is not found.** This string will move in a future
`dsh` release, and a silent no-op ships a broken image that looks fine.

### Why your test of this will lie to you

This is the part that wasted the most time, so it is worth stating plainly.

`dsh` mints every RPC id with `crypto.randomUUID()`, which only exists in a **secure context**.
Browsers grant secure context to `https://` origins and to loopback `http://` origins — and
loopback origins are exactly the ones `isLoopbackHostname()` classifies as loopback.

So over plain HTTP on a LAN address, the two conditions you need in order to observe this bug
(secure context, and a non-loopback origin) are mutually exclusive. Every unary RPC throws before
reaching the wire, `SettingsScopeController` swallows it in a bare `catch`, and **patched and
unpatched builds look identically broken**.

Test over HTTPS — a self-signed cert is enough. Testing `http://192.168.x.x:port` will give you a
false negative every time.

One more, if you are measuring rather than eyeballing: `settings.describe` is called by several
callers that are not gated, so describe counts do not discriminate. Only `settings.mutate` does.

## Verifying it, rather than assuming it

Auth that was never tested against a real unauthenticated request is a guess. The checks that
matter:

```bash
# Every public path refuses without credentials. Expect 401 on all of them.
curl -s -o /dev/null -w '%{http_code}\n' https://your-host/
curl -s -o /dev/null -w '%{http_code}\n' https://your-host/api/users
curl -s -o /dev/null -w '%{http_code}\n' -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
     https://your-host/

# The harness is on loopback and nothing else. Expect only 0100007F (127.0.0.1) for its port.
grep ':0C08' /proc/net/tcp

# Authenticated calls actually reach the harness. A 400 about a missing parameter is a PASS here:
# it means the harness's own handler ran. A 403 would mean the rebinding fence blocked the proxy,
# i.e. the header rewrites are wrong.
curl -s -u admin:PASSWORD -o /dev/null -w '%{http_code}\n' https://your-host/api/session.export
```

Do not treat "the login prompt appeared" as proof. Check that the WebSocket upgrade is refused too
— that is the path a naive `basic_auth` placement most often leaves open.

## Prebuilt images

The images in this repo are exactly the pattern above, already assembled and verified against the
checks in [`SECURITY-PROOF.md`](./ubuntu/SECURITY-PROOF.md):

| Base | Image |
| --- | --- |
| `ubuntu:24.04` + Node 24 | `ghcr.io/bon5co/deepseek-harness-railway` |
| digest-pinned `nixos/nix` | `ghcr.io/bon5co/deepseek-harness-nixos-railway` |

They run on any Docker host. Auth cannot be turned off: an empty password is treated as "not
supplied" rather than "no auth", so the entrypoint generates one, persists it on the volume, and
prints it once to the container log.

I also maintain one-click Railway templates that deploy these images. Disclosure: those carry a
template kickback if you deploy through them, so treat this page as the part that matters and the
templates as a convenience.

- DeepSeek Harness (Ubuntu): https://railway.com/deploy/deepseek-harness-or-just-updated-deepsee?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic
- DeepSeek Harness (nix): https://railway.com/deploy/deepseek-harness-on-nixos-or-just-update?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic

## License

Wrapper: MIT. DeepSeek Harness: MIT, © 2026 DeepSeek.
