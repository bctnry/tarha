# 011: Improved Token Counting

**Priority**: Low  
**Impact**: Better context window estimation, fewer unexpected truncations  
**Complexity**: Low  
**Files affected**: `coding_agent_ollama.erl`

## Problem

The heuristic token estimator (`count_tokens/1`) is rough: code ≈ 2.5 chars/token and English ≈ 4 chars/token. This overestimates for some content types and underestimates for others, leading to premature compaction or unexpected context overflow.

## Current Implementation

```erlang
count_tokens(Content) when is_binary(Content) ->
    %% Fast heuristic: ~4 chars per token for English, ~2.5 for code
    Len = byte_size(Content),
    case is_code_heavy(Content) of
        true -> Len div 25;     %% ~2.5 chars/token
        false -> Len div 4      %% ~4 chars/token
    end.
```

## Proposed Solution

### 1. Per-language token ratios

```erlang
-define(TOKEN_RATIOS, #{
    erlang => 2.3,
    javascript => 2.5,
    python => 2.8,
    html => 3.0,
    json => 2.2,
    yaml => 3.0,
    markdown => 3.5,
    english => 4.0,
    mixed => 2.8,
    default => 3.0
}).
```

### 2. Content-type detection

```erlang
detect_content_type(Content) ->
    %% Check for language-specific patterns
    CondList = [
        {fun is_erlang/1, erlang},
        {fun is_javascript/1, javascript},
        {fun is_python/1, python},
        {fun is_html/1, html},
        {fun is_json/1, json},
        {fun is_yaml/1, yaml},
        {fun is_markdown/1, markdown}
    ],
    detect_type(Content, CondList, mixed).
```

### 3. Weighted token estimation

For messages that mix content types (e.g., a conversation with code blocks):

```erlang
count_tokens_detailed(Content) ->
    ContentLen = byte_size(Content),
    ContentType = detect_content_type(Content),
    Ratio = maps:get(ContentType, ?TOKEN_RATIOS, 3.0),
    BaseTokens = round(ContentLen / Ratio),
    
    %% Adjustments
    ToolCallAdjust = count_tool_call_adjustment(Content),
    SpecialTokenAdjust = count_special_tokens(Content),
    
    BaseTokens + ToolCallAdjust + SpecialTokenAdjust.

%% Tool calls have overhead beyond their text representation
count_tool_call_adjustment(Content) ->
    ToolCallCount = count_tool_calls(Content),
    ToolCallCount * 100.  %% Each tool call ≈ 100 tokens of overhead

%% Special tokens (start/end markers, system tokens, etc.)
count_special_tokens(_Content) ->
    %% Approximate: each message has ~10 tokens of overhead
    10.
```

### 4. Better accurate counting with caching

Enhance `count_tokens_accurate/2`:

```erlang
%% Cache with TTL and size limits
-define(CACHE_MAX_SIZE, 10000).
-define(CACHE_TTL_MS, 300000).  %% 5 minutes

count_tokens_accurate(Content, Model) ->
    CacheKey = {Model, erlang:phash2(Content)},
    Now = erlang:system_time(millisecond),
    case ets:lookup(coding_agent_token_cache, CacheKey) of
        [{_, Tokens, CachedAt}] when Now - CachedAt < ?CACHE_TTL_MS ->
            Tokens;
        _ ->
            %% Query API
            Tokens = query_api_for_tokens(Content, Model),
            ets:insert(coding_agent_token_cache, {CacheKey, Tokens, Now}),
            maybe_evict_cache(),
            Tokens
    end.
```

### 5. Periodic accurate reconciliation

Every N iterations, reconcile estimated tokens with API-provided tokens:

```erlang
-define(RECONCILIATION_INTERVAL, 5).  %% Every 5 API calls

maybe_reconcile_tokens(State, Iteration) when Iteration rem ?RECONCILIATION_INTERVAL =:= 0 ->
    %% Use API-provided token counts to adjust our estimation
    case get_api_token_count() of
        {ok, ApiTokens} ->
            %% Adjust future estimates based on ratio
            adjust_token_ratio(State, ApiTokens, State#state.estimated_tokens);
        _ ->
            State
    end;
maybe_reconcile_tokens(State, _) ->
    State.
```

## Implementation Steps

1. Define per-language token ratios in `coding_agent_ollama.erl`
2. Implement `detect_content_type/1` with language pattern detection
3. Implement `count_tokens_detailed/1` with weighted estimation
4. Enhance `count_tokens_accurate/2` with TTL-based caching
5. Add cache eviction when exceeding 10K entries
6. Implement `maybe_reconcile_tokens/2` for periodic adjustment
7. Add token estimation unit tests for various content types
8. Benchmark estimation accuracy against API-provided counts
9. Add `/tokens` REPL command for debugging token estimation
10. Update `coding_agent_session:stats/1` to include content-type breakdown

## Edge Cases

- **Mixed content**: Messages with both code and prose need blended ratios
- **Very short content**: Under 50 chars, estimation is unreliable; use minimum of 1 token
- **Binary content**: Base64-encoded content has different ratios; estimate separately
- **Tool call overhead**: Tool definitions in the system prompt add significant tokens

## Success Metrics

- Token estimation within 15% of API-provided counts (vs current ~30%)
- No unexpected context overflows due to underestimation
- No premature compaction due to overestimation
- Cache hit rate >50% for repeated content