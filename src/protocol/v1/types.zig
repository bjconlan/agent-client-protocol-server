//! ACP v1 protocol types (session-oriented).
//!
//! Mirrors the v1 schema types (see `.ai/knowledge/references/acp-schema-v1.json`):
//! SessionId, SessionInfo, PromptRequest, PromptResponse, SessionUpdate
//! variants (agent_message_chunk, etc.), ToolCall, content blocks, ...
//!
//! Populated during F3 (session lifecycle). Until then this module has no
//! public declarations.

const std = @import("std");
