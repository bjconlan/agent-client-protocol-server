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

BIN=./zig-out/bin/agent_client_protocol
if [ ! -x "$BIN" ]; then
    echo "build first: zig build" >&2
    exit 1
fi

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}

{"jsonrpc":"2.0","id":"req-3","method":"session/prompt","params":null}
{not json
{"jsonrpc":"2.0","id":4,"method":"session/cancel","params":{"sessionId":"s1"}}'

EXPECTED='{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":"req-3","error":{"code":-32601,"message":"Method not found"}}
{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}'

ACTUAL=$(printf '%s\n' "$INPUT" | "$BIN")

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL: transcript mismatch" >&2
    echo "--- expected ---" >&2
    printf '%s\n' "$EXPECTED" >&2
    echo "--- actual ---" >&2
    printf '%s\n' "$ACTUAL" >&2
    exit 1
fi

# EOF-only input must exit cleanly with no output.
OUT=$(printf '' | "$BIN")
if [ -n "$OUT" ]; then
    echo "FAIL: expected empty output on EOF-only input" >&2
    exit 1
fi

echo "transport smoke test: OK"
