-module(coding_agent_tools).
-export([tools/0, execute/2, execute_concurrent/1]).
-export([create_backup/1, restore_backup/1, list_backups/0, clear_backups/0]).
-export([set_progress_callback/1, set_safety_callback/1]).
-export([get_log/0, clear_log/0]).
-export([start_lsp/1, start_index/1]).
-export([safe_binary/1, safe_binary/2]).
-include_lib("kernel/include/file.hrl").

-define(BACKUP_DIR, ".tarha/backups").
-define(MAX_BACKUPS, 50).
-define(OPS_LOG, coding_agent_ops_log).
-define(MAX_TEXT_SIZE, 50000).
-define(PROGRESS_CALLBACK, coding_agent_progress_cb).
-define(SAFETY_CALLBACK, coding_agent_safety_cb).

% Safely convert to binary with size limit
safe_binary(Input) when is_binary(Input) ->
    case byte_size(Input) of
        Size when Size > ?MAX_TEXT_SIZE ->
            <<First:?MAX_TEXT_SIZE/binary, _/binary>> = Input,
            <<First/binary, "... (truncated)">>;
        _ -> Input
    end;
safe_binary(Input) when is_list(Input) ->
    safe_binary(Input, ?MAX_TEXT_SIZE);
safe_binary(Input) ->
    safe_binary(iolist_to_binary(io_lib:format("~p", [Input])), ?MAX_TEXT_SIZE).

safe_binary(Input, MaxSize) when is_binary(Input) ->
    case byte_size(Input) of
        Size when Size > MaxSize ->
            <<First:MaxSize/binary, _/binary>> = Input,
            <<First/binary, "... (truncated)">>;
        _ -> Input
    end;
safe_binary(Input, MaxSize) when is_list(Input) ->
    try
        Bin = unicode:characters_to_binary(Input),
        safe_binary(Bin, MaxSize)
    catch
        _:_ -> safe_binary(iolist_to_binary(io_lib:format("~p", [Input])), MaxSize)
    end;
safe_binary(Input, _MaxSize) ->
    safe_binary(Input).

% Progress callback: fun((Operation, Status, Data) -> ok)
set_progress_callback(Fun) when is_function(Fun, 3) ->
    erlang:put(?PROGRESS_CALLBACK, Fun),
    ok.

set_safety_callback(Fun) when is_function(Fun, 2) ->
    erlang:put(?SAFETY_CALLBACK, Fun),
    ok.

start_lsp(ProjectRoot) ->
    coding_agent_lsp:start_link(ProjectRoot).

start_index(ProjectRoot) ->
    coding_agent_index:start_link(ProjectRoot).

get_log() ->
    case ets:whereis(?OPS_LOG) of
        undefined -> [];
        _ -> ets:tab2list(?OPS_LOG)
    end.

clear_log() ->
    case ets:whereis(?OPS_LOG) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?OPS_LOG)
    end.

tools() ->
    [
        % File Operations
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"read_file">>,
                <<"description">> => <<"Read a file from the filesystem. Returns the file contents as a string.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The absolute file path to read">>}
                    },
                    <<"required">> => [<<"path">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"edit_file">>,
                <<"description">> => <<"Edit a file by replacing exact string matches. Creates automatic backup. Use this for surgical edits instead of rewriting entire files.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The file path to edit">>},
                        <<"old_string">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The exact text to find and replace (must match exactly)">>},
                        <<"new_string">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The text to replace it with">>},
                        <<"replace_all">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Replace all occurrences (default: false)">>}
                    },
                    <<"required">> => [<<"path">>, <<"old_string">>, <<"new_string">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"write_file">>,
                <<"description">> => <<"Write content to a file (creates or overwrites). Creates automatic backup if file exists.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The file path to write">>},
                        <<"content">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The content to write">>}
                    },
                    <<"required">> => [<<"path">>, <<"content">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"create_directory">>,
                <<"description">> => <<"Create a directory (and parent directories if needed)">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The directory path to create">>}
                    },
                    <<"required">> => [<<"path">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"list_files">>,
                <<"description">> => <<"List files and directories with metadata">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The directory path to list (default: current directory)">>},
                        <<"recursive">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"List recursively (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"file_exists">>,
                <<"description">> => <<"Check if a file or directory exists">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The path to check">>}
                    },
                    <<"required">> => [<<"path">>]
                }
            }
        },
        % Git Operations
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"git_status">>,
                <<"description">> => <<"Get the git status of the repository">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{},
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"git_diff">>,
                <<"description">> => <<"Get git diff (changes between commits, staged changes, or working directory changes)">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Specific file to diff (optional)">>},
                        <<"staged">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Show staged changes (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"git_log">>,
                <<"description">> => <<"Get git commit history">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"count">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Number of commits to show (default: 10)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"git_add">>,
                <<"description">> => <<"Stage files for commit">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"files">> => #{<<"type">> => <<"array">>, <<"items">> => #{<<"type">> => <<"string">>}, <<"description">> => <<"List of files to stage (use [\".\"] for all)">>}
                    },
                    <<"required">> => [<<"files">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"git_commit">>,
                <<"description">> => <<"Create a git commit with a message">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"message">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The commit message">>}
                    },
                    <<"required">> => [<<"message">>]
                }
            }
        },
        % Build/Test Operations
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"run_tests">>,
                <<"description">> => <<"Run tests for the project. Automatically detects the test framework (rebar3, mix, npm, etc.)">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"pattern">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Test pattern to match (optional)">>},
                        <<"verbose">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Enable verbose output (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"run_build">>,
                <<"description">> => <<"Build the project. Automatically detects the build system (rebar3, mix, npm, cargo, etc.)">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"target">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Build target (optional, e.g., 'release', 'prod')">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"run_linter">>,
                <<"description">> => <<"Run linter/formatter. Automatically detects the tool (rebar3 lint, mix format, etc.)">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"fix">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Auto-fix issues (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        % Search Operations
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"grep_files">>,
                <<"description">> => <<"Search for a pattern in files">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"pattern">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The regex pattern to search for">>},
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The directory to search (default: current)">>},
                        <<"file_pattern">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File pattern to match (e.g., \"*.erl\")">>}
                    },
                    <<"required">> => [<<"pattern">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"find_files">>,
                <<"description">> => <<"Find files matching a pattern">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"pattern">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Glob pattern to match (e.g., \"**/*.erl\")">>},
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Starting directory (default: current)">>}
                    },
                    <<"required">> => [<<"pattern">>]
                }
            }
        },
        % Backup
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"undo_edit">>,
                <<"description">> => <<"Restore a file from the most recent backup">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The file path to restore">>}
                    },
                    <<"required">> => [<<"path">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"list_backups">>,
                <<"description">> => <<"List all available backups">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{},
                    <<"required">> => []
                }
            }
        },
        % Project Detection
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"detect_project">>,
                <<"description">> => <<"Detect project type, build tools, and dependencies">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"path">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Project root directory (default: current)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        % Command Execution
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"run_command">>,
                <<"description">> => <<"Execute a shell command. Use with caution.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"command">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The shell command to execute">>},
                        <<"timeout">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Timeout in milliseconds (default: 30000)">>},
                        <<"cwd">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Working directory (optional)">>}
                    },
                    <<"required">> => [<<"command">>]
                }
            }
        },
        % Auto-commit
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"smart_commit">>,
                <<"description">> => <<"Analyze staged changes and create a git commit with an auto-generated message based on the diff.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"preview">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Preview the commit message without committing (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        % Code Review
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"review_changes">>,
                <<"description">> => <<"Review staged or unstaged changes and provide structured feedback.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"staged">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Review staged changes (default: true)">>},
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Specific file to review (optional)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        % Test Generation
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"generate_tests">>,
                <<"description">> => <<"Generate unit tests for a function or module.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File to generate tests for">>},
                        <<"function">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Specific function name (optional, generates for all if not specified)">>},
                        <<"framework">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Test framework (eunit, common_test, prop.erlang, default: eunit)">>}
                    },
                    <<"required">> => [<<"file">>]
                }
            }
        },
        % Documentation Generation
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"generate_docs">>,
                <<"description">> => <<"Generate documentation (@doc, @spec, @moduledoc) for a module or function.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File to generate docs for">>},
                        <<"function">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Specific function (optional, generates for all if not specified)">>},
                        <<"style">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Doc style (edoc, exdoc, default: edoc)">>}
                    },
                    <<"required">> => [<<"file">>]
                }
            }
        },
        % Web Docs Fetcher
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"fetch_docs">>,
                <<"description">> => <<"Fetch documentation from the web for a package or module.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"package">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Package name (e.g., 'hackney', 'phoenix')">>},
                        <<"language">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Language/ecosystem (erlang, elixir, npm, python, rust)">>},
                        <<"version">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Version (optional, latest if not specified)">>}
                    },
                    <<"required">> => [<<"package">>, <<"language">>]
                }
            }
        },
        % Refactoring Tools
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"rename_symbol">>,
                <<"description">> => <<"Rename a symbol (function, variable, module) across the codebase.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File containing the symbol">>},
                        <<"old_name">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Current symbol name">>},
                        <<"new_name">> => #{<<"type">> => <<"string">>, <<"description">> => <<"New symbol name">>},
                        <<"scope">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Scope: 'file' or 'project' (default: file)">>}
                    },
                    <<"required">> => [<<"file">>, <<"old_name">>, <<"new_name">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"extract_function">>,
                <<"description">> => <<"Extract selected code into a new function.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File path">>},
                        <<"start_line">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Start line of code to extract">>},
                        <<"end_line">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"End line of code to extract">>},
                        <<"function_name">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Name for the new function">>}
                    },
                    <<"required">> => [<<"file">>, <<"start_line">>, <<"end_line">>, <<"function_name">>]
                }
            }
        },
        % Multi-file Context
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"load_context">>,
                <<"description">> => <<"Smart-load related files into context for better understanding. Loads imports, dependencies, test files, and related modules.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Primary file to load context for">>},
                        <<"include_tests">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Include test files (default: false)">>},
                        <<"include_deps">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Include dependency source (default: false)">>},
                        <<"max_files">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Maximum files to load (default: 5)">>}
                    },
                    <<"required">> => [<<"file">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"find_references">>,
                <<"description">> => <<"Find all references to a symbol across the codebase.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File containing the symbol">>},
                        <<"symbol">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Symbol name to find references for">>},
                        <<"line">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Line number where symbol appears (optional)">>}
                    },
                    <<"required">> => [<<"file">>, <<"symbol">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"get_callers">>,
                <<"description">> => <<"Find all functions that call a specified function.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File path">>},
                        <<"function">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Function name">>}
                    },
                    <<"required">> => [<<"file">>, <<"function">>]
                }
            }
        },
        % Hello Command
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"hello">>,
                <<"description">> => <<"Print hello world message.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{},
                    <<"required">> => []
                }
            }
        }
    ].

% Execute multiple tools concurrently (for parallel operations)
execute_concurrent(ToolCalls) when is_list(ToolCalls) ->
    Parent = self(),
    Pids = lists:map(fun({Name, Args}) ->
        spawn_link(fun() ->
            Result = execute(Name, Args),
            Parent ! {tool_result, Name, Result}
        end)
    end, ToolCalls),
    collect_concurrent_results(Pids, #{}).

collect_concurrent_results([], Results) ->
    Results;
collect_concurrent_results(Pids, Results) ->
    receive
        {tool_result, Name, Result} ->
            collect_concurrent_results(Pids, Results#{Name => Result})
    after 60000 ->
        #{error => timeout}
    end.

% Log operation
log_operation(Name, Args, Result) ->
    case ets:whereis(?OPS_LOG) of
        undefined ->
            ets:new(?OPS_LOG, [named_table, public, ordered_set]);
        _ ->
            ok
    end,
    ets:insert(?OPS_LOG, {
        erlang:system_time(millisecond),
        Name,
        Args,
        Result
    }).

% Report progress
report_progress(Operation, Status, Data) ->
    case erlang:get(?PROGRESS_CALLBACK) of
        undefined -> ok;
        Fun when is_function(Fun, 3) ->
            try Fun(Operation, Status, Data) catch _:_ -> ok end
    end.

% Safety check for dangerous operations
safety_check(Operation, Args) ->
    case erlang:get(?SAFETY_CALLBACK) of
        undefined -> proceed;
        Fun when is_function(Fun, 2) ->
            try Fun(Operation, Args) catch _:_ -> proceed end
    end.

% File Operations
execute(<<"read_file">>, #{<<"path">> := Path}) ->
    report_progress(<<"read_file">>, <<"starting">>, #{path => Path}),
    PathStr = sanitize_path(Path),
    case file:read_file(PathStr) of
        {ok, Content} ->
            % Truncate large files
            SafeContent = safe_binary(Content),
            Result = #{<<"success">> => true, <<"content">> => SafeContent},
            log_operation(<<"read_file">>, Path, Result),
            report_progress(<<"read_file">>, <<"complete">>, #{path => Path, size => byte_size(SafeContent)}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
            log_operation(<<"read_file">>, Path, Result),
            Result
    end;

execute(<<"edit_file">>, #{<<"path">> := Path, <<"old_string">> := OldStr, <<"new_string">> := NewStr} = Args) ->
    % Safety check for file modifications
    case safety_check(<<"edit_file">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"edit_file">>, NewArgs);
        proceed ->
            report_progress(<<"edit_file">>, <<"starting">>, #{path => Path}),
            PathStr = sanitize_path(Path),
            ReplaceAll = maps:get(<<"replace_all">>, Args, false),
            case file:read_file(PathStr) of
                {ok, Content} ->
                    ContentStr = binary_to_list(Content),
                    OldStrList = binary_to_list(OldStr),
                    NewStrList = binary_to_list(NewStr),
                    case find_occurrences(ContentStr, OldStrList) of
                        0 ->
                            Result = #{<<"success">> => false, <<"error">> => <<"Old string not found in file">>},
                            log_operation(<<"edit_file">>, Path, Result),
                            Result;
                        Count when Count > 1 andalso ReplaceAll =/= true ->
                            Result = #{<<"success">> => false, <<"error">> => iolist_to_binary(io_lib:format("Found ~b occurrences. Use replace_all to replace all.", [Count]))},
                            log_operation(<<"edit_file">>, Path, Result),
                            Result;
                        _ ->
                            _ = create_backup_internal(PathStr),
                            NewContent = case ReplaceAll of
                                true -> replace_all(ContentStr, OldStrList, NewStrList);
                                false -> string:replace(ContentStr, OldStrList, NewStrList)
                            end,
                            case file:write_file(PathStr, list_to_binary(NewContent)) of
                                ok ->
                                    Result = #{<<"success">> => true, <<"message">> => <<"File edited successfully">>},
                                    log_operation(<<"edit_file">>, Path, Result),
                                    report_progress(<<"edit_file">>, <<"complete">>, #{path => Path}),
                                    Result;
                                {error, Reason} ->
                                    restore_backup_internal(PathStr),
                                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                                    log_operation(<<"edit_file">>, Path, Result),
                                    Result
                            end
                    end;
                {error, Reason} ->
                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                    log_operation(<<"edit_file">>, Path, Result),
                    Result
            end
    end;

execute(<<"write_file">>, #{<<"path">> := Path, <<"content">> := Content} = Args) ->
    case safety_check(<<"write_file">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"write_file">>, NewArgs);
        proceed ->
            report_progress(<<"write_file">>, <<"starting">>, #{path => Path}),
            PathStr = sanitize_path(Path),
            case filelib:is_file(PathStr) of
                true -> _ = create_backup_internal(PathStr);
                false -> ok
            end,
            case file:write_file(PathStr, Content) of
                ok ->
                    Result = #{<<"success">> => true, <<"message">> => <<"File written successfully">>},
                    log_operation(<<"write_file">>, Path, Result),
                    report_progress(<<"write_file">>, <<"complete">>, #{path => Path}),
                    Result;
                {error, Reason} ->
                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                    log_operation(<<"write_file">>, Path, Result),
                    Result
            end
    end;

execute(<<"create_directory">>, #{<<"path">> := Path}) ->
    PathStr = sanitize_path(Path),
    case filelib:is_dir(PathStr) of
        true -> #{<<"success">> => true, <<"message">> => <<"Directory already exists">>};
        false ->
            case filelib:ensure_dir(PathStr ++ "/") of
                ok ->
                    case file:make_dir(PathStr) of
                        ok -> #{<<"success">> => true, <<"message">> => <<"Directory created">>};
                        {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
                    end;
                {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
            end
    end;

execute(<<"list_files">>, Args) ->
    Path = maps:get(<<"path">>, Args, <<".">>),
    Recursive = maps:get(<<"recursive">>, Args, false),
    PathStr = sanitize_path(Path),
    list_files_impl(PathStr, Recursive);

execute(<<"file_exists">>, #{<<"path">> := Path}) ->
    PathStr = sanitize_path(Path),
    case filelib:is_file(PathStr) of
        true -> #{<<"success">> => true, <<"exists">> => true};
        false ->
            case filelib:is_dir(PathStr) of
                true -> #{<<"success">> => true, <<"exists">> => true, <<"type">> => <<"directory">>};
                false -> #{<<"success">> => true, <<"exists">> => false}
            end
    end;

% Git Operations
execute(<<"git_status">>, _Args) ->
    run_git_command("git status --porcelain");

execute(<<"git_diff">>, Args) ->
    File = maps:get(<<"file">>, Args, undefined),
    Staged = maps:get(<<"staged">>, Args, false),
    Cmd = case {File, Staged} of
        {undefined, true} -> "git diff --cached";
        {undefined, false} -> "git diff";
        {F, true} -> "git diff --cached " ++ binary_to_list(F);
        {F, false} -> "git diff " ++ binary_to_list(F)
    end,
    run_git_command(Cmd);

execute(<<"git_log">>, Args) ->
    Count = maps:get(<<"count">>, Args, 10),
    Cmd = "git log --oneline -n " ++ integer_to_list(Count),
    run_git_command(Cmd);

execute(<<"git_add">>, #{<<"files">> := Files}) ->
    FilesStr = lists:map(fun binary_to_list/1, Files),
    Cmd = "git add " ++ string:join(FilesStr, " "),
    run_git_command(Cmd);

execute(<<"git_commit">>, #{<<"message">> := Msg} = Args) ->
    case safety_check(<<"git_commit">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"git_commit">>, NewArgs);
        proceed ->
            MsgStr = binary_to_list(Msg),
            SafeMsg = lists:filter(fun(C) -> C =/= $' andalso C =/= $" end, MsgStr),
            Cmd = "git commit -m '" ++ SafeMsg ++ "'",
            run_git_command(Cmd)
    end;

execute(<<"git_branch">>, #{<<"action">> := Action} = Args) ->
    case Action of
        <<"list">> -> run_git_command("git branch -a");
        <<"create">> ->
            case maps:get(<<"name">>, Args, undefined) of
                undefined -> #{<<"success">> => false, <<"error">> => <<"Branch name required">>};
                Name -> run_git_command("git checkout -b " ++ binary_to_list(Name))
            end;
        <<"switch">> ->
            case maps:get(<<"name">>, Args, undefined) of
                undefined -> #{<<"success">> => false, <<"error">> => <<"Branch name required">>};
                Name -> run_git_command("git checkout " ++ binary_to_list(Name))
            end
    end;

% Build/Test Operations
execute(<<"run_tests">>, Args) ->
    Pattern = maps:get(<<"pattern">>, Args, undefined),
    Verbose = maps:get(<<"verbose">>, Args, false),
    detect_and_run_tests(Pattern, Verbose);

execute(<<"run_build">>, Args) ->
    Target = maps:get(<<"target">>, Args, undefined),
    detect_and_run_build(Target);

execute(<<"run_linter">>, Args) ->
    Fix = maps:get(<<"fix">>, Args, false),
    detect_and_run_linter(Fix);

% Search Operations
execute(<<"grep_files">>, Args) ->
    Pattern = binary_to_list(maps:get(<<"pattern">>, Args)),
    Path = case maps:get(<<"path">>, Args, <<".">>) of
        <<".">> -> ".";
        P -> binary_to_list(P)
    end,
    FilePattern = maps:get(<<"file_pattern">>, Args, undefined),
    Cmd = case FilePattern of
        undefined -> "grep -rn \"" ++ Pattern ++ "\" " ++ Path ++ " 2>/dev/null || true";
        FP -> "grep -rn --include=\"" ++ binary_to_list(FP) ++ "\" \"" ++ Pattern ++ "\" " ++ Path ++ " 2>/dev/null || true"
    end,
    Result = os:cmd(Cmd),
    case Result of
        [] -> #{<<"success">> => true, <<"matches">> => <<"No matches found">>};
        _ ->
            Trimmed = string:trim(Result, trailing, "\n"),
            #{<<"success">> => true, <<"matches">> => unicode:characters_to_binary(Trimmed)}
    end;

execute(<<"find_files">>, #{<<"pattern">> := Pattern} = Args) ->
    PatternStr = binary_to_list(Pattern),
    Path = case maps:get(<<"path">>, Args, <<".">>) of
        <<".">> -> ".";
        P -> binary_to_list(P)
    end,
    Cmd = "find " ++ Path ++ " -name \"" ++ PatternStr ++ "\" -type f 2>/dev/null || true",
    Result = os:cmd(Cmd),
    case Result of
        [] -> #{<<"success">> => true, <<"files">> => []};
        _ ->
            Trimmed = string:trim(Result, trailing, "\n"),
            Files = string:split(Trimmed, "\n", all),
            #{<<"success">> => true, <<"files">> => [unicode:characters_to_binary(F) || F <- Files]}
    end;

% Backup Operations
execute(<<"undo_edit">>, #{<<"path">> := Path}) ->
    PathStr = sanitize_path(Path),
    case restore_backup_internal(PathStr) of
        {ok, _} -> #{<<"success">> => true, <<"message">> => <<"File restored from backup">>};
        {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(Reason)}
    end;

execute(<<"list_backups">>, _Args) ->
    Backups = list_backups_impl(),
    #{<<"success">> => true, <<"backups">> => Backups};

% Project Detection
execute(<<"detect_project">>, Args) ->
    Path = case maps:get(<<"path">>, Args, <<".">>) of
        <<".">> -> ".";
        P -> binary_to_list(P)
    end,
    detect_project_impl(Path);

% Command Execution
execute(<<"run_command">>, #{<<"command">> := Command} = Args) ->
    case safety_check(<<"run_command">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"run_command">>, NewArgs);
        proceed ->
            CmdStr = binary_to_list(Command),
            Timeout = maps:get(<<"timeout">>, Args, 30000),
            Cwd = case maps:get(<<"cwd">>, Args, undefined) of
                undefined -> ".";
                CwdPath -> binary_to_list(CwdPath)
            end,
            report_progress(<<"run_command">>, <<"starting">>, #{command => Command}),
            Result = run_command_impl(CmdStr, Timeout, Cwd),
            log_operation(<<"run_command">>, Command, Result),
            Result
    end;

% Auto-commit with smart message
execute(<<"smart_commit">>, Args) ->
    case safety_check(<<"smart_commit">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"smart_commit">>, NewArgs);
        proceed ->
            Preview = maps:get(<<"preview">>, Args, false),
            DiffCmd = "git diff --cached",
            StagedDiff = os:cmd(DiffCmd),
            case StagedDiff of
                [] ->
                    #{<<"success">> => false, <<"error">> => <<"No staged changes. Use git add first.">>};
                Diff ->
                    CommitMsg = generate_commit_message(Diff),
                    case Preview of
                        true ->
                            #{<<"success">> => true, 
                              <<"preview">> => true,
                              <<"message">> => CommitMsg,
                                <<"diff">> => clean_output(string:trim(Diff, trailing))};
                        false ->
                            CommitCmd = "git commit -m '" ++ binary_to_list(CommitMsg) ++ "'",
                            Result = os:cmd(CommitCmd ++ " 2>&1"),
                            #{<<"success">> => true,
                              <<"message">> => CommitMsg,
                                <<"output">> => clean_output(string:trim(Result, trailing))}
                    end
            end
    end;

% Code Review
execute(<<"review_changes">>, Args) ->
    Staged = maps:get(<<"staged">>, Args, true),
    File = maps:get(<<"file">>, Args, undefined),
    
    DiffCmd = case {Staged, File} of
        {true, undefined} -> "git diff --cached";
        {true, F} -> "git diff --cached " ++ binary_to_list(F);
        {false, undefined} -> "git diff";
        {false, F} -> "git diff " ++ binary_to_list(F)
    end,
    
    Diff = os:cmd(DiffCmd ++ " 2>&1"),
    case Diff of
        [] -> 
            #{<<"success">> => false, <<"error">> => <<"No changes to review.">>};
        _ ->
            Review = analyze_diff(Diff),
            #{
                <<"success">> => true,
                            <<"diff">> => clean_output(string:trim(Diff, trailing)),
                <<"review">> => Review,
                <<"summary">> => generate_review_summary(Diff)
            }
    end;

% Test Generation
execute(<<"generate_tests">>, #{<<"file">> := FilePath} = Args) ->
    PathStr = sanitize_path(FilePath),
    Function = maps:get(<<"function">>, Args, undefined),
    Framework = maps:get(<<"framework">>, Args, <<"eunit">>),
    
    case file:read_file(PathStr) of
        {ok, Content} ->
            Functions = case Function of
                undefined -> extract_all_functions(Content, PathStr);
                _ -> [binary_to_list(Function)]
            end,
            
            GeneratedTests = lists:map(fun(FuncName) ->
                generate_function_tests(FuncName, Content, PathStr, Framework)
            end, Functions),
            
            TestFile = generate_test_file(FilePath, GeneratedTests, Framework),
            #{
                <<"success">> => true,
                <<"file">> => list_to_binary(PathStr),
                <<"functions">> => Functions,
                <<"framework">> => Framework,
                <<"test_file">> => TestFile,
                <<"tests">> => GeneratedTests
            };
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end;
    
% Self-Modification Tools
execute(<<"reload_module">>, #{<<"module">> := Module}) ->
    ModuleAtom = binary_to_existing_atom(Module, utf8),
    case coding_agent_self:reload_module(ModuleAtom) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"get_self_modules">>, _Args) ->
    {ok, Modules} = coding_agent_self:get_modules(),
    #{<<"success">> => true, <<"modules">> => Modules};

execute(<<"analyze_self">>, _Args) ->
    {ok, Analysis} = coding_agent_self:analyze_self(),
    #{<<"success">> => true, <<"analysis">> => Analysis};

execute(<<"deploy_module">>, #{<<"module">> := Module, <<"code">> := Code}) ->
    ModuleAtom = binary_to_existing_atom(Module, utf8),
    case coding_agent_self:deploy_improvement(ModuleAtom, Code) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"create_checkpoint">>, _Args) ->
    case coding_agent_self:create_checkpoint() of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"restore_checkpoint">>, #{<<"checkpoint_id">> := CheckpointId}) ->
    case coding_agent_self:restore_checkpoint(CheckpointId) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"list_checkpoints">>, _Args) ->
    {ok, Checkpoints} = coding_agent_self:list_checkpoints(),
    #{<<"success">> => true, <<"checkpoints">> => Checkpoints};

execute(<<"hello">>, _Args) ->
    io:format("hello world~n"),
    #{<<"success">> => true, <<"message">> => <<"hello world">>};

execute(_Tool, _Args) ->
    #{<<"success">> => false, <<"error">> => <<"Unknown tool">>}.

% Internal implementations
detect_and_run_tests(Pattern, Verbose) ->
    VerboseFlag = case Verbose of true -> " -v"; false -> "" end,
    TestCommands = [
        {"rebar3.config" ++ VerboseFlag ++ " eunit", "Erlang (rebar3 eunit)"},
        {"mix test", "Elixir (mix test)"},
        {"npm test", "Node.js (npm test)"},
        {"cargo test", "Rust (cargo test)"},
        {"go test ./...", "Go (go test)"},
        {"pytest", "Python (pytest)"}
    ],
    run_detected_command(TestCommands, <<"run_tests">>, Pattern).

detect_and_run_build(Target) ->
    TargetArg = case Target of
        undefined -> "";
        T -> " " ++ binary_to_list(T)
    end,
    BuildCommands = [
        {"rebar3 compile", "Erlang (rebar3 compile)"},
        {"mix compile", "Elixir (mix compile)"},
        {"npm run build", "Node.js (npm build)"},
        {"cargo build" ++ TargetArg, "Rust (cargo build)"},
        {"go build", "Go (go build)"},
        {"mvn compile", "Java (Maven)"},
        {"gradle build", "Java (Gradle)"}
    ],
    run_detected_command(BuildCommands, <<"run_build">>, undefined).

detect_and_run_linter(Fix) ->
    FixFlag = case Fix of true -> " --fix"; false -> "" end,
    LinterCommands = [
        {"rebar3 fmt" ++ FixFlag, "Erlang (rebar3 fmt)"},
        {"mix format", "Elixir (mix format)"},
        {"npm run lint" ++ FixFlag, "Node.js (npm lint)"},
        {"cargo clippy", "Rust (cargo clippy)"},
        {"gofmt -w .", "Go (gofmt)"}
    ],
    run_detected_command(LinterCommands, <<"run_linter">>, undefined).

run_detected_command(Commands, OpName, ExtraArg) ->
    report_progress(OpName, <<"detecting">>, #{}),
    Found = lists:filtermap(fun({Cmd, _Desc}) ->
        [Prog | _] = string:split(Cmd, " "),
        case os:find_executable(Prog) of
            false -> false;
            _ ->
                case filelib:is_file(Prog) of
                    true -> {true, Cmd};
                    false ->
                        case filelib:is_file(filename:basename(Prog)) of
                            true -> {true, Cmd};
                            false -> {true, Cmd}
                        end
                end
        end
    end, Commands),
    case Found of
        [Cmd | _] ->
            FinalCmd = case ExtraArg of
                undefined -> Cmd;
                Pattern -> Cmd ++ " " ++ binary_to_list(Pattern)
            end,
            report_progress(OpName, <<"running">>, #{command => list_to_binary(FinalCmd)}),
            Result = run_command_impl(FinalCmd, 120000, "."),
            Result#{<<"command">> => list_to_binary(FinalCmd)};
        [] ->
            #{<<"success">> => false, <<"error">> => <<"No suitable build/test tool found">>}
    end.

sanitize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
sanitize_path(Path) when is_list(Path) ->
    Path.

find_occurrences(Content, Pattern) ->
    length(binary:matches(list_to_binary(Content), list_to_binary(Pattern))).

replace_all(Content, Old, New) ->
    binary_to_list(binary:replace(list_to_binary(Content), list_to_binary(Old), list_to_binary(New), [global])).

list_files_impl(Path, Recursive) ->
    case file:list_dir(Path) of
        {ok, Files} ->
            FilesWithInfo = lists:filtermap(fun(F) ->
                FullPath = filename:join(Path, F),
                case file:read_file_info(FullPath) of
                    {ok, Info} ->
                        Type = case Info#file_info.type of
                            regular -> <<"file">>;
                            directory -> <<"directory">>;
                            _ -> <<"other">>
                        end,
                        {true, #{
                            <<"name">> => list_to_binary(F),
                            <<"type">> => Type,
                            <<"size">> => Info#file_info.size
                        }};
                    _ -> false
                end
            end, Files),
            case Recursive of
                true ->
                    Dirs = [filename:join(Path, F) || F <- Files, filelib:is_dir(filename:join(Path, F))],
                    SubFiles = lists:flatmap(fun(D) ->
                        case list_files_impl(D, true) of
                            #{<<"success">> := true, <<"files">> := Fs} -> Fs;
                            _ -> []
                        end
                    end, Dirs),
                    #{<<"success">> => true, <<"files">> => FilesWithInfo ++ SubFiles};
                false ->
                    #{<<"success">> => true, <<"files">> => FilesWithInfo}
            end;
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

run_git_command(Cmd) ->
    case os:cmd(Cmd ++ " 2>&1") of
        [] -> #{<<"success">> => true, <<"output">> => <<"">>};
        Result ->
            CleanResult = clean_output(Result),
            #{<<"success">> => true, <<"output">> => CleanResult}
    end.

run_command_impl(Cmd, _Timeout, Cwd) ->
    OldCwd = file:get_cwd(),
    case Cwd of
        "." -> ok;
        _ -> file:set_cwd(Cwd)
    end,
    try
        case os:cmd(Cmd) of
            [] -> #{<<"success">> => true, <<"output">> => <<>>};
            Result when is_list(Result) ->
                CleanResult = clean_output(Result),
                #{<<"success">> => true, <<"output">> => unicode:characters_to_binary(CleanResult)}
        end
    after
        case OldCwd of
            {ok, D} -> file:set_cwd(D);
            _ -> ok
        end
    end.

clean_output(String) when is_binary(String) ->
    % Remove ANSI escape codes from binary
    % Truncate if too large
    MaxSize = 50000,
    try
        Cleaned = re:replace(String, "\\x1b\\[[0-9;]*[a-zA-Z]", "", [global, {return, binary}]),
        case byte_size(Cleaned) of
            Size when Size > MaxSize ->
                <<Short:MaxSize/binary, _/binary>> = Cleaned,
                <<Short/binary, "... (truncated)">>;
            _ -> Cleaned
        end
    catch
        _:_ -> 
            case byte_size(String) of
                Size when Size > MaxSize ->
                    <<Short:MaxSize/binary, _/binary>> = String,
                    <<Short/binary, "... (truncated)">>;
                _ -> String
            end
    end;
clean_output(String) when is_list(String) ->
    % Check if it's a printable string
    MaxSize = 50000,
    case io_lib:printable_unicode_list(String) of
        true -> 
            % It's a string - convert to binary and clean
            try
                Bin = unicode:characters_to_binary(String),
                Cleaned = re:replace(Bin, "\\x1b\\[[0-9;]*[a-zA-Z]", "", [global, {return, binary}]),
                case byte_size(Cleaned) of
                    Size when Size > MaxSize ->
                        <<Short:MaxSize/binary, _/binary>> = Cleaned,
                        <<Short/binary, "... (truncated)">>;
                    _ -> Cleaned
                end
            catch
                _:_ -> 
                    % Fallback - just truncate the original
                    try
                        Len = length(String),
                        case Len > MaxSize of
                            true -> 
                                unicode:characters_to_binary(string:sub_string(String, 1, MaxSize) ++ "... (truncated)");
                            false -> unicode:characters_to_binary(String)
                        end
                    catch
                        _:_ -> <<"[output too large]">>
                    end
            end;
        false ->
            % It's a nested structure - return as formatted string
            case String of
                [] -> <<"[]">>;
                _ when is_list(hd(String)) ->
                    % Nested list - limit depth and size
                    MaxItems = 100,
                    Limited = lists:sublist(String, MaxItems),
                    unicode:characters_to_binary(io_lib:format("[list of ~p items, showing first ~p]", [length(String), length(Limited)]));
                _ ->
                    % Flat list but not printable - format safely
                    try
                        unicode:characters_to_binary(io_lib:format("~w", [String]))
                    catch
                        _:_ -> <<"[unprintable data]">>
                    end
            end
    end;
clean_output(Other) ->
    % Fallback for any other type - format and truncate
    try
        Bin = iolist_to_binary(io_lib:format("~p", [Other])),
        MaxSize = 50000,
        case byte_size(Bin) of
            Size when Size > MaxSize ->
                <<FirstPart:MaxSize/binary, _/binary>> = Bin,
                <<FirstPart/binary, "... (truncated)">>;
            _ -> Bin
        end
    catch
        _:_ -> <<"[error serializing result]">>
    end.

create_backup_internal(Path) ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> file:make_dir(BackupDir);
        true -> ok
    end,
    Timestamp = erlang:system_time(millisecond),
    BackupName = integer_to_list(Timestamp) ++ "_" ++ filename:basename(Path),
    BackupPath = filename:join(BackupDir, BackupName),
    case file:copy(Path, BackupPath) of
        {ok, _} ->
            cleanup_old_backups(),
            {ok, BackupPath};
        {error, Reason} -> {error, file:format_error(Reason)}
    end.

restore_backup_internal(Path) ->
    BackupDir = ?BACKUP_DIR,
    Basename = filename:basename(Path),
    case filelib:wildcard(filename:join(BackupDir, "*_" ++ Basename)) of
        [Latest | _] ->
            case file:copy(Latest, Path) of
                {ok, _} -> {ok, Path};
                {error, Reason} -> {error, file:format_error(Reason)}
            end;
        [] -> {error, "No backup found"}
    end.

list_backups_impl() ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> [];
        true ->
            Files = filelib:wildcard(filename:join(BackupDir, "*")),
            lists:map(fun(F) ->
                #{<<"path">> => list_to_binary(F), <<"name">> => list_to_binary(filename:basename(F))}
            end, Files)
    end.

cleanup_old_backups() ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> ok;
        true ->
            Files = filelib:wildcard(filename:join(BackupDir, "*")),
            case length(Files) > ?MAX_BACKUPS of
                true ->
                    Sorted = lists:sort(Files),
                    ToDelete = lists:sublist(Sorted, length(Sorted) - ?MAX_BACKUPS),
                    lists:foreach(fun(F) -> file:delete(F) end, ToDelete);
                false -> ok
            end
    end.

detect_project_impl(Path) ->
    Checks = [
        {"rebar.config", "Erlang/OTP (Rebar3)"},
        {"package.json", "Node.js"},
        {"Cargo.toml", "Rust"},
        {"go.mod", "Go"},
        {"pom.xml", "Java (Maven)"},
        {"build.gradle", "Java (Gradle)"},
        {"requirements.txt", "Python"},
        {"pyproject.toml", "Python"},
        {"Gemfile", "Ruby"},
        {"composer.json", "PHP"},
        {"mix.exs", "Elixir"}
    ],
    Results = lists:filtermap(fun({File, Type}) ->
        FullPath = filename:join(Path, File),
        case filelib:is_file(FullPath) of
            true -> {true, #{
                <<"file">> => list_to_binary(File),
                <<"type">> => list_to_binary(Type)
            }};
            false -> false
        end
    end, Checks),
    
    IsGit = filelib:is_dir(filename:join(Path, ".git")),
    
    #{
        <<"success">> => true,
        <<"project_types">> => Results,
        <<"is_git_repo">> => IsGit,
        <<"detected">> => length(Results) > 0
    }.

create_backup(Path) when is_list(Path) ->
    create_backup_internal(Path).

restore_backup(Path) when is_list(Path) ->
    restore_backup_internal(Path).

list_backups() ->
    list_backups_impl().

clear_backups() ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> ok;
        true ->
            Files = filelib:wildcard(filename:join(BackupDir, "*")),
            lists:foreach(fun(F) -> file:delete(F) end, Files)
    end.

% Helper functions for smart_commit
generate_commit_message(Diff) ->
    % Parse diff and generate meaningful commit message
    Lines = string:split(Diff, "\n", all),
    AddedFiles = [Line || Line <- Lines, string:prefix(Line, "diff --git ") =/= nomatch],
    AddedCount = length(AddedFiles),
    
    % Detect change type
    ChangeType = detect_change_type(Diff),
    
    % Generate message based on patterns
    Msg = case ChangeType of
        {add, Files} when Files =/= [] ->
            iolist_to_binary(io_lib:format("Add ~p new file(s): ~s", [length(Files), string:join(Files, ", ")]));
        {modify, Files} when Files =/= [] ->
            iolist_to_binary(io_lib:format("Update ~p file(s): ~s", [length(Files), string:join(Files, ", ")]));
        {refactor, _} ->
            <<"Refactor code structure">>;
        {fix, _} ->
            <<"Fix bugs and issues">>;
        {feature, _} ->
            <<"Add new feature">>;
        {docs, _} ->
            <<"Update documentation">>;
        {test, _} ->
            <<"Add or update tests">>;
        _ ->
            iolist_to_binary(io_lib:format("Update ~p file(s)", [AddedCount]))
    end,
    Msg.

detect_change_type(Diff) ->
    Lines = string:split(Diff, "\n", all),
    Files = lists:filtermap(fun(Line) ->
        case string:prefix(Line, "diff --git a/") of
            nomatch -> false;
            Rest -> {true, filename:basename(string:trim(Rest))}
        end
    end, Lines),
    
    % Check for patterns
    HasTest = lists:any(fun(F) -> string:find(F, "test") =/= nomatch end, Files),
    HasDoc = lists:any(fun(F) -> string:find(F, "doc") =/= nomatch orelse 
                                string:suffix(F, "README.md") orelse
                                string:suffix(F, "CHANGELOG.md") end, Files),
    HasNew = string:find(Diff, "new file") =/= nomatch,
    
    case {HasTest, HasDoc, HasNew, Files} of
        {true, _, _, Files} -> {test, Files};
        {_, true, _, Files} -> {docs, Files};
        {_, _, true, Files} -> {add, Files};
        {_, _, _, Files} -> {modify, Files}
    end.

analyze_diff(Diff) ->
    Lines = string:split(Diff, "\n", all),
    Stats = lists:foldl(fun(Line, {Added, Removed, Files}) ->
        case Line of
            "+++" ++ _ -> {Added, Removed, Files};
            "---" ++ _ -> {Added, Removed, Files};
            "+" ++ _ -> {Added + 1, Removed, Files};
            "-" ++ _ -> {Added, Removed + 1, Files};
            "diff --git " ++ Rest ->
                File = string:trim(Rest),
                {Added, Removed, [File | Files]};
            _ -> {Added, Removed, Files}
        end
    end, {0, 0, []}, Lines),
    
    {LinesAdded, LinesRemoved, ChangedFiles} = Stats,
    
    #{
        <<"files_changed">> => length(lists:usort(ChangedFiles)),
        <<"lines_added">> => LinesAdded,
        <<"lines_removed">> => LinesRemoved,
        <<"issues">> => detect_issues(Diff),
        <<"suggestions">> => generate_suggestions(Diff)
    }.

detect_issues(Diff) ->
    Issues = [],
    
    % Check for common issues
    Issues1 = case string:find(Diff, "TODO") =/= nomatch of
        true -> [<<"Contains TODO comments">> | Issues];
        false -> Issues
    end,
    
    Issues2 = case string:find(Diff, "FIXME") =/= nomatch of
        true -> [<<"Contains FIXME comments">> | Issues1];
        false -> Issues1
    end,
    
    Issues3 = case string:find(Diff, "console.log") =/= nomatch of
        true -> [<<"Contains console.log statements">> | Issues2];
        false -> Issues2
    end,
    
    Issues4 = case string:find(Diff, "debugger") =/= nomatch of
        true -> [<<"Contains debugger statements">> | Issues3];
        false -> Issues3
    end,
    
    Issues4.

generate_suggestions(Diff) ->
    Suggestions = [],
    
    % Check for improvement opportunities
    Sug1 = case string:find(Diff, "password") =/= nomatch orelse 
              string:find(Diff, "secret") =/= nomatch orelse
              string:find(Diff, "api_key") =/= nomatch of
        true -> [<<"Review for potential hardcoded secrets">> | Suggestions];
        false -> Suggestions
    end,
    
    Sug2 = case string:find(Diff, "print") =/= nomatch orelse
              string:find(Diff, "io:format") =/= nomatch of
        true -> [<<"Consider removing debug print statements">> | Sug1];
        false -> Sug1
    end,
    
    Sug2.

generate_review_summary(Diff) ->
    Stats = analyze_diff(Diff),
    Files = maps:get(<<"files_changed">>, Stats, 0),
    Added = maps:get(<<"lines_added">>, Stats, 0),
    Removed = maps:get(<<"lines_removed">>, Stats, 0),
    Issues = maps:get(<<"issues">>, Stats, []),
    
    Summary = io_lib:format("Changed ~p files (+~p/-~p lines).", [Files, Added, Removed]),
    
    case Issues of
        [] -> iolist_to_binary(Summary);
        _ -> 
            IssueList = lists:map(fun(I) -> binary_to_list(I) end, Issues),
            iolist_to_binary([Summary, " Issues: ", string:join(IssueList, ", ")])
    end.

% Test generation helpers
extract_all_functions(Content, FilePath) ->
    Ext = filename:extension(FilePath),
    extract_functions_by_ext(Ext, Content).

extract_functions_by_ext(".erl", Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^([a-z][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, binary_to_list(Name)};
            _ -> false
        end
    end, Lines);
extract_functions_by_ext(".ex", Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^\\s*defp?\\s+([a-z_][a-zA-Z0-9_?!]*)", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, binary_to_list(Name)};
            _ -> false
        end
    end, Lines);
extract_functions_by_ext(_, _) -> [].

generate_function_tests(FuncName, Content, FilePath, Framework) ->
    Ext = filename:extension(FilePath),
    generate_tests_by_ext(Ext, FuncName, Content, Framework).

generate_tests_by_ext(".erl", FuncName, _Content, <<"eunit">>) ->
    #{
        <<"function">> => list_to_binary(FuncName),
        <<"tests">> => [
            generate_test_case(FuncName, "with valid input"),
            generate_test_case(FuncName, "with edge cases"),
            generate_test_case(FuncName, "with invalid input")
        ],
        <<"code">> => iolist_to_binary(io_lib:format("~s_test() ->~n    % TODO: Add test cases~n    ok.~n", [FuncName]))
    };
generate_tests_by_ext(".ex", FuncName, _Content, <<"exunit">>) ->
    #{
        <<"function">> => list_to_binary(FuncName),
        <<"tests">> => [
            <<"test with valid input">>,
            <<"test with edge cases">>,
            <<"test with invalid input">>
        ],
        <<"code">> => iolist_to_binary(io_lib:format("test \"~s with valid input\" do~n  # TODO: Add test~nend~n", [FuncName]))
    };
generate_tests_by_ext(_, FuncName, _Content, _) ->
    #{
        <<"function">> => list_to_binary(FuncName),
        <<"tests">> => [<<"test case">>],
        <<"code">> => <<"TODO: Add tests">>
    }.

generate_test_case(FuncName, Description) ->
    iolist_to_binary(io_lib:format("~s_~s_test() ->~n    ?assert(true).", [FuncName, string:replace(Description, " ", "_")])).

generate_test_file(FilePath, Tests, Framework) ->
    Ext = filename:extension(FilePath),
    TestFileName = generate_test_filename(FilePath, Ext),
    TestContent = generate_test_content(Ext, Framework, Tests),
    #{
        <<"path">> => TestFileName,
        <<"content">> => TestContent
    }.

generate_test_filename(FilePath, ".erl") when is_binary(FilePath) ->
    BaseName = binary_to_list(filename:basename(binary_to_list(FilePath), ".erl")),
    Dir = binary_to_list(filename:dirname(binary_to_list(FilePath))),
    list_to_binary(filename:join([Dir, "..", "test", BaseName ++ "_tests.erl"]));
generate_test_filename(FilePath, ".ex") when is_binary(FilePath) ->
    BaseName = binary_to_list(filename:basename(binary_to_list(FilePath), ".ex")),
    Dir = binary_to_list(filename:dirname(binary_to_list(FilePath))),
    list_to_binary(filename:join([Dir, "..", "test", BaseName ++ "_test.exs"]));
generate_test_filename(FilePath, _) when is_binary(FilePath) ->
    BaseName = binary_to_list(filename:basename(binary_to_list(FilePath))),
    Dir = binary_to_list(filename:dirname(binary_to_list(FilePath))),
    list_to_binary(filename:join([Dir, "..", "test", "test_" ++ BaseName]));
generate_test_filename(FilePath, Ext) when is_list(FilePath) ->
    generate_test_filename(list_to_binary(FilePath), Ext).

generate_test_content(".erl", <<"eunit">>, Tests) ->
    Includes = <<"-include_lib(\"eunit/include/eunit.hrl\").\n\n">>,
    TestCodes = lists:map(fun(T) -> maps:get(<<"code">>, T, <<>>) end, Tests),
    iolist_to_binary([Includes | TestCodes]);
generate_test_content(".ex", <<"exunit">>, Tests) ->
    Includes = <<"defmodule Test do\n  use ExUnit.Case\n\n">>,
    TestCodes = lists:map(fun(T) -> maps:get(<<"code">>, T, <<>>) end, Tests),
    iolist_to_binary([Includes | TestCodes] ++ [<<"\nend\n">>]);
generate_test_content(_, _, Tests) ->
    TestCodes = lists:map(fun(T) -> maps:get(<<"code">>, T, <<>>) end, Tests),
    iolist_to_binary(TestCodes).
% Documentation Generation Implementation
generate_module_docs(Content, FilePath, Style) ->
    Ext = filename:extension(FilePath),
    Functions = extract_all_functions(Content, FilePath),
    ModuleName = filename:basename(FilePath, filename:extension(FilePath)),
    
    DocStrings = lists:map(fun(FuncName) ->
        generate_doc_string(FuncName, Content, Style)
    end, Functions),
    
    case Style of
        <<"exdoc">> ->
            generate_exdoc_header(ModuleName, DocStrings);
        _ ->
            generate_edoc_header(ModuleName, DocStrings)
    end.

generate_function_docs(FuncName, Content, FilePath, Style) ->
    generate_doc_string(FuncName, Content, Style).

generate_doc_string(FuncName, Content, Style) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    case find_function_lines(FuncName, Lines) of
        {StartLine, EndLine} ->
            FuncCode = extract_function_code(Lines, StartLine, EndLine),
            analyze_function_for_docs(FuncName, FuncCode, Style);
        not_found ->
            #{<<"function">> => list_to_binary(FuncName), <<"doc">> => <<"Function not found">>}
    end.

find_function_lines(FuncName, Lines) ->
    Pattern = "^" ++ FuncName ++ "\\s*\\(",
    find_function_lines(FuncName, Lines, 1, undefined, false).

find_function_lines(_FuncName, [], _Line, _Start, false) ->
    not_found;
find_function_lines(FuncName, [Line | Rest], LineNum, Start, InFunc) ->
    case InFunc of
        true ->
            case is_function_end(Line) of
                true -> {Start, LineNum};
                false -> find_function_lines(FuncName, Rest, LineNum + 1, Start, true)
            end;
        false ->
            case re:run(Line, "^([a-z][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
                {match, [FuncNameBin]} ->
                    case FuncNameBin == list_to_binary(FuncName) of
                        true -> find_function_lines(FuncName, Rest, LineNum + 1, LineNum, true);
                        false -> find_function_lines(FuncName, Rest, LineNum + 1, Start, false)
                    end;
                _ ->
                    find_function_lines(FuncName, Rest, LineNum + 1, Start, false)
            end
    end.

is_function_end(Line) ->
    case Line of
        "." ++ _ -> true;
        _ -> false
    end.

extract_function_code(Lines, StartLine, EndLine) ->
    FuncLines = lists:sublist(Lines, StartLine, EndLine - StartLine + 1),
    list_to_binary(string:join([binary_to_list(L) || L <- FuncLines], "\n")).

analyze_function_for_docs(FuncName, FuncCode, Style) ->
    % Analyze function signature and body to infer doc
    Arity = infer_arity(FuncCode),
    Params = extract_params(FuncCode),
    Returns = infer_return_type(FuncCode),
    
    DocText = generate_doc_from_analysis(FuncName, Params, Returns, Style),
    
    #{
        <<"function">> => list_to_binary(FuncName),
        <<"arity">> => Arity,
        <<"params">> => Params,
        <<"returns">> => Returns,
        <<"doc">> => DocText,
        <<"style">> => Style
    }.

infer_arity(Code) ->
    case re:run(Code, "\\(([A-Z][a-zA-Z0-9_]*(?:\\s*,\\s*[A-Z][a-zA-Z0-9_]*)*)\\)", [{capture, [1], binary}]) of
        {match, [Params]} ->
            ParamList = binary:split(Params, <<",">>, [global]),
            length(ParamList);
        nomatch ->
            case re:run(Code, "\\(\\)", []) of
                {match, _} -> 0;
                nomatch -> 0
            end
    end.

extract_params(Code) ->
    case re:run(Code, "\\(([A-Z][a-zA-Z0-9_]*(?:\\s*,\\s*[A-Z][a-zA-Z0-9_]*)*)\\)", [{capture, [1], binary}]) of
        {match, [Params]} ->
            ParamList = binary:split(Params, <<",">>, [global]),
            [binary:trim(P) || P <- ParamList];
        nomatch -> []
    end.

infer_return_type(Code) ->
    % Simple heuristics for return type
    case Code of
        _ when byte_size(Code) > 0 ->
            case re:run(Code, "\\{([^}]+)\\}") of
                {match, _} -> <<"tuple">>;
                nomatch ->
                    case re:run(Code, "\\[") of
                        {match, _} -> <<"list">>;
                        nomatch ->
                            case re:run(Code, "true|false") of
                                {match, _} -> <<"boolean">>;
                                nomatch -> <<"term()">>
                            end
                    end
            end;
        _ -> <<"term()">>
    end.

generate_doc_from_analysis(FuncName, Params, Returns, <<"edoc">>) ->
    ParamDocs = [io_lib:format("%% @param ~s Description", [P]) || P <- Params],
    ReturnDoc = io_lib:format("%% @returns ~s", [Returns]),
    iolist_to_binary(string:join(ParamDocs ++ [ReturnDoc], "\n"));
generate_doc_from_analysis(FuncName, Params, Returns, <<"exdoc">>) ->
    ParamDocs = [io_lib:format("  * `~s` - Description", [P]) || P <- Params],
    iolist_to_binary(string:join(["```erlang"] ++ ParamDocs ++ ["```", "Returns: " ++ binary_to_list(Returns)], "\n"));
generate_doc_from_analysis(FuncName, Params, Returns, _) ->
    iolist_to_binary(io_lib:format("Function: ~s(~s) -> ~s", [FuncName, string:join([binary_to_list(P) || P <- Params], ", "), Returns])).

generate_edoc_header(ModuleName, DocStrings) ->
    ModuleDoc = io_lib:format("%% @doc TODO: Add module documentation\n-module(~s).\n", [ModuleName]),
    FuncDocs = [io_lib:format("\n%% ~s\n~s(~s) ->\n    TODO.\n", 
                              [maps:get(<<"doc">>, D, <<"">>), 
                               maps:get(<<"function">>, D, <<>>),
                               string:join([binary_to_list(P) || P <- maps:get(<<"params">>, D, [])], ", ")])
                 || D <- DocStrings],
    iolist_to_binary([ModuleDoc | FuncDocs]).

generate_exdoc_header(ModuleName, DocStrings) ->
    ModuleDoc = io_lib:format("@moduledoc \"\"\"TODO: Add module documentation\"\"\"\n\ndefmodule ~s do\n", [ModuleName]),
    FuncDocs = [io_lib:format("\n  @doc \"\"\"~s\"\"\"\n  def ~s(~s) do\n    # TODO: Implement\n  end\n",
                              [maps:get(<<"doc">>, D, <<"">>),
                               maps:get(<<"function">>, D, <<>>),
                               string:join([binary_to_list(P) || P <- maps:get(<<"params">>, D, [])], ", ")])
                 || D <- DocStrings],
    EndModule = "\nend\n",
    iolist_to_binary([ModuleDoc | FuncDocs] ++ [EndModule]).

% Web Docs Fetcher Implementation
fetch_package_docs(Package, Language, Version) ->
    case fetch_docs_impl(binary_to_list(Language), binary_to_list(Package), Version) of
        {ok, Docs} -> #{<<"success">> => true, <<"docs">> => Docs};
        {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(Reason)}
    end.

fetch_docs_impl("erlang", Package, Version) ->
    Url = "https://hex.pm/api/packages/" ++ Package,
    fetch_hex_docs(Url);
fetch_docs_impl("elixir", Package, Version) ->
    Url = "https://hex.pm/api/packages/" ++ Package,
    fetch_hex_docs(Url);
fetch_docs_impl("npm", Package, Version) ->
    Url = "https://registry.npmjs.org/" ++ Package,
    fetch_npm_docs(Url);
fetch_docs_impl("python", Package, Version) ->
    Url = "https://pypi.org/pypi/" ++ Package ++ "/json",
    fetch_pypi_docs(Url);
fetch_docs_impl("rust", Package, Version) ->
    Url = "https://crates.io/api/v1/crates/" ++ Package,
    fetch_crates_docs(Url);
fetch_docs_impl(Lang, Package, _Version) ->
    {error, "Unsupported language: " ++ Lang}.

fetch_hex_docs(Url) ->
    fetch_url(Url, [
        {parse_info, fun(Body) ->
            case jsx:is_json(Body) of
                true ->
                    Data = jsx:decode(Body, [return_maps]),
                    Name = maps:get(<<"name">>, Data, <<>>),
                    #{
                        <<"name">> => Name,
                        <<"description">> => maps:get(<<"description">>, Data, <<>>),
                        <<"version">> => maps:get(<<"latest_version">>, Data, <<>>),
                        <<"docs_url">> => maps:get(<<"docs_html_url">>, Data, <<>>),
                        <<"hex_url">> => <<"https://hex.pm/packages/", Name/binary>>
                    };
                false -> #{<<"error">> => <<"Failed to parse response">>}
            end
        end}]).

fetch_npm_docs(Url) ->
    fetch_url(Url, []).

fetch_pypi_docs(Url) ->
    fetch_url(Url, []).

fetch_crates_docs(Url) ->
    fetch_url(Url, []).

fetch_url(Url, _Opts) ->
    case hackney:get(Url, [], <<>>, [{follow_redirect, true}, {recv_timeout, 10000}]) of
        {ok, 200, _Headers, Body} ->
            SafeBody = safe_binary(Body),
            case jsx:is_json(SafeBody) of
                true ->
                    Data = jsx:decode(SafeBody, [return_maps]),
                    #{
                        <<"success">> => true,
                        <<"name">> => maps:get(<<"name">>, Data, <<>>),
                        <<"description">> => safe_binary(maps:get(<<"description">>, Data, <<>>)),
                        <<"version">> => maps:get(<<"version">>, Data, maps:get(<<"latest_version">>, Data, <<>>)),
                        <<"url">> => list_to_binary(Url)
                    };
                false ->
                    #{<<"success">> => true, <<"content">> => SafeBody, <<"url">> => list_to_binary(Url)}
            end;
        {ok, Status, _Headers, _Body} ->
            {error, "HTTP error: " ++ integer_to_list(Status)};
        {error, Reason} ->
            {error, "Request failed: " ++ atom_to_list(Reason)}
    end.

% Refactoring Implementation
rename_in_file(FilePath, OldName, NewName, Content) ->
    _ = create_backup_internal(FilePath),
    
    % Simple token-based rename (preserves exact matches)
    ContentList = binary_to_list(Content),
    Pattern = "\\b" ++ OldName ++ "\\b",
    {ok, MP} = re:compile(Pattern),
    NewContent = re:replace(ContentList, MP, NewName, [global, {return, list}]),
    
    case file:write_file(FilePath, list_to_binary(NewContent)) of
        ok -> 
            #{
                <<"success">> => true,
                <<"file">> => list_to_binary(FilePath),
                <<"old_name">> => list_to_binary(OldName),
                <<"new_name">> => list_to_binary(NewName),
                <<"scope">> => <<"file">>
            };
        {error, Reason} ->
            restore_backup_internal(FilePath),
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

rename_in_project(FilePath, OldName, NewName) ->
    % Find all files in project
    Ext = filename:extension(FilePath),
    Files = case Ext of
        ".erl" -> filelib:wildcard("src/**/*.erl");
        ".ex" -> filelib:wildcard("lib/**/*.ex");
        _ -> filelib:wildcard("**/*" ++ Ext)
    end,
    
    Results = lists:filtermap(fun(F) ->
        case file:read_file(F) of
            {ok, Content} ->
                case re:run(Content, "\\b" ++ OldName ++ "\\b") of
                    {match, _} ->
                        case rename_in_file(F, OldName, NewName, Content) of
                            #{<<"success">> := true} = Result -> {true, Result};
                            Error -> {true, Error}
                        end;
                    nomatch -> false
                end;
            _ -> false
        end
    end, Files),
    
    #{
        <<"success">> => true,
        <<"old_name">> => list_to_binary(OldName),
        <<"new_name">> => list_to_binary(NewName),
        <<"files_modified">> => length(Results),
        <<"changes">> => Results
    }.

extract_function_impl(FilePath, Content, StartLine, EndLine, FuncName) ->
    _ = create_backup_internal(FilePath),
    
    Lines = binary:split(Content, <<"\n">>, [global]),
    ExtractedLines = lists:sublist(Lines, StartLine, EndLine - StartLine + 1),
    ExtractedCode = string:join([binary_to_list(L) || L <- ExtractedLines], "\n"),
    
    % Infer parameters from extracted code
    Params = extract_params(list_to_binary(ExtractedCode)),
    ParamList = string:join([binary_to_list(P) || P <- Params], ", "),
    
    % Create new function
    NewFunc = io_lib:format("~s(~s) ->\n~s.\n", [FuncName, ParamList, "    " ++ ExtractedCode]),
    
    % Insert new function after extracted code
    BeforeLines = lists:sublist(Lines, 1, StartLine - 1),
    AfterLines = lists:sublist(Lines, EndLine + 1, length(Lines) - EndLine),
    CallCode = io_lib:format("~s(~s)", [FuncName, ParamList]),
    
    NewContent = string:join([binary_to_list(L) || L <- BeforeLines] ++ [CallCode] ++ [binary_to_list(L) || L <- AfterLines], "\n"),
    
    % Write modified content
    case file:write_file(FilePath, list_to_binary(NewContent)) of
        ok ->
            #{
                <<"success">> => true,
                <<"file">> => list_to_binary(FilePath),
                <<"new_function">> => list_to_binary(FuncName),
                <<"function_code">> => list_to_binary(NewFunc),
                <<"lines_extracted">> => EndLine - StartLine + 1
            };
        {error, Reason} ->
            restore_backup_internal(FilePath),
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

% Multi-file Context Implementation
load_smart_context(FilePath, IncludeTests, IncludeDeps, MaxFiles) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            % Find imports and dependencies
            Imports = extract_imports(FilePath, Content),
            RelatedFiles = find_related_files(FilePath, Imports, IncludeTests, MaxFiles),
            
            % Load content of related files
            LoadedFiles = lists:filtermap(fun(RelPath) ->
                case file:read_file(RelPath) of
                    {ok, RelContent} -> 
                        {true, #{
                            <<"path">> => list_to_binary(RelPath),
                            <<"content">> => RelContent,
                            <<"relation">> => determine_relation(RelPath, FilePath)
                        }};
                    _ -> false
                end
            end, RelatedFiles),
            
            #{
                <<"success">> => true,
                <<"primary_file">> => list_to_binary(FilePath),
                <<"related_files">> => LoadedFiles,
                <<"imports">> => Imports
            };
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

extract_imports(FilePath, Content) ->
    Ext = filename:extension(FilePath),
    extract_imports_by_ext(Ext, Content, FilePath).

extract_imports_by_ext(".erl", Content, _FilePath) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "-include_lib\\(\"([^\"]+)\"", [{capture, [1], binary}]) of
            {match, [Lib]} -> {true, Lib};
            _ ->
                case re:run(Line, "-include\\(\"([^\"]+)\"", [{capture, [1], binary}]) of
                    {match, [Inc]} -> {true, Inc};
                    _ -> false
                end
        end
    end, Lines);

extract_imports_by_ext(".ex", Content, _FilePath) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "use\\s+([A-Z][a-zA-Z.]+)", [{capture, [1], binary}]) of
            {match, [Module]} -> {true, Module};
            _ ->
                case re:run(Line, "import\\s+([A-Z][a-zA-Z.]+)", [{capture, [1], binary}]) of
                    {match, [Module]} -> {true, Module};
                    _ -> false
                end
        end
    end, Lines);

extract_imports_by_ext(_, _, _) -> [].

find_related_files(FilePath, Imports, IncludeTests, MaxFiles) ->
    Dir = filename:dirname(FilePath),
    Ext = filename:extension(FilePath),
    
    % Find files matching imports
    ImportFiles = find_import_files(Imports, Dir, Ext),
    
    % Find test files
    TestFiles = case IncludeTests of
        true -> find_test_files(FilePath);
        false -> []
    end,
    
    % Merge and limit
    AllFiles = lists:usort(ImportFiles ++ TestFiles),
    lists:sublist(AllFiles, MaxFiles).

find_import_files(Imports, Dir, Ext) ->
    lists:filtermap(fun(Import) ->
        case Ext of
            ".erl" ->
                % Convert module name to file path
                ModulePath = string:replace(binary_to_list(Import), ".", "/") ++ ".erl",
                FullPath = filename:join([Dir, ModulePath]),
                case filelib:is_file(FullPath) of
                    true -> {true, FullPath};
                    _ -> false
                end;
            ".ex" ->
                ModulePath = string:replace(binary_to_list(Import), ".", "/") ++ ".ex",
                FullPath = filename:join([Dir, "lib", ModulePath]),
                case filelib:is_file(FullPath) of
                    true -> {true, FullPath};
                    _ -> false
                end;
            _ -> false
        end
    end, Imports).

find_test_files(FilePath) ->
    BaseName = filename:basename(FilePath, filename:extension(FilePath)),
    Ext = filename:extension(FilePath),
    
    TestPattern = case Ext of
        ".erl" -> "**/" ++ BaseName ++ "_tests.erl";
        ".ex" -> "**/" ++ BaseName ++ "_test.exs";
        _ -> "**/test_" ++ BaseName ++ "*"
    end,
    
    filelib:wildcard(TestPattern).

determine_relation(RelPath, PrimaryPath) ->
    case filename:extension(RelPath) of
        ".erl" ->
            Name = filename:basename(RelPath, ".erl"),
            PrimaryName = filename:basename(PrimaryPath, ".erl"),
            case Name of
                PrimaryName -> <<"self">>;
                _ ->
                    case string:find(Name, "_test") of
                        nomatch -> case string:find(Name, "_tests") of
                            nomatch -> <<"import">>;
                            _ -> <<"test">>
                        end;
                        _ -> <<"test">>
                    end
            end;
        ".ex" ->
            Name2 = filename:basename(RelPath, ".ex"),
            case string:find(Name2, "_test") of
                nomatch -> <<"import">>;
                _ -> <<"test">>
            end;
        _ -> <<"related">>
    end.

% Find References Implementation
find_symbol_references(FilePath, Symbol, _Line) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            Pattern = "\\b" ++ Symbol ++ "\\b",
            {ok, MP} = re:compile(Pattern),
            
            Lines = binary:split(Content, <<"\n">>, [global]),
            References = lists:filtermap(fun({LineNum, LineContent}) ->
                case re:run(LineContent, MP) of
                    {match, Matches} ->
                        {true, #{
                            <<"line">> => LineNum,
                            <<"content">> => LineContent,
                            <<"matches">> => length(Matches)
                        }};
                    nomatch -> false
                end
            end, lists:enumerate(1, Lines)),
            
            #{
                <<"success">> => true,
                <<"file">> => list_to_binary(FilePath),
                <<"symbol">> => list_to_binary(Symbol),
                <<"references">> => References,
                <<"count">> => length(References)
            };
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

find_function_callers(FilePath, Function) ->
    Ext = filename:extension(FilePath),
    Dir = filename:dirname(FilePath),
    
    Pattern = "\\b" ++ Function ++ "\\s*\\(",
    {ok, MP} = re:compile(Pattern),
    
    Files = case Ext of
        ".erl" -> filelib:wildcard(filename:join([Dir, "**/*.erl"]));
        ".ex" -> filelib:wildcard(filename:join([Dir, "**/*.ex"]));
        _ -> filelib:wildcard(filename:join([Dir, "**/*" ++ Ext]))
    end,
    
    Callers = lists:filtermap(fun(File) ->
        case file:read_file(File) of
            {ok, Content} ->
                case re:run(Content, MP) of
                    {match, _} ->
                        {true, #{
                            <<"file">> => list_to_binary(File),
                            <<"function">> => list_to_binary(Function)
                        }};
                    nomatch -> false
                end;
            _ -> false
        end
    end, Files),
    
    #{
        <<"success">> => true,
        <<"function">> => list_to_binary(Function),
        <<"callers">> => Callers,
        <<"count">> => length(Callers)
    }.
