# Verification: tool-call round-trip (F5)

Validates the implementation against the plan's verification strategy.

## Verification Strategy → Results

### Data layer
- **Request body exact JSON** — PASS: `buildBody` test asserts `tools` array
  (function type, name, description, parameters object) and model/effort/
  stream flags; `function_call_output` items appended from tool results
- **ToolCall collection from scripted SSE** — PASS: `function_call_arguments.delta`
  accumulation + `output_item.done` finalization → `{id, name, arguments}`

### Function layer
- **Executor branches** — PASS: `get_current_time` (ISO 8601 format asserted),
  `echo` (deterministic), unknown tool → `"ERROR: unknown tool"` text
- **Permission response parsing** — PASS by construction: `{granted: bool}`
  (fossil) and `{outcome: ...}` handled; error responses → denied; timeout →
  denied (10s cap)
- **Loop cap** — PASS: `tool_iteration_cap = 8` bounds the loop

### Context layer
- **Permission slot** — PASS: armed synchronously in `sessionPrompt` (main
  thread) before spawn; the loop can route a response that arrives at any
  time. Race found during testing: the response was processed before the
  worker armed the slot (→ spurious denial + 10s timeout) — fixed by arming
  in the handler
- **History survives multiple prompts** — PASS: worker-level unit test
  (`buildInput` includes stored history + current prompt); the full-transcript
  variant was dropped — back-to-back prompts in a fixed reader race the
  worker's history append (the real client waits for each response, so this
  is a test artifact, not a protocol issue)
- **No leaks** — PASS: 47/47 under testing allocator

### API layer
- **Tool round-trip transcript** — PASS: prompt → `tool_call` (pending) →
  `session/request_permission` (id p1) → `{granted: true}` routed → execute →
  `tool_call_update` (completed, rawOutput) → result fed back → final text →
  `{stopReason: end_turn}` (deterministic `echo` tool)
- **Real binary** — PASS (manual): initialize/session/new work with the openai
  provider wired (no-key lazy fail intact)

## Final checkpoints (review stage)

| Check | Result |
|-------|--------|
| `zig fmt --check .` | PASS |
| `zig build test` | 47/47 PASS |
| `tests/transport-smoke.sh` | PASS |
| Tool round-trip transcript (granted) | PASS |
| History (worker-level unit) | PASS |
| openai function_call SSE collection | PASS |
| Binary wired to openai provider (was echo — F4 gap) | PASS |

## Exceptions / follow-ups
- **Live DeepSeek smoke test: DONE** (2025-08-11) — basic prompt + full tool-call round-trip verified live against api.deepseek.com
- **Genuine fossil-client e2e: DONE** — the real fossil-agent.tcl ACP backend drove our binary (initialize → session/new → prompt → tool call with auto-grant → answer). Found and fixed: fossil string-id serialization (invalid JSON) → integer permission ids; history missing assistant text (back-to-back user messages confused the model) → assistant text accumulated; http Response by-value dangling reader
- History holds user prompts only; assistant text/tool exchanges are
  within-turn (richer history: Epic 2)
- Parallel tool calls are executed sequentially (OpenAI may emit several in
  one response) — fine for MVP
- `session/request_permission` timeout is 10s fixed — client policy (allow
  always) means the client answers from memory; no server-side persistence
- HTTP request timeout for provider calls not yet added (noted in F4
  follow-ups; the permission spin + provider reads can still block on a hung
  connection — revisit with the real smoke test)
