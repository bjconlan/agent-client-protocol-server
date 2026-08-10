# Glossary

Project-specific terms and definitions. Add entries as concepts become load-bearing.

## Protocol & Transport

- **ACP (Agent Client Protocol)** — protocol spec (zed-industries/agent-client-protocol, agentclientprotocol.com) defining JSON-RPC 2.0 message exchange between an agent host ("client") and an agent implementation ("server") over stdio.
- **JSON-RPC 2.0** — stateless request/response protocol; ACP uses it with `request_id` correlation for async notifications.
- **Request ID correlation** — ACP associates responses to requests via a `request_id` in notifications (e.g., `turn/update` carrying the `request_id` of the originating `turn/create`).
- **Provider adapter** — internal abstraction isolating ACP protocol semantics from model provider HTTP APIs (OpenAI, etc.). See `src/provider/adapter.zig`.

## ACP Core Types

- **Session** — the top-level container: a conversation history shared across threads. `session/new` creates one.
- **Thread** — a single conversation within a session. `thread/create` starts one.
- **Turn** — a single exchange in a thread: user input + agent output (possibly multiple messages). `turn/create` initiates; `turn/update` streams progress.
- **Message** — a single message in a turn, with a role (user/agent) and content blocks.
- **Content block** — typed message content: `text`, `image`, `audio`, `tool_call`, `tool_result`, `file`.
- **Tool call** — server asks the *client* to execute a tool (tools are client-provided in ACP). `tool/call` request; result delivered via `tool_result` content block in a subsequent turn.
- **Capabilities** — negotiated at `initialize`: server exposes model capabilities; client exposes its own (e.g., tools, prompts, partners).
- **Partner** — a distinct agent identity (model, provider, persona) the client may select between.
- **protocolVersion** — uint16 negotiated in the ACP `initialize` handshake; bumped only for breaking changes, so the server can support multiple protocol versions and route to a versioned method registry. Non-breaking additions arrive via capabilities negotiation.

## Model Provider

- **Chat Completions API** — OpenAI's classic chat endpoint (`/v1/chat/completions`), request/response JSON, optional SSE streaming.
- **Responses API** — OpenAI's newer unified API (`/v1/responses`), supersedes Chat Completions with built-in tooling, streaming, and reasoning.
- **SSE (Server-Sent Events)** — streaming format used by OpenAI (`data: {...}\n\n` deltas).
- **Function calling / tool calling** — OpenAI mechanism for the model to request tool invocation; `tools` array with `function` type, `tool_calls` in response.

- **OpenAI-compatible endpoint** — any provider exposing OpenAI-shaped APIs (e.g. DeepSeek at `https://api.deepseek.com`, `/v1` alias). Configured via `OPENAI_URL`; DeepSeek also documents a Responses API.

## Tooling

- **Zig build system** — `build.zig` + `build.zig.zon`; `zig build`, `zig build test`, `zig fetch` for dependencies.
- **mise** — user-level version manager used to install/pin the Zig toolchain (`mise.toml`).
- **zig fmt** — canonical Zig formatter; enforced via pre-commit hook (`zig fmt --check`).
