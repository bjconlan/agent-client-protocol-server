//! ACP method handlers: initialize, session/*, thread/*, turn/*, tool/*,
//! prompt/*.
//!
//! Each handler receives a parsed JSON-RPC request plus the server state and
//! produces a response or notification. The handler set mirrors the ACP spec
//! method list (see `.ai/knowledge/references/acp-spec.md`).
//!
//! Versioning: the `initialize` handshake negotiates `protocolVersion`
//! (uint16, breaking changes only). Handlers are organised per version —
//! `protocol/methods/v1.zig` now, `protocol/methods/v2.zig` later — over a
//! shared core (session/thread/turn machinery). JSON-RPC framing is shared.

const std = @import("std");
