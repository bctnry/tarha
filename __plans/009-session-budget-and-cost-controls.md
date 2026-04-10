# 009: Session Budget and Cost Controls

**Priority**: Medium  
**Impact**: Prevent runaway sessions, resource awareness  
**Complexity**: Medium  
**Files affected**: `coding_agent_session.erl`, `coding_agent_config.erl`, `coding_agent_repl.erl`

## Problem

Tarha has per-session iteration limits but no concept of cost or token budgets. A session can consume unbounded tokens and API calls. There is no `max_tokens` budget, no cost estimation, and no way to set limits on how expensive a session can get.

## Proposed Solution

### 1. Configuration in `config.yaml`

```yaml
agent:
  max_iterations: 100          # (existing)
  max_tokens: 500000           # New: total token budget per session
  max_tool_calls: 200          # New: total tool calls per session
  context_ratio: 0.85          # (existing, renamed from max_context_ratio)

budget:
  warn_at_percent: 80          # Warn when budget is 80% consumed
  stop_at_percent: 100         # Stop session at 100%
  max_cost_usd: 10.0          # Optional: stop at estimated cost
```

### 2. Budget tracking in `coding_agent_session.erl`

Add budget fields to state:

```erlang
-record(state, {
    %% ... existing fields ...
    budget_used :: integer(),        %% Tokens consumed so far
    budget_limit :: integer(),       %% Max tokens for this session
    tool_calls_remaining :: integer(), %% Tool calls remaining
    tool_calls_limit :: integer()     %% Max tool calls for this session
}).
```

### 3. Budget enforcement

```erlang
check_budget(State) ->
    #state{budget_used = Used, budget_limit = Limit, tool_calls_remaining = Remaining} = State,
    WarnThreshold = Limit * get_warn_percent() / 100,
    
    %% Token budget check
    case Used > Limit of
        true -> {error, budget_exceeded, Used, Limit};
        false ->
            case Used > WarnThreshold of
                true -> {warning, budget_warning, Used, Limit};
                false -> ok
            end
    end,
    
    %% Tool call budget check
    case Remaining =< 0 of
        true -> {error, tool_budget_exceeded, Remaining};
        false -> ok
    end.
```

### 4. Token estimation improvements

Enhance `coding_agent_ollama:count_tokens/1` with per-session accumulation:

```erlang
update_budget(State, TokenInfo) ->
    Used = case TokenInfo of
        #{prompt_eval_count := P, eval_count := C} -> P + C;
        _ -> State#state.estimated_tokens
    end,
    State#state{
        budget_used = State#state.budget_used + Used,
        tool_calls_remaining = State#state.tool_calls_remaining - 1
    }.
```

### 5. Cost estimation

Add per-model cost estimation for common Ollama models:

```erlang
-define(COST_PER_1K_TOKENS, #{
    <<"glm-5:cloud">> => 0.0001,
    <<"llama3.2">> => 0.00005,
    <<"codellama">> => 0.00003,
    %% ... add more
    default => 0.0001
}).

estimate_cost(Tokens, Model) ->
    Rate = maps:get(Model, ?COST_PER_1K_TOKENS, 0.0001),
    Tokens * Rate / 1000.
```

### 6. `/status` command enhancement

```
Model: glm-5:cloud
Context: 45,230 / 131,072 tokens (34.5%)
Session budget: 234,500 / 500,000 tokens used (46.9%)
Tool calls: 42 / 200 (21.0%)
Estimated cost: $0.0234
Messages: 28 / 100
⚠ Budget warning at 80% (400,000 tokens)
```

### 7. Budget exhaustion behavior

When budget is exhausted:
- Send a final message to the LLM: "Session budget exhausted. Provide a summary of what was accomplished."
- LLM gets one final turn to summarize
- Session stops accepting new tool calls
- `/status` shows budget exceeded status

## Implementation Steps

1. Add budget fields to `#state{}` record
2. Add configuration keys to `coding_agent_config.erl`
3. Implement budget initialization from config in `init/1`
4. Implement `check_budget/1` and `update_budget/2`
5. Add budget checks to `run_agent_loop/5` (before each API call)
6. Add token accumulation after each API response
7. Implement cost estimation with per-model rates
8. Enhance `/status` command with budget display
9. Add `/budget` command to show detailed budget info
10. Add budget exhaustion handling (final summary turn)
11. Write tests for budget tracking and enforcement

## Edge Cases

- **Initial budget unknown**: If `context_length` query fails, use default 128K
- **Budget config changes mid-session**: Use session-initial values, don't react to config changes
- **Negative budget**: Set `budget_limit = infinity` to disable limits
- **Summarization budget**: Reserve ~2K tokens for the final summary turn
- **Streaming budget**: Update budget incrementally as streaming tokens arrive

## Success Metrics

- Sessions respect configured token budgets
- Users can see real-time budget consumption via `/status`
- Budget exhaustion triggers a clean shutdown with summary
- No session exceeds `max_tokens` or `max_tool_calls` limits