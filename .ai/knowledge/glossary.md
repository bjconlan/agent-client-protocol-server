# Glossary

Project-specific terms and definitions. Add entries as concepts become load-bearing.

## Project

- **acps** — short name of this project (Agent Client Protocol Server, repo
  `agent-client-protocol-server`). Also the binary/package name (`acps`), the ACP
  `agentInfo.name` reported at `initialize`, and the default config dir
  (`~/.config/acps/config.json`).

## Protocol & Transport

- **ACP (Agent Client Protocol)** — protocol spec (zed-industries/agent-client-protocol, agentclientprotocol.com) defining JSON-RPC 2.0 message exchange between an agent host ("client") and an agent implementation ("server") over stdio.
- **JSON-RPC 2.0** — stateless request/response protocol; ACP uses it with `request_id` correlation for async notifications.
- **Request ID correlation** — ACP associates responses to requests via a `request_id` in notifications (e.g., `turn/update` carrying the `request_id` of the originating `turn/create`).
- **Provider adapter** — internal abstraction isolating ACP protocol semantics from model provider HTTP APIs (OpenAI, etc.). See `src/provider/adapter.zig`.

## ACP Core Types (session-oriented — per schema v1/v2)

- **Session** — the top-level container: a conversation history and state. `session/new` creates one; `session/prompt` sends prompts into it; `session/cancel` interrupts. No Thread/Turn types exist in the current schemas (earlier ACP drafts used them; the pinned v1/v2 schemas do not).
- **Prompt** — the unit of exchange: `session/prompt` params carry a `prompt` array of content blocks (text, etc.).
- **SessionUpdate** — the streaming update notification: `session/update` params carry `update.sessionUpdate` variants (`agent_message_chunk`, `agent_message_completed`, `plan_update`, `session_info_update`, `usage_update`, `config_update`, `current_mode_update`, …).
- **PromptResponse** — the result of a prompt turn, incl. `stopReason` (e.g. `end_turn`, `max_tokens`, `cancelled`).
- **Content block** — typed content: `text`, `image`, `audio`, `tool_call`, `tool_result`, `file` (schema `ContentBlock`).
- **Tool call** — the server asks the *client* to execute a tool (tools are client-provided in ACP); results flow back via `tool_result` content in a subsequent prompt / follow-up turn.
- **Capabilities** — negotiated at `initialize`: server exposes model capabilities; client exposes its own (e.g., tools, prompts, partners).
- **Partner** — a distinct agent identity (model, provider, persona) the client may select between.
- **protocolVersion** — uint16 negotiated in the ACP `initialize` handshake; bumped only for breaking changes, so the server can support multiple protocol versions and route to a versioned method registry. Non-breaking additions arrive via capabilities negotiation.

## Model Provider

- **Chat Completions API** — OpenAI's classic chat endpoint (`/v1/chat/completions`), request/response JSON, optional SSE streaming.
- **Responses API** — OpenAI's newer unified API (`/v1/responses`), supersedes Chat Completions with built-in tooling, streaming, and reasoning.
- **SSE (Server-Sent Events)** — streaming format used by OpenAI (`data: {...}\n\n` deltas).
- **Function calling / tool calling** — OpenAI mechanism for the model to request tool invocation; `tools` array with `function` type, `tool_calls` in response.

- **OpenAI-compatible endpoint** — any provider exposing OpenAI-shaped APIs (e.g. DeepSeek at `https://api.deepseek.com`, `/v1` alias). Configured via `OPENAI_URL`; DeepSeek also documents a Responses API.

## Zig 0.16 stdlib idioms (learned during F1)

- `std.json.Value.jsonParse(allocator, &scanner, .{ .allocate = .alloc_always, .max_value_len = line.len })` with `std.json.Scanner.initCompleteInput(allocator, slice)` parses a dynamic value; pass `.max_value_len` explicitly (jsonParse unwraps it)
- **Union field access is non-optional** in 0.16 — `value.object orelse ...` is a compile error; use `switch (value) { .object => |o| o, else => ... }`
- `std.json.Stringify.value(x, .{}, writer)` where `x` must be an explicit `std.json.Value{...}` — an anonymous `.{ .object = obj }` literal is inferred as a struct and fails to stringify (iterates the map's internals, hits `[*]u8`)
- `std.Io.Reader.takeDelimiter('\n')` returns `!?[]u8` (null on EOF; slice is borrowed from the reader's buffer, valid until the next read); `error.StreamTooLong` when the line exceeds the reader buffer; `discardDelimiterInclusive` consumes the oversized line
- `std.json.ObjectMap` / `std.json.Array` are managed — `obj.put(allocator, key, value)`, `obj.get(key)` (allocator-free), `obj.deinit(allocator)`

## Tooling

- **Zig build system** — `build.zig` + `build.zig.zon`; `zig build`, `zig build test`, `zig fetch` for dependencies.
- **mise** — user-level version manager used to install/pin the Zig toolchain (`mise.toml`).
- **zig fmt** — canonical Zig formatter; enforced via pre-commit hook (`zig fmt --check`).

## Runtime internals (post-Epic-2)

- **PromptWorker** — per-prompt thread: own arena (process-allocator backed),
  deep-copied params/id; streams chunks (writer mutex), polls the cancel flag,
  executes tools agent-side, writes the final response. Joined at EOF.
- **DeferredResponse** — sentinel error returned by `session/prompt` after
  spawning: the dispatcher must not write a response (the worker owns the
  turn's output). Returning it fires errdefers — the worker arena is passed
  by explicit ownership, never errdefer.
- **PendingPermission** — single-slot `session/request_permission` handshake:
  armed synchronously before spawn with an INTEGER request id (1000+; the
  fossil client serializes string ids as bare tokens → invalid JSON); the
  main loop routes inbound responses by id.
- **ApiKind** — adapter discriminator from config `api`: `openai` (Responses
  API: nested `function` tools, Bearer auth, `reasoning.effort`) | `anthropic`
  (Messages API: flat tools, `x-api-key` + `anthropic-version`, `max_tokens`
  required, `tool_use`/`tool_result` blocks). Dispatched via
  `Context.adapters[@intFromEnum(ApiKind)]`.
- **Session config KVs** — `session/set_config_option` stores arbitrary
  configId→value pairs; forwarded to the provider request (`model` required,
  known knobs applied, unknowns skipped with a log).
- **ACP_LOG scopes** — `transport` (stdio in/out), `http` (one line per
  request `{url} {method} body=…` / response `{url} {status} body=…`),
  `provider` (SSE lines). Runtime level via the env var; binary only.
- **Zig 0.16 replacements** — `Io.Mutex` (spinlock via `tryLock`+yield),
  `Io.Clock.now(.real, io)`, `Io.Threaded.init(a, .{}).io()`, `Io.Dir.cwd()`
  + `readFileAlloc(dir, io, ...)`, `std.testing.io`, `std.process.Environ`
  (createMap/get), `std.os.linux.*` for nanosleep/clock_gettime.

## MCP

- **MCP (Model Context Protocol)** — protocol (modelcontextprotocol.io) standardizing how applications expose tools/resources/prompts to LLM applications. JSON-RPC 2.0 based; client and server roles. acps implements the **client** role (`src/mcp_client/`) to call external tool servers.
- **MCP stdio transport** — newline-delimited JSON-RPC 2.0 over a spawned child process's stdin/stdout (same framing as ACP's own transport).
- **`initialize` handshake** — MCP's version negotiation: client sends `protocolVersion` (date-stamped, e.g. `2025-06-18`) + capabilities + clientInfo; server replies with its protocol version, capabilities, serverInfo; client then MUST send `notifications/initialized`.
- **`tools/list` / `tools/call`** — MCP tool discovery and invocation. Tool `inputSchema` is JSON Schema — maps directly onto ACP's `Tool.parameters` shape. `tools/call` returns content blocks (`text` supported in the first cut) plus `isError`.
- **`resources/*` / `prompts/*`** — MCP's other surfaces (named resources read by URI; prompt templates resolved to messages). Client methods implemented; ACP-side wiring deferred to ACP v2 (whose schema includes MCP capabilities).
- **mcp_client module** — `src/mcp_client/`, Zig module `mcp_client`; generic and protocol-agnostic, extractable to a separate package later. Depends on the `json_rpc` module (declared module import).
