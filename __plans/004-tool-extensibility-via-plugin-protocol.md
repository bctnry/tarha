# 004: Tool Extensibility via Plugin Protocol

**Priority**: High  
**Impact**: Unlimited tool expansion without core modifications  
**Complexity**: Medium  
**Files affected**: new `coding_agent_plugins.erl`, `coding_agent_tools.erl`, `coding_agent_session.erl`

## Problem

All 38 tools are hardcoded in `coding_agent_tools:tools/0` and `coding_agent_tools:execute/2`. Adding a new tool requires modifying core source code. There is no mechanism for project-specific or user-specific tools.

## Proposed Solution

### 1. Plugin directory convention

```
.tarha/plugins/
├── my-custom-tool/
│   ├── plugin.json          # Plugin manifest
│   ├── tool.erl              # Optional: native Erlang tool
│   └── prompt.md             # System prompt injection
```

Example `plugin.json`:

```json
{
  "name": "my-custom-tool",
  "version": "1.0.0",
  "description": "Describe what this tool does",
  "tools": [
    {
      "name": "my_tool",
      "description": "My custom tool that does X",
      "parameters": {
        "type": "object",
        "properties": {
          "input": {
            "type": "string",
            "description": "The input to process"
          }
        },
        "required": ["input"]
      }
    }
  ],
  "handler": "shell",
  "command": "my-tool-script",
  "timeout": 30000
}
```

### 2. Handler types

| Handler | Description |
|---------|-------------|
| `shell` | Execute a shell command with tool arguments as JSON stdin or CLI args |
| `module` | Call an Erlang module function |
| `http` | POST to an HTTP endpoint |

### 3. Shell handler

```json
{
  "handler": "shell",
  "command": "node ./my-tool.js",
  "timeout": 30000
}
```

Execution:
1. Serialize tool arguments as JSON to stdin
2. Run `command` via `os:cmd/1` with timeout
3. Parse stdout as JSON result
4. Return to LLM

```erlang
execute_plugin_tool(ToolName, Args, #plugin{handler = shell, command = Cmd, timeout = Timeout}) ->
    JsonInput = jsx:encode(Args),
    FullCmd = io_lib:format("echo '~s' | ~s", [JsonInput, Cmd]),
    Result = run_with_timeout(FullCmd, Timeout),
    parse_plugin_result(Result).
```

### 4. Module handler

```json
{
  "handler": "module",
  "module": "my_custom_tools",
  "function": "handle_tool"
}
```

```erlang
execute_plugin_tool(ToolName, Args, #plugin{handler = module, module = Mod, function = Fn}) ->
    Mod:Fn(ToolName, Args).
```

### 5. HTTP handler

```json
{
  "handler": "http",
  "url": "http://localhost:8080/tools",
  "method": "POST",
  "headers": {"Authorization": "Bearer ${API_KEY}"},
  "timeout": 30000
}
```

```erlang
execute_plugin_tool(ToolName, Args, #plugin{handler = http, url = Url, headers = Hdrs}) ->
    coding_agent_tools_command:http_request(Url, Args, Hdrs).
```

### 6. `coding_agent_plugins.erl` — Plugin manager

```erlang
-module(coding_agent_plugins).
-behaviour(gen_server).

-record(state, {
    workspace :: string(),
    plugins :: #{binary() => #plugin{}},
    tool_to_plugin :: #{binary() => binary()}  %% ToolName -> PluginName
}).

-record(plugin, {
    name :: binary(),
    version :: binary(),
    description :: binary(),
    tools :: [map()],
    handler :: shell | module | http,
    command :: string() | undefined,
    module :: atom() | undefined,
    function :: atom() | undefined,
    url :: string() | undefined,
    headers :: map(),
    timeout :: integer(),
    prompt :: binary() | undefined,
    enabled :: boolean()
}).

%% API
load_plugins/0,1     %% Load from .tarha/plugins/ and priv/plugins/
get_tool_schemas/0   %% Return tool definitions for all loaded plugins
execute/2            %% Delegate tool call to appropriate plugin handler
list_plugins/0       %% List all loaded plugins
enable/1, disable/1 %% Enable/disable plugins at runtime
```

### 7. Integration with tool system

Modify `coding_agent_tools:tools/0` to include plugin tools:

```erlang
tools() ->
    BuiltInTools = built_in_tools(),
    PluginTools = coding_agent_plugins:get_tool_schemas(),
    BuiltInTools ++ PluginTools.
```

Modify `coding_agent_tools:execute/2` to check plugins:

```erlang
execute(ToolName, Args) ->
    case dispatch_builtin(ToolName, Args) of
        {error, <<"Unknown tool">>} ->
            coding_agent_plugins:execute(ToolName, Args);
        Result ->
            Result
    end.
```

### 8. Plugin priority

Built-in tools always take priority over plugin tools with the same name. If a plugin defines a tool named `read_file`, it is ignored in favor of the built-in.

### 9. System prompt injection

Plugins with a `prompt.md` file have their content injected into the system prompt:

```erlang
%% In coding_agent_session system prompt construction
PluginPrompts = coding_agent_plugins:get_prompts(),
SystemPrompt = <<BasePrompt/binary, "\n\n", PluginPrompts/binary>>.
```

### 10. REPL commands

- `/plugins` — list loaded plugins and their status
- `/plugin enable <name>` — enable a plugin
- `/plugin disable <name>` — disable a plugin
- `/plugin reload <name>` — reload a plugin from disk

## Implementation Steps

1. Define `#plugin{}` record and JSON schema for `plugin.json`
2. Implement `coding_agent_plugins.erl` with directory scanning and loading
3. Implement shell handler (JSON stdin, command execution, result parsing)
4. Implement module handler (dynamic module function call)
5. Implement HTTP handler (reuse existing `coding_agent_tools_command:http_request`)
6. Add plugin tool schemas to `coding_agent_tools:tools/0`
7. Add plugin dispatch fallback to `coding_agent_tools:execute/2`
8. Add system prompt injection for plugin prompt.md files
9. Add REPL commands for plugin management
10. Add plugin sandboxing: timeout enforcement, output truncation, working directory restriction
11. Write example plugins (shell, module, HTTP)
12. Add plugin loading to application startup
13. Write tests

## Edge Cases

- **Plugin crash**: Execute in a spawned process with timeout; return error to LLM
- **Plugin name conflict**: Built-in wins; log a warning
- **Plugin directory missing**: Create `.tarha/plugins/` on first use
- **Invalid plugin.json**: Skip with warning, don't crash the application
- **Security**: Sandshell the `command` execution; restrict file access to workspace
- **Hot reload**: Allow runtime plugin enable/disable without session restart
- **Timeout**: Default 30s, configurable per plugin

## Success Metrics

- Plugins can be added to `.tarha/plugins/` and appear in `/tools` listing
- Shell, module, and HTTP handlers all work correctly
- Plugin tool calls are indistinguishable from built-in tool calls to the LLM
- Crashed plugins don't affect the parent session
- Built-in tools always take priority over plugin tools