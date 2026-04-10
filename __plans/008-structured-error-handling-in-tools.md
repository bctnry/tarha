# 008: Structured Error Handling in Tools

**Priority**: Medium  
**Impact**: Better LLM recovery from tool failures  
**Complexity**: Low  
**Files affected**: `coding_agent_tools_git.erl`, `coding_agent_tools_file.erl`, all tool modules

## Problem

Git tools always return `#{success => true, output => ...}` even when the git command fails. The error message is buried in the `output` field as raw text. The LLM has no structured way to detect and recover from failures.

Example current behavior:
```erlang
%% git_push to a rejected remote returns:
#{success => true, output => <<"To github.com:repo.git\n ! [rejected] main -> main...">>}
```

The LLM must parse free-text output to determine success or failure, which is unreliable.

## Proposed Solution

### 1. Standardize result format

All tools return maps with consistent structure:

```erlang
%% Success
#{
    <<"success">> => true,
    <<"result">> => #{...},     %% Tool-specific data
    <<"message">> => binary()   %% Human-readable summary
}

%% Error
#{
    <<"success">> => false,
    <<"error">> => binary(),       %% Human-readable error message
    <<"error_code">> => binary(),  %% Machine-readable error category
    <<"details">> => #{...}         %% Optional structured details
}
```

### 2. Error code taxonomy

```erlang
-define(ERROR_NOT_FOUND, <<"not_found">>).
-define(ERROR_PERMISSION_DENIED, <<"permission_denied">>).
-define(ERROR_ALREADY_EXISTS, <<"already_exists">>).
-define(ERROR_INVALID_INPUT, <<"invalid_input">>).
-define(ERROR_TIMEOUT, <<"timeout">>).
-define(ERROR_CONFLICT, <<"conflict">>).
-define(ERROR_GIT_REJECTED, <<"git_rejected">>).
-define(ERROR_GIT_MERGE_CONFLICT, <<"git_merge_conflict">>).
-define(ERROR_BUILD_FAILED, <<"build_failed">>).
-define(ERROR_COMMAND_FAILED, <<"command_failed">>).
-define(ERROR_NETWORK, <<"network_error">>).
-define(ERROR_UNKNOWN, <<"unknown">>).
```

### 3. Fix git tools

```erlang
run_git_command(Cmd) ->
    Output = os:cmd(Cmd ++ " 2>&1"),
    case parse_git_result(Output) of
        {ok, Result} ->
            #{
                success => true,
                result => Result,
                message => format_git_success(Cmd, Result)
            };
        {error, ErrorCode, ErrorMessage} ->
            #{
                success => false,
                error => ErrorMessage,
                error_code => ErrorCode,
                details => #{command => list_to_binary(Cmd), output => Output}
            }
    end.
```

### 4. Git result parsing

```erlang
parse_git_result(Output) ->
    %% Detect common git failure patterns
    CondList = [
        {fun is_git_rejected/1, ?ERROR_GIT_REJECTED},
        {fun is_git_merge_conflict/1, ?ERROR_GIT_MERGE_CONFLICT},
        {fun is_git_not_found/1, ?ERROR_NOT_FOUND},
        {fun is_git_permission_denied/1, ?ERROR_PERMISSION_DENIED},
        {fun is_git_remote_error/1, ?ERROR_NETWORK}
    ],
    case detect_git_error(Output, CondList) of
        {error, Code} -> {error, Code, classify_git_message(Code, Output)};
        ok -> {ok, Output}
    end.
```

### 5. Fix file tools

Already partially structured, but add `error_code` consistently:

```erlang
%% read_file when file not found
#{success => false, error => <<"File not found: src/missing.erl">>, error_code => <<"not_found">>};

%% edit_file when old_string not found
#{success => false, error => <<"old_string not found in file">>, error_code => <<"not_found">>};

%% edit_file when multiple matches
#{success => false, error => <<"old_string matches 3 times; use replace_all: true">>, error_code => <<"conflict">>};

%% write_file when permission denied
#{success => false, error => <<"Permission denied: /root/file.erl">>, error_code => <<"permission_denied">>};
```

### 6. Fix command tools

```erlang
%% run_command with non-zero exit code
#{success => false, error => <<"Command 'make test' exited with code 1">>, 
  error_code => <<"command_failed">>, details => #{exit_code => 1, stderr => ...}};

%% run_command with timeout
#{success => false, error => <<"Command timed out after 30000ms">>, 
  error_code => <<"timeout">>};
```

## Implementation Steps

1. Create `coding_agent_tools_errors.erl` with error code macros and constructors
2. Define `success_result/1,2` and `error_result/2,3` helper functions
3. Update `coding_agent_tools_git.erl` — replace `run_git_command/1` with structured parser
4. Update `coding_agent_tools_file.erl` — add error codes to all error returns
5. Update `coding_agent_tools_command.erl` — add exit codes and error categories
6. Update `coding_agent_tools_build.erl` — add build-specific error codes
7. Update `coding_agent_tools_search.erl` — add search-specific error codes
8. Update `coding_agent_tools_refactor.erl` — add refactoring error codes
9. Update `coding_agent_session.erl` — detect error codes in tool results for retry logic
10. Write tests verifying error codes are correct for each failure scenario

## Edge Cases

- **Git output mixed success/failure**: Some git commands output both success and error lines
- **Localized git messages**: Git output language depends on locale; use `LC_ALL=C` for consistent parsing
- **Partial failures**: `execute_parallel` should report per-item errors with codes
- **Backwards compatibility**: LLM prompts may rely on current `success/output` format; add `result` alongside `output`

## Success Metrics

- Every tool error returns a machine-readable `error_code`
- LLM can reliably distinguish between "file not found" and "permission denied"
- Git tool failures return `success => false` with structured error info
- All existing tests pass with new result format