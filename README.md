# Coding Agent

> An AI-powered coding assistant built in Erlang with Ollama tool calling capabilities.

A production-ready coding agent that uses Ollama for AI-powered code assistance with comprehensive tool support, conversational context management, and multiple interfaces (REPL, HTTP API, Zulip bot).

## Features

### Core Capabilities
- **🧠 Thoughtful Responses** — Uses Ollama's `think` flag for reasoning before acting
- **💬 Conversational Sessions** — Maintains context across multiple turns
- **📁 File Context Caching** — Tracks open files for better context
- **📊 Token Estimation** — Monitors approximate token usage

### Tools Available (35+)

| Category | Tools |
|----------|-------|
| **File Operations** | `read_file`, `write_file`, `edit_file`, `create_directory`, `list_files`, `file_exists` |
| **Git Operations** | `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_branch` |
| **Search** | `grep_files`, `find_files` |
| **Build & Test** | `run_tests`, `run_build`, `run_linter` |
| **Project Detection** | `detect_project` |
| **Backup & Recovery** | `undo_edit`, `list_backups` |
| **Refactoring** | `rename_symbol`, `extract_function`, `find_references`, `get_callers` |
| **Code Intelligence** | `load_context`, `generate_tests`, `generate_docs`, `fetch_docs` |
| **Smart Commits** | `smart_commit`, `review_changes` |
| **Shell** | `run_command` |

### Interfaces
- **REPL** — Interactive terminal interface (`./coder`)
- **HTTP API** — RESTful API with streaming support (`./coder-http`)
- **Zulip Bot** — Chat bot integration (`./coder-zulip`)

## Quick Start

### Prerequisites
1. Erlang/OTP 24+ and rebar3
2. Ollama running locally (https://ollama.ai)
3. A model with tool support (e.g., `glm-5:cloud`, `llama3.2`)

### Installation

```bash
# Clone and build
git clone <repo-url>
cd tarha-new
rebar3 compile
```

### Configuration

Create `config.yaml` (or use environment variables):

```yaml
ollama:
  host: "http://localhost:11434"
  model: "glm-5:cloud"

http:
  enabled: true
  port: 8080

agent:
  max_tokens: 80000
  temperature: 0.7
  max_history: 100
```

Or use environment variables:
```bash
export OLLAMA_MODEL="glm-5:cloud"
export OLLAMA_HOST="http://localhost:11434"
```

### Run

```bash
# Interactive REPL
./coder

# HTTP Server (port 8080)
./coder-http

# HTTP Server with custom port
./coder-http 3000

# Zulip Bot (requires config.yaml)
./coder-zulip
```

## Usage

### Conversational Sessions (Recommended)

Sessions maintain context between messages, enabling follow-up questions:

```erlang
% Start the application
application:ensure_all_started(coding_agent).

% Create a new session
{ok, {SessionId, _Pid}} = coding_agent_session:new().

% Ask questions
{ok, Response, Thinking, History} = coding_agent_session:ask(SessionId,
    <<"List files in the src directory">>).

% Multi-turn conversation
{ok, R2, T2, _} = coding_agent_session:ask(SessionId,
    <<"Edit the README.md to add a Testing section">>).
{ok, R3, T3, _} = coding_agent_session:ask(SessionId,
    <<"Git commit the changes">>).

% Get session statistics
{ok, Stats} = coding_agent_session:stats(SessionId).
% => #{total_tokens_estimate => 5000, tool_calls => 3, message_count => 5}

% Stop session
coding_agent_session:stop_session(SessionId).
```

### HTTP API

```bash
# Health check
curl http://localhost:8080/health

# Send a message (creates new session automatically)
curl -X POST -H 'Content-Type: application/json' \
  -d '{"message":"What is 2+2?"}' \
  http://localhost:8080/chat

# Continue existing session
curl -X POST -H 'Content-Type: application/json' \
  -d '{"message":"What about 3+3?", "session_id":"SESSION_ID"}' \
  http://localhost:8080/chat

# Create named session
curl -X POST -H 'Content-Type: application/json' \
  -d '{"action":"create"}' \
  http://localhost:8080/session

# List tools
curl http://localhost:8080/tools

# Get memory
curl http://localhost:8080/memory
```

### Streaming API (Server-Sent Events)

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"message":"Explain the project structure"}' \
  http://localhost:8080/chat/stream
```

### Memory System

The agent has a two-layer memory system:

1. **MEMORY.md** — Long-term memory (facts, preferences)
2. **HISTORY.md** — Grep-searchable conversation history

```bash
# Get memory
curl http://localhost:8080/memory

# Update memory
curl -X POST -H 'Content-Type: application/json' \
  -d '{"content":"# User Preferences\n- Name: Alice\n- Project: my-app"}' \
  http://localhost:8080/memory

# Get history
curl http://localhost:8080/memory/history

# Trigger consolidation
curl -X POST http://localhost:8080/memory/consolidate
```

### Skills

Skills are modular capabilities that can be loaded dynamically:

```bash
# List available skills
curl http://localhost:8080/skills

# Get skill details
curl http://localhost:8080/skills/weather
```

Skills are stored in `priv/skills/` (built-in) and `skills/` (user-defined).

## Project Structure

```
src/
├── coding_agent.app.src          # App config (vsn: 0.3.0)
├── coding_agent_app.erl          # Application module
├── coding_agent_sup.erl          # Supervisor
├── coding_agent_ollama.erl       # Ollama API client
├── coding_agent_tools.erl       # 35+ tool implementations
├── coding_agent.erl              # Single-shot agent
├── coding_agent_session_sup.erl  # Session supervisor
├── coding_agent_session.erl      # Conversational session
├── coding_agent_session_store.erl # Session persistence (ETS)
├── coding_agent_stream.erl       # Streaming support
├── coding_agent_lsp.erl          # LSP integration
├── coding_agent_index.erl       # Code indexing
├── coding_agent_self.erl        # Self-modification, checkpoints
├── coding_agent_healer.erl      # Crash analysis, auto-fix
├── coding_agent_process_monitor.erl # Process monitoring
├── coding_agent_conv_memory.erl # Conversational memory
├── coding_agent_skills.erl      # Skills loader
├── coding_agent_repl.erl        # Interactive REPL
├── coding_agent_cli.erl         # CLI interface
├── coding_agent_http.erl        # HTTP API (Cowboy)
├── coding_agent_zulip.erl       # Zulip bot integration
└── coding_agent_config.erl      # Config loader

priv/skills/                      # Built-in skills
skills/                           # User-defined skills
memory/
├── MEMORY.md                     # Long-term memory
└── HISTORY.md                    # Conversation history
```

## Example Workflows

### Edit and Commit

```erlang
{ok, {Sess, _}} = coding_agent_session:new().

% Turn 1: Make edits
coding_agent_session:ask(Sess,
    <<"Edit src/my_module.erl to add function hello/0 that returns 'world'">>).

% Turn 2: Review changes
coding_agent_session:ask(Sess, <<"Show me the git diff">>).

% Turn 3: Commit
coding_agent_session:ask(Sess, 
    <<"Commit with message 'Add hello function'">>).
```

### Undo Mistakes

```erlang
% Made a mistake? Undo it
coding_agent_session:ask(Sess, <<"Undo the last edit to config.erl">>).

% Or list available backups
coding_agent_session:ask(Sess, <<"What backups are available?">>).
```

### Project Exploration

```erlang
% Detect project type
coding_agent_session:ask(Sess, <<"What kind of project is this?">>).

% Find specific files
coding_agent_session:ask(Sess, <<"Find all files with 'test' in the name">>).

% Search code
coding_agent_session:ask(Sess, <<"Grep for 'gen_server' in all .erl files">>).
```

## Architecture

### Tool Loop

1. Agent receives a task
2. Sends task to LLM with tool definitions (and `think: true`)
3. Model thinks, then requests tool calls if needed
4. Agent executes tools, returns results
5. Process repeats until model provides final answer
6. Maximum 15 tool-calling iterations to prevent infinite loops

### Session Context

- Each session maintains conversation history
- History trimmed to last 50 messages
- Open files are cached for context
- System prompt includes working directory and session ID
- Token usage is estimated for monitoring

### Backup System

- Automatic backups in `.tarha/backups/`
- Maximum 50 backups retained
- Use `undo_edit` to restore from backup
- Use `list_backups` to see all backups

## Key Improvements Over Basic Agents

1. **Diff-based editing** — Use `edit_file` for surgical edits instead of rewriting entire files
2. **Automatic backups** — Every edit creates a backup, undoable with `undo_edit`
3. **Git integration** — Full git workflow support (status, diff, commit, branch)
4. **Project detection** — Automatically understands project structure
5. **Context management** — Token estimation and file caching
6. **Memory system** — Long-term memory and conversation history
7. **Skills system** — Extensible capabilities via skill modules
8. **HTTP API** — RESTful API with streaming support for web integration

## Dependencies

- **hackney** — HTTP client for Ollama API
- **jsx** — JSON parsing/encoding
- **cowboy** — HTTP server for API

## Development

```bash
# Run tests
rebar3 eunit

# Start interactive shell
rebar3 shell

# Build release
rebar3 release
```

## License

MIT License - see LICENSE file for details.