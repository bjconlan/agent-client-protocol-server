# Architecture

System architecture decisions and rationale. Updated whenever a decision is revisited.

*(Initial skeleton — architecture will be written during the project overview / first planning stage, referencing the ACP spec and OpenAI API docs in `references/`.)*

## Planned Shape (from setup)

```
                 ┌──────────────────────────┐
                 │       ACP Client          │
                 │   (agent host / editor)   │
                 └────────────┬─────────────┘
                              │ JSON-RPC 2.0 over stdio
                 ┌────────────▼─────────────┐
                 │      src/main.zig         │  transport loop: parse stdin → dispatch → write stdout
                 │      protocol/            │  ACP v1 types + method handlers (session/*, thread/*, turn/*, tool/*, prompt/*)
                 │      provider/            │  provider adapters (OpenAI Responses first)
                 └────────────┬─────────────┘
                              │ HTTPS
                 ┌────────────▼─────────────┐
                 │      OpenAI API           │  /v1/responses (streaming, tool calling)
                 └──────────────────────────┘
```

## MVP scope (confirmed 2025-08-10)

Usable-for-basic-use ACP v1 server, OpenAI Responses API only, no config file, minimal env vars (`OPENAI_API_KEY`). Deployed locally first; cross-platform + GitHub Actions release builds later. The first feature (planning stage) defines the exact MVP method set — likely: `initialize`, `session/new`, `thread/create`, `turn/create` (+ streaming `turn/update`), minimal `tool/call` support for client-provided tools.

Key principles:
- **Protocol/transport separated from provider** — `protocol/` knows ACP and JSON-RPC; `provider/` knows HTTP APIs; `src/main.zig` wires them together.
- **Stdlib-only** — `std.json`, `std.http.Client`, `std.io`; no third-party Zig deps until a real need appears.
- **Stateless core + explicit state** — sessions/threads/turns stored in memory (prototype phase); persistence is a later decision.
- **Version-aware protocol layer** — ACP v1 primary, v2-ready. `InitializeRequest.protocolVersion` (uint16) selects a versioned method registry at the handshake; JSON-RPC framing and session/thread/turn core are shared across versions. Non-breaking additions ride on capabilities negotiation.
