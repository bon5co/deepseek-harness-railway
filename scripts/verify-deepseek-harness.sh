#!/usr/bin/env bash
# Verification suite for the DeepSeek Harness Railway templates.
# Usage: dsh-verify.sh <image> <container-name> <host-port>
set -uo pipefail
IMG="$1"; NAME="$2"; HP="$3"; B="http://127.0.0.1:${HP}"
PASS=0; FAIL=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$3"; PASS=$((PASS+1));
  else printf '  FAIL  %-46s expected=%s got=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }

echo "=== $IMG ==="
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --memory 1g --memory-swap 1g --cpus 2 \
  -p "${HP}:8080" -e PORT=8080 -e DSH_PASSWORD=testpw123 "$IMG" >/dev/null

for i in $(seq 1 40); do
  [ "$(code $B/healthz)" = "200" ] && break
  sleep 3
done

ST=$(docker inspect "$NAME" --format 'status={{.State.Status}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}')
echo "  container: $ST"
echo "  memory:    $(docker stats --no-stream --format '{{.MemUsage}}' "$NAME" 2>/dev/null)"

echo "-- auth gate (the release condition) --"
chk "unauthenticated GET /"                401 "$(code $B/)"
chk "unauthenticated GET /api/session.export" 401 "$(code $B/api/session.export)"
chk "unauthenticated GET /api/users"       401 "$(code $B/api/users)"
chk "forged loopback Host header"          401 "$(code -H 'Host: 127.0.0.1:3080' $B/api/session.export)"
chk "wrong password"                       401 "$(code -u admin:wrongpw $B/)"
chk "empty password"                       401 "$(code -u admin: $B/)"
chk "unauthenticated WebSocket upgrade"    401 "$(code -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
                                                    -H 'Sec-WebSocket-Version: 13' \
                                                    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
                                                    $B/api/events.host)"

echo "-- function through the proxy --"
chk "authenticated GET / (UI)"             200 "$(code -u admin:testpw123 $B/)"
chk "healthcheck path, unauthenticated"    200 "$(code $B/healthz)"
chk "authenticated API w/ public Origin"   400 "$(code -u admin:testpw123 \
                                                    -H 'Origin: https://dsh-demo.up.railway.app' \
                                                    -H 'Sec-Fetch-Site: same-origin' \
                                                    $B/api/session.export)"
chk "authenticated WebSocket upgrade"      101 "$(code -u admin:testpw123 \
                                                    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
                                                    -H 'Sec-WebSocket-Version: 13' \
                                                    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
                                                    -H 'Origin: https://dsh-demo.up.railway.app' \
                                                    $B/api/events.host)"

echo "-- dsh must not be reachable off loopback --"
BIND=$(docker exec "$NAME" sh -c "grep -c '0100007F:0C08' /proc/net/tcp" 2>/dev/null | tr -d '[:space:]')
chk "dsh bound to 127.0.0.1:3080 only"     "yes" "$([ "${BIND:-0}" -ge 1 ] && echo yes || echo no)"
WILD=$(docker exec "$NAME" sh -c "awk 'NR>1 && \$4==\"0A\" && \$2 ~ /^00000000:0C08/' /proc/net/tcp | wc -l" 2>/dev/null | tr -d '[:space:]')
chk "dsh NOT bound to 0.0.0.0:3080"        "0" "${WILD:-x}"

echo "-- persistence + shell tool prerequisites --"
chk "bash present (bash tool contract)"    "yes" "$(docker exec "$NAME" sh -c 'command -v bash >/dev/null && echo yes || echo no')"
chk "DSH_HOME under /home/dsh"             "yes" "$(docker exec "$NAME" sh -c '[ -d /home/dsh/.dsh/profiles ] && echo yes || echo no')"
chk "sessions dir on the volume path"      "yes" "$(docker exec "$NAME" sh -c '[ -d /home/dsh/.dsh ] && echo yes || echo no')"

echo "  ---- $IMG: ${PASS} passed, ${FAIL} failed ----"
exit $FAIL
