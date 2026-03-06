# Coding Agent - Erlang Implementation

This is an Erlang-based coding agent using Ollama with tool calling capabilities.

## Project Structure

```
src/
├── coding_agent.app.src          # App config (vsn: 0.4.0)
├── coding_agent_app.erl          # Application module
├── coding_agent_sup.erl          # Supervisor
├── coding_agent_ollama.erl       # Ollama API client
├── coding_agent_tools.erl        # 30+ tools (read_file, write_file, etc.)
├── coding_agent.erl              # Single-shot agent
├── coding_agent_session_sup.erl  # Session supervisor
├── coding_agent_session.erl      # Conversational session
├── coding_agent_self.erl         # Self-modification, checkpoints
├── coding_agent_healer.erl       # Crash analysis, auto-fix
├── coding_agent_process_monitor.erl # Process monitoring, GC, crash tracking
├── coding_agent_conv_memory.erl  # Conversational memory (MEMORY.md + HISTORY.md)
├── coding_agent_skills.erl       # Skills loader (workspace + builtin)
├── coding_agent_repl.erl         # Interactive REPL
├── coding_agent_http.erl         # HTTP API (Cowboy)
├── coding_agent_zulip.erl        # Zulip bot integration
└── coding_agent_config.erl       # Config loader

priv/
└── skills/
    └── example/SKILL.md          # Example builtin skill

skills/                           # Workspace skills (user-defined)
└── my-skill/SKILL.md

memory/
├── MEMORY.md                     # Long-term memory (facts, preferences)
└── HISTORY.md                    # Grep-searchable conversation history

config.yaml                        # Example configuration
coder                              # REPL launcher script
coder-http                         # HTTP server launcher
coder-zulip                        # Zulip bot launcher
rebar.config                       # Dependencies: hackney, jsx, cowboy
```

## Build & Run

```bash
# Build
rebar3 compile

# Run REPL
./coder

# Run HTTP server (port 8080)
./coder-http 8080

# Run Zulip bot (requires config.yaml)
./coder-zulip
```

## HTTP API Endpoints

- `GET /` - API info
- `GET /health` - Health check
- `GET /status` - Agent status
- `POST /chat` - Send message to agent
- `POST /session` - Create session
- `GET /session/:id` - Get session info
- `GET /memory` - Get long-term memory
- `POST /memory` - Update long-term memory
- `GET /memory/history` - Get conversation history log
- `POST /memory/consolidate` - Trigger memory consolidation
- `GET /tools` - List available tools

### Example Usage

```bash
# Health check
curl http://localhost:8080/health

# Chat
curl -X POST -H 'Content-Type: application/json' \
  -d '{"message":"What is 2+2?"}' \
  http://localhost:8080/chat

# Chat with session
curl -X POST -H 'Content-Type: application/json' \
  -d '{"message":"What about 3+3?", "session_id":"SESSION_ID"}' \
  http://localhost:8080/chat

# Create session
curl -X POST -H 'Content-Type: application/json' \
  -d '{"action":"create"}' \
  http://localhost:8080/session

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
OLLAMA_MODEL=glm-5:cloud ./coder-http 8080
```

Or in `config.yaml`:
```yaml
model: glm-5:cloud
ollama_host: http://localhost:11434
```

## Architecture Notes

- Uses Cowboy HTTP server for API
- Sessions stored in ETS table `coding_agent_sessions`
- Conversational memory stored in `memory/MEMORY.md` and `memory/HISTORY.md`
- Tool calling requires `think: true` flag in Ollama API
- Zulip integration only starts when `zulip_site` is configured
- HTTP server only starts when `http_port` is configured via script
- CORS enabled for cross-origin requests from web frontend

## Recent Changes

- Added conversational memory system (MEMORY.md + HISTORY.md)
- Added memory API endpoints
- Fixed CORS headers for web frontend
- Fixed HTTP handler to be plain Cowboy handler
- Session persistence correctly uses ETS table