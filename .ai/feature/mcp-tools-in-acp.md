# Plan: MCP tools in the ACP tool flow (feature/mcp-tools-in-acp)

## Scope

Wire the `mcp_client` module + `mcpServers` config into the ACP server:
spawn + initialize configured MCP servers at startup, fetch their
`tools/list`, merge the definitions into the tool surface the model sees
(alongside the static registry), and execute `tools/call` agent-side through
the existing ACP flow (report → `session/request_permission` grant →
execute → result fed back). stdio-only.

Out of scope: resources/prompts ACP-side wiring (ACP v2), streamable HTTP,
MCP server role, library extraction.

## Architecture

### Data
- `tools/registry.zig` `Tool` gains `ctx: ?*anyopaque = null` (default — the
  static entries are unchanged) and `execute` takes `ctx` first: dynamic
  tools (MCP) carry a dispatch context; Zig has no closures, so the ctx
  pointer is the seam.
- `mcp_bridge.zig` (new, acps module): `Connection { name, client:
  mcp_client.Client }`; `Dispatch { conn: *Connection, tool_name: []const u8 }`
  (one per MCP tool, arena-owned).

### Functions
- `mcp_bridge.connectAll(allocator, io, config, parent_env) ![]Connection` —
  per configured server: spawn `StdioTransport` (argv = command+args; env =
  parent clone + overrides), `initialize` (protocol `2025-06-18`, client
  "acps"). Per-server failures warn + skip (server still runs; tools absent).
- `mcp_bridge.buildToolSurface(allocator, connections) ![]tools.Tool` —
  static registry entries + one entry per MCP tool, name prefixed
  `"<server>:<tool>"` (collision-free), `parameters` = MCP `inputSchema`
  JSON text (same shape), `ctx` → its `Dispatch`.
- `mcpExecute(ctx, allocator, io, args_json)` — parse args JSON →
  `callTool` → join text content blocks → result text (the existing tools'
  contract).

### Context / lifetimes
- `methods.v1.Context` gains `tools: []const tools.Tool` (the merged
  surface); `server.run` builds it once (process-lifetime allocator) and
  takes `mcp_connections` as a parameter (built in `main`).
- Connections + surface outlive sessions/workers; each client serializes its
  own traffic via its write mutex (worker-thread tool calls are safe).

### API / Contract
- `Tool.execute(ctx, allocator, io, args) ![]const u8` — ctx is null for
  static tools.
- MCP tool names in the surface are `"<server>:<tool>"`; the client sees
  them as ordinary tools and grants via the existing flow.
- Failed MCP tool calls become `"ERROR: …"` text (model-recoverable), like
  the static tools.

## Units of Work

1. **registry.zig** — `Tool.ctx` + `execute(ctx, …)` signatures (static fns
   ignore ctx); `lookupIn(surface, name)`. Checkpoint: existing tests pass.
2. **mcp_bridge.zig** — `Connection`, `connectAll`, `buildToolSurface`,
   `Dispatch`, `mcpExecute`; export `mock` from the mcp_client root.
   Checkpoint: unit test — mock-backed connection → merged surface (prefixed
   name, schema text, dispatch round-trip).
3. **methods.zig + server.zig + main.zig wiring** — `Context.tools`,
   `runToolCall` uses `lookupIn` + passes ctx, provider `options.tools` from
   the surface; `run()` takes connections + builds surface; `main` connects.
   build.zig: acps module imports `mcp_client`. Checkpoint: end-to-end
   transcript test (mock-backed MCP server, permission granted, result fed
   back).
4. **Docs + verification** — README tool section, plan/verify files,
   knowledge base. Checkpoint: full suite + fmt.

## Verification Strategy

- Unit: `buildToolSurface` merging + dispatch (mock), name prefixing,
  schema text shape, unknown-tool lookup.
- Integration (server.zig transcript, mirroring the echo tool test): model
  requests `"mcp:<server>:<tool>"` → tool_call notification, permission
  request, grant → mock receives `tools/call` → result text fed back.
- Failure paths: MCP server connection failure warns + skips (server still
  runs); MCP tool call failure → "ERROR: …" text.
- Whole repo: `zig build test` + `zig fmt --check`; live smoke against a real
  MCP server (filesystem) if available.

## References

- `src/mcp_client/` (module), `src/tools/registry.zig`, `src/protocol/v1/
  methods.zig` (`runToolCall`, `Context`), `src/server.zig` (run, tests),
  `src/main.zig` (config/io/env wiring).

## Status

- **Stage:** 1 (Planning)
- **Current unit:** —
- **Last checkpoint:** Plan written
- **Next action:** Implement units 1–4

## Status

- **Stage:** 2 (Implementation complete — units 1–4 done)
- **Current unit:** —
- **Last checkpoint:** `zig build test` 74/74 pass (bridge unit test + full
  ACP-flow MCP round-trip test); `zig fmt --check` clean
- **Next action:** Review, then `feature/mcp-extraction` (standalone mcp_client
  package + v2 MCP-capability wiring) when the v2 spec stabilizes

## Outcomes

### What was implemented
- `tools.Tool` gained `ctx: ?*anyopaque` (default null) + `execute(ctx, …)`;
  `lookupIn(surface, name)`; static registry unchanged.
- `src/mcp_bridge.zig`: `connectAll` (spawn + initialize mcpServers; argv =
  command+args; child env = parent clone + overrides; per-server failure
  warns + skips), `buildToolSurface` (static + MCP tools as
  `"<server>:<tool>"`, `parameters` = MCP inputSchema JSON text, `ctx` →
  per-tool `Dispatch`), `mcpExecute` (args → tools/call → joined text).
- `run()` takes connections + builds the surface; `Context.tools`;
  `runToolCall` uses the merged surface + passes ctx; providers get it.
- `json_rpc.zig` is now a shared `json_rpc` module (a file cannot live in
  two modules) with its own test target; `main` connects at startup.

### Changes from the original plan
- Module-sharing constraint forced `json_rpc.zig` into its own module with a
  dedicated test target (test count redistributed across acps/json_rpc/
  mcp_client targets; nothing lost).
- unmanaged ArrayList `append`/`appendSlice` take the allocator first.

### Use cases resolved
- The model can call MCP-hosted tools through the full ACP flow: the client
  sees `"<server>:<tool>"` defs, grants via `session/request_permission`, and
  acps executes against the owning MCP server, feeding the result back.
- Multiple servers with colliding tool names are collision-free.

### Verification results
- All checkpoints passed: yes
- Full test suite: 74/74
- Live smoke: real reference filesystem MCP server (npx) spawned, initialized,
  and listed tools at startup with no MCP errors (2025-08-11)

### Knowledge updates
- Decisions: MCP tools merged into the ACP tool surface (ctx seam);
  `"<server>:<tool>"` name namespacing.
- Glossary: mcp_bridge, tool surface.
- Architecture: ACP integration section + module-sharing note.
