# 002: Interactive Permission System

**Priority**: High  
**Impact**: Safe interactive use, human-in-the-loop control  
**Complexity**: High  
**Files affected**: `coding_agent_repl.erl`, `coding_agent_session.erl`, `coding_agent_tools.erl`, new `coding_agent_permissions.erl`

## Problem

Tarha's only permission mechanism is a process-dictionary callback that requires programmatic setup. There is no user-facing interactive prompt system. This makes Tarha unsafe for interactive use — destructive operations like `git_push --force`, `run_command`, and `edit_file` execute without confirmation.

## Proposed Solution

### 1. Create `coding_agent_permissions.erl` — Permission Manager

```erlang
-module(coding_agent_permissions).
-behaviour(gen_server).

%% Permission modes
-define(MODE_ASK, ask).        %% Prompt for every action
-define(MODE_AUTO, auto).      %% Auto-approve everything
-define(MODE_PLAN, plan).      %% Read-only mode

%% Permission decisions
-define(DECISION_ALLOW, allow).
-define(DECISION_DENY, deny).
-define(DECISION_ASK, ask).

-record(rule, {
    pattern :: binary(),  %% e.g., <<"Bash(git *)">>, <<"Edit">>
    decision :: allow | deny | ask,
    source :: cli | session | project | user
}).

-record(state, {
    mode :: ask | auto | plan,
    rules :: [#rule{}],
    session_rules :: [#rule{}]
}).
```

### 2. Permission rule syntax

Rules match tool calls by pattern:

```
Bash(git *)         %% Allow all git commands
Bash(rm *)          %% Deny rm commands
Edit                 %% Ask for any file edit
Write                %% Ask for any file write
read_file            %% Allow reading
```

Rule priority: `cli > session > project > user`

### 3. Configuration sources

Load rules from multiple sources in priority order:

1. **CLI flags**: `./coder --allow "Bash(git *)" --deny "Bash(rm *)"`
2. **Session rules**: Set dynamically via `/allow` and `/deny` REPL commands
3. **Project rules**: `.tarha/permissions.yaml` in project root
4. **User rules**: `~/.tarha/permissions.yaml` global rules

Example `.tarha/permissions.yaml`:

```yaml
rules:
  - pattern: "read_file"
    decision: allow
  - pattern: "list_files"
    decision: allow
  - pattern: "grep_files"
    decision: allow
  - pattern: "Bash(git status)"
    decision: allow
  - pattern: "Bash(git diff*)"
    decision: allow
  - pattern: "Edit"
    decision: ask
  - pattern: "Write"
    decision: ask
  - pattern: "Bash(*)"
    decision: deny
```

### 4. Interactive prompts in REPL

When a tool call requires permission, the REPL blocks and prompts:

```
╭──────────────────────────────────────────╮
│ Tool call requires permission:            │
│                                           │
│   edit_file                               │
│   Path: src/my_module.erl                 │
│   Old: "old_string"                       │
│   New: "new_string"                       │
│                                           │
│ Allow? [y/n/a/e] (y=yes, n=no,            │
│   a=always for this tool, e=edit args)    │
╰──────────────────────────────────────────╯
```

Key bindings:
- `y` — allow once
- `n` — deny (returns error to LLM)
- `a` — always allow this tool pattern for the session
- `e` — edit the tool arguments before execution

### 5. Plan mode

Plan mode (`/plan` command) restricts the agent to read-only operations. All write tools (`edit_file`, `write_file`, `create_directory`, `git_commit`, `git_push`, `run_command`) return an error describing what they would have done.

### 6. Integration with existing safety callbacks

Replace the process-dictionary safety callback with the permission system:

```erlang
%% In coding_agent_session:init/1
coding_agent_permissions:start_link(SessionId, Mode, Rules),

%% In execute_single_tool/3
case coding_agent_permissions:check(ToolName, Args) of
    allow -> execute_tool(ToolName, Args, State);
    deny -> {error, <<"Permission denied">>};
    ask -> prompt_user_and_wait(ToolName, Args, State)
end
```

### 7. REPL commands

Add to `coding_agent_repl.erl`:

- `/permissions` — show current rules and mode
- `/allow <pattern>` — add an allow rule for the session
- `/deny <pattern>` — add a deny rule for the session
- `/mode ask|auto|plan` — switch permission mode
- `/trust` — auto-approve the current tool and remember

## Implementation Steps

1. Create `coding_agent_permissions.erl` with rule matching and mode management
2. Implement rule loading from YAML config files
3. Add interactive prompt rendering to `coding_agent_repl.erl`
4. Replace process-dictionary callbacks with permission system calls
5. Add REPL commands for permission management
6. Add default rule sets for plan mode and auto mode
7. Implement pattern matching for `Bash(command)` subcommand rules
8. Add session rule persistence (rules survive across asks)
9. Write tests for rule matching, priority, and mode switching

## Edge Cases

- **Streaming interruption**: Permission prompts must pause the agent loop until the user responds
- **Rule conflicts**: Higher-priority source wins; within same source, first-match wins
- **Bash subcommand matching**: `Bash(git commit *)` should match `git commit -m "..."` but not `git push`
- **Session rules vs file rules**: Session rules should be additive, not replace file rules
- **Plan mode bypass**: Some tools (like `read_file`) should always work in plan mode

## Success Metrics

- All destructive operations require explicit approval in `ask` mode
- `/mode plan` blocks all write operations with informative errors
- Rule configuration persists across sessions
- No tool executes without permission check first