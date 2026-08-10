//! Provider adapter interface.
//!
//! Isolates ACP protocol semantics from model provider HTTP APIs. A provider
//! implementation converts a turn (messages + client-provided tool
//! definitions) into a provider request and streams deltas back as ACP
//! message updates. OpenAI is the first implementation.

const std = @import("std");
