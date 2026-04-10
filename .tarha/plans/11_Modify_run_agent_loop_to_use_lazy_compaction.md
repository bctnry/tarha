# Step 11: Modify run_agent_loop to use lazy compaction

## Description
### Part A: Add compaction config functions to coding_agent_config.erl

Add three new exported functions:
- `compaction_initial_ratio/0` - default 0.8 (compact to 80% on first context error)
- `compaction_min_ratio/0` - default 0.2 (don't compact below 20% of messages)
- `compaction_enabled/0` - default true (allow disabling lazy compaction)

```erlang
-spec compaction_initial_ratio() -> float().
compaction_initial_ratio() ->
    application:get_env(coding_agent, compaction_initial_ratio, 0.8).

-spec compaction_min_ratio() -> float().
compaction_min_ratio() ->
    application:get_env(coding_agent, compaction_min_ratio, 0.2).

-spec compaction_enabled() -> boolean().
compaction_enabled() ->
    application:get_env(coding_agent, compaction_enabled, true).
```

### Part B: Modify run_agent_loop/3 in coding_agent.erl

Replace the direct `chat_with_tools/3` call with `compact_and_retry/5`:

**Before (lines 100-103):**
```erlang
run_agent_loop(Model, Messages, Iteration) ->
    Tools = coding_agent_tools:tools(),
    case coding_agent_ollama:chat_with_tools(Model, Messages, Tools) of
        {ok, #{<<"message">> := ResponseMsg}} ->
            handle_response(Model, Messages, ResponseMsg, Iteration);
        {error, Reason} ->
            {error, Reason}
    end.
```

**After:**
```erlang
run_agent_loop(Model, Messages, Iteration) ->
    Tools = coding_agent_tools:tools(),
    InitialRatio = coding_agent_config:compaction_initial_ratio(),
    MinRatio = coding_agent_config:compaction_min_ratio(),
    case coding_agent_ollama:compact_and_retry(Model, Messages, Tools, InitialRatio, MinRatio) of
        {ok, #{<<"message">> := ResponseMsg}} ->
            handle_response(Model, Messages, ResponseMsg, Iteration);
        {ok, Response, _Metadata} when is_map(Response) ->
            %% Response with compaction metadata
            handle_response(Model, Messages, Response, Iteration);
        {error, {context_exhausted, Reason, CompactionLog}} ->
            %% All compaction attempts failed
            io:format("[agent] Context exhausted after ~p compaction attempts~n", 
                      [length(CompactionLog)]),
            {error, {context_exhausted, Reason}};
        {error, Reason} ->
            {error, Reason}
    end.
```

## Files
- src/coding_agent_config.erl (add 3 new config functions)

## Status
pending
