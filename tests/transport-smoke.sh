#!/bin/sh
# Transport smoke test — F1 stdio JSON-RPC 2.0.
#
# Pipes a scripted client exchange (shaped like the fossil ACP client's
# messages) into the built binary and diffs the exact stdout transcript.
#
# Run after `zig build`:
#   sh tests/transport-smoke.sh
set -e
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/acps
if [ ! -x "$BIN" ]; then
    echo "build first: zig build" >&2
    exit 1
fi

# The server requires a config file; use a keyless fixture (health check is
# skipped without a key, so this exercises the transport only).
CFG=tests/fixtures/config.json
if [ ! -f "$CFG" ]; then
    echo "missing $CFG" >&2
    exit 1
fi

INPUT='{"jsonrpc":"2.0","id":1,"method":"test/unknown","params":{}}
{"jsonrpc":"2.0","id":2,"method":"test/unknown2","params":{}}

{"jsonrpc":"2.0","id":"req-3","method":"test/unknown3","params":null}
{not json
{"jsonrpc":"2.0","id":4,"method":"test/unknown4","params":null}'

EXPECTED='{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":"req-3","error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}'

ACTUAL=$(printf '%s\n' "$INPUT" | ACP_CONFIG="$CFG" "$BIN")

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL: transcript mismatch" >&2
    echo "--- expected ---" >&2
    printf '%s\n' "$EXPECTED" >&2
    echo "--- actual ---" >&2
    printf '%s\n' "$ACTUAL" >&2
    exit 1
fi

# EOF-only input must exit cleanly with no output.
OUT=$(printf '' | ACP_CONFIG="$CFG" "$BIN")
if [ -n "$OUT" ]; then
    echo "FAIL: expected empty output on EOF-only input" >&2
    exit 1
fi

echo "transport smoke test: OK"
