# Plan: session lifecycle + prompt flow (F3)

## Scope

Implement the session-oriented core of ACP v1: an in-memory session store,
`session/new`, `session/prompt` with streamed `session/update` notifications,
`session/cancel`, and a stub provider behind the adapter seam (OpenAI lands in
F4). After this feature the fossil client can complete a real prompt round-trip.

**In scope:**
- `Context` struct (session store + stdout writer) threaded through handlers
- `session/new` — validate `cwd`, accept `mcpServers` (ignored), return
  `{sessionId}` (monotonic counter as string)
- `session/prompt` — validate sessionId + prompt array; stream
  `agent_message_chunk` updates; return `PromptResponse {stopReason}`
- `session/cancel` (notification) — set pending-cancel flag; cooperative
  best-effort in F3 (see Cancellation decision)
- Provider adapter interface + `EchoProvider` stub in `provider/`
- Capabilities: `sessionCapabilities: {}` stays (now truthful)

**Out of scope (this feature):** real provider (F4), preemptive cancellation
architecture (F4), `session/load`/`list`/`delete`/`resume`/`close` (not
required by baseline — fossil client only uses new/prompt/cancel), tools (F5),
MCP servers, session persistence (Epic 2).

## Architecture

### Data layer

```
Context {
  sessions: *SessionStore,     // StringHashMap(Session) by sessionId
  writer:   *Io.Writer,        // for streaming notifications
  next_session_id: u64,        // monotonic counter
  cancel_flags: ...            // per-session pending-cancel (F3: single flag)
}

Session { id: []const u8, cwd: []const u8 }

Provider (adapter seam):
  generate(ctx, request) !StreamResult   // EchoProvider: split text → chunks
```

- `session/update` notification params (schema `SessionNotification`):
  `{ sessionId, update: { sessionUpdate: "agent_message_chunk", content:
  { type: "text", text: <chunk> }, messageId: <id> } }`
- `PromptResponse` result: `{ stopReason: "end_turn" }`

### Function layer

- `sessionNew(ctx, allocator, params)` — validate `cwd` string (required);
  create Session, assign id, return `{sessionId}`
- `sessionPrompt(ctx, allocator, params)` — look up session (missing →
  `error.InvalidParams`); extract text blocks from `prompt` array; iterate
  provider chunks: emit `session/update` notification per chunk (flush each);
  return `{stopReason: "end_turn"}`
- `sessionCancel(ctx, allocator, params)` — notification handler; set pending
  cancel flag; log
- EchoProvider: for each text block, emit whole text as one chunk (MVP);
  checks pending-cancel flag between blocks (cooperative)

### Context layer

- Session store lives for the process (arena-backed map; sessions persist
  across prompts — the client relies on agent-side context)
- Per-prompt: the handler streams notifications then returns; allocations
  use the per-message arena (notifications serialize into the writer's buffer
  directly)
- Cancellation: F3 = flag + cooperative check (instant stub ⇒ cancel never
  races in practice). Preemptive cancel (schema MUST return `cancelled`) lands
  with F4's event loop / worker thread — documented in decisions.md

### API / Contract

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server
    C->>S: session/new {cwd, mcpServers}
    S-->>C: {sessionId}
    C->>S: session/prompt {sessionId, prompt:[{type:text,text}]}
    loop chunks
        S-->>C: notification session/update {sessionUpdate: agent_message_chunk, content:{type:text,text}}
    end
    S-->>C: {stopReason: end_turn}
    C->>S: notification session/cancel {sessionId}
    S-->>C: (next prompt answers; preemptive cancel in F4)
```

- Handler signature: `fn(ctx: *Context, allocator, params) anyerror!Value`
- Notifications are written by handlers via `ctx.writer` and flushed per
  chunk; server.zig serializes the final response after the handler returns
- Unknown session in `session/prompt` → `-32602 invalid params`

## Units of Work

1. **Context + store** — `Context`, `Session`, `SessionStore`; thread `ctx`
   through `server.zig` dispatch and registry `Handler` signature
   - *Checkpoint:* existing tests updated to the new signature; build green
2. **session/new** — validation + id assignment
   - *Checkpoint:* unit tests — valid request, missing `cwd`, non-string `cwd`;
     id increments
3. **Echo provider + adapter seam** — `provider/adapter.zig` interface,
   `provider/echo.zig`
   - *Checkpoint:* unit tests — chunks emitted, end_turn stopReason
4. **session/prompt streaming** — notifications + PromptResponse via the loop
   - *Checkpoint:* transcript test — prompt → N chunk notifications → response,
     exact bytes; unknown session → -32602
5. **session/cancel** — notification handler + pending flag
   - *Checkpoint:* unit — flag set; notification elicits no response
6. **Conformance + knowledge** — fmt, tests, fixture, docs
   - *Checkpoint:* hook passes; commit

## Verification Strategy

- **Data:** notification JSON exact shape; PromptResponse exact bytes;
  sessionId increments; sessions persist across prompts
- **Function:** validation branches (missing/invalid cwd, unknown sessionId,
  empty prompt array, non-text blocks skipped or error — decide: skip
  non-text blocks with a log, echo text blocks)
- **Context:** session store survives multiple prompts (the client's model);
  no leaks (testing allocator)
- **API:** transcript — full fossil-client flow: initialize → session/new →
  session/prompt (streamed) → response → session/cancel; notifications
  interleaved before response; unknown methods still -32601

## Integration Contract (fossil client, read-only)

- `session/new` params: `{cwd, mcpServers: []}` → expects `{sessionId}`
- `session/prompt` params: `{sessionId, prompt: [{type: text, text}]}` →
  reads `session/update` notifications (`agent_message_chunk` → appends
  `update.content.text`), ignores unknown update kinds, collects usage from
  `usage_update`; does not require specific response fields beyond the
  response arriving
- `session/cancel` notification: `{sessionId}`; client sets its own cancelled
  state; schema says agent MUST answer pending prompt with
  `stopReason: cancelled` (F4)
- `session/request_permission`: client auto-grants — server may send later (F5)

## References

- `.ai/knowledge/references/acp-schema-v1.json` — `NewSessionRequest/Response`,
  `PromptRequest/Response`, `CancelNotification`, `SessionNotification`,
  `SessionUpdate` oneOf variants, `StopReason`, `ContentChunk`/`ContentBlock`
- `~/Downloads/fossil-linux-x64-2.28/fossil-agent.tcl` — client session flow

## Status

- **Stage:** 2 (Implementation)
- **Current unit:** 6 (Conformance)
- **Last checkpoint:** Units 1–5 done — Context/store, session/new, EchoProvider, session/prompt streaming, session/cancel; 31/31 tests; live binary flow verified
- **Next action:** fmt, commit, then review

---

## Outcomes

### What was implemented
- `src/protocol/v1/types.zig` — `Session`, `SessionStore` (process-lifetime
  arena-backed StringHashMap, monotonic ids)
- `src/protocol/v1/methods.zig` — `Context` (sessions + writer + provider),
  `Handler` signature takes ctx; `session/new`, `session/prompt` (streams
  `agent_message_chunk` notifications), `session/cancel` (notification);
  notification registry added
- `src/provider/adapter.zig` + `src/provider/echo.zig` — provider seam +
  EchoProvider stub
- `src/server.zig` — ctx wiring, notification dispatch
- Full session flow works against the real binary

### Changes from the original plan
- None material. Testing caught and fixed a real bug: session keys were
  allocated in the per-message arena (dangling after reset) — the store now
  owns its allocator
- `session/cancel` flag is global (not per-session) — equivalent while at
  most one prompt runs; per-session state lands with F4 preemption

### Use cases resolved
- Client creates a session → `{sessionId}` ✓
- Client sends a prompt → streamed `agent_message_chunk` notifications →
  `{stopReason: end_turn}` ✓
- Client cancels → accepted; cancel-before-prompt answers `cancelled` ✓
  (mid-prompt preemption: F4)
- Sessions persist across prompts (client relies on agent-side context) ✓
- Unknown methods still -32601; malformed input still recovers ✓

### Verification results
- All checkpoints passed: yes
- Full test suite: 31/31 passing; fmt clean; smoke fixture OK
- Benchmarks: n/a

### Knowledge updates
- glossary.md: session-oriented model already corrected (F2); EchoProvider/
  adapter seam described in `provider/` doc comments
- architecture.md: F3 MVP scope noted (session/new + prompt + cancel)
- decisions.md: F3 entry (Handler ctx signature, sessionId counter, cancel
  scoping → F4, mcpServers ignored)
- backlog: F3 task marked done on merge
