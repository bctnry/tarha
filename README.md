# Coding Agent in Erlang

A production-ready coding agent that uses Ollama for AI-powered code assistance with tool support, conversational context, and thinking capability.

## Features

### Core Capabilities
- **Thoughtful responses** - Uses Ollama's `think` flag for reasoning before acting
- **Conversational sessions** - Maintains context across multiple turns
- **File context caching** - Tracks open files for better context
- **Token estimation** - Tracks approximate token usage

### Tools Available
- **File Operations**: `read_file`, `write_file`, `edit_file`, `create_directory`, `list_files`, `file_exists`
- **Git Operations**: `git_status`, `git_diff`, `git_log`, `git_add`, `git_commit`, `git_branch`
- **Search**: `grep_files`, `find_files`
- **Project Detection**: `detect_project` - auto-detect project type and build tools
- **Safety**: `undo_edit`, `list_backups` - restore files from automatic backups

### Key Improvements over Basic Agents
1. **Diff-based editing** - Use `edit_file` for surgical edits instead of rewriting entire files
2. **Automatic backups** - Every edit creates a backup, undoable with `undo_edit`
3. **Git integration** - Full git workflow support (status, diff, commit, branch)
4. **Project detection** - Automatically understands project structure
5. **Context management** - Token estimation and file caching

## Prerequisites

1. Install Erlang/OTP 24+ and rebar3
2. Install and run Ollama: https://ollama.ai
3. Pull a model with tool support (e.g., `glm-5:cloud`, `llama3.2`, etc.)

## Installation

```bash
rebar3 get-deps
rebar3 compile
```

## Configuration

Edit `src/coding_agent.app.src` to configure:
- `ollama_host`: Ollama server URL (default: http://localhost:11434)
- `model`: Model to use (default: glm-5:cloud) - must support tools

## Usage

### Conversational Sessions (Recommended)

Sessions maintain context between messages, allowing follow-up questions:

```erlang
% Start the application
application:ensure_all_started(coding_agent).

% Create a new session
{ok, {SessionId, _Pid}} = coding_agent_session:new().

% Ask questions (returns thinking + response + history)
{ok, Response, Thinking, History} = coding_agent_session:ask(SessionId, "List files in src directory").

% Multi-turn conversation
{ok, R2, T2, _} = coding_agent_session:ask(SessionId, "Edit the README.md to add a Testing section").
{ok, R3, T3, _} = coding_agent_session:ask(SessionId, "Git commit the changes").

% Get session statistics
{ok, Stats} = coding_agent_session:stats(SessionId).
% => #{total_tokens_estimate => 5000, tool_calls => 3, message_count => 5}

% Stop session
coding_agent_session:stop_session(SessionId).
```

### Single-shot Tasks (No Context)

```erlang
% Run a single task without maintaining context
{ok, Result, Thinking} = coding_agent:run("List files and explain the project structure").
```

### Example Workflows

#### Edit and Commit
```erlang
{ok, {Sess, _}} = coding_agent_session:new().

% Turn 1: Make edits
{ok, _, _, _} = coding_agent_session:ask(Sess, 
    "Edit src/my_module.erl to add a function called hello/0 that returns 'world'").

% Turn 2: Review changes
{ok, _, _, _} = coding_agent_session:ask(Sess, "Show me the git diff").

% Turn 3: Commit
{ok, _, _, _} = coding_agent_session:ask(Sess, "Commit with message 'Add hello function'").
```

#### Undo Mistakes
```erlang
% Make an edit
coding_agent_session:ask(Sess, "Edit config.erl to change port to 8080").

% Made a mistake? Undo it
coding_agent_session:ask(Sess, "Undo the last edit to config.erl").

% Or list available backups
coding_agent_session:ask(Sess, "What backups are available?").
```

#### Project Exploration
```erlang
% Detect project type
coding_agent_session:ask(Sess, "What kind of project is this?").

% Find specific files
coding_agent_session:ask(Sess, "Find all files with 'test' in the name").

% Search code
coding_agent_session:ask(Sess, "Grep for 'gen_server' in all .erl files").
```

## Architecture

```
src/
├── coding_agent.app.src       # App config
├── coding_agent_app.erl       # Application module
├── coding_agent_sup.erl       # Supervisor
├── coding_agent_ollama.erl    # Ollama API client (with think flag)
├── coding_agent_tools.erl     # Tool implementations (20+ tools)
├── coding_agent.erl           # Main agent (single-shot)
├── coding_agent_session_sup.erl # Session supervisor
├── coding_agent_session.erl   # Conversational session
└── coding_agent_cli.erl       # CLI interface
```

## How It Works

### Thinking Phase
- Uses Ollama's `think` flag to enable model reasoning
- Model thinks through the problem before acting
- Returns both thinking process and final response

### Tool Loop
1. Agent receives a task
2. Sends task to LLM with tool definitions (and think=true)
3. Model thinks, then requests tool calls if needed
4. Agent executes tools, returns results
5. Process repeats until model provides final answer
6. Maximum 15 tool-calling iterations to prevent infinite loops

### Session Context
- Each session maintains conversation history
- History is trimmed to last 50 messages to stay within context limits
- Open files are cached for context (auto-refreshed on edit)
- System prompt includes working directory and session ID
- Token usage is estimated for monitoring

### Backup System
- Automatic backups created in `.coding_agent_backups/`
- Maximum 50 backups retained
- Use `undo_edit` to restore from backup
- Use `list_backups` to see all backups

## Session Management

Sessions are useful for:
- Multi-step refactoring tasks
- Exploring unfamiliar codebases
- Interactive debugging sessions
- Ongoing development conversations

## Error Recovery

- `undo_edit` - Restore file from backup
- Automatic backups on every edit/write
- Clear error messages from tool failures