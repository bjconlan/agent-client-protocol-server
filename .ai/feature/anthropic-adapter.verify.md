# Verification: Anthropic adapter (Epic 2 F2)

## Verification Strategy → Results

### Data layer
- **Request body exact JSON** — PASS: buildBody tests assert `model`,
  `max_tokens` (from config KV, default 1024), `stream`, translated messages
  (roles/order), flat `tools` `{name, description, input_schema}` from the
  registry
- **SSE parse** — PASS: `message_start` usage, `content_block_start/delta/
  stop` (text_delta → chunks; thinking skipped for display but echoed;
  `input_json_delta` partial accumulation → tool arguments), `message_delta`
  stop_reason/usage merge, `message_stop`, `ping` ignored, `error` →
  GenerateFailed
- **Tool continuation** — PASS: `tool_results` → `tool_result` user message
  (`tool_use_id` + content); assistant content blocks (thinking + tool_use)
  echoed via `output_items`

### Function layer
- **Messages translation** — PASS: Responses-style input items → Anthropic
  messages (user/assistant roles, first text content)
- **tool_use → ToolCall** — PASS: id/name from the block, arguments from
  accumulated partials
- **Stop reasons** — PASS: end_turn / max_tokens; tool_use drives the worker
  loop via non-empty tool_calls
- **Usage** — PASS: message_start input_tokens + message_delta output_tokens
  merged (total = prompt + output)

### Context layer
- **Per-ApiKind dispatch** — PASS: worker transcript test with the anthropic
  slot (fake) — tool call reported, permission, execution, answer streamed;
  the openai slot unchanged (all prior tests green)
- **Health check** — PASS: skipped for anthropic providers (no models
  endpoint — validated lazily); openai unchanged

### API layer
- **Mock round-trip** — PASS: POST /v1/messages with `x-api-key` +
  `anthropic-version` headers; chunks + usage
- **Live (DeepSeek /anthropic)** — PASS: basic prompt streamed
  ("ANTHROPIC E2E OK", usage 135/167); full tool-call round-trip
  (get_current_time executed → timestamp → answer streamed → end_turn)

## Checkpoints

| Check | Result |
|-------|--------|
| `zig fmt --check .` | PASS |
| `zig build test` | 55/55 PASS |
| `tests/transport-smoke.sh` | PASS |
| Cross-compile (windows ReleaseSafe) | PASS |
| Live DeepSeek /anthropic basic + tool call | PASS |

## Exceptions / follow-ups
- Health check has no anthropic equivalent (no models endpoint) — lazy
  validation; a token-costing probe could be added later if desired
- `thinking` blocks are echoed for continuation but not surfaced as ACP
  `agent_thought_chunk` notifications (display-only; out of scope)
- Anthropic `max_tokens` is hard-required by the API — default 1024,
  session-configurable via the `max_tokens` KV
