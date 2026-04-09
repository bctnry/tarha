# Tarha

> An AI-powered coding agent built in Erlang/OTP with Ollama tool calling, self-healing, MCP support, and comprehensive tooling.

A production-ready coding agent that uses Ollama for AI-powered code assistance with 38+ built-in tools, Model Context Protocol (MCP) extensibility, interactive permission controls, step-by-step execution, and an interactive REPL interface.

## Features

### Core Capabilities

- **🧠 Thoughtful Responses** — Uses Ollama's `think` flag for reasoning before acting
- **💬 Conversational Sessions** — Maintains context across multiple turns with persistent storage
- **📁 File Context Caching** — Tracks open files for better context injection
- **📊 Token Estimation** — Per-language token counting (Erlang, JS, Python, etc.) with content-type detection
- **🔄 Three Session Modes** — Build (execute), Plan (discuss only), Meticulous (step-by-step execution)
- **🔐 Permission System** — Interactive ask/auto/plan modes with rule-based allow/deny patterns
- **🧩 MCP Support** — Connect to external tool servers via Model Context Protocol (stdio + HTTP)
- **🛡️ Self-Healing** — Three-layer crash recovery with automatic source-level bug fixing

### Tools Available (38+)

| Category | Tools |
|----------|-------|
| **File Operations** | `read_file`, `write_file`, `edit_file`, `create_directory`, `list_files`, `file_exists` |
| **Git Operations** | `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_branch`, `git_stash`, `git_pull`, `git_push`, `git_tag`, `git_merge`, `git_remote` |
| **Search** | `grep_files`, `find_files`, `find_references`, `get_callers` |
| **Build & Test** | `run_tests`, `run_build`, `run_linter`, `detect_project` |
| **Undo/Redo** | `undo_edit`, `list_backups`, `undo`, `redo`, `undo_history`, `begin_transaction`, `end_transaction`, `cancel_transaction` |
| **Command Execution** | `run_command`, `http_request`, `execute_parallel`, `fetch_docs`, `load_context` |
| **Refactoring** | `smart_commit`, `resolve_merge_conflicts`, `review_changes`, `generate_tests`, `generate_docs`, `rename_symbol`, `extract_function` |
| **Self-Modification** | `reload_module`, `get_self_modules`, `analyze_self`, `deploy_module`, `create_checkpoint`, `restore_checkpoint`, `list_checkpoints` |
| **Model Management** | `list_models`, `switch_model`, `show_model` |
| **Skills** | `list_skills`, `load_skill` |
| **MCP** | Dynamically loaded from connected MCP servers (prefixed `mcp_<server>_<tool>`) |

### Agent Modes

| Mode | Description |
|------|-------------|
| **Build** | Full execution — agent can read, write, and run commands |
| **Plan** | Read-only — agent discusses and creates plans without execution |
| **Meticulous** | Step-by-step — agent breaks plan into numbered steps, executes one at a time with approval |

### Meticulous Mode

In meticulous mode, the agent:
1. Discusses and refines the plan with you
2. Outputs structured `<<<STEP>>>...<<<ENDSTEP>>>` blocks
3. Each step is saved as a separate file in `.tarha/plans/`
4. Use `/confirm` to approve, `/exec` to execute the next step, `/steps` to view progress

### MCP (Model Context Protocol)

Connect to external tool servers (filesystem, databases, APIs) via MCP:

```json
// .tarha/mcp_servers.json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
      "transport": "stdio"
    },
    "github-api": {
      "url": "https://mcp.example.com/api",
      "headers": {"Authorization": "Bearer token"},
      "transport": "http"
    }
  }
}
```

MCP tools become available as `mcp_<server>_<tool>` (e.g., `mcp_filesystem_read_file`).

## Quick Start

### Prerequisites

1. Erlang/OTP 24+ and rebar3
2. Ollama running locally (https://ollama.ai)
3. A model with tool support (e.g., `glm-5:cloud`, `llama3.2`)

### Installation

```bash
git clone <repo-url>
cd tarha-new
rebar3 compile
```

### Configuration

Create `config.yaml` or use environment variables:

```yaml
ollama:
  host: "http://localhost:11434"
  model: "glm-5:cloud"
```

```bash
export OLLAMA_MODEL="glm-5:cloud"
export OLLAMA_HOST="http://localhost:11434"
```

### Run

```bash
./coder
```

## REPL Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/status` | Show model, context, tokens, budget, memory |
| `/models` | List available models |
| `/switch <model>` | Switch model |
| `/plan` | Enter plan mode (read-only) |
| `/build` | Exit to build mode |
| `/meticulous` | Enter step-by-step mode |
| `/steps` | View implementation steps |
| `/confirm` | Confirm plan for execution |
| `/exec` | Execute next step |
| `/skip <n>` | Skip to step n |
| `/permissions` | Show permission mode and rules |
| `/allow <pattern>` | Allow a tool pattern |
| `/deny <pattern>` | Deny a tool pattern |
| `/mode ask\|auto\|plan` | Set permission mode |
| `/mcp` | List MCP servers and status |
| `/mcp-add <name>` | Add MCP server from config |
| `/mcp-remove <name>` | Remove MCP server |
| `/mcp-tools` | List MCP tools |
| `/mcp-resources` | List MCP resources |
| `/sessions` | List saved sessions with metadata |
| `/resume` | Resume most recent session |
| `/compact` | Force context compaction |

## Programmatic Use

```erlang
%% Start the application
application:ensure_all_started(coding_agent).

%% Create a session
{ok, {SessionId, _Pid}} = coding_agent_session:new().

%% Ask questions
{ok, Response, Thinking, History} = coding_agent_session:ask(SessionId,
    <<"List files in the src directory">>).

%% Get session statistics (now includes budget info)
{ok, Stats} = coding_agent_session:stats(SessionId).
%% => #{session_total_tokens => 5000, tool_calls => 3,
%%      budget_used => 12000, budget_limit => 0, ...}

%% Use MCP tools
coding_agent_mcp_registry:start_server(#{name => <<"fs">>, transport => stdio,
    command => "npx", args => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}).
coding_agent_tools:execute(<<"mcp_fs_read_file">>, #{<<"path">> => <<"/tmp/test.txt">>}).
```

## Architecture

### Supervision Tree

```
coding_agent_lifeline_sup
  └── coding_agent_lifeline (watchdog)
       └── coding_agent_sup (supervisor)
            ├── coding_agent_request_registry
            ├── coding_agent_undo
            ├── coding_agent_permissions
            ├── coding_agent_telemetry
            ├── coding_agent_process_monitor
            ├── coding_agent_conv_memory
            ├── coding_agent_skills
            ├── coding_agent_session_store
            ├── coding_agent_self
            ├── coding_agent_healer
            ├── coding_agent_mcp_registry
            ├── coding_agent_mcp_sup (dynamic supervisor)
            │     └── coding_agent_mcp_client (per server)
            ├── coding_agent_session_sup
            │     └── coding_agent_session (per session)
            └── coding_agent (legacy single-shot)
```

### Key Enhancements

| Enhancement | Module | Description |
|-------------|--------|-------------|
| **Multi-level compaction** | `coding_agent_session` | Microcompact (70%) → Compact (85%) → Collapse (95%) |
| **Permission system** | `coding_agent_permissions` | ask/auto/plan modes with rule-based allow/deny |
| **Sub-agents** | `coding_agent_subagent` | Scoped sub-agent spawning (build/plan/readonly) |
| **Plugin protocol** | `coding_agent_plugins` | Shell/module/HTTP handlers |
| **Streaming dispatch** | `coding_agent_ollama` | Incremental tool call delivery during streaming |
| **MCP support** | `coding_agent_mcp_client/registry/sup` | Model Context Protocol (stdio + HTTP transports) |
| **Budget tracking** | `coding_agent_session` | Token and tool call budgets with warnings |
| **Tool validation** | `coding_agent_tools_schema` | JSON Schema validation for 6 core tools |
| **Improved token counting** | `coding_agent_ollama` | Per-language ratios with content-type detection |
| **Session resumption** | `coding_agent_session_store` | Metadata, auto-summaries, `/resume` command |
| **Enhanced skills** | `coding_agent_skills` | path_patterns, tags, context modes, search |
| **Diff-based editing** | `coding_agent_tools_file` | Normalized matching, line-number editing, dry-run |
| **Telemetry** | `coding_agent_telemetry` | JSONL event logging with metrics |
| **Model fallback** | `coding_agent_config/ollama` | Configurable fallback chain with retryable error classification |
| **Git undo** | `coding_agent_undo/tools_git` | Git-aware undo with ref tracking and structured errors |
| **Meticulous mode** | `coding_agent_repl` | Step-by-step execution with plan files and per-step approval |

### On-Disk Layout

```
.tarha/
├── sessions/           # Session persistence (<id>.json)
├── plans/              # Meticulous mode step files (1_<title>.md)
├── index/              # Code intelligence index
├── versions/           # Archived BEAM versions
├── checkpoints/        # Full checkpoint snapshots
├── backups/            # File edit backups (max 50)
├── reports/            # Crash and fix reports
├── memory/
│   ├── MEMORY.md       # Long-term memory (max 10KB)
│   ├── HISTORY.md      # Timestamped consolidation events
│   └── details/        # Archived conversation details
├── telemetry/          # Event logs (events.jsonl)
├── skills/             # Workspace skills
│   └── <name>/SKILL.md # Skill definitions with YAML frontmatter
├── plugins/            # Workspace plugins
│   └── <name>/plugin.json  # Plugin manifests
└── mcp_servers.json    # MCP server configurations
```

## Dependencies

- **hackney** — HTTP client for Ollama API
- **jsx** — JSON parsing/encoding

## Development

```bash
rebar3 compile      # Build
rebar3 eunit        # Run tests (186 tests)
rebar3 shell        # Interactive shell
rebar3 release      # Build release
```

## License

MIT License — see LICENSE file for details.