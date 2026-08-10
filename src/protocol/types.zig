//! ACP protocol types: Session, Thread, Turn, Message, content blocks.
//!
//! Mirrors the ACP spec types (see `.ai/knowledge/references/acp-spec.md`).
//! Definitions are derived from the schema during the first feature; until
//! then this module intentionally has no public declarations.

const std = @import("std");
