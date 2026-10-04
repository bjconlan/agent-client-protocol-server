# Plan: ACP schema refresh — canonical v1.24.1 / v2.0.0-alpha.7

**Branch:** `feature/acp-schema-refresh`
**Created:** 2026-10-04
**Depends on:** none

## Scope

Refresh the canonical ACP references to the currently tagged releases, point
the bibliography at the relocated upstream repository, and reconcile the
implementation with any stable-surface changes.

- Upstream repo moved: `zed-industries/agent-client-protocol` →
  **`agentclientprotocol/agent-client-protocol`**.
- v1 reference: was fetched 2026-08-10 (≈ v1.20.x); canonical is now
  **`schema-v1.24.1`** (2026-09-30, stable).
- v2 reference: was `2.0.0-alpha.2`; canonical is now
  **`schema-v2.0.0-alpha.7`** (2026-09-30, still prerelease).

## Findings — v1.24.1 stable deltas vs the previous local copy

Semantic `$defs` comparison: **no removed definitions, 2 added, 5 changed**.
All changes are **additive and non-breaking**.

| Def | Change |
|---|---|
| `ToolCall` | optional nullable `name` added |
| `ToolCallUpdate` | optional nullable `name` added |
| `AuthMethod` | new `terminal` variant (`AuthMethodTerminal`) |
| `ClientCapabilities` | new optional `auth: AuthCapabilities` (default `{terminal:false}`) |
| `InitializeRequest` | default client capabilities gain `auth.terminal=false` |
| `AuthCapabilities` | **new** |
| `AuthMethodTerminal` | **new** |

Notes:
- `providers/*` and `mcp/message` are **not** in the stable v1 or v2 schema;
  they remain in the v2 `schema.unstable.json`. `feature/acp-v2` and
  `feature/multi-llm-per-session` stay deferred.
- New **stable** v1 agent methods exist that acps does not implement
  (`session/list`, `session/delete`, `session/resume`, `session/close`,
  `logout`, `authenticate`, `session/load`, `session/set_mode`). Unimplemented
  methods are permitted (not advertised); this is an opportunity for the
  session-persistence feature, not a break.
- acps parses `initialize` params as a dynamic `std.json.Value`, so the new
  `auth` client capability is tolerated; `authMethods: []` remains valid.

## Changes

1. Replace `references/acp-schema-v1.json` with the tagged `schema-v1.24.1`
   schema and `references/acp-schema-v2.json` with `schema-v2.0.0-alpha.7`.
2. Add authoritative method-name metadata:
   `references/acp-meta-v1.json`, `references/acp-meta-v1-unstable.json`,
   `references/acp-meta-v2.json`.
3. Update `bibliography.md` to the relocated repo + tagged versions.
4. Conformance: emit the optional `name` field in `tool_call`,
   `tool_call_update`, and the `session/request_permission` `toolCall` object.
5. Record the additive-only finding in `decisions.md`.

## Verification Strategy

- `zig fmt --check .`, `zig build`, `zig build test` (existing suite green).
- The schema files parse as JSON and match the tagged upstream content
  (byte-identical).
- Tool-call notifications now carry `name` (asserted via existing
  transcript/tool tests where applicable).

## Status

- **Stage:** Implementation
- **Current unit:** U1–U5
- **Next action:** verify + commit
