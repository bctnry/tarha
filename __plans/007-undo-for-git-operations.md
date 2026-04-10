# 007: Undo for Git Operations

**Priority**: Medium  
**Impact**: Safer git operations with rollback capability  
**Complexity**: Low  
**Files affected**: `coding_agent_tools_git.erl`, `coding_agent_undo.erl`

## Problem

The undo system only covers file edits. Git operations like `git_commit`, `git_merge`, `git_checkout`, and `git_push` are not tracked. If the LLM makes an unwanted git operation, the user has to manually reverse it.

## Proposed Solution

### 1. Extend the `#operation{}` record with git operation types

```erlang
-record(operation, {
    id :: binary(),
    type :: edit | write | transaction | git_commit | git_merge | git_checkout | git_stash,
    timestamp :: integer(),
    description :: binary(),
    files :: [{Path, BackupPath}],   %% For file operations
    git_ref :: binary() | undefined,  %% Git ref before the operation
    git_data :: map() | undefined,     %% Additional git data for rollback
    metadata :: map()
}).
```

### 2. Git stashing before operations

Before committing, merging, or checking out:

```erlang
preflight_git_op(OpType, Args) ->
    %% Get current HEAD ref and working tree state
    {ok, CurrentRef} = get_current_head(),
    {ok, Status} = get_git_status(),
    %% Stash any dirty working tree
    case has_unstaged_changes(Status) of
        true -> git_stash_push(<<"auto-undo-">>);
        false -> ok
    end,
    #{ref => CurrentRef, stash => has_unstaged_changes(Status)}.
```

### 3. Operation-specific rollback

```erlang
rollback_git(OpType, #operation{git_ref = Ref, git_data = Data}) ->
    case OpType of
        git_commit ->
            %% Reset to previous commit
            git_reset(Ref, soft);
        git_merge ->
            %% Reset to pre-merge state
            git_reset(Ref, hard),
            %% Restore stash if any
            maybe_restore_stash(Data);
        git_checkout ->
            %% Checkout previous branch/ref
            git_checkout(Ref),
            maybe_restore_stash(Data);
        git_stash ->
            %% Stash pop
            git_stash_pop()
    end.
```

### 4. Implementation in `coding_agent_tools_git.erl`

Add undo tracking to mutating git operations:

```erlang
execute(<<"git_commit">>, Args) ->
    %% Pre-flight: capture state
    {ok, PreState} = preflight_git_op(git_commit, Args),
    
    %% Execute commit
    Result = do_git_commit(Args),
    
    %% Track for undo
    case Result of
        #{success := true} ->
            coding_agent_undo:push(#operation{
                type = git_commit,
                description = <<"git commit">>,
                git_ref = maps:get(ref, PreState),
                git_data = PreState
            });
        _ -> ok
    end,
    Result;

execute(<<"git_merge">>, Args) ->
    %% Similar: preflight, execute, track
    ...;
```

### 5. New tool: `git_undo`

Add a new tool for git-specific undo:

```erlang
{
    <<"git_undo">>,
    <<"Undo the last git operation (commit, merge, checkout)">>,
    #{
        type => <<"object">>,
        properties => #{
            <<"steps">> => #{type => <<"integer">>, description => <<"Number of operations to undo">>}
        }
    }
}
```

### 6. Grouped transactions

For complex operations like "commit then push":

```erlang
execute(<<"smart_commit">>, Args) ->
    coding_agent_undo:begin_transaction(),
    %% ... commit ...
    %% ... maybe push ...
    coding_agent_undo:end_transaction(),
```

## Implementation Steps

1. Extend `#operation{}` record with `git_ref` and `git_data` fields
2. Implement `preflight_git_op/2` to capture current HEAD and working tree state
3. Implement auto-stash before mutating git operations
4. Add undo tracking to `git_commit`, `git_merge`, `git_checkout`, `smart_commit`
5. Implement `rollback_git/2` for each operation type
6. Add `git_undo` tool definition and dispatch
7. Update `coding_agent_undo:undo/1` to handle git operations
8. Add auto-stash restoration on undo
9. Write tests for each git operation's undo path
10. Update `/status` to show git undo stack

## Edge Cases

- **Detached HEAD**: Capture full ref, not just branch name
- **Stash conflicts**: If stash pop has conflicts during undo, warn and leave working tree dirty
- **Push reversal**: `git_push` cannot be undone locally (remote already has it). Track but mark as `irreversible`
- **Merge conflicts**: If undo of a merge leaves conflicts, provide instructions
- **Concurrent file + git operations**: Undo stack should handle interleaved file and git operations

## Success Metrics

- `git_commit` can be undone with a single command
- `git_merge` can be undone, restoring pre-merge state
- Auto-stash preserves working tree changes through git operations
- Undo stack correctly handles mixed file and git operations