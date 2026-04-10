# Step 12: Modify run_agent_loop to use lazy compaction

## Description
This step integrates the lazy compaction mechanism into the main agent loop. Instead of preemptively compacting messages, we let requests fail naturally and recover via compact_and_retry.

**Part A: Add compaction config functions to coding_agent_config.erl**

Add three new exported functions after the existing accessors section:

```erlang
%% Compaction settings for lazy context management
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

Add these to the -export list.

**Part B: Modify run_agent_loop/3 in coding_agent.erl**

Replace the direct `chat_with_tools/3` call with `compact_and_retry/5`:

**Current code (lines 96-103):**
```erlang
run_agent_loop(Model, Messages, Iteration) when Iteration >= ?MAX_ITERATIONS ->
    {error, max_iterations_reached, Messages};
run_agent_loop(Model, Messages, Iteration) ->
    Tools = coding_agent_tools:tools(),
    case coding_agent_ollama:chat_with_tools(Model, Messages, Tools) of
        {ok, #{<<"message">> := ResponseMsg}} ->
            handle_response(Model, Messages, ResponseMsg, Iteration);
        {error, Reason} ->
            {error, Reason}
    end.
```

**New code:**
```erlang
run_agent_loop(Model, Messages, Iteration) when Iteration >= ?MAX_ITERATIONS ->
    {error, max_iterations_reached, Messages};
run_agent_loop(Model, Messages, Iteration) ->
    Tools = coding_agent_tools:tools(),
    InitialRatio = coding_agent_config:compaction_initial_ratio(),
    MinRatio = coding_agent_config:compaction_min_ratio(),
    case coding_agent_ollama:compact_and_retry(Model, Messages, Tools, InitialRatio, MinRatio) of
        {ok, Response, _Metadata} when is_map(Response) ->
            %% Response may include compaction metadata in _Metadata
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

Note: The `compact_and_retry/5` function (from Step 4) already handles:
1. First attempt without compaction
2. On context error, progressive compaction with ratio reduction
3. Returning either `{ok, Response, Metadata}` or `{error, {context_exhausted, ...}}`

## Files
- src/coding_agent_config.erl (add 3 config functions + export)

## Status
pending
