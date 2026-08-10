//! OpenAI provider implementation (Responses API).
//!
//! Target: `/v1/responses` — the modern unified API; see
//! `.ai/knowledge/references/openai-api.md` for the extracted contract
//! (request/response shapes, output items, SSE events, tools).
//! Translates ACP turns/tool calls into Responses API calls; isolated by the
//! provider adapter interface so Chat Completions (or other providers) can be
//! added later.

const std = @import("std");
