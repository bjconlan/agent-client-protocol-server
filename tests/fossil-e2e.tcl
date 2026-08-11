#!/usr/bin/env tclsh
# Genuine e2e: drive the fossil client's ACP backend against our server.
# Spawns acps as the ACP agent, runs initialize →
# session/new → session/prompt (streamed) → collects content/usage/calls.
# Run with a provider config (config file required): e.g.
#   ACP_CONFIG=/path/to/config.json tclsh tests/fossil-e2e.tcl
source /home/bjc/Downloads/fossil-linux-x64-2.28/fossil-agent.tcl

set cfg [dict create \
    acp_command /home/bjc/Workspace/agent-client-protocol-server/zig-out/bin/acps \
    model      deepseek-v4-flash \
    cwd        /tmp \
    timeout    90]

set handle [::agent::backend::create acp $cfg]
puts "== initialized (backend ready) =="

set resp [::agent::backend::acp::prompt $handle \
    [list [dict create role user content "Reply with exactly: FOSSIL E2E OK"]]]
puts "== prompt 1 done =="
puts "CONTENT [dict get $resp content]"
puts "USAGE   [dict get $resp usage]"
puts "CALLS   [dict get $resp calls]"

puts "== prompt 2: tool call (get_current_time) =="
set resp2 [::agent::backend::acp::prompt $handle \
    [list [dict create role user content "What is the current UTC time? Use the get_current_time tool."]]]
puts "CONTENT [dict get $resp2 content]"
puts "USAGE   [dict get $resp2 usage]"
puts "CALLS   [dict get $resp2 calls]"

::agent::backend::acp::close $handle
puts "== closed =="
