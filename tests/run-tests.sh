#!/usr/bin/env bash
# Run the ERT suite against recorded TickTick responses served by WireMock.
#
# WireMock is located in this order:
#   $WIREMOCK_CMD  -- e.g. "java -jar /path/to/wiremock-standalone.jar"
#   wiremock       -- a launcher on PATH
#
# Override the port with $TICKTICK_TEST_PORT (default 4123).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
port="${TICKTICK_TEST_PORT:-4123}"
emacs="${EMACS:-emacs}"

if [ -n "${WIREMOCK_CMD:-}" ]; then
  # shellcheck disable=SC2206
  wiremock_cmd=($WIREMOCK_CMD)
elif command -v wiremock >/dev/null 2>&1; then
  wiremock_cmd=(wiremock)
else
  echo "error: no WireMock found. Install it, or set WIREMOCK_CMD," >&2
  echo "       e.g. WIREMOCK_CMD='java -jar wiremock-standalone.jar'" >&2
  exit 127
fi

log="$(mktemp -t ticktick-wiremock-XXXXXX.log)"
wiremock_pid=""

cleanup() {
  if [ -n "$wiremock_pid" ] && kill -0 "$wiremock_pid" 2>/dev/null; then
    kill "$wiremock_pid" 2>/dev/null || true
    wait "$wiremock_pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

echo "starting WireMock on port $port ..."
"${wiremock_cmd[@]}" \
  --root-dir "$here/wiremock" \
  --port "$port" \
  --disable-banner >"$log" 2>&1 &
wiremock_pid=$!

for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "http://localhost:$port/__admin/mappings"; then
    ready=1
    break
  fi
  if ! kill -0 "$wiremock_pid" 2>/dev/null; then
    echo "WireMock exited before becoming ready:" >&2
    cat "$log" >&2
    exit 1
  fi
  sleep 1
done

if [ -z "${ready:-}" ]; then
  echo "WireMock did not become ready in time:" >&2
  cat "$log" >&2
  exit 1
fi

echo "running tests ..."
TICKTICK_TEST_PORT="$port" "$emacs" -Q --batch \
  -f package-initialize \
  -L "$root" \
  -l "$here/ticktick-tests.el" \
  -f ert-run-tests-batch-and-exit
