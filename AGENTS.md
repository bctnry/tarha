# Coding Agent - Erlang Implementation

This is an Erlang-based coding agent using Ollama with tool calling capabilities.

## Project Structure

```
src/
├── coding_agent.app.src          # App config
├── coding_agent_app.erl          # Application module
├── coding_agent_sup.erl          # Supervisor
├── coding_agent_config.erl       # Centralized config (model, host, etc.)
├── coding_agent_ollama.erl       # Ollama API client
├── coding_agent_tools.erl        # Tool dispatcher (delegates to sub-modules)
├── coding_agent_tools_build.erl  # Build/test/lint tools
├── coding_agent_tools_command.erl# Shell command & HTTP tools
├── coding_agent_tools_file.erl   # File operation tools
├── coding_agent_tools_git.erl    # Git operation tools
├── coding_agent_tools_model.erl  # Model management tools
├── coding_agent_tools_refactor.erl# Smart commit, merge, review tools
├── coding_agent_tools_search.erl # Grep/find search tools
├── coding_agent_tools_self.erl   # Self-modification & checkpoint tools
├── coding_agent_tools_skills.erl # Skills listing & loading tools
├── coding_agent_tools_undo.erl   # Undo/redo & backup tools
├── coding_agent.erl              # Single-shot agent
├── coding_agent_session_sup.erl  # Session supervisor
├── coding_agent_session.erl      # Conversational session
├── coding_agent_session_store.erl# Session persistence
├── coding_agent_self.erl         # Self-modification, checkpoints
├── coding_agent_healer.erl       # Crash analysis, auto-fix
├── coding_agent_process_monitor.erl # Process monitoring, GC, crash tracking
├── coding_agent_conv_memory.erl  # Conversational memory (MEMORY.md + HISTORY.md)
├── coding_agent_skills.erl       # Skills loader (workspace + builtin)
├── coding_agent_repl.erl         # Interactive REPL
├── coding_agent_cli.erl          # CLI interface
├── coding_agent_undo.erl         # Undo stack manager
├── coding_agent_request_registry.erl # Request tracking
├── coding_agent_stream.erl       # Streaming response handler
├── coding_agent_lsp.erl          # LSP client
└── coding_agent_index.erl        # Code index

priv/
├── skills/
│   └── example/SKILL.md          # Example builtin skill

skills/                           # Workspace skills (user-defined)
└── my-skill/SKILL.md

memory/
├── MEMORY.md                     # Long-term memory (facts, preferences)
└── HISTORY.md                    # Grep-searchable conversation history

config.example.yaml               # Documented config template
config.yaml                        # User configuration (gitignored)
coder                              # REPL launcher script
rebar.config                       # Dependencies: hackney, jsx
```

## Build & Run

```bash
# Build
rebar3 compile

# Run REPL
./coder
```

## Conversational Memory

The agent has a two-layer memory system similar to nanobot:

1. **MEMORY.md** - Long-term memory storing facts, preferences, and important info
2. **HISTORY.md** - Grep-searchable log of conversations with timestamps

Memory is automatically included in the system prompt for all sessions, allowing the agent to remember preferences and context across sessions.

### Memory Consolidation

When triggered (either manually or automatically after enough messages), the agent uses an LLM to:
1. Summarize old conversations into HISTORY.md entries
2. Extract important facts and update MEMORY.md

## Model Configuration

Set the model via environment variable:
```bash
OLLAMA_MODEL=glm-5:cloud ./coder
```

Or in `config.yaml` (see `config.example.yaml` for all options):
```yaml
ollama:
  model: glm-5:cloud
  host: http://localhost:11434
```

Configuration is centralized in `coding_agent_config` module, which provides:
- `coding_agent_config:model/0` — current model name
- `coding_agent_config:ollama_host/0` — Ollama API host
- `coding_agent_config:max_iterations/0` — agent loop limit
- `coding_agent_config:sessions_dir/0` — session storage path
- `coding_agent_config:set_model/1` — switch model at runtime

## Architecture Notes

- Sessions stored in ETS table `coding_agent_sessions`
- Conversational memory stored in `memory/MEMORY.md` and `memory/HISTORY.md`
- Tool calling requires `think: true` flag in Ollama API
- `coding_agent_tools` dispatches tool calls to sub-modules (file, git, search, etc.)

## IMPORTANT

- THIS IS NOT A NODE PROJECT, THIS IS NOT A NODE PROJECT, THIS IS NOT A NODE PROJECT, DO NOT USE NPM TEST. DO NOT USE NPM TEST. DO NOT USE NPM TEST.
