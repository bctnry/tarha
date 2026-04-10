# 001: Concurrent Tool Execution

**Priority**: High  
**Impact**: Significant latency reduction on multi-tool turns  
**Complexity**: Medium  
**Files affected**: `coding_agent_tools.erl`, `coding_agent_session.erl`

## Problem

Tarha executes tool calls sequentially within each agent loop iteration. When the model requests multiple independent tools (e.g., `read_file` on three different files), they execute one after another, wasting time on I/O-bound operations.

Claude Code's `StreamingToolExecutor` dispatches concurrency-safe tools in parallel while the stream is still being received, and runs non-safe tools serially.

## Current Behavior

In `coding_agent_session.erl`, `execute_tool_calls/2` iterates over tool calls one at a time:

```erlang
execute_tool_calls(ToolCalls, State) ->
    lists:foldl(fun(ToolCall, {Results, S}) ->
        {Result, NewState} = execute_single_tool(ToolCall, S),
        {[Result | Results], NewState}
    end, {[], State}, ToolCalls).
```

## Proposed Solution

### 1. Add concurrency metadata to tool definitions

In `coding_agent_tools:tools/0`, add a `concurrent` field to each tool schema:

```erlang
%% Concurrency-safe tools (read-only, no side effects, no shared state mutation)
- define(CONCURRENT_TOOLS, 
    [<<"read_file">>, <<"list_files">>, <<"file_exists">>, <<"grep_files">>,
     <<"find_files">>, <<"find_references">>, <<"get_callers">>, <<"git_status">>,
     <<"git_log">>, <<"git_diff">>, <<"list_models">>, <<"list_skills">>,
     <<"list_backups">>, <<"undo_history">>, <<"detect_project">>, <<"show_model">>,
     <<"get_self_modules">>, <<"analyze_self">>, <<"list_checkpoints">>,
     <<"load_context">>, <<"review_changes">>, <<"http_request">>,
     <<"fetch_docs">>]).
```

### 2. Implement parallel execution in `coding_agent_session.erl`

Replace `execute_tool_calls/2` with a version that partitions tool calls into concurrent-safe and sequential groups:

```erlang
execute_tool_calls(ToolCalls, State) ->
    {Concurrent, Sequential} = partition_by_concurrency(ToolCalls),
    
    %% Execute concurrent tools in parallel
    ConcurrentResults = execute_concurrent_tools(Concurrent, State),
    
    %% Execute sequential tools one at a time (state may change between calls)
    {SequentialResults, FinalState} = execute_sequential_tools(Sequential, State),
    
    {merge_results(ConcurrentResults, SequentialResults), FinalState}.
```

### 3. Implement `execute_concurrent_tools/2`

Use Erlang's natural concurrency — spawn a process per tool call and collect results:

```erlang
execute_concurrent_tools(ToolCalls, State) ->
    Parent = self(),
    Refs = [spawn_monitor(fun() ->
        Result = execute_single_tool(ToolCall, State),
        Parent ! {tool_result, Ref, Result}
    end) || {Ref, ToolCall} <- lists:zip(lists:seq(1, length(ToolCalls)), ToolCalls)],
    collect_concurrent_results(Refs, []).
```

### 4. Add concurrency flag to `coding_agent_tools.erl`

```erlang
is_concurrent_tool(<<"read_file">>) -> true;
is_concurrent_tool(<<"edit_file">>) -> false;
%% ... etc
is_concurrent_tool(_) -> false.

partition_by_concurrency(ToolCalls) ->
    lists:partition(
        fun(#{<<"function">> := #{<<"name">> := Name}}) ->
            is_concurrent_tool(Name)
        end, ToolCalls).
```

## Implementation Steps

1. Define the concurrent tool list in `coding_agent_tools.erl`
2. Add `is_concurrent_tool/1` and `partition_by_concurrency/1` functions
3. Rewrite `execute_tool_calls/2` in `coding_agent_session.erl` to partition and dispatch
4. Add timeout handling for concurrent tool execution (default 120s per tool)
5. Handle partial failure: if a concurrent tool throws, cancel siblings and return error
6. Update `coding_agent_tools:execute_concurrent/1` to reuse the same pattern
7. Add unit tests for partition logic and concurrent execution

## Edge Cases

- **State mutation**: Concurrent tools must not modify shared state (`open_files`, `messages`). Only read-only tools should be concurrent.
- **Error propagation**: If any concurrent tool fails, the LLM should see the partial results plus the error.
- **Timeout**: Each concurrent tool needs its own timeout to prevent hanging.
- **File caching**: `read_file` updates `open_files` — concurrent reads must merge their caches afterward.

## Success Metrics

- Multi-tool turns complete in `max(tool_times)` instead of `sum(tool_times)`
- No regressions in tool result ordering for the LLM
- All existing tests pass