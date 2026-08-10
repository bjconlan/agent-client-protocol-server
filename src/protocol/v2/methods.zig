//! ACP v2 protocol namespace (placeholder).
//!
//! Per the F2 decision, protocol support is version-namespaced and v2 may
//! reuse v1 behavior via `@import("protocol/v1/methods.zig")` — "2 can ref 1".
//! v2 deltas per `acp-schema-v2.json`: PlanUpdate/StateUpdate variants,
//! SessionListCursor, CancelSessionNotification, richer prompt capabilities.
//!
//! Implementation lands in a future epic (Epic 2).

const std = @import("std");
