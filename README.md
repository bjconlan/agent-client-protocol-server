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

Skeleton project — setup complete. **MVP scope**: a usable-for-basic-use ACP v1
server with OpenAI Responses API support (streaming turns + tool calling), no
config file, minimal env vars. See `AGENTS.md` for workflow conventions and
`.ai/knowledge/` for architecture and decisions.

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
zig build run      # runs the binary (prints placeholder banner until the server transport lands)
```

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

Model selection and further options arrive with the first feature.

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
