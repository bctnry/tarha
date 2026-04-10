# 005: Multi-Level Context Compaction

**Priority**: Medium  
**Impact**: Better context window management, fewer lost conversations  
**Complexity**: Medium  
**Files affected**: `coding_agent_session.erl`

## Problem

Tarha has a single compaction strategy: when estimated tokens exceed 85% of context length, it summarizes old messages via an LLM call and keeps the last 10 messages. This is a blunt instrument that can lose important context (recent tool results, important decisions).

Claude Code has three levels: **microcompact** (trim oldest messages), **compact** (LLM summarization), and **context collapse** (emergency drainage).

## Current Behavior

```erlang
maybe_compact_session(State) ->
    case State#state.estimated_tokens > State#state.context_length * 0.85 of
        true -> compact_session(State);
        false -> {ok, State}
    end.
```

## Proposed Solution

### 1. Three-level compaction strategy

| Level | Trigger | Action | Cost |
|-------|---------|--------|------|
| **Microcompact** | >70% context | Trim oldest messages, keep last 20 + system | No LLM call |
| **Compact** | >85% context | LLM summarization of old messages | 1 LLM call |
| **Collapse** | >95% context | Aggressive drainage: keep only system + last 5 messages | No LLM call |

### 2. Implementation in `coding_agent_session.erl`

```erlang
-define(MICROCOMPACT_THRESHOLD, 0.70).
-define(COMPACT_THRESHOLD, 0.85).
-define(COLLAPSE_THRESHOLD, 0.95).
-define(MICROCOMPACT_KEEP_MESSAGES, 20).
-define(COMPACT_KEEP_MESSAGES, 10).
-define(COLLAPSE_KEEP_MESSAGES, 5).

maybe_compact_session(State) ->
    Ratio = State#state.estimated_tokens / State#state.context_length,
    cond
        Ratio > ?COLLAPSE_THRESHOLD -> collapse_session(State);
        Ratio > ?COMPACT_THRESHOLD -> compact_session(State);
        Ratio > ?MICROCOMPACT_THRESHOLD -> microcompact_session(State);
        true -> {ok, State}
    end.
```

### 3. Microcompact implementation

```erlang
microcompact_session(State) ->
    Messages = State#state.messages,
    KeepCount = ?MICROCOMPACT_KEEP_MESSAGES,
    case length(Messages) =< KeepCount of
        true -> {ok, State};
        false ->
            %% Split: discard oldest, keep system prompt + recent messages
            {SystemMsgs, Rest} = split_system_messages(Messages),
            {_, RecentMsgs} = lists:split(length(Rest) - KeepCount + 1, Rest),
            NewMessages = SystemMsgs ++ RecentMsgs,
            {ok, State#state{messages = NewMessages}}
    end.
```

### 4. Collapse implementation

```erlang
collapse_session(State) ->
    Messages = State#state.messages,
    %% Keep only system messages and last N messages
    SystemMsgs = lists:filter(fun is_system_message/1, Messages),
    RecentMsgs = lists:last_n(Messages, ?COLLAPSE_KEEP_MESSAGES),
    %% Add a collapse indicator
    CollapseMsg = #{role => <<"system">>, content => 
        <<"[Context collapsed due to length. Earlier conversation has been removed.]">>},
    NewMessages = SystemMsgs ++ [CollapseMsg] ++ RecentMsgs,
    {ok, State#state{messages = NewMessages}}.
```

### 5. Improved compact (existing, but with better message preservation)

The existing `compact_session` already uses LLM summarization. Enhance it to:

- Identify and preserve messages containing important context (tool results with `file_cached`, explicit `important` markers)
- Preserve the last assistant message (often contains the current plan)
- Add a summary message that explicitly lists the tools that were called

```erlang
compact_session(State) ->
    Messages = State#state.messages,
    %% Split into old (to summarize) and recent (to keep)
    SplitPoint = max(1, length(Messages) - ?COMPACT_KEEP_MESSAGES),
    {OldMsgs, RecentMsgs} = lists:split(SplitPoint, Messages),
    
    %% Extract important messages from old section
    {ImportantMsgs, NormalMsgs} = lists:partition(fun is_important_message/1, OldMsgs),
    
    %% Summarize normal messages via LLM
    case summarize_messages_with_timeout(NormalMsgs, State#state.model) of
        {ok, Summary} ->
            SummaryMsg = #{role => <<"system">>, content => 
                <<"[Context from previous conversation]\n", Summary/binary>>},
            NewMessages = ImportantMsgs ++ [SummaryMsg] ++ RecentMsgs,
            {ok, State#state{messages = NewMessages}};
        {error, _} ->
            %% Fallback to microcompact
            microcompact_session(State)
    end.
```

### 6. Progress reporting

Add compaction level reporting to `/status`:

```erlang
%% In coding_agent_repl
{context_usage, Ratio} ->
    Level = if
        Ratio > ?COLLAPSE_THRESHOLD -> <<"CRITICAL">>;
        Ratio > ?COMPACT_THRESHOLD -> <<"HIGH">>;
        Ratio > ?MICROCOMPACT_THRESHOLD -> <<"MODERATE">>;
        true -> <<"LOW">>
    end,
    io:format("Context: ~.1f% (~s)~n", [Ratio * 100, Level]).
```

## Implementation Steps

1. Define threshold constants and keep-message counts
2. Implement `microcompact_session/1` (message trimming without LLM)
3. Implement `collapse_session/1` (emergency drainage without LLM)
4. Enhance existing `compact_session/1` with important message preservation
5. Update `maybe_compact_session/1` with three-level check
6. Add `is_important_message/1` function (check for `file_cached`, explicit markers)
7. Add `split_system_messages/1` to preserve system messages
8. Add `lists:last_n/2` utility function
9. Update `/status` command to show compaction level
10. Add `/compact` command variants: `/compact micro`, `/compact full`, `/compact collapse`
11. Write tests for each compaction level (mock LLM for full compact)

## Edge Cases

- **Rapid context growth**: If a single tool result is huge, microcompact and collapse should still work
- **System message preservation**: Never discard system messages (they contain instructions)
- **Important message extraction**: Tool results with `file_cached` should be preserved over plain text
- **Compact failure**: Fall back to microcompact if LLM summarization fails or times out
- **Consecutive compactions**: After collapse, usage should drop well below thresholds

## Success Metrics

- Sessions can sustain longer conversations without hitting context limits
- Microcompact triggers first (cheapest), compact only when needed
- Collapse (most disruptive) triggers only in emergencies
- No important context (file caches, key decisions) lost during compaction