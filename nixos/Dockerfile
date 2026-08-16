# DeepSeek Harness on nix — the DSH agent Web UI, behind an authenticating proxy, with all of
# nixpkgs reachable by the agent at runtime.
#
# What this flavor is FOR, versus the Ubuntu one: the agent can `nix profile add nixpkgs#<x>` for
# anything in nixpkgs during a session, without a rebuild and without root, and get an exact
# pinned build rather than whatever the distro repo happens to carry. The Ubuntu flavor is the
# familiar apt sandbox; this one is the reproducible one.
#
# Base is the nix package manager on a minimal userland (154 MB measured), not a full NixOS with
# systemd: systemd in an unprivileged container buys nothing here, and the value is `nix run` /
# `nix profile add` being available to the agent at runtime.
#
# Digest-pinned deliberately. `latest` moves, and a published template is read at deploy time by
# strangers who did not choose the version.
FROM nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c

ENV NIX_CONFIG="experimental-features = nix-command flakes"

# Only what the base actually lacks - it already ships coreutils, grep, curl and git, and adding
# those again fails the build with "An existing package already provides the following file".
#
# `nixpkgs#nodejs` is 24.19.0 (verified 2026-08-16) and copies from the binary cache. Upstream DSH
# requires "^22.19.0 || >=24.0.0", so the default attribute already satisfies the floor - do NOT
# "pin" it to nixpkgs#nodejs_22, which builds from source and turns this layer into a compile.
#
# bash is a hard requirement (the bash tool contract is bash-dialect, and the persistent terminal
# runs a real interactive bash under a PTY) but it is NOT in this list: the base image already
# ships GNU bash 5.3.9 at /root/.nix-profile/bin/bash, and adding nixpkgs#bashInteractive fails
# the build with "An existing package already provides the following file ... The conflicting
# packages have a priority of 5." Verified on the pinned digest, 2026-08-16.
#
# ripgrep is NOT needed by DSH - it bundles its own via @vscode/ripgrep - but it is included here
# because this image is an agent workspace and rg is the search tool the agent reaches for.
#
# gcc/gnumake/python3 are NOT optional: DSH depends on node-pty, which ships no prebuilt binary
# for this platform and compiles through node-gyp at install time. Without a toolchain the image
# build fails at `npm install -g` with "gyp ERR! not ok / $npm_package_name node-pty".
RUN nix profile add \
      nixpkgs#nodejs \
      nixpkgs#caddy \
      nixpkgs#gnused \
      nixpkgs#openssl \
      nixpkgs#ripgrep \
      nixpkgs#jq \
      nixpkgs#python3 \
      nixpkgs#tini \
      nixpkgs#gcc \
      nixpkgs#gnumake \
 && nix store gc

ENV PATH=/root/.nix-profile/bin:/opt/npm/bin:$PATH \
    NPM_CONFIG_PREFIX=/opt/npm \
    SHELL=/root/.nix-profile/bin/bash

# Pinned exactly. Upstream README: "currently in developer preview ... THERE WILL BE
# COMPATIBILITY-BREAKING CHANGES." The bundle packages' npm `latest` dist-tags are stale
# (dsh-web-app latest is 0.0.1-rc.1) but the ^0.1.0-rc.6 ranges inside this manifest resolve
# correctly - never install those by bare name.
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
# a single root ($DSH_HOME, default ~/.dsh) holding profiles/, sessions/, storages/, settings.yaml
# and .credentials.yaml; the agent's workspace is separate ("All modes treat the invoking
# directory as the default workspace root") and is placed under the same home.
#
# NOTE, and the listing says this plainly: a /home volume persists the agent's SESSIONS, config,
# credentials and files. It does NOT fully persist installed packages, and the reason is worth
# being precise about because it looks like it should.
#
# `nix profile add` writes two things: a manifest under $HOME/.nix-profile (on the volume, so it
# survives) and the actual package under /nix/store (in the image layer, so it does not). After a
# redeploy the manifest therefore references store paths that are gone. Re-running `nix profile
# add` repairs it as a binary-cache copy - seconds, not a rebuild - but it is not automatic and it
# is not persistence. A deployer who wants installs to survive redeploys mounts /nix as well.
ENV HOME=/home/dsh \
    DSH_HOME=/home/dsh/.dsh \
    DSH_WORKSPACE=/home/dsh/workspace \
    XDG_CONFIG_HOME=/home/dsh/.config \
    DSH_TELEMETRY_DISABLED=1

# `nix profile` writes to $HOME/.nix-profile. The packages above were installed during the build,
# when HOME was still /root, so they live in /root/.nix-profile - but at runtime HOME is /home/dsh,
# so anything the AGENT installs lands in /home/dsh/.nix-profile instead. Both have to be on PATH
# or `nix profile add nixpkgs#x` reports success and leaves x not found, which is this flavor's
# entire selling point failing silently. The runtime profile goes FIRST so the agent can shadow a
# baked-in package with its own version.
ENV PATH=/home/dsh/.nix-profile/bin:/root/.nix-profile/bin:/opt/npm/bin:$PATH

RUN mkdir -p /home/dsh/.dsh /home/dsh/workspace /home/dsh/.config /etc/caddy

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

WORKDIR /home/dsh/workspace

EXPOSE 8080

# tini reaps the PTY and bash children the agent spawns; without a real init they accumulate as
# zombies over a long-lived session.
ENTRYPOINT ["tini", "--", "/usr/local/bin/railway-entrypoint.sh"]
