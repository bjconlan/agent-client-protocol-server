# Verify: MCP server configuration (feature/mcp-config)

Validates the implementation against the plan's verification strategy
(`.ai/feature/mcp-config.md`).

## Config fixture tests (`loadFileAt`)

| Criterion | Result |
|-----------|--------|
| Valid `mcpServers` parse: command/args/env + `mcpServer()` lookup | ✅ `test "loadFileAt: parses and validates mcpServers"` — two servers (full + bare), args/env contents asserted, unknown name → null |
| Section absent → empty list (MCP stays optional) | ✅ `test "loadFileAt: mcpServers absent leaves the list empty"` |
| Server not an object → `InvalidConfig` | ✅ |
| Missing `command` → `InvalidConfig` | ✅ |
| Non-string `command` → `InvalidConfig` | ✅ |
| `args` not an array / non-string arg → `InvalidConfig` | ✅ |
| `env` not an object / non-string env value → `InvalidConfig` | ✅ |
| `mcpServers` itself not an object → `InvalidConfig` | ✅ (all in `test "loadFileAt: invalid mcpServers rejected"` — 7 cases) |

## Whole repo

| Criterion | Result |
|-----------|--------|
| `zig build test` all suites green | ✅ 72/72 (69 + 3 new) |
| `zig fmt --check` clean | ✅ |
| Existing provider configs unchanged (empty default) | ✅ existing tests pass |

## Out of scope (next task)

- Spawning/lifecycle of MCP servers, env merge into a spawn `Environ.Map`,
  ACP tool-surface integration — `feature/mcp-tools-in-acp`.
