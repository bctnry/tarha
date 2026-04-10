# 016: Model Fallback Chain

**Priority**: Low  
**Impact**: Improved reliability when primary model fails  
**Complexity**: Medium  
**Files affected**: `coding_agent_ollama.erl`, `coding_agent_session.erl`, `coding_agent_config.erl`

## Problem

When a model fails (timeout, overload, connection error), the session stops. There is no fallback to a different model. The only option is to manually switch models with `/switch` and retry.

## Proposed Solution

### 1. Configuration

```yaml
models:
  primary: glm-5:cloud
  fallback: llama3.2
  timeout: 30000

fallback:
  enabled: true
  chain: [glm-5:cloud, llama3.2, codellama]
  retry_on: [timeout, connection_error, server_error]
  max_retries: 3
```

### 2. Fallback chain in `coding_agent_config.erl`

```erlang
get_fallback_chain() ->
    case application:get_env(coding_agent, fallback_chain) of
        {ok, Chain} -> Chain;
        undefined ->
            Primary = model(),
            case application:get_env(coding_agent, fallback_model) of
                {ok, Fallback} -> [Primary, Fallback];
                undefined -> [Primary]
            end
    end.

get_retryable_errors() ->
    case application:get_env(coding_agent, retry_on) of
        {ok, Errors} -> Errors;
        undefined -> [timeout, connection_error, server_error]
    end.
```

### 3. Fallback logic in `coding_agent_ollama.erl`

```erlang
chat_with_tools_cancellable(Model, Messages, Tools, SessionId) ->
    Chain = coding_agent_config:get_fallback_chain(),
    chat_with_fallback(Chain, Messages, Tools, SessionId, []).

chat_with_fallback([], _Messages, _Tools, _SessionId, Errors) ->
    {error, {all_models_failed, Errors}};
chat_with_fallback([Model | Rest], Messages, Tools, SessionId, Errors) ->
    case do_chat_with_tools(Model, Messages, Tools, SessionId) of
        {ok, Response} ->
            {ok, Response};
        {error, Reason} ->
            case is_retryable(Reason) of
                true ->
                    %% Try next model in chain
                    chat_with_fallback(Rest, Messages, Tools, SessionId,
                        [{Model, Reason} | Errors]);
                false ->
                    %% Non-retryable error, don't try other models
                    {error, {Model, Reason}}
            end
    end.

is_retryable(Reason) ->
    RetryableErrors = coding_agent_config:get_retryable_errors(),
    lists:any(fun(E) -> Reason =:= E end, RetryableErrors).
```

### 4. Fallback notification

When falling back to a different model, notify the session:

```erlang
%% In run_agent_loop
case Response of
    {ok, Result} ->
        {ok, Result};
    {error, {fallback, OriginalModel, FallbackModel}} ->
        io:format("⚠ Model ~ts unavailable, falling back to ~ts~n", 
                  [OriginalModel, FallbackModel]),
        %% Inject a system message about the fallback
        FallbackMsg = #{role => <<"system">>, content => 
            iolist_to_binary([<<"Note: Fell back from ">>, OriginalModel, 
                             <<" to ">>, FallbackModel, <<" due to error.">>])},
        {continue, [FallbackMsg | Messages]}
end.
```

### 5. Model capability checking

Before using a model, check if it supports tools:

```erlang
chat_with_fallback([Model | Rest], Messages, Tools, SessionId, Errors) ->
    case model_supports_tools(Model) of
        true ->
            case do_chat_with_tools(Model, Messages, Tools, SessionId) of
                {ok, Response} -> {ok, Response};
                {error, Reason} ->
                    case is_retryable(Reason) of
                        true -> chat_with_fallback(Rest, Messages, Tools, SessionId, [{Model, Reason} | Errors]);
                        false -> {error, {Model, Reason}}
                    end
            end;
        false ->
            %% Model doesn't support tools, try next
            chat_with_fallback(Rest, Messages, Tools, SessionId, [{Model, no_tool_support} | Errors])
    end.
```

### 6. Fallback strategy in session

After falling back, consider whether to switch back:

```erlang
-define(FALLBACK_COOLDOWN_MS, 60000).  %% 1 minute before retrying primary model

-record(state, {
    %% ... existing fields ...
    model :: binary(),
    original_model :: binary(),    %% Model set by user/config
    fallback_active :: boolean(),  %% Currently using fallback?
    fallback_until :: integer()     %% Timestamp to retry primary
}).
```

After the cooldown period, the next API call tries the original model again.

### 7. REPL feedback

```
/glm-5:cloud unavailable (timeout), falling back to llama3.2
⚠ Model glm-5:cloud unavailable, using llama3.2 instead
  Use /switch glm-5:cloud to retry, or /model to see options
```

### 8. `/model` command

```
/model

Current: llama3.2 (fallback from glm-5:cloud)
Chain: glm-5:cloud → llama3.2 → codellama
Status: primary model (glm-5:cloud) failed at 14:32:01
  Reason: timeout
  Fallback active for: 28 seconds
```

## Implementation Steps

1. Add `fallback_chain` and `retry_on` configuration to `coding_agent_config.erl`
2. Implement `chat_with_fallback/4` in `coding_agent_ollama.erl`
3. Add `is_retryable/1` error classification
4. Add model capability checking (`model_supports_tools/1`) integration
5. Track original model and fallback state in session `#state{}`
6. Implement fallback cooldown timer
7. Add fallback notification to agent loop
8. Enhance `/status` and add `/model` REPL command
9. Add configuration parsing for fallback chain from YAML
10. Write tests for fallback chain (mock model failures)
11. Write tests for capability checking (skip non-tool models)
12. Document fallback configuration in `config.example.yaml`

## Edge Cases

- **All models fail**: Return comprehensive error with all failure reasons
- **Non-retryable error**: Don't try other models (e.g., auth error)
- **Model doesn't support tools**: Skip it, try next in chain
- **Fallback model also fails**: Continue down the chain
- **Cooldown expiry**: Transparently switch back to primary model
- **Manual `/switch`**: Clears fallback state and uses specified model
- **Primary model recovers mid-session**: Next API call tries primary first

## Success Metrics

- Sessions continue uninterrupted when primary model fails
- Fallback happens within 30 seconds of primary failure
- Users are notified of model switches
- Primary model is automatically retried after cooldown