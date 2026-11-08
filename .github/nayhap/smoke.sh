#!/usr/bin/env bash
# Smoke test for a CLI Proxy API image, run the way Nayhap's host broker runs
# hosted instances: read-only root filesystem, no capabilities,
# no-new-privileges, non-root user 10001, only /state writable, small
# /tmp tmpfs, memory and pid limits. Boots with a minimal config and checks
# health, client-key auth on /v1/models and the management API.
#
# usage: smoke.sh <image>
set -euo pipefail

img="$1"
name="cpa-smoke-$$"
dir="$(mktemp -d)"
port=18317
key="smoke-$(openssl rand -hex 24)"
mgmt="mgmt-$(openssl rand -hex 24)"

cleanup() {
	docker logs "$name" >"$dir/container.log" 2>&1 || true
	docker rm -f "$name" >/dev/null 2>&1 || true
	sudo -n rm -rf "$dir" 2>/dev/null || rm -rf "$dir"
}
trap cleanup EXIT

fail() {
	echo "::error::smoke test failed: $*"
	docker logs "$name" 2>&1 | tail -n 60 || true
	exit 1
}

mkdir -p "$dir/state/auth"
cat >"$dir/state/config.yaml" <<YAML
config-version: 8
server:
  host: ""
  port: 8317
  github-token: ""
  discovery:
    enabled: false
management:
  allow-remote: true
  secret-key: "$mgmt"
  disable-control-panel: true
  disable-auto-update-panel: true
access:
  api-keys:
    - "$key"
oauth:
  auth-dir: "/state/auth"
observability:
  logs:
    logging-to-file: false
    request-log: false
  usage:
    usage-statistics-enabled: true
  pprof:
    enable: false
plugins:
  enabled: false
YAML
# The state directory belongs to the container's user, as the broker sets it
# up; where chown is not possible (a developer machine) it is opened up.
if sudo -n chown -R 10001:10001 "$dir/state" 2>/dev/null; then
	sudo -n chmod 700 "$dir/state"
else
	chmod -R a+rwX "$dir/state"
fi
as_root() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else "$@"; fi; }

docker run -d --name "$name" \
	--read-only --tmpfs /tmp:rw,nosuid,nodev,size=64m \
	--cap-drop ALL --security-opt no-new-privileges \
	--user 10001:10001 --pids-limit 256 --memory 512m --cpus 1 \
	-e TZ=UTC -e HOME=/tmp \
	-v "$dir/state:/state" \
	-p "127.0.0.1:$port:8317" \
	"$img" /CLIProxyAPI/CLIProxyAPI -config /state/config.yaml >/dev/null

base="http://127.0.0.1:$port"
for i in $(seq 1 60); do
	if curl -fsS "$base/healthz" >/dev/null 2>&1; then
		break
	fi
	[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ] || fail "container exited"
	sleep 1
	[ "$i" = 60 ] && fail "no /healthz after 60s"
done

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

[ "$(code -H "Authorization: Bearer $key" "$base/v1/models")" = 200 ] || fail "/v1/models with the client key did not answer 200"
curl -fsS -H "Authorization: Bearer $key" "$base/v1/models" | grep -q '"object"' || fail "/v1/models did not answer a model list"
[ "$(code "$base/v1/models")" = 401 ] || fail "/v1/models without a key did not answer 401"
[ "$(code -H "Authorization: Bearer wrong-$key" "$base/v1/models")" = 401 ] || fail "/v1/models with a wrong key did not answer 401"
[ "$(code -H "Authorization: Bearer $mgmt" "$base/v0/management/config")" = 200 ] || fail "management API did not answer 200 with its key"
[ "$(code -H "Authorization: Bearer wrong" "$base/v0/management/config")" = 401 ] || fail "management API accepted a wrong key"
body="{\"old\":\"second-$key\",\"new\":\"second-$key\"}"
status="$(code -X PATCH -H "Authorization: Bearer $mgmt" -H 'Content-Type: application/json' --data "$body" "$base/v0/management/api-keys")"
[ "$status" = 200 ] || fail "adding a client key through the management API answered $status"
[ "$(code -H "Authorization: Bearer second-$key" "$base/v1/models")" = 200 ] || fail "a key added through the management API is not accepted"
as_root grep -q 'secret-key: "\$2' "$dir/state/config.yaml" || fail "the management key was not hashed into the config"
[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$name")" = "true 0" ] || fail "container is not running cleanly"
echo "smoke test passed for $img"
