//! JSON-RPC 2.0 framing, parsing, and serialization.
//!
//! ACP is a JSON-RPC 2.0 protocol carried over stdio. This module owns the
//! wire format: parsing incoming requests/notifications and serializing
//! responses/notifications, including error objects and request-id
//! correlation. Implementation lands during the first feature.

const std = @import("std");
