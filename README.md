# acps — Agent Client Protocol Server

A CLI-based [Agent Client Protocol](https://agentclientprotocol.com) server implemented in Zig.

## What is this?

This project is **acps** (Agent Client Protocol Server) — an ACP server that runs as a CLI
process and communicates with clients (agent hosts/editors) over **stdio** using
JSON-RPC 2.0, as defined by the Agent Client Protocol specification.

The server brokers requests between an ACP-speaking client and a model provider
API. Providers are declared in a config file and served through adapter
implementations per API dialect — currently **OpenAI Responses** (`api:
"openai"`) and **Anthropic Messages** (`api: "anthropic"`), both verified live
end-to-end (including against DeepSeek, which serves both dialects).

## Tech Stack

| Concern | Choice |
|---------|--------|
| Language | Zig (latest stable, managed via mise) |
| Build / dependency resolution | `build.zig` + `build.zig.zon` (`zig fetch`) |
| Protocol | ACP **v1** (v2-ready via `protocolVersion` negotiation) |
| Transport | stdio (stdin/stdout), JSON-RPC 2.0 per ACP spec |
| Model providers | OpenAI Responses API + Anthropic Messages API (adapter per `api`) |
| Tool calling | Agent-side execution; client grants via `session/request_permission` |
| Formatting / conformance | `zig fmt` (enforced via pre-commit hook) |
| Testing | `zig build test` (`std.testing`), mock HTTP server |
| Logging | Zig `std.log`, scoped edge tracing via `ACP_LOG` |
| Target platforms | Linux (initial), cross-platform macOS/Windows later |

## Status

**Epics 1–2 complete.** The server handles the full ACP v1 session flow over
stdio: `initialize` (version negotiation), `session/new` (with a model
config-option selector), `session/set_config_option` (per-session API knobs),
`session/prompt` (streamed `session/update` notifications), `session/cancel`
(preemptive), and agent-side tool execution with client-persisted
permissions. Multi-provider config with two API dialects, both live-verified
(DeepSeek via `/v1` Responses and `/anthropic` Messages).

Deferred items (Epic 3, `.ai/backlog/3.md`): per-session provider switching
(waits on the stabilized ACP v2 `providers/*`), ACP v2 support, session
persistence, a Chat Completions adapter.

## Prerequisites

- [mise](https://mise.jdx.dev) — used to manage the Zig toolchain
- Zig (latest stable):

  ```sh
  mise install          # reads mise.toml, installs zig
  mise use zig@latest   # or update to latest
  ```

## Building

```sh
zig build              # Debug build (dev) → zig-out/bin/acps
zig build --release    # ReleaseFast — pass --release=small for the size-
                       # optimized build used by the release artifacts
```

`zig build test` always runs the suite in Debug (the testing allocator keeps
its safety checks); `--release` builds default to ReleaseFast.

The binary is an ACP server: it reads newline-delimited JSON-RPC 2.0 messages
from stdin and writes responses/notifications to stdout. It waits for a client
connection — stdin EOF (client closing the pipe) terminates it cleanly.

```sh
# e.g. pipe a request in; it answers and waits for more input
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./zig-out/bin/acps
```

`zig build run` does the same but with the terminal attached to stdin — exit
with Ctrl-D (EOF).

## Use as a library

The repo is a library + CLI split: `src/root.zig` exposes the public API
(protocol JSON-RPC framing, session/server machinery, provider adapters,
config, utils), while the CLI (`src/main.zig`) is a separate module — no
`main` conflicts for consumers. The package (`build.zig.zon` `.paths`) ships
only `build.zig`, `build.zig.zon`, and `src/`.

Add it as a dependency (the `src` artifact from a release tag works too):

```zig
// build.zig.zon
.dependencies = .{
    .acps = .{
        .url = "https://github.com/bjconlan/agent-client-protocol-server/archive/refs/tags/<date-time-stamp>.tar.gz",
        .hash = "...", // fill with `zig fetch --save <url>`
    },
},
```

```zig
// build.zig
const acps = b.dependency("acps", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("acps", acps.module("acps"));
```

```zig
// usage — `parse` returns a `Parsed` whose arena owns all message memory
const acps = @import("acps");
var parsed = try acps.protocol.json_rpc.parse(allocator, line);
defer parsed.deinit();
switch (parsed.message) {
    .request => |r| …,  // r.method, r.params
    else => …,
}
```

### API surface

Exported by `src/root.zig` (`@import("acps")`):

| Module | Contents |
|--------|----------|
| `acps.protocol.json_rpc` | Wire format: `parse` (→ `Parsed`, arena-owned `Message`), `Message` (request/notification/response/error_response), `RequestId`, `ErrorObject`, `ErrorCode`, `serializeRequest/Notification/Response/Error` |
| `acps.protocol.v1` | ACP v1 `types` + `methods` (initialize, session/new, session/prompt, …) |
| `acps.protocol.v2` | ACP v2 method registry (v2-ready dispatch seam) |
| `acps.server` | `run()` — the stdio transport loop |
| `acps.config` | `Config`, `ApiKind` (`openai` \| `anthropic`), `ProviderConfig` |
| `acps.provider` | Adapter interface + `openai`, `anthropic`, `echo` implementations |
| `acps.tools` | Server-side tool registry |
| `acps.util` | `json` helpers, `http` client, `log`, `mock_http` (test-only) |

## Testing

```sh
zig build test     # runs the test suite (std.testing)
zig fmt --check .  # formatting conformance
```

A pre-commit hook runs `zig fmt --check` + `zig build test` on every commit
(versioned in `.githooks/`, wired via `git config core.hooksPath .githooks`).

An end-to-end smoke test drives the real fossil ACP client against the binary
(`tclsh tests/fossil-e2e.tcl`), and `tests/transport-smoke.sh` checks the
stdio transport transcript.

## Configuration

### Config file (multi-provider)

A JSON config file (from `$ACP_CONFIG` or
`~/.config/acps/config.json`) declares named providers:

```json
{
  "default_provider": "deepseek",
  "providers": {
    "deepseek": {
      "api": "openai",
      "url": "https://api.deepseek.com/v1",
      "api_key_env": "DEEPSEEK_API_KEY",
      "model": "deepseek-v4-flash"
    },
    "deepseek-anthropic": {
      "api": "anthropic",
      "url": "https://api.deepseek.com/anthropic",
      "api_key_env": "DEEPSEEK_API_KEY",
      "model": "deepseek-v4-flash"
    }
  }
}
```

| Field | Purpose |
|-------|---------|
| `default_provider` | Optional; the default is the **first listed** provider |
| `providers.<name>.api` | Adapter dialect: `openai` (Responses API) or `anthropic` (Messages API) |
| `providers.<name>.url` | Base URL; `/responses` or `/v1/messages` is appended per dialect |
| `providers.<name>.api_key` | Inline key, or |
| `providers.<name>.api_key_env` | Name of an env var holding the key (resolved at load) |
| `providers.<name>.model` | Fallback model (default `deepseek-v4-flash`); the session can override it |

See `examples/config.example.json` for a full example.

### Environment variables

**A config file is required** — all provider settings (keys, URLs, models)
live there; the server's own env surface is intentionally minimal:

| Variable | Purpose |
|----------|---------|
| `ACP_CONFIG` | Provider config — a **file path** or **inline JSON** (auto-detected: a leading `{` is taken as the JSON itself, anything else as a path). Defaults to `~/.config/acps/config.json` |
| `ACP_LOG_LEVEL` | Log level: `err` / `warn` / `info` / `debug` (default `info`) |

For example, inline (handy in k8s — the ConfigMap value *is* the config):

```sh
ACP_CONFIG='{"providers":{"default":{"api":"openai","url":"https://api.deepseek.com/v1","api_key_env":"DEEPSEEK_API_KEY","model":"deepseek-v4-flash"}}}' \
  ./zig-out/bin/acps
```

A missing config is a clear startup error naming the expected source.
Provider keys come from `api_key` (inline) or `api_key_env` (an env var the
config references — e.g. `"api_key_env": "DEEPSEEK_API_KEY"`), so secrets can
stay in Secret env vars while the config lives in a ConfigMap.

### Session configuration (per session)

`session/new` advertises a **model** config option (ACP `configOptions`).
`session/set_config_option` stores arbitrary key/value pairs on the session —
the model plus any API knob (`max_tokens`, `temperature`, `system`, …) — which
are forwarded to the provider request. The provider applies the fields it
understands and skips the rest with a log. Values are free-form, so newer
models/knobs work without config changes; invalid values surface as clear
provider errors at prompt time.

## Turn lifecycle & cancellation

- `session/cancel` preempts an in-flight prompt (the worker polls between
  streamed chunks and answers `stopReason: "cancelled"`). A cancel that
  arrives before a prompt answers it `cancelled` immediately; the flag is
  consumed per turn, so the next prompt is unaffected.
- **Closing stdin mid-turn cancels the prompt** (the server treats EOF as
  client shutdown: it cancels any in-flight worker and joins it). A client
  that closes its pipes while a prompt is running gets `stopReason:
  "cancelled"`.
- Writes after the client has gone are safe: SIGPIPE is ignored at startup and
  write errors end the turn quietly (no crash, no stderr spam).

## Logging

All logs go to **stderr** (stdout carries protocol messages only). Set
`ACP_LOG_LEVEL=debug` to trace everything on the system edge:

```
[transport] https://…  ← every stdio line in/out (the client session)
[http]      https://api.deepseek.com/v1/responses POST body={...}   ← request
[http]      https://api.deepseek.com/v1/models 200 body={...}       ← response (non-streaming)
[provider]  sse: data: {"type":"response.output_text.delta",...}    ← streaming response body
```

| Scope | Traces |
|-------|--------|
| `transport` | Every JSON-RPC line in/out over stdio |
| `http` | One line per request (`{url} {method} body=…`) and response (`{url} {status} body=…`) |
| `provider` | Every SSE event/data line of a streaming response |
| `config` | Config file loading/validation |

Log levels: `debug` enables the traces above; `info` (default) shows
informational messages; `warn`/`err` reduce noise.

## Deployment

- **Local development** (current)
- **Cross-platform builds** (macOS/Windows) — verified via `zig build -Dtarget=…`
- **GitHub Actions** (`.github/workflows/`) — CI matrix (fmt/build/test on
  linux/mac/windows) and a release workflow that runs only on pushed tags.
  Tags are date-time stamps in fossil's snapshot format (`YYYYMMDDHHMMSS`,
  e.g. `20260801193352`); the tag is the version in the artifacts, named
  fossil-style `acps-<platform>-<stamp>` — `linux-x64`, `mac-arm`, `mac-x64`,
  `pi`, `src`, `w32`, `w64`, `win-arm` (`.tar.gz` for unix/pi/src, `.zip` for
  windows). All targets are cross-compiled from the ubuntu runner via
  `zig build -Dtarget=…`; `src` is a `git archive` tarball.

### Cutting a release

A release is triggered by pushing a tag in fossil's snapshot date-time format
(`YYYYMMDDHHMMSS`, UTC — the workflow also accepts the 12-digit
`YYYYMMDDHHMM`). The tag becomes the version in the artifact names:

```sh
export TAG="$(date -u +%Y%m%d%H%M%S)"; git tag $TAG && git push origin $TAG
```

The workflow then cross-compiles all 7 binary targets + the source tarball and
attaches them to a GitHub release (`acps-<platform>-<stamp>`, e.g.
`acps-linux-x64-20260801193352.tar.gz`).

## Project layout

```
src/
├── main.zig          # CLI entry: stdio loop + health check + std_options
├── root.zig          # library root (public API)
├── config.zig        # provider registry (JSON file / env)
├── protocol/         # ACP: json_rpc framing, v1 types + method handlers
├── provider/         # adapter interface + openai / anthropic / echo impls
├── tools/            # server-side tool registry (agent-executed)
└── util/             # http client wrapper, logging, mock HTTP server (tests)
```
