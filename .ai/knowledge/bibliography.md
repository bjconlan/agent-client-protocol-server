# Bibliography

External references — maps URLs to local files in `references/`.

## Agent Client Protocol

- **Source:** https://github.com/agentclientprotocol/agent-client-protocol (repo — moved from `zed-industries/agent-client-protocol`)
  **Local:** references/acp-schema-v1.json, references/acp-meta-v1.json, references/acp-meta-v1-unstable.json, references/acp-schema-v2.json, references/acp-meta-v2.json
  **Notes:** JSON Schema + method-name metadata. v1 = current implementation target (tag `schema-v1.24.1`); v2 = future, still alpha (tag `schema-v2.0.0-alpha.7`). `providers/*` and `mcp/message` remain in the v2 **unstable** schema. Fetched 2026-10-04.
- **Source:** https://agentclientprotocol.com
  **Local:** — (hosted docs; repo schemas are authoritative for us)
  **Notes:** Generated docs site for the spec.

## OpenAI API

- **Source:** https://github.com/openai/openai-openapi (repo)
  **Local:** references/openai-api.md
  **Notes:** Curated extraction of the Responses API (endpoints, request/response, output items, SSE events, tools). Full spec is `openapi.json`/`openapi.yaml` in the repo. Fetched 2026-08-10.
- **Source:** https://platform.openai.com/docs
  **Local:** —
  **Notes:** Guides (function calling, conversation state, streaming).

## Research summary

- **Local:** references/acp-openai-research.md
  **Notes:** Key findings, ACP↔OpenAI mapping table, open questions.

## Zig Toolchain

- **Source:** https://ziglang.org/download/0.17.0/release-notes.html
  **Local:** references/zig-0.17-release-notes.md
  **Notes:** Migration-relevant extract of the Zig 0.17.0 release notes (build system, language, stdlib). Basis of `feature/zig_0_17_migration`. Read 2026-10-04.
- **Source:** https://ziglang.org/download/0.16.0/release-notes.html
  **Local:** — (superseded by 0.17.0; historical mutations referenced in old plans)
