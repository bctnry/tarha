# 003: Sub-Agent / Multi-Agent Support

**Priority**: High  
**Impact**: Task decomposition, parallel work, isolated operations  
**Complexity**: High  
**Files affected**: new `coding_agent_subagent.erl`, `coding_agent_session.erl`, `coding_agent_session_sup.erl`, `coding_agent_tools.erl`

## Problem

Tarha has no capability to delegate subtasks. The agent operates as a single entity — all work happens sequentially in one session. This prevents parallel work, isolated file operations, and task decomposition.

## Current Architecture

`coding_agent_session` is a single `gen_server` process. Tool calls execute within that process's agent loop. There is no mechanism to spawn child sessions or delegate work.

## Proposed Solution

### 1. Sub-agent tool definition

Add a new tool to `coding_agent_tools.erl`:

```erlang
{
    <<"subagent">>, 
    <<"Spawn a sub-agent to perform a specific task">>,
    #{
        type => <<"object">>,
        properties => #{
            <<"description">> => #{
                type => <<"string">>,
                description => <<"3-5 word task description">>
            },
            <<"prompt">> => #{
                type => <<"string">>,
                description => <<"The task for the sub-agent to perform">>
            },
            <<"mode">> => #{
                type => <<"string">>,
                enum => [<<"build">>, <<"plan">>, <<"readonly">>],
                description => <<"Sub-agent permission mode">>
            },
            <<"tools">> => #{
                type => <<"array">>,
                items => #{type => <<"string">>},
                description => <<"Allowed tools (default: all)">>
            }
        },
        required => [<<"description">>, <<"prompt">>]
    }
}
```

### 2. `coding_agent_subagent.erl` — Sub-agent manager

```erlang
-module(coding_agent_subagent).
-behaviour(gen_server).

-record(state, {
    parent :: pid(),
    parent_session_id :: binary(),
    subagents :: #{reference() => #subagent{}}
}).

-record(subagent, {
    id :: binary(),
    pid :: pid(),
    description :: binary(),
    mode :: build | plan | readonly,
    allowed_tools :: [binary()],
    status :: running | completed | failed,
    result :: term()
}).
```

### 3. Sub-agent execution flow

```
Parent Session
    │
    ├── subagent tool call received
    │
    ├── coding_agent_subagent:start_link(ParentSessionId, Opts)
    │       │
    │       ├── Creates child session under coding_agent_session_sup
    │       ├── Injects system prompt with task description
    │       ├── Restricts tools based on mode
    │       ├── Runs coding_agent_session:ask/2 with the prompt
    │       └── Returns result to parent
    │
    └── Parent continues with sub-agent result
```

### 4. Permission modes for sub-agents

| Mode | Description | Allowed tools |
|------|-------------|---------------|
| `build` | Full capabilities | All tools (default) |
| `plan` | Discussion only, no writes | read, search, git_read, model tools |
| `readonly` | Read-only research | read, search, git_read, model tools |

### 5. Tool scoping

`coding_agent_tools:execute/2` checks tool permissions:

```erlang
%% In sub-agent sessions, a process dictionary flag restricts tools
execute(<<"subagent">>, _Args) ->
    %% Sub-agents cannot spawn further sub-agents
    {error, <<"Sub-agents cannot spawn further sub-agents">>};

execute(ToolName, Args) ->
    case get(subagent_allowed_tools) of
        undefined -> dispatch(ToolName, Args);
        Allowed ->
            case lists:member(ToolName, Allowed) of
                true -> dispatch(ToolName, Args);
                false -> {error, <<"Tool not allowed in this sub-agent mode">>}
            end
    end.
```

### 6. Result format

Sub-agent results are returned as a structured map:

```erlang
#{
    <<"success">> => true,
    <<"description">> => Description,
    <<"content">> => Content,
    <<"tool_calls">> => ToolCallCount,
    <<"duration_ms">> => Duration,
    <<"mode">> => Mode
}
```

### 7. Background sub-agents (future)

For future extension, support `run_in_background: true`:

```erlang
%% Background sub-agent returns immediately with a task ID
{ok, TaskId} = coding_agent_subagent:spawn_background(Prompt, Opts),
%% Parent can check status later
Status = coding_agent_subagent:status(TaskId),
%% Or wait for completion
Result = coding_agent_subagent:await(TaskId, Timeout).
```

## Implementation Steps

1. Create `coding_agent_subagent.erl` with child session management
2. Add `subagent` tool definition to `coding_agent_tools:tools/0`
3. Implement `execute(<<"subagent">>, Args)` dispatch
4. Add tool scoping via process dictionary in sub-agent sessions
5. Modify `coding_agent_session_sup` to tag child sessions with parent info
6. Add sub-agent result formatting
7. Implement mode-based tool restrictions (readonly, plan, build)
8. Add maximum sub-agent depth guard (prevent infinite nesting)
9. Update system prompt to explain sub-agent tool usage
10. Write tests for each mode and tool restriction
11. (Future) Add background sub-agent support

## Edge Cases

- **Recursive spawning**: Sub-agents must not spawn further sub-agents to prevent infinite recursion
- **Resource limits**: Cap total sub-agents per session (e.g., 5) and total across system (e.g., 20)
- **Context inheritance**: Sub-agents should NOT inherit the parent's conversation history (they get only the prompt)
- **File cache isolation**: Sub-agents get their own `open_files` map
- **Memory isolation**: Sub-agents don't write to parent's MEMORY.md
- **Crash propagation**: If a sub-agent crashes, the parent should receive an error, not crash itself
- **Timeout**: Sub-agents should have a configurable timeout (default: 5 minutes)

## Success Metrics

- LLM can decompose tasks into sub-agent calls
- Sub-agents in `readonly` mode cannot modify files
- Sub-agents in `plan` mode cannot execute commands
- Parent session remains responsive while sub-agent runs
- Sub-agent results are clear and usable by the parent LLM