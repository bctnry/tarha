# 010: Tool Input Validation

**Priority**: Low  
**Impact**: Fewer crashes, better LLM error messages  
**Complexity**: Low  
**Files affected**: `coding_agent_tools.erl`, all tool modules, new `coding_agent_tools_schema.erl`

## Problem

Tool input validation relies on pattern-matching on map keys. Missing or malformed arguments cause `function_clause` or `badmatch` crashes rather than clean error messages. For example:

```erlang
%% This crashes if <<"path">> key is missing:
execute(<<"read_file">>, #{<<"path">> := Path}) -> ...
%% Instead of returning a helpful error
```

## Proposed Solution

### 1. Define schemas for each tool

Create `coding_agent_tools_schema.erl` with validation functions:

```erlang
-module(coding_agent_tools_schema).

-export([validate/2, required/1, optional/2]).

-type validation_result() :: {ok, map()} | {error, binary()}.

validate(ToolName, Args) ->
    Schema = get_schema(ToolName),
    validate_args(Schema, Args).

%% Schema format: [{Key, Type, Required, Validator}]
get_schema(<<"read_file">>) ->
    [{<<"path">>, binary, required, fun validate_path/1}];

get_schema(<<"edit_file">>) ->
    [{<<"path">>, binary, required, fun validate_path/1},
     {<<"old_string">>, binary, required, fun validate_nonempty/1},
     {<<"new_string">>, binary, required, fun validate_nonempty/1},
     {<<"replace_all">>, boolean, optional, nil}];

get_schema(<<"run_command">>) ->
    [{<<"command">>, binary, required, fun validate_nonempty/1},
     {<<"timeout">>, integer, optional, fun validate_positive/1},
     {<<"cwd">>, binary, optional, fun validate_path/1}];

%% ... etc for all 38 tools
```

### 2. Validation function

```erlang
validate_args(Schema, Args) when is_map(Args) ->
    case check_required(Schema, Args) of
        {error, _} = Error -> Error;
        ok ->
            case validate_types(Schema, Args) of
                {error, _} = Error -> Error;
                ok -> validate_values(Schema, Args)
            end
    end.

check_required(Schema, Args) ->
    Missing = [Key || {Key, _, required, _} <- Schema, not maps:is_key(Key, Args)],
    case Missing of
        [] -> ok;
        _ -> {error, <<"Missing required parameters: ", (format_keys(Missing))/binary>>}
    end.

validate_types(Schema, Args) ->
    Errors = [begin
        ExpectedType = Type,
        ActualValue = maps:get(Key, Args),
        case validate_type(ExpectedType, ActualValue) of
            true -> ok;
            false -> {Key, ExpectedType}
        end
    end || {Key, Type, _, _} <- Schema, maps:is_key(Key, Args)],
    case [E || E <- Errors, E =/= ok] of
        [] -> ok;
        BadKeys -> {error, <<"Type errors: ", (format_type_errors(BadKeys))/binary>>}
    end.

validate_values(Schema, Args) ->
    Errors = [begin
        Validator = ValidatorFn,
        case Validator(maps:get(Key, Args)) of
            ok -> ok;
            {error, Reason} -> {Key, Reason}
        end
    end || {Key, _, _, ValidatorFn} <- Schema, ValidatorFn =/= nil, maps:is_key(Key, Args)],
    case [E || E <- Errors, E =/= ok] of
        [] -> ok;
        BadKeys -> {error, <<"Validation errors: ", (format_value_errors(BadKeys))/binary>>}
    end.
```

### 3. Common validators

```erlang
validate_path(Path) when is_binary(Path), byte_size(Path) > 0 -> ok;
validate_path(_) -> {error, <<"Path must be a non-empty string">>}.

validate_nonempty(Val) when is_binary(Val), byte_size(Val) > 0 -> ok;
validate_nonempty(_) -> {error, <<"Value must be a non-empty string">>}.

validate_positive(N) when is_integer(N), N > 0 -> ok;
validate_positive(_) -> {error, <<"Value must be a positive integer">>}.

validate_command(Cmd) when is_binary(Cmd), byte_size(Cmd) > 0 ->
    case contains_shell_injection(Cmd) of
        true -> {error, <<"Command contains potentially dangerous patterns">>};
        false -> ok
    end.
```

### 4. Integration with tool dispatch

```erlang
execute(ToolName, Args) ->
    case coding_agent_tools_schema:validate(ToolName, Args) of
        {ok, ValidatedArgs} ->
            dispatch(ToolName, ValidatedArgs);
        {error, Reason} ->
            #{success => false, error => Reason, error_code => <<"invalid_input">>}
    end.
```

### 5. Defensive pattern matching

Change tool implementations to use `maps:get/2` with defaults instead of pattern matching:

```erlang
%% Before:
execute(<<"read_file">>, #{<<"path">> := Path}) -> ...

%% After (validation already done, but defensive):
execute(<<"read_file">>, Args) ->
    Path = maps:get(<<"path">>, Args),
    ...
```

## Implementation Steps

1. Create `coding_agent_tools_schema.erl` with schema definitions for all 38 tools
2. Implement `validate/2`, `check_required/2`, `validate_types/2`, `validate_values/2`
3. Implement common validators (path, nonempty, positive, command safety)
4. Add `validate/2` call to `coding_agent_tools:execute/2` before dispatch
5. Convert all tool implementations from pattern-matching to `maps:get/2`
6. Add error codes to validation failures
7. Write property-based tests (proper) for each tool's schema
8. Add integration tests for missing/malformed parameters

## Edge Cases

- **Extra parameters**: Silently ignore unknown keys (forward-compatible)
- **Type coercion**: Consider accepting string `"3"` where integer `3` is expected
- **Null values**: Treat `null` as missing for optional parameters
- **Nested objects**: `http_request` headers should be validated as map of strings

## Success Metrics

- No tool crashes from missing or malformed arguments
- Every validation error includes the parameter name and expected type
- LLM receives actionable error messages it can use to retry
- All 38 tools have complete schemas