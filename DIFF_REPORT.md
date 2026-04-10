# Diff Report: Claude Code vs. Tarha (Coding Agent)

A comparative analysis of two AI coding assistant implementations: **Claude Code** (v2.1.88, TypeScript/React) by Anthropic and **Tarha** (v0.3.0, Erlang/OTP) by Trius. This report reflects the state after implementing 16 enhancement plans.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Language & Runtime](#2-language--runtime)
3. [Architecture](#3-architecture)
4. [LLM Backend](#4-llm-backend)
5. [Agent Loop](#5-agent-loop)
6. [Tool System](#6-tool-system)
7. [Permission & Safety System](#7-permission--safety-system)
8. [Sub-Agent / Multi-Agent](#8-sub-agent--multi-agent)
9. [Session & Context Management](#9-session--context-management)
10. [Memory System](#10-memory-system)
11. [Self-Modification & Crash Recovery](#11-self-modification--crash-recovery)
12. [MCP / Extensibility](#12-mcp--extensibility)
13. [Skills / Commands](#13-skills--commands)
14. [UI & Interaction](#14-ui--interaction)
15. [Code Intelligence](#15-code-intelligence)
16. [Cost & Token Tracking](#16-cost--token-tracking)
17. [Configuration & Deployment](#17-configuration--deployment)
18. [Undo / Backup](#18-undo--backup)
19. [Feature Matrix](#19-feature-matrix)
20. [Architectural Philosophy Differences](#20-architectural-philosophy-differences)

---

## 1. Executive Summary

| Dimension | Claude Code | Tarha |
|-----------|-------------|-------|
| **Language** | TypeScript / React | Erlang / OTP |
| **Scale** | ~4,756 source files, ~13MB minified bundle | ~39 source modules |
| **LLM** | Anthropic API (Claude models) | Ollama API (any local model) |
| **Maturity** | Production (v2.1.88) | Experimental (v0.3.0) |
| **Architecture** | React-based TUI, single-process event loop | OTP supervision tree, multi-process gen_servers |
| **Tool count** | ~25 built-in + unlimited MCP | 38 built-in + plugin protocol |
| **Sub-agents** | Yes (fork, async, teammate, remote, worktree) | Yes (build/plan/readonly modes) ✅ |
| **Permission system** | 5-layer (tool, rules, hooks, classifier, interactive) | 3-mode (ask/auto/plan) + rule system + meticulous mode ✅ |
| **Self-modification** | No | Yes (hot-code reload, source patching) |
| **Crash recovery** | No | Yes (healer with auto-fix, lifeline watchdog) |
| **MCP support** | Full (stdio, SSE, HTTP, WebSocket, SDK) | Plugin protocol (shell/module/HTTP) ✅ |
| **Cost tracking** | Detailed per-model cost/token tracking | Budget tracking with limits and warnings ✅ |
| **Streaming tool dispatch** | Yes (StreamingToolExecutor) | Yes (chat_with_tools_streaming) ✅ |
| **Context compaction** | Multi-level (compact, microcompact, collapse) | Multi-level (microcompact/compact/collapse) ✅ |
| **Token counting** | API-provided | Per-language heuristic + API with TTL cache ✅ |
| **Session resumption** | No persistent sessions | Yes (JSON persistence + metadata + /resume) ✅ |
| **Edit robustness** | Zod schema validation | Schema validation + normalized matching + line-number editing ✅ |
| **Model fallback** | Yes (fallback chain) | Yes (fallback chain with capability check) ✅ |
| **Undo/redo** | No (git only) | Yes (stack + transactions + git undo) ✅ |
| **Git error handling** | Basic | Structured error codes ✅ |
| **Telemetry/observability** | OpenTelemetry | JSONL event logging ✅ |

Items marked ✅ have been implemented in the enhancement plans.

---

## 2. Language & Runtime

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Primary language** | TypeScript | Erlang |
| **UI framework** | React (custom Ink fork for terminal) | Plain Erlang I/O |
| **Runtime** | Node.js ≥18 | BEAM VM (Erlang/OTP 24+) |
| **Concurrency model** | Single-threaded event loop (async/await) | Actor model (processes, message passing) |
| **Binary size** | ~13MB minified JS bundle | ~39 `.erl` source files |

**Key difference**: Claude Code runs on Node.js with a single-threaded event loop. Tarha leverages the BEAM VM's actor model with isolated processes, supervisors, and message passing — providing natural fault tolerance and concurrency.

---

## 3. Architecture

### Claude Code

Single-process Node.js application with React TUI, async agent loop, two state systems (mutable global + React store), streaming tool execution, and MCP integration.

### Tarha

Multi-process Erlang/OTP application with supervision tree, 12+ gen_servers, ETS-based state, lifeline watchdog, healer with source-level auto-fix, and process monitor with memory GC.

**Key difference**: Tarha has built-in crash recovery at the architecture level; Claude Code does not. Tarha adds concurrent tool execution, sub-agent spawning, and plugin extensibility since the original analysis.

---

## 4. LLM Backend

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Provider** | Anthropic API (Claude models) | Ollama API (any local/remote model) |
| **Streaming** | Yes, with SSE and incremental processing | Yes, via hackney streaming ✅ |
| **Model fallback** | Yes (fallback chain) | Yes (chat_with_fallback with capability check) ✅ |
| **Token counting** | API-provided (prompt_eval_count) | Per-language heuristic + API with TTL cache ✅ |
| **Content-type detection** | No | Yes (detect_content_type with 8 language types) ✅ |
| **Detailed token breakdown** | No | Yes (count_tokens_detailed returns type, ratio, overhead) ✅ |

---

## 5. Agent Loop

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Loop implementation** | AsyncGenerator | Recursive function |
| **Concurrent tools** | Yes (StreamingToolExecutor) | Yes (execute_concurrent for safe tools) ✅ |
| **Streaming tool dispatch** | Yes (tools dispatched as stream arrives) | Yes (chat_with_tools_streaming with callback) ✅ |
| **Context compaction** | Multi-level (compact, microcompact, collapse) | Multi-level (microcompact 70%, compact 85%, collapse 95%) ✅ |
| **Model fallback** | Yes (fallback chain) | Yes (chat_with_fallback/3,4) ✅ |
| **Budget limits** | Max turns, max tokens, max USD cost | Budget tracking with limits and warnings ✅ |
| **Tool result limits** | Configurable per-tool maxResultSizeChars | 50KB per result, 100KB total |

---

## 6. Tool System

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Tool count** | ~25 built-in + unlimited MCP | 38 built-in + plugin protocol |
| **Input validation** | Zod schema validation | JSON Schema validation (coding_agent_tools_schema) ✅ |
| **Permission checks** | Per-tool checkPermissions() with allow/deny/ask | 3-mode permission system + rule patterns + meticulous mode ✅ |
| **Concurrency safety** | isConcurrencySafe() per tool | is_concurrent_tool/1 per tool ✅ |
| **Sub-agent tool** | Yes (AgentTool, 6 modes) | Yes (coding_agent_subagent, 3 modes) ✅ |
| **Plugin/extensibility** | MCP (full protocol) | Shell/module/HTTP handlers ✅ |
| **Edit robustness** | Exact string match | Normalized matching + line-number editing + dry-run ✅ |
| **Git error handling** | Basic | Structured error codes ✅ |
| **Git undo** | No | Yes (push_git, git_undo, rollback) ✅ |
| **Telemetry** | OpenTelemetry | JSONL event logging ✅ |

---

## 7. Permission & Safety System

### Claude Code

Five-layer: tool-level, rule-based, hook-based, classifier-based, and interactive.

### Tarha (now enhanced)

Three-mode system with rule storage:

| Mode | Description |
|------|-------------|
| `ask` | Every tool call requires approval |
| `auto` | All tool calls execute without approval |
| `plan` / `meticulous` | Only read-only tools allowed |

Plus:
- **Rule storage**: ETS-backed allow/deny patterns (glob-based)
- **REPL commands**: `/permissions`, `/allow`, `/deny`, `/mode`
- **Meticulous mode**: Step-by-step execution with plan breakdown and per-step approval
- **Process-dictionary callback hook**: Still available for programmatic use

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Permission layers** | 5 (tool, rules, hooks, classifier, interactive) | 3 (mode, rules, callback hook) + meticulous mode ✅ |
| **User-facing prompts** | Yes, per tool call | Yes, via mode switching ✅ |
| **Rule-based control** | Yes (CLI, session, project, user, policy) | Yes (session rules, glob patterns) ✅ |
| **Hook system** | Yes (PreToolUse, PostToolUse, Stop) | No |
| **Auto-approval** | YOLO classifier (secondary model) | No |
| **Step-by-step execution** | No | Yes (meticulous mode) ✅ |

---

## 8. Sub-Agent / Multi-Agent

### Claude Code

6 modes: sync, async, fork, teammate, remote, worktree. Custom agent types via `.claude/agents/` YAML.

### Tarha (now enhanced)

**Module**: `coding_agent_subagent.erl`

3 modes:

| Mode | Tools Available |
|------|----------------|
| `build` | All tools |
| `plan` | read_file, list_files, file_exists, grep_files, find_files, detect_project, list_models, show_model |
| `readonly` | read_file, list_files, file_exists, grep_files, find_files |

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Sub-agent support** | 6 modes (sync, async, fork, teammate, remote, worktree) | 3 modes (build, plan, readonly) ✅ |
| **Tool scoping** | Per-agent tool restriction | Yes (filter_tools_for_mode) ✅ |
| **Worktree isolation** | Yes | No |

---

## 9. Session & Context Management

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Session persistence** | No (in-memory only) | Yes (JSON to disk) |
| **Session restoration** | No | Yes (load from file + /resume) ✅ |
| **Metadata** | No | Yes (model, message count, tokens, summary) ✅ |
| **Session cleanup** | No | Yes (30-day auto-cleanup, max 100 sessions) ✅ |
| **Context compaction** | Multi-level | Multi-level (70/85/95% thresholds) ✅ |
| **Budget tracking** | Max turns, max tokens, max USD | Budget tracking with limits and warnings ✅ |

---

## 10. Memory System

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Cross-session memory** | No (CLAUDE.md only) | Yes (MEMORY.md + HISTORY.md) |
| **Consolidation** | No | Yes (LLM-based, 20-session threshold) |
| **Detail archival** | No | Yes (timestamped MEMORY-DETAILS files) |

---

## 11. Self-Modification & Crash Recovery

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Self-modification** | No | Yes (hot-code reload, source patching) |
| **Crash recovery** | No | Yes (lifeline, healer, process monitor) |
| **Version archiving** | No | Yes (5 versions per module) |
| **Crash context injection** | No | Yes (recent crash reports in system prompt) |

---

## 12. MCP / Extensibility

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **MCP support** | Full (stdio, SSE, HTTP, WebSocket, SDK) | No |
| **Plugin protocol** | No | Yes (shell/module/HTTP handlers) ✅ |
| **Dynamic tool registration** | Yes (MCP) | Yes (plugin registration at runtime) ✅ |

---

## 13. Skills / Commands

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Skill format** | Markdown + YAML frontmatter (name, description, allowed-tools, model, context, agent, effort, shell, paths, hooks) | Markdown + YAML frontmatter (name, description, requires, always, path_patterns, context, model, tags, hooks, max_tokens) ✅ |
| **Conditional activation** | Yes (path-based) | Yes (path_patterns + glob matching) ✅ |
| **Skill search** | No | Yes (search_skills by name/description/tags) ✅ |
| **Context modes** | Yes (inline, fork) | Yes (inline, fork, background) ✅ |
| **Skill model override** | Yes | Yes (model field in frontmatter) ✅ |
| **Hook execution** | Yes (shell commands) | Yes (on_activate/on_deactivate) ✅ |

---

## 14. UI & Interaction

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Rich terminal UI** | Yes (React/Ink) | No (plain text) |
| **Modes** | Default, plan, auto | Build, plan, meticulous ✅ |
| **Step-by-step execution** | No | Yes (meticulous mode with /steps, /confirm, /exec) ✅ |
| **Permission commands** | Yes (interactive prompts) | Yes (/permissions, /allow, /deny, /mode) ✅ |
| **Session resumption** | No | Yes (/sessions with metadata, /resume) ✅ |
| **Budget display** | Yes (detailed cost) | Yes (token budget, warnings) ✅ |

---

## 15. Code Intelligence

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Built-in index** | No | Yes (module map, function definitions, cross-references, n-grams) |
| **LSP interface** | Feature-gated | Yes (definition, references, hover, completion, symbols, diagnostics) |
| **Refactoring tools** | No | Yes (rename_symbol, extract_function, find_references, get_callers) |
| **Smart git** | No | Yes (smart_commit, review_changes, resolve_merge_conflicts) |

---

## 16. Cost & Token Tracking

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Per-model cost tracking** | Yes (detailed USD cost) | No (token-based only) |
| **Token counting** | API-provided | Per-language heuristic + API with TTL cache ✅ |
| **Content-type detection** | No | Yes (8 language types) ✅ |
| **Detailed token breakdown** | No | Yes (count_tokens_detailed returns type, ratio, overhead) ✅ |
| **Budget limits** | Yes (max turns, max tokens, max USD) | Yes (token budget, tool call budget, warnings) ✅ |
| **Session budget persistence** | Yes (project config) | No (in-session only) |

---

## 17. Configuration & Deployment

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Configuration priority** | CLI > settings > env | Env vars > app env > YAML > defaults |
| **Model fallback** | Built-in (sonnet → haiku) | Configurable chain (get_fallback_chain) ✅ |
| **Retryable errors** | Hardcoded | Configurable (get_retryable_errors) ✅ |

---

## 18. Undo / Backup

| Aspect | Claude Code | Tarha |
|--------|-------------|-------|
| **Automatic backups** | No | Yes (`.tarha/backups/`, max 50) |
| **Undo/redo** | No (git only) | Yes (stack-based with transactions) |
| **Git undo** | No | Yes (push_git, git_undo, rollback_git_op) ✅ |
| **Git error handling** | Basic | Structured error codes ✅ |
| **Edit robustness** | Exact string match | Normalized matching + line editing + dry-run ✅ |

---

## 19. Feature Matrix

| Feature | Claude Code | Tarha |
|---------|-------------|-------|
| **Language** | TypeScript | Erlang |
| **LLM backend** | Anthropic API | Ollama (any model) |
| **Streaming tool dispatch** | Yes | Yes ✅ |
| **Concurrent tool execution** | Yes (StreamingToolExecutor) | Yes (execute_concurrent) ✅ |
| **Sub-agents** | 6 modes | 3 modes (build/plan/readonly) ✅ |
| **Permission system** | 5-layer with interactive prompts | 3-mode + rules + meticulous mode ✅ |
| **Plugin/extensibility** | MCP (full protocol) | Shell/module/HTTP handlers ✅ |
| **Context compaction** | Multi-level | Multi-level (70/85/95%) ✅ |
| **Budget limits** | Yes (turns, tokens, USD) | Yes (tokens, tool calls) ✅ |
| **Persistent sessions** | No | Yes (JSON + metadata) ✅ |
| **Session resumption** | No | Yes (/resume) ✅ |
| **Cross-session memory** | No (CLAUDE.md only) | Yes (MEMORY.md + HISTORY.md) |
| **Undo/redo** | No (git only) | Yes (stack + transactions + git undo) ✅ |
| **Automatic backups** | No | Yes |
| **Self-modification** | No | Yes (hot-code reload, source patching) |
| **Crash recovery** | No | Yes (lifeline, healer, process monitor) |
| **Code intelligence** | LSP tool (feature-gated) | Built-in index + LSP interface |
| **Refactoring tools** | No (Edit tool only) | Rename, extract, find references |
| **Smart git** | No | Smart commit, review changes, merge resolution |
| **Test/doc generation** | No | Yes |
| **Project detection** | No | Yes (detect_project) |
| **Cost tracking** | Per-model cost + budget limits | Token estimation + budget tracking ✅ |
| **Model capabilities query** | No (static) | Yes (dynamic) |
| **Model fallback** | Yes | Yes (configurable chain) ✅ |
| **Token counting** | API-provided | Per-language heuristic + API cache ✅ |
| **Edit robustness** | Exact match | Normalized + line-number + dry-run ✅ |
| **Skill system** | Basic (name, description, requires) | Enhanced (path_patterns, tags, context, model, hooks) ✅ |
| **Skill search** | No | Yes ✅ |
| **Step-by-step execution** | No | Yes (meticulous mode) ✅ |
| **Telemetry** | OpenTelemetry | JSONL event logging ✅ |
| **Rich terminal UI** | Yes (React/Ink) | No (plain text) |
| **MCP support** | Full protocol | Plugin protocol only |
| **Git structured errors** | No | Yes (error codes) ✅ |

---

## 20. Architectural Philosophy Differences

### Claude Code: The Production Product

Emphasis on: safety (multi-layered permissions), extensibility (MCP), user experience (rich TUI), provider diversity, corporate deployment, observability (OTel).

Trade-offs: No persistent memory, no undo system, no crash recovery, no self-modification, no code intelligence index, no concurrent tool execution within a single agent.

### Tarha: The Self-Improving System

Emphasis on: resilience (three-layer crash recovery), self-improvement (hot-code reload), persistence (sessions + memory), undo safety (backups + git undo), code intelligence (built-in index + LSP), model flexibility, step-by-step execution (meticulous mode).

Trade-offs: No rich UI, no MCP extensibility (plugin protocol only), limited cost tracking (no per-model USD tracking), no worktree isolation, no multi-provider auth.

### Remaining Gaps (Tarha → Claude Code)

| Feature | Status |
|---------|--------|
| Rich terminal UI (React/Ink) | ❌ Not implemented |
| MCP protocol support (stdio, SSE, HTTP, WS) | ❌ Not implemented |
| Worktree isolation for sub-agents | ❌ Not implemented |
| Per-model USD cost tracking | ❌ Not implemented |
| Hook system (PreToolUse, PostToolUse, Stop) | ❌ Not implemented |
| YOLO-style auto-approval classifier | ❌ Not implemented |
| OpenTelemetry integration | ❌ Not implemented |
| Multi-provider auth (OAuth, Bedrock, Vertex) | ❌ Not implemented |
| Keybinding system | ❌ Not implemented |
| Voice mode | ❌ Not implemented |