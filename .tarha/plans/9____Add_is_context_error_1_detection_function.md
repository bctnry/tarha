# Step 9: ** Add is_context_error/1 detection function

## Description
** 
Add a new function `is_context_error/1` to `src/coding_agent_ollama.erl` that detects context length errors from Ollama API responses. This function will:
- Pattern match on HTTP 4xx errors (400-499)
- Parse the JSON error body
- Check for context-related keywords: "context", "token", "length", "exceed", "maximum", "limit"
- Return `true` if it's a context error, `false` otherwise

**Files:** 
- `src/coding_agent_ollama.erl`

**Implementation Details:**
```erlang
%% @doc Check if error is a context length exceeded error
is_context_error({http_error, StatusCode, Body}) 
    when StatusCode >= 400, StatusCode < 500 ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"error">> := ErrorMsg} when is_binary(ErrorMsg) ->
            ContextKeywords = [<<"context">>, <<"token">>, <<"length">>, 
                               <<"exceed">>, <<"maximum">>, <<"limit">>],
            lists:any(fun(Kw) -> 
                binary:match(ErrorMsg, Kw) =/= nomatch 
            end, ContextKeywords);
        _ -> false
    catch _:_ -> false
    end;
is_context_error({error, Reason}) ->
    is_context_error(Reason);
is_context_error(_) -> false.
```

**Location:** Add after the existing `is_retryable_error/1` function (around line 635)

## Files
**

## Status
pending
