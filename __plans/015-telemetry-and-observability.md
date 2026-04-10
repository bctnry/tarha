# 015: Telemetry and Observability

**Priority**: Low  
**Impact**: Debugging, performance tuning, usage analysis  
**Complexity**: Low  
**Files affected**: new `coding_agent_telemetry.erl`, `coding_agent_session.erl`, `coding_agent_ollama.erl`

## Problem

Tarha has no observability beyond `io:format` debug output. There is no structured logging, no metrics collection, and no way to analyze performance, token usage, or tool call patterns across sessions.

## Proposed Solution

### 1. Telemetry module

```erlang
-module(coding_agent_telemetry).
-behaviour(gen_server).

-record(event, {
    timestamp :: integer(),
    type :: atom(),           %% api_call, tool_call, session, compaction
    session_id :: binary(),
    data :: map()
}).

-record(state, {
    events :: [#event{}],
    metrics :: #{atom() => integer()},
    enabled :: boolean(),
    output_dir :: string()   %% .tarha/telemetry/
}).
```

### 2. Event types

| Event | Fields |
|-------|--------|
| `api_call` | model, prompt_tokens, completion_tokens, duration_ms, success |
| `tool_call` | tool_name, duration_ms, success, result_size |
| `session_start` | session_id, model, context_length |
| `session_end` | session_id, duration_ms, total_tokens, total_tool_calls |
| `compaction` | messages_before, messages_after, tokens_before, tokens_after |
| `memory_consolidation` | entries_before, entries_after |
| `error` | module, function, error_type, stacktrace |
| `budget_update` | tokens_used, budget_remaining, tool_calls_remaining |

### 3. Metrics counters

```erlang
-type metric_name() :: 
    total_api_calls | total_tool_calls | total_tokens_used |
    total_errors | total_compactions | total_sessions |
    avg_api_latency_ms | avg_tool_latency_ms |
    tokens_by_model | calls_by_tool.
```

### 4. Event recording API

```erlang
%% Simple API for recording events
coding_agent_telemetry:record(api_call, #{
    model => Model,
    prompt_tokens => PT,
    completion_tokens => CT,
    duration_ms => Dur,
    success => true
}).

coding_agent_telemetry:record(tool_call, #{
    tool_name => ToolName,
    duration_ms => Dur,
    success => true,
    result_size => Size
}).

%% Query API
coding_agent_telemetry:get_metrics() -> #{atom() => integer() | float()}.
coding_agent_telemetry:get_events(Type, Since) -> [#event{}].
coding_agent_telemetry:get_summary() -> #{
    total_sessions => integer(),
    total_tokens => integer(),
    total_tool_calls => integer(),
    total_errors => integer(),
    avg_latency_ms => float(),
    tool_breakdown => #{binary() => integer()},
    model_breakdown => #{binary() => integer()}
}.
```

### 5. Output formats

Events are written to `.tarha/telemetry/` in daily JSON files:

```
.tarha/telemetry/
├── 2026-04-09.jsonl
├── 2026-04-08.jsonl
└── metrics.json
```

Each line in the JSONL file:
```json
{"timestamp":1712635200000,"type":"api_call","session_id":"abc123","data":{"model":"glm-5:cloud","prompt_tokens":1234,"completion_tokens":567,"duration_ms":2345,"success":true}}
```

`metrics.json` is updated on each event:
```json
{
  "total_sessions": 42,
  "total_tokens": 1234567,
  "total_tool_calls": 891,
  "total_errors": 12,
  "avg_api_latency_ms": 2345.6,
  "tool_breakdown": {"read_file": 234, "edit_file": 123, "git_status": 89},
  "model_breakdown": {"glm-5:cloud": 890123, "llama3.2": 344444}
}
```

### 6. REPL commands

```
/metrics              Show current session metrics
/metrics summary      Show all-time summary
/metrics tools        Show tool call breakdown
/metrics export       Export metrics as JSON
/telemetry on         Enable telemetry
/telemetry off        Disable telemetry
```

### 7. Integration points

Add telemetry calls at key points:

```erlang
%% In coding_agent_session:run_agent_loop
coding_agent_telemetry:record(api_call, #{
    model => Model, prompt_tokens => PT, completion_tokens => CT,
    duration_ms => Duration, success => true
}),

%% In coding_agent_session:execute_single_tool
coding_agent_telemetry:record(tool_call, #{
    tool_name => ToolName, duration_ms => Duration,
    success => Success, result_size => Size
}),

%% In coding_agent_session:compact_session
coding_agent_telemetry:record(compaction, #{
    messages_before => Before, messages_after => After,
    tokens_before => TokensBefore, tokens_after => TokensAfter
}),

%% In coding_agent_healer:auto_fix
coding_agent_telemetry:record(error, #{
    module => Module, function => Function,
    error_type => ErrorType, stacktrace => StackTrace
}).
```

### 8. Configuration

```yaml
telemetry:
  enabled: true
  output_dir: ".tarha/telemetry"
  max_file_age_days: 30
  events:
    - api_call
    - tool_call
    - session_start
    - session_end
    - compaction
    - error
```

## Implementation Steps

1. Create `coding_agent_telemetry.erl` gen_server with event recording
2. Implement ETS-backed metrics counters with atomic increments
3. Implement JSONL file writer with daily rotation
4. Implement `record/2` function for event recording
5. Implement `get_metrics/0`, `get_summary/0`, `get_events/2` query API
6. Add telemetry calls to `coding_agent_session` (api_call, tool_call, session lifecycle)
7. Add telemetry calls to `coding_agent_ollama` (API latency, token usage)
8. Add telemetry calls to `coding_agent_healer` (error events)
9. Add `/metrics` and `/telemetry` REPL commands
10. Add configuration in `config.yaml`
11. Add file rotation and cleanup (30-day retention)
12. Write tests for event recording and metrics aggregation

## Edge Cases

- **High volume**: ETS counters are atomic and non-blocking; file writes are async via `gen_server:cast`
- **Disk full**: Catch file write errors, disable telemetry gracefully
- **Crash during write**: Use temp file + atomic rename pattern
- **Concurrent sessions**: Each session records its own session_id; metrics are aggregated
- **Telemetry disabled**: All `record` calls become no-ops

## Success Metrics

- All API calls, tool calls, and errors are recorded
- `/metrics` shows real-time and historical data
- JSONL files are written daily with proper rotation
- Telemetry overhead <1% of session time