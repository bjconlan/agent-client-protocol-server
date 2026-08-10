# Research: ACP spec + OpenAI Responses API

## Date
2025-08-10

## Sources consulted
- **Primary (saved locally):**
  - ACP schema v1: `acp-schema-v1.json` (zed-industries/agent-client-protocol, `schema/v1/schema.json`, fetched 2025-08-10)
  - ACP schema v2: `acp-schema-v2.json` (same repo, `schema/v2/schema.json`)
  - OpenAI Responses API extraction: `openai-api.md` (openai/openai-openapi `openapi.json`, fetched 2025-08-10)
- **Web (not saved):**
  - https://agentclientprotocol.com (hosted spec docs)
  - https://platform.openai.com/docs (API guides)

## Key findings

### ACP (Agent Client Protocol)
- JSON-RPC 2.0 over stdio; server reads stdin, writes stdout.
- **Versioning:** `InitializeRequest.protocolVersion` is a **uint16**, bumped only for breaking changes; non-breaking additions ride on capabilities negotiation. → the hook for dual-version support.
- **v1 schema:** 168 defs, 55 request/response method types. Covers: `initialize`, session lifecycle (`new/load/resume/close/delete/list`), threads/turns, `cancel`, prompts, **terminals** (create/kill/read/write/wait/release + output), **elicitation** (create + complete notification), **permissions** (`request_permission`), auth (`authenticate`/`logout`), session config (`set_session_config_option`, `set_session_mode`).
- **v2 schema:** 172 defs — adds plan content (`PlanUpdateContent`), **MCP capabilities**, resource links/embedded resources, diffs (file patches), additional capabilities. v2 is still evolving (see `schema/v2/meta.unstable.json`).
- ACP is **client-driven**: the *client* supplies tools (tool definitions + execution); the server requests tool calls from the client and receives results. This inverts the usual OpenAI direction and shapes the `tool/call` → `tool_result` turn flow.

### OpenAI — Responses API (chosen target over Chat Completions)
- Modern unified API at `https://api.openai.com/v1/responses`; Chat Completions is the legacy API.
- **Lifecycle endpoints:** `POST /responses` (create, `stream: true` for SSE), `GET|DELETE /responses/{id}`, `POST /responses/{id}/cancel` (background responses only), `GET /responses/{id}/input_items`, `POST /responses/compact`, `POST /responses/input_tokens`.
- **Request:** `model`, `input` (typed input items), `instructions`, `tools` (function, file_search, web_search, computer, mcp, code_interpreter, programmatic), `tool_choice`, `stream`, `include`, `previous_response_id`, `reasoning`, `context_management`, `store`, `prompt_cache_*`.
- **Response:** `id`, `status` (`queued|in_progress|completed|failed|cancelled|incomplete`), `output` (typed items), `output_text`, `usage`, `error`.
- **Output items** (discriminated by `type`): `message` (role assistant, content parts), `function_call` (`call_id`, `name`, `arguments` JSON string), `function_call_output`, `reasoning`, `web_search_call`, `code_interpreter_call`, `mcp_call`, `custom_tool_call`.
- **Streaming events:** `response.created`, `response.in_progress`, `response.output_item.added`, `response.content_part.added`, `response.output_text.delta` / `.done`, `response.function_call_arguments.delta` / `.done`, `response.output_item.done`, `response.completed`, `response.failed`, `response.incomplete`, `response.error`.
- **Tool calling flow:** model emits `function_call` output item → caller executes → `function_call_output` item is appended to `input` for the next `/responses` call.

### ACP ↔ OpenAI Responses mapping (for the provider adapter)
| ACP | OpenAI Responses |
|-----|------------------|
| Turn (user input) | `POST /responses` with `input` items |
| Agent text content | `message` output item + `output_text`; SSE `response.output_text.delta` → ACP `turn/update` content chunks |
| Tool request (client-provided tools) | `function_call` output item + `tools` param from client tool defs |
| Tool result content block | `function_call_output` input item appended to `input` for next call |
| Turn streaming | SSE events → `turn/update` notifications |
| Turn cancellation | `POST /responses/{id}/cancel` |
| Session compaction (v2 `SessionConfig`) | `POST /responses/compact` |
| Token usage in `turn/update` | `usage` in final event / response object (`stream_options.include_usage`) |

## Relevance to current work
- Implement against **v1 schema** (the contract), with the protocol layer structured to route by `protocolVersion` so v2 can be added without rework.
- Provider adapter must translate ACP tool definitions (client-provided) → OpenAI `tools` array, and OpenAI `function_call` items → ACP `tool_call` content blocks.
- OpenAI key goes in env (`OPENAI_API_KEY`), never in code.

## Open questions
- Does the hosted agentclientprotocol.com docs reflect v2 as current? (We pin to the repo schemas regardless.)
- ACP v1 tool schema details (exact `ToolCall`/`ToolCallContent` shape) — extract from `acp-schema-v1.json` during planning.
- Which OpenAI models are available for the chosen deployment (model list is dynamic; pin via config). Note: with `OPENAI_URL` pointed at DeepSeek, the model would be `deepseek-chat` / `deepseek-reasoner`.
