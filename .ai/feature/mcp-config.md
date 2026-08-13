# Plan: MCP server configuration (feature/mcp-config)

## Scope

Add an optional `mcpServers` section to the JSON config (`config.json` /
`ACP_CONFIG`) per the MCP convention: `{ "<name>": { "command": "…",
"args": […], "env": { "KEY": "value" } } }`. Parsed, validated, and exposed
on `Config` for the next task (`feature/mcp-tools-in-acp`) to spawn and wire
into the ACP tool flow. stdio-only for this cut (streamable-HTTP deferred).

Out of scope: spawning/lifecycle, tool-surface integration, env merging into
a spawn `Environ.Map` (the integration task).

## Architecture

- **Data:** `McpServerConfig { name, command, args: [][]const u8, env: []EnvKV }`;
  `EnvKV { key, value }`. All arena-owned (existing config convention).
- **Functions:** `parseMcpServer(allocator, name, value) !McpServerConfig`
  (validates command/args/env, errors name the offending server);
  `Config.mcpServer(name) ?*const McpServerConfig` lookup.
- **Context:** `Config` gains `mcp_servers: []McpServerConfig` (empty when the
  section is absent — MCP stays optional). Parsed once at startup in
  `parseConfig`, alongside providers.
- **API:** config JSON surface only; no behavior changes until the
  integration task consumes `mcp_servers`.

## Units of Work

1. **`EnvKV` + `McpServerConfig` + `Config.mcp_servers`** — types and field.
   Checkpoint: compiles; existing tests pass unchanged (empty default).
2. **`parseMcpServer` + `parseConfig` wiring** — optional `mcpServers`
   section; validation (server must be an object; `command` required string;
   `args` array of strings; `env` object of string values) with errors naming
   the server. Checkpoint: config fixture tests below.
3. **Tests** — parse valid mcpServers (command/args/env, lookup); missing
   command rejected; non-string env value rejected; non-object server
   rejected; section absent → empty list. Checkpoint: `zig build test` green.
4. **Docs + example** — `examples/config.example.json` gains an `mcpServers`
   section; README config docs mention it. Checkpoint: review.

## Verification Strategy

- Config fixture tests via `loadFileAt` (mirrors existing provider tests):
  valid parse + `mcpServer()` lookup; each invalid shape rejected with
  `error.InvalidConfig`; absence → `mcp_servers.len == 0`.
- Whole repo: `zig build test` + `zig fmt --check`.

## References

- MCP client config convention (modelcontextprotocol.io) — `mcpServers`
  map of server name → `{ command, args, env }`.
- Existing: `src/config.zig` provider parsing patterns.

## Status

- **Stage:** 2 (Implementation complete — units 1–4 done)
- **Current unit:** —
- **Last checkpoint:** `zig build test` 72/72 pass (3 new mcpServers config
  tests); `zig fmt --check` clean; example config + README updated
- **Next action:** Review, then `feature/mcp-tools-in-acp` (spawn + wire into
  the ACP tool flow)

## Outcomes

### What was implemented
- `McpServerConfig { name, command, args, env }` + `EnvKV`; `Config.mcp_servers`
  (empty default) + `Config.mcpServer(name)` lookup.
- `parseMcpServer` validation (missing/non-string command, non-array args,
  non-string args/env values, non-object server/section) — errors name the
  server; `parseConfig` wires the optional `mcpServers` section.

### Changes from the original plan
- None material.

### Use cases resolved
- MCP servers declared in `config.json` per the MCP convention, validated at
  startup with clear errors — before any spawning/ACP wiring.

### Verification results
- All checkpoints passed: yes
- Full test suite: 72/72 (3 new)
- Benchmarks: n/a

### Knowledge updates
- (None beyond the plan; config surface follows the existing provider
  parsing patterns.)
