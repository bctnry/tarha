# Tarha (Coding Agent) — Implementation Report

This report documents the architecture and implementation of Tarha (the `coding_agent` Erlang/OTP application, version 0.3.0), an AI-powered coding assistant that uses Ollama for LLM inference with comprehensive tool calling, session management, self-healing capabilities, and 16 enhancement plans implemented from comparative analysis with Claude Code.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Supervision Tree & Bootstrap](#2-supervision-tree--bootstrap)
3. [Configuration System](#3-configuration-system)
4. [The Agent Loop](#4-the-agent-loop)
5. [Tool System](#5-tool-system)
6. [Session & Conversation Management](#6-session--conversation-management)
7. [Permission & Safety System](#7-permission--safety-system)
8. [Ollama API Client](#8-ollama-api-client)
9. [Memory System](#9-memory-system)
10. [Skills System](#10-skills-system)
11. [Self-Modification & Crash Recovery](#11-self-modification--crash-recovery)
12. [LSP & Code Intelligence](#12-lsp--code-intelligence)
13. [Undo/Redo System](#13-undoredo-system)
14. [Request Cancellation](#14-request-cancellation)
15. [Process Monitoring & GC](#15-process-monitoring--gc)
16. [REPL Interface](#16-repl-interface)
17. [Enhancement Plans](#17-enhancement-plans)
18. [On-Disk Data Layout](#18-on-disk-data-layout)

---

## 1. Project Overview

Tarha is an Erlang/OTP application that provides an AI-powered coding assistant through Ollama's tool-calling API. Key characteristics:

- **Language**: Erlang/OTP, built with rebar3
- **LLM Backend**: Ollama (local or remote), using the `/api/chat` endpoint with tool calling
- **Dependencies**: hackney (HTTP), jsx (JSON), yamerl (YAML)
- **Module count**: 39 source modules (34 original + 5 new enhancement modules)
- **Tool count**: 38 tool definitions exposed to the LLM
- **Interface**: Interactive REPL (`./coder` script)

The application follows standard OTP design patterns: a supervision tree with gen_servers for stateful components, ETS tables for fast lookups, and a layered architecture where the REPL delegates to sessions, which delegate to the agent loop, which delegates to tools.

### High-Level Architecture

```
User Input (Terminal)
       │
       ▼
   coder script ──► coding_agent_repl (REPL loop)
       │
       ▼
   coding_agent_session (gen_server per session)
       │
       ├── Build system prompt (SYSTEM_PROMPT + context + memory + skills + files + crash context)
       │
       ▼
   run_agent_loop (recursive, max 100 iterations)
       │
       ▼
   coding_agent_ollama:chat_with_tools_cancellable (HTTP → Ollama API)
       │
       ▼
   Model Response
       │
       ├── Has tool_calls? ──► execute_tool_calls ──► coding_agent_tools:execute/2
       │                                                      │
       │                                              ┌───────┴───────┐
       │                                              ▼               ▼
       │                                        coding_agent_tools_file   coding_agent_tools_git
       │                                        coding_agent_tools_command coding_agent_tools_search
       │                                        coding_agent_tools_build   coding_agent_tools_undo
       │                                        coding_agent_tools_refactor coding_agent_tools_model
       │                                        coding_agent_tools_self    coding_agent_tools_skills
       │                                        coding_agent_subagent      coding_agent_plugins
       │                                        coding_agent_permissions   coding_agent_telemetry
       │                                              │
       │                                              ▼
       │                                        Tool results (JSON)
       │                                              │
       └──────────────────────────────────────────────┘
       │
       ▼
   Text response ──► Return to user
```

---

## 2. Supervision Tree & Bootstrap

### Application Start Sequence

```
coding_agent_app:start/2
  │
  ├── coding_agent_config:init_config()  (load YAML, apply env overrides)
  │
  └── coding_agent_lifeline_sup:start_link()
        │
        └── coding_agent_lifeline (watchdog gen_server)
              │
              └── coding_agent_sup:start_link() (monitored, auto-restarted on crash)
                    │
                    ├── coding_agent_request_registry  (permanent worker)
                    ├── coding_agent_undo              (permanent worker)
                    ├── coding_agent_permissions       (permanent worker)  ← NEW (Plan 002)
                    ├── coding_agent_telemetry          (permanent worker)  ← NEW (Plan 015)
                    ├── coding_agent_process_monitor   (permanent worker)
                    ├── coding_agent_conv_memory       (permanent worker)
                    ├── coding_agent_skills            (permanent worker)
                    ├── coding_agent_session_store     (permanent worker)
                    ├── coding_agent_self              (permanent worker)
                    ├── coding_agent_healer            (permanent worker)
                    ├── coding_agent_session_sup       (supervisor, simple_one_for_one)
                    │     └── coding_agent_session      (temporary, dynamic)
                    └── coding_agent                   (permanent worker)
```

### Lifeline (Watchdog) — `coding_agent_lifeline.erl`

The lifeline process wraps the entire supervision tree with crash recovery:

- **Starts** `coding_agent_sup` as a monitored child process
- **On crash**: writes a markdown crash report to `.tarha/reports/`, applies exponential backoff (5s → 60s), restarts the supervisor
- **Crash limit**: after 10 crashes within 5 minutes, permanently gives up (sets `giving_up=true`)
- **Stability tracking**: if the supervisor runs stably for 60 seconds, backoff resets to 5s
- **Manual reset**: `reset_crash_count/0` allows recovery from the give-up state

---

## 3. Configuration System

**Module**: `coding_agent_config.erl`

Configuration is layered with explicit priority:

```
Environment Variables > Application Env (sys.config) > YAML Config (config.yaml) > Defaults
```

### Key Configuration Functions

| Function | Default | Purpose |
|----------|---------|---------|
| `model/0` | `<<"glm-5:cloud">>` | Current model name |
| `ollama_host/0` | `"http://localhost:11434"` | Ollama API URL |
| `max_iterations/0` | `100` | Agent loop max iterations |
| `sessions_dir/0` | `$CWD/.tarha/sessions` | Session storage directory |
| `workspace/0` | `"."` | Project workspace root |
| `memory_max_size/0` | `10000` | Max memory size (bytes) |
| `memory_consolidate_threshold/0` | `20` | Sessions before consolidation |
| `session_max_messages/0` | `100` | Max messages per session |
| `get_fallback_chain/0` | `[PrimaryModel]` | Model fallback chain ← NEW (Plan 016) |
| `get_retryable_errors/0` | `[timeout, connection_error, server_error]` | Errors that trigger fallback |
| `get_fallback_enabled/0` | `true` | Whether fallback is enabled |

---

## 4. The Agent Loop

### Session State

```erlang
-record(state, {
    id :: binary(),
    model :: binary(),
    context_length :: integer(),
    messages :: list(),
    working_dir :: string(),
    open_files :: #{binary() => binary()},
    prompt_tokens :: integer(),
    completion_tokens :: integer(),
    estimated_tokens :: integer(),
    tool_calls :: integer(),
    budget_used :: integer(),            %% ← NEW (Plan 009)
    budget_limit :: integer(),           %% ← NEW (Plan 009)
    tool_calls_remaining :: integer(),   %% ← NEW (Plan 009)
    tool_calls_limit :: integer(),       %% ← NEW (Plan 009)
    busy :: boolean(),
    ephemeral :: boolean()
}).
```

### Context Window Management (Enhanced — Plan 005)

Multi-layered strategy with three thresholds:

| Threshold | Level | Action |
|-----------|-------|--------|
| 70% | Microcompact | Strip oldest messages, keep system + 20 recent |
| 85% | Compact | LLM-based summarization of old messages |
| 95% | Collapse | Emergency: keep only system + 5 recent + collapse notice |

Constants:
- `MICROCOMPACT_THRESHOLD = 0.70`
- `CONTEXT_USAGE_THRESHOLD = 0.85`
- `COLLAPSE_THRESHOLD = 0.95`
- `MICROCOMPACT_KEEP_MESSAGES = 20`
- `COLLAPSE_KEEP_MESSAGES = 5`

### Budget Tracking (Enhanced — Plan 009)

- `budget_used` accumulates token costs per turn
- `budget_limit` (default 0 = unlimited) can be set via app env
- `tool_calls_remaining` decrements per tool call
- Budget check at start of each `ask`: returns `{error, budget_exceeded}` or `{error, tool_budget_exceeded}`
- Warning logged at 80% budget usage

### Model Fallback Chain (Enhanced — Plan 016)

When the primary model fails with a retryable error (timeout, connection_error, server_error), the agent automatically tries the next model in the fallback chain:

```
fallback_chain: [PrimaryModel, FallbackModel, ...]
```

`chat_with_fallback/3,4` iterates through the chain. Skips models that don't support tools. Notifies the session on fallback.

---

## 5. Tool System

### Tool Schema Validation (NEW — Plan 010)

**Module**: `coding_agent_tools_schema.erl`

Provides JSON Schema validation for tool inputs before execution:

| Tool | Validated Parameters |
|------|---------------------|
| `read_file` | `path` (required, non-empty) |
| `edit_file` | `path`, `old_string`, `new_string` (all required) |
| `write_file` | `path`, `content` (all required) |
| `run_command` | `command` (required, non-empty) |
| `grep_files` | `pattern` (required, non-empty) |
| `find_files` | `path` (required, non-empty) |

### Concurrent Tool Execution (NEW — Plan 001)

`coding_agent_tools:execute_concurrent/1` spawns a linked process per tool call. `is_concurrent_tool/1` identifies safe-to-parallelize tools (read_file, grep_files, find_files, file_exists, list_files). Sequential-only tools (edit_file, write_file, create_directory, git operations) wait for completion.

### Sub-Agent Spawning (NEW — Plan 003)

**Module**: `coding_agent_subagent.erl`

Spawns scoped sub-agents with three modes:

| Mode | Description |
|------|-------------|
| `build` | Full tool access |
| `plan` | Read-only tools only |
| `readonly` | Only file-inspection tools |

Sub-agents create temporary sessions with filtered tool sets, execute in a linked process, and return results.

### Plugin Protocol (NEW — Plan 004)

**Module**: `coding_agent_plugins.erl`

Three handler types:

| Handler | Mechanism |
|---------|-----------|
| `shell` | Execute shell command, capture stdout |
| `module` | Call `Module:Function(Args)` |
| `http` | POST to URL with Args as JSON body |

Plugins are registered with `register_plugin/3` and invoked via the standard `execute/2` dispatch.

### Diff-Based Editing (Enhanced — Plan 014)

`edit_file` now supports:

- **Whitespace normalization**: CRLF → LF, tabs → spaces, trailing whitespace stripping for fuzzy matching
- **Line-number editing**: `start_line`/`end_line` parameters for direct line range replacement
- **Dry-run mode**: `dry_run: true` returns preview without applying changes
- **Error codes**: `not_found`, `invalid_range` structured error fields

### Tool Dispatch Table

| Tool Name Pattern | Delegate Module |
|---|---|
| `read_file`, `edit_file`, `write_file`, `create_directory`, `list_files`, `file_exists` | `coding_agent_tools_file` |
| `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_stash`, `git_pull`, `git_push`, `git_tag`, `git_merge`, `git_remote`, `git_branch` | `coding_agent_tools_git` |
| `grep_files`, `find_files` | `coding_agent_tools_search` |
| `undo_edit`, `list_backups`, `undo`, `redo`, `undo_history`, `begin_transaction`, `end_transaction`, `cancel_transaction` | `coding_agent_tools_undo` |
| `run_tests`, `run_build`, `run_linter`, `detect_project` | `coding_agent_tools_build` |
| `run_command`, `http_request`, `execute_parallel`, `fetch_docs`, `load_context` | `coding_agent_tools_command` |
| `smart_commit`, `resolve_merge_conflicts`, `review_changes`, `generate_tests`, `generate_docs`, `rename_symbol`, `extract_function` | `coding_agent_tools_refactor` |
| `list_models`, `switch_model`, `show_model` | `coding_agent_tools_model` |
| `reload_module`, `get_self_modules`, `analyze_self`, `deploy_module`, `create_checkpoint`, `restore_checkpoint`, `list_checkpoints` | `coding_agent_tools_self` |
| `list_skills`, `load_skill` | `coding_agent_skills` |
| `hello` | Inline: returns "hello world" |

---

## 6. Session & Conversation Management

### Session Store (Enhanced — Plan 012)

**New functions**:

| Function | Purpose |
|----------|---------|
| `list_sessions_with_metadata/0` | Lists sessions with model, message count, tokens, summary |
| `get_session_metadata/1` | Gets metadata for a single session |
| `cleanup_old_sessions/0` | Removes sessions >30 days old, keeps max 100 |

Sessions now generate auto-summaries (first user message, truncated to 80 chars) and track `updated_at` timestamps for sorting.

### Session Resumption (NEW — Plan 012)

REPL commands `/resume` and enhanced `/sessions`:

- `/sessions` — Shows session list with model, message count, token count, and summary
- `/resume` — Loads the most recent session by `updated_at` timestamp

---

## 7. Permission & Safety System

### Interactive Permission System (NEW — Plan 002)

**Module**: `coding_agent_permissions.erl` (gen_server)

Three permission modes:

| Mode | Behavior |
|------|----------|
| `ask` | Every tool call requires user approval |
| `auto` | All tool calls execute without approval |
| `plan` | Only read-only tools allowed |
| `meticulous` | Only read-only tools allowed (same as plan) |

Rule storage in ETS `coding_agent_permissions_rules`:

```erlang
-record(rule, {pattern, decision, source}).
%% pattern: binary glob like <<"git_*">>
%% decision: allow | deny | ask
%% source: session | config
```

REPL commands:
- `/permissions` — Show current mode and rules
- `/allow <pattern>` — Add allow rule
- `/deny <pattern>` — Add deny rule
- `/mode ask|auto|plan` — Switch permission mode

### Meticulous Mode (NEW)

A third interaction mode beyond `build` and `plan`:

1. Agent outputs structured `<<<STEP>>>...<<<ENDSTEP>>>` blocks
2. Steps are auto-parsed and stored as `#{title, description, files}` maps
3. `/confirm` saves steps as individual `.md` files in `.tarha/plans/`
4. `/exec` executes the next step by sending a focused prompt in build mode
5. `/steps` shows all steps with progress markers (✓/▶/○)
6. `/skip <n>` jumps to a specific step

---

## 8. Ollama API Client

**Module**: `coding_agent_ollama.erl`

### Token Counting (Enhanced — Plan 011)

Per-language token ratios:

| Content Type | Ratio (chars/token) |
|-------------|---------------------|
| erlang | 2.3 |
| javascript | 2.5 |
| python | 2.8 |
| json | 2.2 |
| html | 3.0 |
| yaml | 3.0 |
| markdown | 3.5 |
| english | 4.0 |
| mixed | 2.8 |
| default | 3.0 |

`detect_content_type/1` auto-classifies content and applies the appropriate ratio. `count_tokens_detailed/1` returns a map with `tokens`, `content_type`, `ratio`, and overhead breakdown.

Token cache now includes TTL (5 minutes) via `?CACHE_TTL_MS = 300000`.

### Streaming Tool Dispatch (NEW — Plan 006)

`chat_with_tools_streaming/4,5` provides incremental tool call delivery:

- As each tool call is parsed from the stream, it's yielded via callback
- Concurrent-safe tools can be dispatched immediately
- Sequential tools queue for after stream completion

### Model Fallback (NEW — Plan 016)

`chat_with_fallback/3,4` iterates through a model chain, skipping models that don't support tools, and falling back on retryable errors (timeout, connection_error, server_error).

---

## 9. Memory System

**Module**: `coding_agent_conv_memory.erl`

Two-layer persistent memory:

| Layer | File | Purpose | Size Limit |
|-------|------|---------|------------|
| Long-term | `.tarha/memory/MEMORY.md` | Facts, preferences, important info | 10KB |
| History | `.tarha/memory/HISTORY.md` | Timestamped conversation summaries | No limit |

---

## 10. Skills System

**Module**: `coding_agent_skills.erl` (Enhanced — Plan 013)

### Enhanced YAML Frontmatter

```yaml
---
name: database-migrations
description: "Run and manage database migrations"
always: false
context: inline          # inline | fork | background
model: inherit           # inherit | sonnet | opus | haiku
path_patterns:
  - "migrations/**"
  - "**/schema/**"
tags: [database, migration]
hooks:
  on_activate: "echo 'Database migration skill activated'"
max_tokens: 4000
---
```

### New Features

| Feature | API |
|---------|-----|
| Conditional activation | `activate_conditional_skills(FilePaths)` — activates skills matching file patterns |
| Skill search | `search_skills(Query)` — search by name, description, or tags |
| Path pattern matching | Glob patterns like `"migrations/**"` activate skills when matching files are touched |
| Context modes | `inline` (default), `fork` (sub-agent), `background` (async) |

### Frontmatter Parsers

New fields: `context`, `model`, `path_patterns`, `tags`, `hooks` (on_activate/on_deactivate), `max_tokens`.

---

## 11. Self-Modification & Crash Recovery

### Self-Modification (`coding_agent_self.erl`)

A gen_server that tracks 19+ core modules for hot-code reloading.

**Version Archive**: `.tarha/versions/<module>/v<timestamp>.beam` — stores up to 5 previous BEAM versions per module.

### Crash Analysis & Auto-Fix (`coding_agent_healer.erl`)

Classifies errors into 14 categories and attempts source-level auto-fixes (wildcard clauses, catch blocks, rollback).

---

## 12. LSP & Code Intelligence

### LSP Interface (`coding_agent_lsp.erl`)

| Function | Behavior |
|----------|----------|
| `definition/3` | Find definition of symbol at position |
| `references/3` | Find all references to symbol at position |
| `hover/3` | Hover info (line content + spec extraction) |
| `completion/3` | Autocompletion for exports + keywords |
| `symbols/2` | List all symbols in a file |
| `diagnostics/2` | Run `rebar3 compile` and parse errors/warnings |

### Code Index (`coding_agent_index.erl`)

Persistent code intelligence: module map, function definitions, cross-references, n-gram index, symbol index.

---

## 13. Undo/Redo System

**Module**: `coding_agent_undo.erl` (Enhanced — Plan 007)

### State

```erlang
-record(operation, {
    id :: binary(),
    type :: atom(),
    timestamp :: integer(),
    description :: binary(),
    files :: [{Path, BackupPath}],
    metadata :: map(),
    git_ref :: binary() | undefined,     %% ← NEW (Plan 007)
    git_data :: map() | undefined          %% ← NEW (Plan 007)
}).
```

### Git Undo (NEW — Plan 007)

| Function | Purpose |
|----------|---------|
| `push_git/3,4` | Push an operation with git ref for rollback |
| `git_undo/0,1` | Undo N operations, automatically rolling back git state |
| `do_git_undo/2` | Internal: rolls back git operations in reverse order |

### Structured Error Codes (NEW — Plan 008)

Git tools now return structured errors:

```erlang
#{success => false, error => <<"Permission denied">>, error_code => <<"permission_denied">>}
```

Error codes: `not_found`, `permission_denied`, `merge_conflict`, `network_error`, `not_a_repo`, `stash_empty`, `tag_exists`.

---

## 14. Request Cancellation

**Module**: `coding_agent_request_registry.erl`

- `register/2` — register an active HTTP request for a session
- `halt/1` — cancel the request and send `request_halted` message
- `halt_all/0` — cancel all active requests

---

## 15. Process Monitoring & GC

**Module**: `coding_agent_process_monitor.erl`

Periodic GC every 60 seconds. Trim strategies: sessions, ETS tables, code paths, binary heaps.

---

## 16. REPL Interface

**Module**: `coding_agent_repl.erl`

### Modes

| Mode | Description |
|------|-------------|
| `build` | Agent executes tool calls and modifies files |
| `plan` | Agent discusses without executing (read-only tools only) |
| `meticulous` | Agent breaks plans into numbered steps, executes one at a time with approval |

### Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/status` | Show model, context usage, tokens, tool calls, budget, memory |
| `/history` | Show conversation history |
| `/tools` | List available tools |
| `/models` | List available models |
| `/switch <model>` | Switch to a different model |
| `/context` | Show context window info |
| `/modules` | Show loaded modules |
| `/reload <module>` | Hot-reload a module |
| `/checkpoint` | Create a checkpoint |
| `/restore <id>` | Restore from checkpoint |
| `/clear` | Clear conversation |
| `/trim` | Trim conversation history |
| `/compact` | Force context compaction |
| `/sessions` | List sessions with metadata |
| `/load <id>` | Load a saved session |
| `/resume` | Resume most recent session |
| `/save` | Save current session |
| `/cancel` | Cancel in-progress request |
| `/crashes` | Show recent crashes |
| `/reports` | Show crash reports |
| `/fix <module>` | Auto-fix a crashed module |
| `/dump <path> [format]` | Dump context to file |
| `/plan` | Enter plan mode |
| `/build` | Exit plan mode |
| `/showplan` | Show current plan |
| `/editplan` | Open plan in `$EDITOR` |
| `/clearplan` | Clear plan and steps |
| `/meticulous` | Enter meticulous step-by-step mode |
| `/steps` | View implementation steps and progress |
| `/confirm` | Confirm plan, save steps to `.tarha/plans/` |
| `/exec` | Execute next pending step |
| `/skip <n>` | Skip to step n |
| `/permissions` | Show permission mode and rules |
| `/allow <pattern>` | Allow a tool pattern |
| `/deny <pattern>` | Deny a tool pattern |
| `/mode ask\|auto\|plan` | Set permission mode |
| `/quit`, `/exit` | Exit REPL |

---

## 17. Enhancement Plans

The following 16 enhancement plans were implemented based on comparative analysis with Claude Code:

| # | Module | Description |
|---|--------|-------------|
| 001 | `coding_agent_tools.erl` | Concurrent tool execution — `is_concurrent_tool/1`, `partition_by_concurrency/1`, parallel dispatch |
| 002 | `coding_agent_permissions.erl` | Interactive permission system with ask/auto/plan modes, rule storage, REPL commands |
| 003 | `coding_agent_subagent.erl` | Sub-agent spawning with scoped tools (build/plan/readonly modes) |
| 004 | `coding_agent_plugins.erl` | Plugin protocol with shell/module/HTTP handlers |
| 005 | `coding_agent_session.erl` | Multi-level context compaction (microcompact/compact/collapse at 70%/85%/95%) |
| 006 | `coding_agent_ollama.erl` | Streaming tool dispatch with incremental tool call delivery |
| 007 | `coding_agent_tools_git.erl` + `coding_agent_undo.erl` | Git undo tracking (push_git, git_undo, rollback_git_op) |
| 008 | `coding_agent_tools_git.erl` | Structured error codes for git operations |
| 009 | `coding_agent_session.erl` + `coding_agent_repl.erl` | Budget tracking with limits, warnings, and REPL display |
| 010 | `coding_agent_tools_schema.erl` | Tool input validation schemas for 6 core tools |
| 011 | `coding_agent_ollama.erl` | Improved token counting with per-language ratios, content detection, TTL cache |
| 012 | `coding_agent_session_store.erl` + `coding_agent_repl.erl` | Session resumption with metadata, `/resume`, `/sessions` enhancements |
| 013 | `coding_agent_skills.erl` | Enhanced skills with path_patterns, tags, context modes, search, conditional activation |
| 014 | `coding_agent_tools_file.erl` | Diff-based editing with normalized matching, line-number editing, dry-run mode |
| 015 | `coding_agent_telemetry.erl` | Event recording, metrics counters, JSONL file output |
| 016 | `coding_agent_config.erl` + `coding_agent_ollama.erl` | Model fallback chain with retryable error classification |

---

## 18. On-Disk Data Layout

```
.tarha/
├── sessions/                          # Session persistence
│   └── <id>.json                      # Per-session state
├── plans/                             # ← NEW: Meticulous step files
│   └── 1_<title>.md                  # Per-step plan files
├── index/
│   └── index.term                      # Code intelligence index
├── versions/                           # Archived BEAM versions
│   └── <module>/v<timestamp>.beam
├── checkpoints/                        # Full checkpoint snapshots
│   └── <id>/<module>.beam
├── backups/                            # File edit backups
│   └── <timestamp>_<basename>
├── reports/                            # Crash and fix reports
│   ├── crash-*.md
│   ├── mem-crash-*.md
│   └── lifeline-*.md
├── memory/
│   ├── MEMORY.md                        # Long-term memory (max 10KB)
│   ├── HISTORY.md                       # Timestamped consolidation events
│   └── details/
│       └── MEMORY-DETAILS-<timestamp>.md
├── telemetry/                          # ← NEW: Telemetry event logs
│   └── events.jsonl
└── skills/                              # Workspace skills
    └── <name>/SKILL.md
```

---

## Summary of Key Design Decisions

1. **OTP Supervision with Lifeline**: Three-layer crash recovery — lifeline restarts supervisor with backoff, healer attempts source-level fixes, process monitor manages memory and reports crashes.

2. **Session-based Architecture**: The primary interface is conversational sessions (`coding_agent_session`), not single-shot calls. Sessions maintain their own state, file cache, token tracking, and can be persisted across restarts.

3. **Recursive Agent Loop**: The agent loop is a recursive function that calls the Ollama API, processes tool calls, and recurses until the model produces a final text response or hits the iteration limit.

4. **Tool Dispatcher Pattern**: A central `execute/2` function pattern-matches tool name binaries to delegate to 9+ category-specific sub-modules, keeping the tool implementations modular while maintaining a unified interface.

5. **Process Dictionary Hooks**: Safety and progress callbacks are stored per-process rather than per-session, enabling different REPL instances or embedding contexts to provide different behavior.

6. **Self-Healing**: On startup, sessions check for recent crash reports. If found, the self-healing prompt is injected into the system context, asking the agent to analyze and fix the bug.

7. **Multi-Level Context Management**: Three-level compaction (microcompact at 70%, compact at 85%, collapse at 95%) with budget tracking and warning thresholds.

8. **Interactive Permission System**: Three modes (ask/auto/plan) with rule-based allow/deny patterns, replacing the simple process-dictionary callback hook.

9. **Meticulous Mode**: Step-by-step execution with structured plan breakdown, file persistence, and per-step approval.

10. **Model Fallback Chain**: Automatic model switching on retryable errors with capability checking.

11. **Enhanced Token Counting**: Per-language ratios with content-type detection and TTL-based accurate token caching.