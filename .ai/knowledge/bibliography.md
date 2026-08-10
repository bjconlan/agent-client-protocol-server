# Bibliography

External references — maps URLs to local files in `references/`.

## Agent Client Protocol

- **Source:** https://github.com/zed-industries/agent-client-protocol (repo)
  **Local:** references/acp-schema-v1.json, references/acp-schema-v2.json
  **Notes:** JSON Schema for both protocol versions (v1 = current implementation target, v2 = future). Fetched 2025-08-10.
- **Source:** https://agentclientprotocol.com
  **Local:** — (hosted docs; repo schemas are authoritative for us)
  **Notes:** Generated docs site for the spec.

## OpenAI API

- **Source:** https://github.com/openai/openai-openapi (repo)
  **Local:** references/openai-api.md
  **Notes:** Curated extraction of the Responses API (endpoints, request/response, output items, SSE events, tools). Full spec is `openapi.json`/`openapi.yaml` in the repo. Fetched 2025-08-10.
- **Source:** https://platform.openai.com/docs
  **Local:** —
  **Notes:** Guides (function calling, conversation state, streaming).

## Research summary

- **Local:** references/acp-openai-research.md
  **Notes:** Key findings, ACP↔OpenAI mapping table, open questions.
