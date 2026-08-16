#!/usr/bin/env bash
set -euo pipefail

# Railway entrypoint for DeepSeek Harness.
#
# Layout:
#
#   internet --> Caddy on 0.0.0.0:$PORT  (basic auth, this is the only public surface)
#                  |
#                  '--> dsh web on 127.0.0.1:3080  (never reachable off-loopback)
#
# The reasoning for the proxy is in the Dockerfile header. The short version: DSH has no auth of
# any kind, and its own CLI refuses to bind 0.0.0.0 because doing so "would expose remote code
# execution to the network". We honour that refusal rather than patching around it.

DSH_INTERNAL_PORT="${DSH_INTERNAL_PORT:-3080}"

# Railway injects PORT and its healthcheck dials THAT port, not the app's own default. A template
# that listens on its upstream default passes locally and then fails every deploy with
# "service unavailable".
PUBLIC_PORT="${PORT:-8080}"

DSH_USERNAME="${DSH_USERNAME:-admin}"
PASS_FILE="${DSH_HOME}/.dashboard-password"

mkdir -p "$DSH_HOME" "$DSH_WORKSPACE"

# ---------------------------------------------------------------------------
# 1. Credentials. Auth defaults ON and cannot be turned off.
# ---------------------------------------------------------------------------
# Precedence: deployer-supplied wins, else reuse the one persisted on the volume, else mint one.
# We never start without a password. An empty DSH_PASSWORD is treated as "not supplied", not as
# "no auth" - on a surface that runs arbitrary bash, failing open is not an option the deployer
# should be able to select by accident.
if [ -n "${DSH_PASSWORD:-}" ]; then
  DASH_PASS="$DSH_PASSWORD"
elif [ -s "$PASS_FILE" ]; then
  DASH_PASS="$(cat "$PASS_FILE")"
else
  DASH_PASS="$(openssl rand -hex 18)"
  printf '%s' "$DASH_PASS" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
  echo "[entrypoint] no DSH_PASSWORD set - generated one and stored it at $PASS_FILE"
  echo "[entrypoint] username=$DSH_USERNAME password=$DASH_PASS"
  echo "[entrypoint] set DSH_PASSWORD as a service variable to keep it out of the deploy logs"
fi

# Caddy wants a bcrypt hash, never the plaintext, so the password is not recoverable from the
# running config.
PASS_HASH="$(caddy hash-password --plaintext "$DASH_PASS")"

if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "[entrypoint] WARNING: DEEPSEEK_API_KEY is not set - the UI will start but the agent"
  echo "[entrypoint]          cannot call a model until you add it as a service variable."
fi

# ---------------------------------------------------------------------------
# 2. Proxy config.
# ---------------------------------------------------------------------------
# The Host and Origin rewrites are load-bearing, not cosmetic. DSH guards /api with a trust fence
# (packages/client/connection/src/api-request-trust.ts) that requires the Host header to be a
# loopback authority and, when an Origin header is present, requires it to match that authority.
# Proxying with Railway's public Host intact makes every API call fail the fence, so the UI loads
# and then does nothing. Rewriting both to the loopback authority is what makes the app work
# through a proxy without weakening its binding policy.
#
# /healthz is answered by Caddy itself and is deliberately NOT authenticated: Railway's
# healthcheck cannot present credentials. It exposes nothing - it is a static 200 from the proxy
# and never reaches dsh. Liveness of the agent itself is handled by the supervision below: if dsh
# dies, the container exits and Railway restarts it, so a dead agent never keeps answering 200.
cat > /etc/caddy/Caddyfile <<CADDY
{
	admin off
	auto_https off
	persist_config off
}

:${PUBLIC_PORT} {
	handle /healthz {
		respond "ok" 200
	}

	handle {
		basic_auth {
			${DSH_USERNAME} ${PASS_HASH}
		}

		reverse_proxy 127.0.0.1:${DSH_INTERNAL_PORT} {
			header_up Host 127.0.0.1:${DSH_INTERNAL_PORT}
			header_up Origin http://127.0.0.1:${DSH_INTERNAL_PORT}
			header_up -Referer
			header_up -Authorization
		}
	}
}
CADDY

# ---------------------------------------------------------------------------
# 3. Start both, supervise both.
# ---------------------------------------------------------------------------
# Neither process may outlive the other. If dsh crashes and Caddy keeps serving, the healthcheck
# stays green over a dead agent; if Caddy crashes and dsh keeps running, nothing is exposed but
# the service is silently broken. Either exit takes the container down and Railway's ON_FAILURE
# policy restarts it.
term() {
  echo "[entrypoint] received stop signal, shutting down"
  kill -TERM "${DSH_PID:-}" "${CADDY_PID:-}" 2>/dev/null || true
  wait || true
  exit 0
}
trap term TERM INT

echo "[entrypoint] starting dsh web on 127.0.0.1:${DSH_INTERNAL_PORT} (DSH_HOME=${DSH_HOME})"
cd "$DSH_WORKSPACE"

# Launched as `node --expose-internals <bin>` rather than as plain `dsh`, on purpose.
#
# The loader needs Node's internal module loader. It takes it from `--expose-internals` when that
# flag is in process.execArgv, and otherwise falls back to the native addon
# node-addon-require-builtin (cordis-plugin-loader/src/internal.ts, requireInternal). When that
# addon fails to load, the fallback returns undefined and startup dies with
# "Error: --expose-internals is required for HMR service".
#
# The addon loads on this Ubuntu userland but NOT on the nix one, so the nix flavor crash-looped
# on boot until the flag was passed. Both flavors use the flag so the two images share one
# entrypoint and neither depends on a native addon resolving correctly.
#
# NODE_OPTIONS is not an option here: --expose-internals is not in its allowlist.
DSH_BIN="$(command -v dsh)"
node --expose-internals "$DSH_BIN" web --host 127.0.0.1 --port "${DSH_INTERNAL_PORT}" &
DSH_PID=$!

echo "[entrypoint] starting authenticating proxy on 0.0.0.0:${PUBLIC_PORT}"
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# wait -n returns as soon as EITHER child exits; whichever it was, we take the container down.
wait -n "$DSH_PID" "$CADDY_PID"
EXIT_CODE=$?
echo "[entrypoint] a supervised process exited (status ${EXIT_CODE}) - stopping the container"
kill -TERM "$DSH_PID" "$CADDY_PID" 2>/dev/null || true
wait || true
exit "${EXIT_CODE}"
