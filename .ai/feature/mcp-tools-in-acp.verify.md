# Verify: MCP tools in the ACP tool flow (feature/mcp-tools-in-acp)

## Unit (mcp_bridge)

| Criterion | Result |
|-----------|--------|
| Merged surface: static registry + MCP tools | ✅ `test "buildToolSurface merges static + MCP tools and dispatches"` — 2 static + 1 MCP tool; lookup by prefixed name + static name; unknown miss |
| Name prefixing `"<server>:<tool>"` | ✅ same test — `fs:read_file` |
| `parameters` = MCP inputSchema JSON text | ✅ same test — contains `"path"` |
| Dispatch round-trip (execute via ctx → tools/call → text) | ✅ same test — `"file contents"` |
| Static tools unchanged (ctx null) | ✅ existing registry test passes |

## Integration (server.zig transcript)

| Criterion | Result |
|-----------|--------|
| Model requests `"fs:read_file"` through the full ACP flow | ✅ `test "MCP tool round-trip: model calls an MCP tool through the full ACP flow"` — tool_call notification, `session/request_permission` sent, grant consumed |
| MCP server result fed back to the model | ✅ — `"file contents"` appears in the transcript, `status: completed` |
| Model answers after the tool result | ✅ — `"it is now done"`, `stopReason: end_turn` |
| Merged tool name visible to the ACP client | ✅ — `fs:read_file` in the transcript |

## Failure paths

| Criterion | Result |
|-----------|--------|
| MCP server spawn/initialize failure → warn + skip (server still runs) | ✅ `connectAll` catches per-server, logs, continues (not directly tested with a real spawn in CI) |
| Failed MCP tool call → "ERROR: …" text | ✅ `mcpExecute` errors propagate to `runToolCall`'s existing `catch` → `"ERROR: …"` |
| Missing/unknown tool → "ERROR: unknown tool" | ✅ existing path (now via `lookupIn` on the merged surface) |

## Whole repo

| Criterion | Result |
|-----------|--------|
| `zig build test` | ✅ 74/74 across acps / json_rpc / mcp_client targets |
| `zig fmt --check` | ✅ |
| `zig build` binary | ✅ |

## Out of scope

- resources/prompts ACP-side wiring (ACP v2 MCP capabilities), streamable
  HTTP, MCP server role, standalone mcp_client package — `feature/mcp-extraction`.
- Live smoke against a real MCP server (e.g. the reference filesystem server
  via `npx`) — deferred; the scripted transcripts cover the protocol paths.

## Live smoke (2026-08-13)

| Criterion | Result |
|-----------|--------|
| Real MCP server spawn + initialize + tools/list at startup | ✅ ran `zig-out/bin/acps` with `mcpServers.fs = npx @modelcontextprotocol/server-filesystem /tmp`; no `mcp:` warnings; ACP initialize answered normally |
