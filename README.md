# Agent Client Protocol — Server

A CLI-based [Agent Client Protocol](https://agentclientprotocol.com) server implemented in Zig.

## What is this?

This project is an **ACP server** that runs as a CLI process and communicates with
clients (agent hosts/editors) over **stdio** using JSON-RPC 2.0, as defined by the
Agent Client Protocol specification.

The server brokers requests between an ACP-speaking client and a model provider
API. The current implementation targets **OpenAI's Responses API**, behind a
provider-adapter interface intended to support additional providers later.

## Tech Stack

| Concern | Choice |
|---------|--------|
| Language | Zig (latest stable, managed via mise) |
| Build / dependency resolution | `build.zig` + `build.zig.zon` (`zig fetch`) |
| Protocol | ACP **v1** (v2-ready via `protocolVersion` negotiation) |
| Transport | stdio (stdin/stdout), JSON-RPC 2.0 per ACP spec |
| Model provider | OpenAI Responses API (first adapter) |
| Formatting / conformance | `zig fmt` (enforced via pre-commit hook) |
| Testing | `zig build test` (`std.testing`) |
| Target platforms | Linux (initial), cross-platform macOS/Windows later |

## Status

**MVP complete.** The server handles the full ACP v1 session flow over stdio:
`initialize` (version negotiation), `session/new`, `session/prompt` with
streamed `session/update` notifications, `session/cancel` (preemptive), and
agent-side tool execution (`session/request_permission` + `tool_call`
updates) with client-persisted permissions. Backed by the OpenAI Responses
API (or any OpenAI-compatible endpoint — verified live against DeepSeek with
`get_current_time`). No config file; env-only.

Remaining roadmap (Epic 2): Anthropic adapter, multi-provider config,
multiple LLMs per session (ACP v2 partners), ACP v2 support, persistence.

## Prerequisites

- [mise](https://mise.jdx.dev) — used to manage the Zig toolchain
- Zig (latest stable):

  ```sh
  mise install          # reads mise.toml, installs zig
  mise use zig@latest   # or update to latest
  ```

## Building

```sh
zig build          # compiles to zig-out/bin/agent_client_protocol
```

The binary is an ACP server: it reads newline-delimited JSON-RPC 2.0 messages
from stdin and writes responses/notifications to stdout. It waits for a client
connection — stdin EOF (client closing the pipe) terminates it cleanly.

```sh
# e.g. pipe a request in; it answers and waits for more input
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./zig-out/bin/agent_client_protocol
```

`zig build run` does the same but with the terminal attached to stdin — exit
with Ctrl-D (EOF).

## Testing

```sh
zig build test     # runs the test suite (std.testing)
zig fmt --check .  # formatting conformance
```

A pre-commit hook runs `zig fmt --check` + `zig build test` on every commit
(versioned in `.githooks/`, wired via `git config core.hooksPath .githooks`).

## Configuration

MVP has no config file. Provider settings come from environment:

| Variable | Purpose |
|----------|---------|
| `OPENAI_API_KEY` | Required. Provider API key (never commit it) |
| `OPENAI_URL` | Base URL, default `https://api.openai.com/v1`. Point at any OpenAI-compatible endpoint, e.g. `OPENAI_URL=https://api.deepseek.com/v1` for DeepSeek (their Responses API is OpenAI-compatible) |
| `ACP_LOG` | Log level: `err` / `warn` / `info` / `debug` (default `info`). `debug` traces the system edges — stdio lines (`transport`), provider HTTP requests/bodies/status (`http`), and provider SSE (`provider`) — all on stderr |

**Multi-provider config:** a JSON file (`$ACP_CONFIG` or
`~/.config/agent-client-protocol/config.json`) declares named providers:
```json
{ "default_provider": "deepseek",
  "providers": {
    "deepseek": { "api": "openai", "url": "https://api.deepseek.com/v1", "api_key_env": "DEEPSEEK_API_KEY", "model": "deepseek-v4-flash" },
    "anthropic": { "api": "anthropic", "url": "https://api.anthropic.com", "api_key_env": "ANTHROPIC_API_KEY", "model": "claude-sonnet-4-5" }
  } }
```
`api` selects the adapter dialect (`openai` Responses API | `anthropic`
Messages API); `model` is the fallback — the session can override it (or set
any API knob like `max_tokens`, `temperature`) via `session/set_config_option`.
Without a file, the flat env vars define a single default provider.

## Deployment

- **Phase 1:** local development usage
- **Phase 2:** cross-platform builds (macOS/Windows)
- **Phase 3 (later):** GitHub Actions CI with release artifacts

## Project layout

```
src/
├── main.zig          # CLI entry: stdio JSON-RPC 2.0 transport loop
├── root.zig          # library root (public API)
├── config.zig        # env configuration (API key, model)
├── protocol/         # ACP: json_rpc framing, types, v1 method handlers
├── provider/         # adapter interface + OpenAI Responses implementation
└── util/             # json / http helpers
```
