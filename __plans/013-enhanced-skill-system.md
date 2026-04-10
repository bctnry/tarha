# 013: Enhanced Skill System

**Priority**: Low  
**Impact**: More powerful, context-aware skill dispatch  
**Complexity**: Medium  
**Files affected**: `coding_agent_skills.erl`, `coding_agent_session.erl`

## Problem

Skills are simple markdown documents with YAML frontmatter. They lack conditional activation, agent-type binding, and execution hooks. The system only supports `SKILL.md` files with basic `requires`, `always`, and `description` fields.

## Proposed Solution

### 1. Enhanced YAML frontmatter

```yaml
---
name: database-migrations
description: "Run and manage database migrations"
always: false
context: inline          # inline | fork | background
model: inherit          # inherit | sonnet | opus | haiku
path_patterns:
  - "migrations/**"
  - "**/schema/**"
  - "*.sql"
tags: [database, migration]
hooks:
  on_activate: "echo 'Database migration skill activated'"
max_tokens: 4000
---

You are an expert at database migrations. When the user asks about migrations:

1. First check the current migration status with `run_command`
2. Create migration files with `write_file`
3. Run migrations with `run_command`

Always back up the database before running destructive migrations.
```

### 2. Conditional activation

Skills with `path_patterns` are dormant until matching files are touched:

```erlang
%% In coding_agent_skills
activate_conditional_skills(FilePaths) ->
    AllSkills = get_all_skills(),
    lists:filter(fun(Skill) ->
        case maps:get(path_patterns, Skill, undefined) of
            undefined -> true;  %% Always-active skills
            Patterns -> matches_any_pattern(FilePaths, Patterns)
        end
    end, AllSkills).
```

Called from `coding_agent_session` when files are read or written:

```erlang
%% In execute_single_tool, after file operations
case maps:get(file_cached, Result, undefined) of
    undefined -> ok;
    Path -> coding_agent_skills:activate_conditional_skills([Path])
end.
```

### 3. Context modes

| Mode | Description |
|------|-------------|
| `inline` | Skill prompt is injected directly into the system prompt (current behavior) |
| `fork` | Skill prompt is sent as a separate sub-agent call |
| `background` | Skill runs in background, user is notified when done |

### 4. Skill-level model override

```erlang
%% In coding_agent_session system prompt construction
get_skills_summary() ->
    Skills = coding_agent_skills:list_skills(false),
    AlwaysSkills = [S || S <- Skills, maps:get(always, S, false)],
    ActiveConditional = [S || S <- Skills, not maps:get(always, S, false), maps:get(active, S, false)],
    
    %% Build summary with model hints
    Prompt = iolist_to_binary([
        <<"## Available Skills\n\n">>,
        [format_skill(S) || S <- AlwaysSkills ++ ActiveConditional]
    ]),
    Prompt.
```

When the LLM calls the skill tool, the session checks if a model override is specified and creates a temporary model switch.

### 5. Hook support

```erlang
-record(skill, {
    name :: binary(),
    description :: binary(),
    always :: boolean(),
    path_patterns :: [binary()] | undefined,
    context :: inline | fork | background,
    model :: inherit | binary(),
    tags :: [binary()],
    hooks :: #{on_activate => binary(), on_deactivate => binary()},
    prompt :: binary()
}).
```

- `on_activate`: Shell command to run when the skill is activated
- `on_deactivate`: Shell command to run when the skill is deactivated (session end)

### 6. Skill search

```erlang
%% In coding_agent_skills
search_skills(Query) ->
    AllSkills = list_skills(false),
    lists:filter(fun(Skill) ->
        NameMatch = binary:match(maps:get(name, Skill), Query) =/= nomatch,
        DescMatch = binary:match(maps:get(description, Skill), Query) =/= nomatch,
        TagMatch = lists:any(fun(T) -> binary:match(T, Query) =/= nomatch end, 
                              maps:get(tags, Skill, [])),
        NameMatch orelse DescMatch orelse TagMatch
    end, AllSkills).
```

### 7. REPL commands

```
/skills                    List all skills (always + conditional)
/skills active             List currently active conditional skills
/skill <name>              Activate a skill manually
/skill <name> deactivate  Deactivate a skill
```

## Implementation Steps

1. Extend `#skill{}` record with `path_patterns`, `context`, `model`, `tags`, `hooks`
2. Update `parse_yaml_frontmatter/1` to parse new fields
3. Implement `activate_conditional_skills/1` for path-based activation
4. Implement context modes (inline, fork, background) in skill execution
5. Implement `on_activate` and `on_deactivate` hook execution
6. Add model override support in skill execution
7. Add `/skills` and `/skill` REPL commands
8. Implement `search_skills/1` for skill discovery
9. Update `build_skills_summary` to include active conditional skills
10. Write example skills using new frontmatter fields
11. Update built-in skills to use new frontmatter format

## Edge Cases

- **Circular activation**: Skill A activates Skill B which activates Skill A — prevent via activation visited set
- **Missing binary in `requires`**: Skill should not activate, log a warning
- **Hook command failure**: Log warning, don't block skill activation
- **Model not available**: Fall back to `inherit` if specified model is not in Ollama
- **Background skill timeout**: Default 5-minute timeout, configurable per skill

## Success Metrics

- Skills auto-activate based on file paths
- `/skills` shows both always-active and conditionally-active skills
- Skill model overrides work correctly
- Hook commands execute reliably on activate/deactivate