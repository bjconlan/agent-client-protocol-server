//! CLI arguments and environment configuration.
//!
//! MVP is env-only (no config file):
//! - `OPENAI_API_KEY` — required. Provider API key (never commit it).
//! - `OPENAI_URL` — optional base URL, default `https://api.openai.com/v1`.
//!   Set to an OpenAI-compatible endpoint (e.g. `https://api.deepseek.com/v1`
//!   for DeepSeek) to use another provider.
//! - model selection: TBD during first feature.
//!
//! Parsed from environment during startup.

const std = @import("std");
