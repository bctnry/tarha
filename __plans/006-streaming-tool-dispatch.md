# 006: Streaming Tool Dispatch

**Priority**: Medium  
**Impact**: Reduced time-to-first-tool-execution  
**Complexity**: Medium  
**Files affected**: `coding_agent_ollama.erl`, `coding_agent_session.erl`

## Problem

Tarha waits for the complete Ollama API response before executing any tools. When a model outputs multiple tool calls in a streaming response, all tools wait until the entire response finishes. This adds latency equal to the time between the first and last tool call in the stream.

## Current Flow

```
1. Send messages to Ollama API
2. Wait for complete response (all tool_calls fully received)
3. Execute tool calls sequentially
4. Send tool results back
```

## Proposed Flow

```
1. Send messages to Ollama API (streaming)
2. As each tool_call completes in the stream:
   a. If concurrent-safe: execute immediately in parallel
   b. If non-safe: queue for sequential execution
3. As soon as all tool_calls are received:
   a. Execute any queued sequential tools
4. Collect all results
5. Send results back
```

## Proposed Solution

### 1. Streaming tool call accumulation in `coding_agent_ollama.erl`

Add a streaming variant that yields tool calls as they complete:

```erlang
%% New function: stream with incremental tool call delivery
chat_with_tools_streaming(Model, Messages, Tools, Opts) ->
    %% Returns:
    %%   {tool_call, ToolCall} - individual tool call ready to execute
    %%   {thinking, Text} - thinking content
    %%   {content, Text} - text content
    %%   {done, FinalResponse} - stream complete
```

### 2. Streaming session integration in `coding_agent_session.erl`

```erlang
run_agent_loop_streaming(Model, Messages, Tools, SessionId, Iteration) ->
    %% Start streaming request
    case coding_agent_ollama:chat_with_tools_streaming(Model, Messages, Tools, Opts) of
        {tool_call, ToolCall} ->
            %% Execute concurrent-safe tools immediately
            case is_concurrent_tool(ToolCall) of
                true ->
                    spawn_and_execute(ToolCall, SessionId);
                false ->
                    queue_tool_call(ToolCall, SessionId)
            end,
            %% Continue streaming
            run_agent_loop_streaming(Model, Messages, Tools, SessionId, Iteration);
        {done, Response} ->
            %% Collect all results and continue agent loop
            Results = collect_all_results(),
            NewMessages = Messages ++ [AssistantMsg | ToolResults],
            run_agent_loop(NewMessages, Tools, SessionId, Iteration + 1);
        {text, Content} ->
            {ok, Content, ...}
    end.
```

### 3. Progressive tool execution

As each tool call is fully parsed from the stream:
- **Concurrent-safe tools** (read_file, grep, etc.) are dispatched immediately
- **Sequential tools** (edit_file, git_commit, etc.) are queued
- Results are collected via message passing (Erlang's natural concurrency)

### 4. Result buffering

```erlang
-record(streaming_state, {
    concurrent_results = [] :: [{reference(), term()}],
    sequential_queue = [] :: [map()],
    sequential_results = [] :: [term()],
    thinking = <<>> :: binary(),
    content = <<>> :: binary()
}).
```

## Implementation Steps

1. Add `chat_with_tools_streaming/4,5` to `coding_agent_ollama.erl`
2. Implement streaming tool call accumulation using hackney's streaming mode
3. Add `is_concurrent_tool/1` to `coding_agent_tools.erl` (reuse from plan 001)
4. Create `run_agent_loop_streaming/5` in `coding_agent_session.erl`
5. Implement progressive result collection with Erlang message passing
6. Handle stream interruption (connection loss, timeout) gracefully
7. Add fallback to non-streaming mode if streaming is unavailable
8. Write tests with mocked streaming responses

## Edge Cases

- **Stream interruption**: If the connection drops mid-stream, partial results should be usable
- **Tool errors mid-stream**: Stop queuing new tools if a previous tool fails catastrophically
- **Context limits**: Estimated tokens should be updated as streaming content arrives
- **Cancellation**: Must be able to cancel mid-stream (reuse existing request registry)
- **Model compatibility**: Not all Ollama models stream tool calls the same way; fall back to non-streaming if parsing fails

## Success Metrics

- Time-to-first-tool-execution reduced by ~50% for multi-tool turns
- No regressions in non-streaming correctness
- Streaming falls back gracefully for incompatible models