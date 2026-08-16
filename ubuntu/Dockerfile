# DeepSeek Harness on Ubuntu — the DSH agent Web UI, behind an authenticating proxy.
#
# Two things about upstream drive every decision in this file.
#
# 1. DSH ships NO authentication. Upstream says so itself, in
#    packages/host/webserver/README.md: "No TLS, auth, or origin policy - binding a non-loopback
#    address exposes the server to that network; deployment hardening (or fronting it with a real
#    reverse proxy) is deliberately out of scope for the dev-facing v1." The /api "trust fence" in
#    packages/client/connection/src/api-request-trust.ts is a DNS-rebinding defense and says of
#    itself "this fence is not an auth layer."
#
# 2. The CLI therefore HARD-REFUSES to bind the world:
#      "error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose
#       remote code execution to the network; use 127.0.0.1 instead"
#
#    That refusal is defeatable with a --patch overlay, because the webserver's own schema still
#    accepts 0.0.0.0. We deliberately DO NOT do that. An agent that runs bash on a public URL with
#    no password is remote code execution on the deployer's Railway account, and a persistent
#    volume means an attacker's foothold survives the redeploy that would otherwise clear it.
#
# So: dsh stays on 127.0.0.1:3080 exactly as upstream intends, and Caddy owns Railway's $PORT,
# enforces basic auth, and proxies to loopback. The public surface is the proxy; the agent is
# never reachable off-loopback. See railway-entrypoint.sh for the header rewriting that keeps
# DSH's own fence satisfied through the proxy.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# bash is a hard requirement, not a convenience: the bash tool contract is bash-dialect
# (packages/shell/tool-bash/README.md) and the persistent terminal runs a real interactive bash
# under a PTY. This is why the image is not node:alpine - busybox ash does not satisfy it.
#
# ripgrep is deliberately NOT installed: DSH ships its own via @vscode/ripgrep and does not use a
# host rg. The rest is what an agent sandbox is expected to have on hand.
#
# build-essential is NOT optional and NOT just for the agent's convenience: DSH depends on
# node-pty, which ships no prebuilt binary for this platform and compiles through node-gyp at
# install time. Without a toolchain the image build fails at `npm install -g` with
# "gyp ERR! not ok / $npm_package_name node-pty". It is kept in the final image rather than
# removed afterwards because an agent sandbox is expected to be able to build things.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      wget \
      git \
      xz-utils \
      procps \
      python3 \
      python3-venv \
      build-essential \
      jq \
      unzip \
      less \
      openssl \
      tini \
 && rm -rf /var/lib/apt/lists/*

# Node from the official tarball rather than a distro package or a vendor apt repo: deterministic,
# no repo key rotation to break the build later, and Ubuntu 24.04 ships Node 18 which is below the
# floor. Upstream engines: "^22.19.0 || >=24.0.0" (root package.json); the base bundle uses
# node:sqlite, so the floor is real.
ARG NODE_VERSION=24.19.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) node_arch='x64' ;; \
      arm64) node_arch='arm64' ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      -o /tmp/node.tar.xz; \
    mkdir -p /opt/node; \
    tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1; \
    rm /tmp/node.tar.xz; \
    /opt/node/bin/node --version

ENV PATH=/opt/node/bin:/opt/npm/bin:$PATH \
    NPM_CONFIG_PREFIX=/opt/npm

# Caddy is the auth layer, so it is pinned and checksummed rather than curl|sh'd. It is used
# instead of a hand-rolled Node proxy on purpose: a subtle bug in hand-written basic-auth or
# WebSocket upgrade handling here is not a bug, it is an authentication bypass on an RCE surface.
ARG CADDY_VERSION=2.11.4
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" \
      -o /tmp/caddy.tar.gz; \
    tar -xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy; \
    rm /tmp/caddy.tar.gz; \
    caddy version

# Pinned exactly. Upstream README: "currently in developer preview ... THERE WILL BE
# COMPATIBILITY-BREAKING CHANGES." A published template is deployed by strangers who did not pick
# the version, so a floating tag would break their deploy on an upstream release.
#
# Note the bundle packages' npm `latest` dist-tags are stale (dsh-web-app latest is 0.0.1-rc.1),
# but the ^0.1.0-rc.6 ranges inside this manifest resolve correctly. Never install those by bare
# name.
ARG DSH_VERSION=0.1.0-rc.6
RUN mkdir -p /opt/npm \
 && npm install -g --no-fund --no-audit "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force \
 && dsh --version

# Force host-backed settings persistence. THIS IS ONLY CORRECT BEHIND THE PROXY IN THIS IMAGE.
#
# The DSH client decides where a settings namespace is stored with
#   new SettingsScopeController(connection.api, spec, connection.isLoopback ? "host" : "memory")
# (@deepseek-ai/dsh-client-ui-settings/lib/client.js) and the same expression for the welcome
# notice in dsh-client-ui-settings-models. `connection.isLoopback` is computed from the BROWSER's
# own page hostname (isLoopbackHostname() in @deepseek-ai/dsh-client-connection). It is a
# client-side PREDICTION that the Host would refuse a settings RPC from a non-loopback page, and
# when it predicts refusal the controller short-circuits every read and write into process memory:
# nothing is ever sent, nothing is stored, settings silently reset on reload and the
# Settings -> Plugins tab renders empty because its `writable` flag never arrives. Upstream
# discussions #849 and #2403 are this.
#
# In THIS image that prediction is wrong. Nobody reaches DSH from a browser directly: dsh binds
# 127.0.0.1:3080 and Caddy owns the public port, and railway-entrypoint.sh rewrites the request
# with `header_up Host 127.0.0.1:3080` and `header_up Origin http://127.0.0.1:3080`. The Host
# therefore evaluates its trust fence against loopback and accepts the settings RPCs. Verified on
# 0.1.0-rc.6 with a browser origin on a LAN address: settings.describe returns
# `ok:true, writable:true`, settings.mutate returns `ok:true` with an incremented revision, and the
# value lands in $DSH_HOME/settings.yaml. The same call made directly to 127.0.0.1:3080 with a
# non-loopback Host/Origin (i.e. bypassing the proxy) is refused with 403 `forbidden` — which is
# what the fence is for, and it is untouched by this patch. Only the client's redundant guess is
# removed; the server-side fence and the Caddy basic-auth gate both still stand.
#
# DO NOT lift this patch into an image that serves dsh to a browser WITHOUT that header rewriting.
# There the Host really would refuse, and the writes this patch enables would fail instead of
# degrading to memory.
#
# The substitution asserts the exact set of files it changed and exits non-zero on any mismatch,
# so a dsh bump that renames, moves, or adds a persistence-mode site fails the BUILD rather than
# shipping a silent no-op that leaves the bug in place.
RUN node -e 'const fs=require("fs"),p=require("path"),R="/opt/npm/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai",N="connection.isLoopback ? \"host\" : \"memory\"",E=["dsh-client-ui-settings/lib/client.js","dsh-client-ui-settings-models/lib/client.js"],h=[];for(const k of fs.readdirSync(R)){const d=p.join(R,k,"lib");if(!fs.existsSync(d))continue;for(const f of fs.readdirSync(d)){if(!f.endsWith(".js"))continue;const t=p.join(d,f),s=fs.readFileSync(t,"utf8");if(!s.includes(N))continue;fs.writeFileSync(t,s.split(N).join("\"host\""));h.push(k+"/lib/"+f)}}console.log("[dsh-railway] forced host settings persistence in: "+(h.join(", ")||"(none)"));if(h.sort().join(",")!==E.sort().join(",")){console.error("[dsh-railway] FATAL: settings-persistence patch sites changed in this dsh version. expected: "+E.join(", ")+" | found: "+(h.join(", ")||"(none)")+" -- re-audit dsh before shipping.");process.exit(1)}' \
 && ! grep -rq 'isLoopback ? "host" : "memory"' /opt/npm/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/

# Everything stateful lives under /home/dsh so ONE volume covers it. DSH keeps all user data under
# a single root (packages/util/home-paths/src/index.ts: resolveDshHome precedence is explicit
# config, then $DSH_HOME, then ~/.dsh) - that root holds profiles/, sessions/, storages/,
# settings.yaml and .credentials.yaml. The agent's WORKSPACE is separate: "All modes treat the
# invoking directory as the default workspace root", so it is placed under the same home to be
# covered by the same mount.
ENV HOME=/home/dsh \
    DSH_HOME=/home/dsh/.dsh \
    DSH_WORKSPACE=/home/dsh/workspace \
    XDG_CONFIG_HOME=/home/dsh/.config \
    DSH_TELEMETRY_DISABLED=1

RUN mkdir -p /home/dsh/.dsh /home/dsh/workspace /home/dsh/.config /etc/caddy

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

WORKDIR /home/dsh/workspace

EXPOSE 8080

# tini reaps the PTY and bash children the agent spawns; without a real init they accumulate as
# zombies over a long-lived session. SIGTERM is upstream's ordinary stop request and exits 0.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint.sh"]
