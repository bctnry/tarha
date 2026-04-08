-module(coding_agent_tools).
-export([tools/0, execute/2, execute_concurrent/1]).
-export([create_backup/1, restore_backup/1, list_backups/0, clear_backups/0]).
-export([http_request/1, http_request/2]).
-export([set_progress_callback/1, set_safety_callback/1]).
-export([get_log/0, clear_log/0]).
-export([start_lsp/1, start_index/1]).
-export([safe_binary/1, safe_binary/2]).
-export([sanitize_path/1, find_occurrences/2, replace_all/3]).
-export([contains_merge_conflict/1, resolve_conflicts/2, resolve_conflicts_with_strategy/2]).
-export([detect_change_type/1, analyze_diff/1, detect_issues/1, generate_suggestions/1]).
-export([format_undo_results/1, limit_grep_output/2, clean_output/1]).
%% New exports for sub-module access
-export([run_command_impl/3, resolve_conflicts_in_file/2]).
-export([report_progress/3, log_operation/3, safety_check/2]).
-include_lib("kernel/include/file.hrl").

-define(BACKUP_DIR, ".tarha/backups").
-define(MAX_BACKUPS, 50).
-define(OPS_LOG, coding_agent_ops_log).
-define(MAX_TEXT_SIZE, 20000).
-define(PROGRESS_CALLBACK, coding_agent_progress_cb).
-define(SAFETY_CALLBACK, coding_agent_safety_cb).

%%===================================================================
%% safe_binary — shared text sanitization
%%===================================================================

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
    safe_binary_any(Input, ?MAX_TEXT_SIZE).

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
        _:_ -> safe_binary_any(Input, MaxSize)
    end;
safe_binary(Input, _MaxSize) ->
    safe_binary(Input).

safe_binary_any(Term, MaxSize) ->
    try
        Flat = flatten_term(Term, MaxSize * 2),
        Bin = unicode:characters_to_binary(Flat),
        case byte_size(Bin) of
            Size when Size > MaxSize ->
                <<First:MaxSize/binary, _/binary>> = Bin,
                <<First/binary, "... (truncated)">>;
            _ -> Bin
        end
    catch
        _:_ -> <<"[term too large to serialize]">>
    end.

flatten_term(Bin, _MaxSize) when is_binary(Bin) -> Bin;
flatten_term(Int, _MaxSize) when is_integer(Int) -> integer_to_binary(Int);
flatten_term(Float, _MaxSize) when is_float(Float) -> float_to_binary(Float);
flatten_term(Atom, _MaxSize) when is_atom(Atom) -> atom_to_binary(Atom);
flatten_term([], _MaxSize) -> <<"[]">>;
flatten_term({}, _MaxSize) -> <<"{}">>;
flatten_term(List, MaxSize) when is_list(List) ->
    case is_flat_string(List) of
        true -> List;
        false -> flatten_list(List, MaxSize, 0, [])
    end;
flatten_term(Map, MaxSize) when is_map(Map) ->
    flatten_map(maps:to_list(Map), MaxSize);
flatten_term(Tuple, MaxSize) when is_tuple(Tuple) ->
    flatten_tuple(tuple_to_list(Tuple), MaxSize);
flatten_term(Term, _MaxSize) ->
    io_lib:format("~w", [Term]).

is_flat_string([]) -> true;
is_flat_string([H|T]) when is_integer(H), H >= 0, H =< 255 -> is_flat_string(T);
is_flat_string(_) -> false.

flatten_list([], _MaxSize, _Size, Acc) -> lists:reverse(Acc);
flatten_list(_, MaxSize, Size, Acc) when Size > MaxSize -> 
    lists:reverse([<<"...">> | Acc]);
flatten_list([H|T], MaxSize, Size, Acc) ->
    Flat = flatten_term(H, MaxSize),
    NewSize = safe_iolist_size(Flat),
    flatten_list(T, MaxSize, Size + NewSize, [Flat, <<" ">> | Acc]).

flatten_map([], _MaxSize) -> <<"#{}">>;
flatten_map(Pairs, MaxSize) ->
    FlatPairs = flatten_map_pairs(Pairs, MaxSize, []),
    [<<"#{">>, FlatPairs, <<"}">>].

flatten_map_pairs([], _MaxSize, Acc) -> lists:reverse(Acc);
flatten_map_pairs([{K, V}|Rest], MaxSize, Acc) ->
    FlatK = flatten_term(K, MaxSize),
    FlatV = flatten_term(V, MaxSize),
    Pair = [FlatK, <<" => ">>, FlatV],
    flatten_map_pairs(Rest, MaxSize, [Pair, <<", ">> | Acc]).

flatten_tuple(Elems, MaxSize) ->
    FlatElems = flatten_list(Elems, MaxSize, 0, []),
    [<<"{">>, FlatElems, <<"}">>].

safe_iolist_size(Bin) when is_binary(Bin) -> byte_size(Bin);
safe_iolist_size(Int) when is_integer(Int) -> 1;
safe_iolist_size([]) -> 0;
safe_iolist_size([H|T]) -> safe_iolist_size(H) + safe_iolist_size(T);
safe_iolist_size(_) -> 0.

%%===================================================================
%% Callback setters
%%===================================================================

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

%%===================================================================
%% tools/0 — tool schema
%%===================================================================
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
        % Undo/Redo Stack
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"undo">>,
                <<"description">> => <<"Undo the last operation (file edit, etc.). Reverts changes using backup system.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"count">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Number of operations to undo (default: 1)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"redo">>,
                <<"description">> => <<"Redo a previously undone operation. Restores changes that were reverted.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"count">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Number of operations to redo (default: 1)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"undo_history">>,
                <<"description">> => <<"Get the history of operations that can be undone. Shows recent edit operations.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"count">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Number of operations to show (default: 10)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"begin_transaction">>,
                <<"description">> => <<"Begin a transaction for grouping multiple file edits as a single undo unit. All edits until end_transaction will be undone/redone together.">>,
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
                <<"name">> => <<"end_transaction">>,
                <<"description">> => <<"End the current transaction and push it as a single undo unit. All grouped edits are now treated as one operation for undo/redo.">>,
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
                <<"name">> => <<"cancel_transaction">>,
                <<"description">> => <<"Cancel the current transaction without pushing it to the undo stack. Useful for error recovery.">>,
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
        % Merge Conflict Resolution
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"resolve_merge_conflicts">>,
                <<"description">> => <<"Resolve git merge conflicts in files. Can auto-resolve using 'ours', 'theirs', or 'both' strategy.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"file">> => #{<<"type">> => <<"string">>, <<"description">> => <<"File to resolve conflicts in (optional, resolves all if not specified)">>},
                        <<"strategy">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Resolution strategy: 'ours' (keep current), 'theirs' (keep incoming), 'both' (keep both), 'smart' (prefer non-empty, default: smart)">>}
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
        },
        % HTTP Client
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"http_request">>,
                <<"description">> => <<"Make an HTTP request to any URL. Supports GET, POST, PUT, DELETE, PATCH methods with headers and body.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"url">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The URL to request">>},
                        <<"method">> => #{<<"type">> => <<"string">>, <<"description">> => <<"HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS). Default: GET">>},
                        <<"headers">> => #{<<"type">> => <<"object">>, <<"description">> => <<"HTTP headers as key-value pairs">>},
                        <<"body">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Request body (for POST, PUT, PATCH)">>},
                        <<"timeout">> => #{<<"type">> => <<"integer">>, <<"description">> => <<"Timeout in milliseconds (default: 30000)">>},
                        <<"follow_redirect">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Follow redirects (default: true)">>},
                        <<"response_format">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Response format: 'json', 'text', 'binary'. Default: auto-detect">>}
                    },
                    <<"required">> => [<<"url">>]
                }
            }
        },
        % Model Management
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"list_models">>,
                <<"description">> => <<"List all available Ollama models. Returns model names, sizes, and details.">>,
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
                <<"name">> => <<"switch_model">>,
                <<"description">> => <<"Switch the current Ollama model. Updates the model configuration for subsequent requests.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"model">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The model name to switch to (e.g., 'llama3', 'qwen2.5', 'glm-5:cloud')">>}
                    },
                    <<"required">> => [<<"model">>]
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"show_model">>,
                <<"description">> => <<"Show detailed information about an Ollama model including parameters, capabilities, architecture, context length, and more.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"model">> => #{<<"type">> => <<"string">>, <<"description">> => <<"The model name to show details for (e.g., 'llama3', 'gemma3')">>},
                        <<"verbose">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"If true, includes large verbose fields in the response (default: false)">>}
                    },
                    <<"required">> => [<<"model">>]
                }
            }
        },
        % Parallel Execution
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"execute_parallel">>,
                <<"description">> => <<"Execute multiple tool calls in parallel. Use this when you need to run independent operations concurrently for better performance.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"calls">> => #{
                            <<"type">> => <<"array">>,
                            <<"description">> => <<"Array of tool calls to execute in parallel. Each call is an object with 'name' (tool name) and 'args' (arguments object).">>,
                            <<"items">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{
                                    <<"name">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Tool name to call">>},
                                    <<"args">> => #{<<"type">> => <<"object">>, <<"description">> => <<"Arguments for the tool call">>}
                                },
                                <<"required">> => [<<"name">>, <<"args">>]
                            }
                        }
                    },
                    <<"required">> => [<<"calls">>]
                }
            }
        },
        % Skills
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"list_skills">>,
                <<"description">> => <<"List available skills. Skills are markdown files that provide specialized knowledge and instructions.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"available_only">> => #{<<"type">> => <<"boolean">>, <<"description">> => <<"Only show skills whose requirements are met (default: false)">>}
                    },
                    <<"required">> => []
                }
            }
        },
        #{
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"load_skill">>,
                <<"description">> => <<"Load and read a skill's content by name. Returns the full SKILL.md content.">>,
                <<"parameters">> => #{
                    <<"type">> => <<"object">>,
                    <<"properties">> => #{
                        <<"name">> => #{<<"type">> => <<"string">>, <<"description">> => <<"Skill name (directory name in priv/skills/ or skills/)">>}
                    },
                    <<"required">> => [<<"name">>]
                }
            }
        }
    ].

% Execute multiple tools concurrently (for parallel operations)

%%===================================================================
%% execute_concurrent/1 — parallel tool execution
%%===================================================================

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

%%===================================================================
%% Logging, progress, and safety — shared infrastructure
%%===================================================================

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

report_progress(Operation, Status, Data) ->
    case erlang:get(?PROGRESS_CALLBACK) of
        undefined -> ok;
        Fun when is_function(Fun, 3) ->
            try Fun(Operation, Status, Data) catch _:_ -> ok end
    end.

safety_check(Operation, Args) ->
    case erlang:get(?SAFETY_CALLBACK) of
        undefined -> proceed;
        Fun when is_function(Fun, 2) ->
            try Fun(Operation, Args) catch _:_ -> proceed end
    end.

%%===================================================================
%% execute/2 — dispatch to sub-modules
%%===================================================================

% File Operations -> coding_agent_tools_file
execute(<<"read_file">>, Args) -> coding_agent_tools_file:execute(<<"read_file">>, Args);
execute(<<"edit_file">>, Args) -> coding_agent_tools_file:execute(<<"edit_file">>, Args);
execute(<<"write_file">>, Args) -> coding_agent_tools_file:execute(<<"write_file">>, Args);
execute(<<"create_directory">>, Args) -> coding_agent_tools_file:execute(<<"create_directory">>, Args);
execute(<<"list_files">>, Args) -> coding_agent_tools_file:execute(<<"list_files">>, Args);
execute(<<"file_exists">>, Args) -> coding_agent_tools_file:execute(<<"file_exists">>, Args);

% Git Operations -> coding_agent_tools_git
execute(<<"git_status">>, Args) -> coding_agent_tools_git:execute(<<"git_status">>, Args);
execute(<<"git_diff">>, Args) -> coding_agent_tools_git:execute(<<"git_diff">>, Args);
execute(<<"git_log">>, Args) -> coding_agent_tools_git:execute(<<"git_log">>, Args);
execute(<<"git_add">>, Args) -> coding_agent_tools_git:execute(<<"git_add">>, Args);
execute(<<"git_commit">>, Args) -> coding_agent_tools_git:execute(<<"git_commit">>, Args);
execute(<<"git_branch">>, Args) -> coding_agent_tools_git:execute(<<"git_branch">>, Args);

% Search Operations -> coding_agent_tools_search
execute(<<"grep_files">>, Args) -> coding_agent_tools_search:execute(<<"grep_files">>, Args);
execute(<<"find_files">>, Args) -> coding_agent_tools_search:execute(<<"find_files">>, Args);

% Undo/Backup Operations -> coding_agent_tools_undo
execute(<<"undo_edit">>, Args) -> coding_agent_tools_undo:execute(<<"undo_edit">>, Args);
execute(<<"list_backups">>, Args) -> coding_agent_tools_undo:execute(<<"list_backups">>, Args);
execute(<<"undo">>, Args) -> coding_agent_tools_undo:execute(<<"undo">>, Args);
execute(<<"redo">>, Args) -> coding_agent_tools_undo:execute(<<"redo">>, Args);
execute(<<"undo_history">>, Args) -> coding_agent_tools_undo:execute(<<"undo_history">>, Args);
execute(<<"begin_transaction">>, Args) -> coding_agent_tools_undo:execute(<<"begin_transaction">>, Args);
execute(<<"end_transaction">>, Args) -> coding_agent_tools_undo:execute(<<"end_transaction">>, Args);
execute(<<"cancel_transaction">>, Args) -> coding_agent_tools_undo:execute(<<"cancel_transaction">>, Args);

% Build/Test Operations -> coding_agent_tools_build
execute(<<"run_tests">>, Args) -> coding_agent_tools_build:execute(<<"run_tests">>, Args);
execute(<<"run_build">>, Args) -> coding_agent_tools_build:execute(<<"run_build">>, Args);
execute(<<"run_linter">>, Args) -> coding_agent_tools_build:execute(<<"run_linter">>, Args);
execute(<<"detect_project">>, Args) -> coding_agent_tools_build:execute(<<"detect_project">>, Args);

% Command/HTTP Operations -> coding_agent_tools_command
execute(<<"run_command">>, Args) -> coding_agent_tools_command:execute(<<"run_command">>, Args);
execute(<<"http_request">>, Args) -> coding_agent_tools_command:execute(<<"http_request">>, Args);
execute(<<"execute_parallel">>, Args) -> coding_agent_tools_command:execute(<<"execute_parallel">>, Args);

% Refactor/Smart Operations -> coding_agent_tools_refactor
execute(<<"smart_commit">>, Args) -> coding_agent_tools_refactor:execute(<<"smart_commit">>, Args);
execute(<<"resolve_merge_conflicts">>, Args) -> coding_agent_tools_refactor:execute(<<"resolve_merge_conflicts">>, Args);
execute(<<"review_changes">>, Args) -> coding_agent_tools_refactor:execute(<<"review_changes">>, Args);
execute(<<"generate_tests">>, Args) -> coding_agent_tools_refactor:execute(<<"generate_tests">>, Args);

% Self-Modification -> coding_agent_tools_self
execute(<<"reload_module">>, Args) -> coding_agent_tools_self:execute(<<"reload_module">>, Args);
execute(<<"get_self_modules">>, Args) -> coding_agent_tools_self:execute(<<"get_self_modules">>, Args);
execute(<<"analyze_self">>, Args) -> coding_agent_tools_self:execute(<<"analyze_self">>, Args);
execute(<<"deploy_module">>, Args) -> coding_agent_tools_self:execute(<<"deploy_module">>, Args);
execute(<<"create_checkpoint">>, Args) -> coding_agent_tools_self:execute(<<"create_checkpoint">>, Args);
execute(<<"restore_checkpoint">>, Args) -> coding_agent_tools_self:execute(<<"restore_checkpoint">>, Args);
execute(<<"list_checkpoints">>, Args) -> coding_agent_tools_self:execute(<<"list_checkpoints">>, Args);

% Model Operations -> coding_agent_tools_model
execute(<<"list_models">>, Args) -> coding_agent_tools_model:execute(<<"list_models">>, Args);
execute(<<"switch_model">>, Args) -> coding_agent_tools_model:execute(<<"switch_model">>, Args);
execute(<<"show_model">>, Args) -> coding_agent_tools_model:execute(<<"show_model">>, Args);

% Search -> coding_agent_tools_search (additional)
execute(<<"find_references">>, Args) -> coding_agent_tools_search:execute(<<"find_references">>, Args);
execute(<<"get_callers">>, Args) -> coding_agent_tools_search:execute(<<"get_callers">>, Args);

% Refactor -> coding_agent_tools_refactor (additional)
execute(<<"rename_symbol">>, Args) -> coding_agent_tools_refactor:execute(<<"rename_symbol">>, Args);
execute(<<"extract_function">>, Args) -> coding_agent_tools_refactor:execute(<<"extract_function">>, Args);
execute(<<"generate_docs">>, Args) -> coding_agent_tools_refactor:execute(<<"generate_docs">>, Args);

% Command -> coding_agent_tools_command (additional)
execute(<<"fetch_docs">>, Args) -> coding_agent_tools_command:execute(<<"fetch_docs">>, Args);
execute(<<"load_context">>, Args) -> coding_agent_tools_command:execute(<<"load_context">>, Args);

% Skills -> coding_agent_tools_skills
execute(<<"list_skills">>, Args) -> coding_agent_tools_skills:execute(<<"list_skills">>, Args);
execute(<<"load_skill">>, Args) -> coding_agent_tools_skills:execute(<<"load_skill">>, Args);

% Inline (trivial)
execute(<<"hello">>, _Args) ->
    io:format("hello world~n"),
    #{<<"success">> => true, <<"message">> => <<"hello world">>};

% Catch-all
execute(_Tool, _Args) ->
    #{<<"success">> => false, <<"error">> => <<"Unknown tool">>}.

%%===================================================================
%% http_request — delegates to command module
%%===================================================================

http_request(Url) ->
    coding_agent_tools_command:http_request(Url).

http_request(Url, Opts) ->
    coding_agent_tools_command:http_request(Url, Opts).

%%===================================================================
%% Backup public API
%%===================================================================

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

%%===================================================================
%% Shared utilities (exported — called by sub-modules)
%%===================================================================

sanitize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
sanitize_path(Path) when is_list(Path) ->
    Path.

find_occurrences(Content, Pattern) ->
    length(binary:matches(list_to_binary(Content), list_to_binary(Pattern))).

replace_all(Content, Old, New) ->
    binary_to_list(binary:replace(list_to_binary(Content), list_to_binary(Old), list_to_binary(New), [global])).

contains_merge_conflict(Cmd) when is_list(Cmd) ->
    lists:any(fun(Pattern) -> string:str(Cmd, Pattern) > 0 end,
              ["<<<<<<<", "=======", ">>>>>>>"]);
contains_merge_conflict(Cmd) when is_binary(Cmd) ->
    contains_merge_conflict(binary_to_list(Cmd));
contains_merge_conflict(_) -> false.

resolve_conflicts(Content, <<"ours">>) ->
    resolve_conflicts_with_strategy(Content, ours);
resolve_conflicts(Content, <<"theirs">>) ->
    resolve_conflicts_with_strategy(Content, theirs);
resolve_conflicts(Content, <<"both">>) ->
    resolve_conflicts_with_strategy(Content, both);
resolve_conflicts(Content, <<"smart">>) ->
    resolve_conflicts_with_strategy(Content, smart);
resolve_conflicts(Content, _) ->
    resolve_conflicts_with_strategy(Content, smart).

resolve_conflicts_with_strategy(Content, Strategy) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    ResolvedLines = resolve_conflict_lines(Lines, Strategy, [], false, []),
    iolist_to_binary(lists:join(<<"\n">>, ResolvedLines)).

resolve_conflicts_in_file(FilePath, Strategy) ->
    case file:read_file(FilePath) of
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("Cannot read file: ~p", [Reason]))};
        {ok, Content} ->
            Resolved = resolve_conflicts(Content, Strategy),
            case Resolved =:= Content of
                true ->
                    {ok, <<"no_change">>};
                false ->
                    case file:write_file(FilePath, Resolved) of
                        ok ->
                            {ok, Strategy};
                        {error, Reason} ->
                            {error, list_to_binary(io_lib:format("Cannot write file: ~p", [Reason]))}
                    end
            end
    end.

run_command_impl(Cmd, _Timeout, Cwd) ->
    case contains_merge_conflict(Cmd) of
        true ->
            #{<<"success">> => false, 
              <<"error">> => <<"Command contains merge conflict markers (<<<<<<<, =======, >>>>>>>). Please resolve conflicts first.">>};
        false ->
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
            end
    end.

detect_change_type(Diff) ->
    Lines = string:split(Diff, "\n", all),
    Files = lists:filtermap(fun(Line) ->
        case string:prefix(Line, "diff --git a/") of
            nomatch -> false;
            Rest -> {true, filename:basename(string:trim(Rest))}
        end
    end, Lines),
    HasTest = lists:any(fun(F) -> string:find(F, "test") =/= nomatch end, Files),
    HasDoc = lists:any(fun(F) -> 
        string:find(F, "doc") =/= nomatch orelse 
        lists:suffix("README.md", F) orelse
        lists:suffix("CHANGELOG.md", F)
    end, Files),
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

format_undo_results(Results) when is_list(Results) ->
    lists:map(fun
        ({ok, OpId}) -> #{<<"status">> => <<"ok">>, <<"operation_id">> => OpId};
        ({error, Path, Reason}) -> #{<<"status">> => <<"error">>, <<"path">> => list_to_binary(Path), <<"reason">> => list_to_binary(io_lib:format("~p", [Reason]))};
        ({error, Err}) -> #{<<"status">> => <<"error">>, <<"reason">> => list_to_binary(io_lib:format("~p", [Err]))}
    end, Results);
format_undo_results(_) ->
    [].

limit_grep_output(Output, MaxLines) when is_binary(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    case length(Lines) > MaxLines of
        true ->
            Limited = lists:sublist(Lines, MaxLines),
            Omitted = length(Lines) - MaxLines,
            iolist_to_binary([Limited, <<"\n... (">>, integer_to_binary(Omitted), <<" more lines omitted)">>]);
        false ->
            Output
    end.

clean_output(String) when is_binary(String) ->
    MaxSize = 50000,
    Cleaned = try
        re:replace(String, "\\x1b\\[[0-9;]*[a-zA-Z]", "", [global, {return, binary}])
    catch
        _:_ -> String
    end,
    case byte_size(Cleaned) of
        Size when Size > MaxSize ->
            <<Short:MaxSize/binary, _/binary>> = Cleaned,
            <<Short/binary, "... (truncated)">>;
        _ -> Cleaned
    end;
clean_output(String) when is_list(String) ->
    MaxSize = 50000,
    case io_lib:printable_unicode_list(String) of
        true -> 
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
            case String of
                [] -> <<"[]">>;
                _ when is_list(hd(String)) ->
                    MaxItems = 100,
                    Limited = lists:sublist(String, MaxItems),
                    unicode:characters_to_binary(io_lib:format("[list of ~p items, showing first ~p]", [length(String), length(Limited)]));
                _ ->
                    try
                        unicode:characters_to_binary(io_lib:format("~w", [String]))
                    catch
                        _:_ -> <<"[unprintable data]">>
                    end
            end
    end;
clean_output(Other) ->
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

%%===================================================================
%% Internal helpers (not exported — used by backup API and conflict resolution)
%%===================================================================

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
            push_to_undo_stack(Path, BackupPath),
            {ok, BackupPath};
        {error, Reason} -> {error, file:format_error(Reason)}
    end.

push_to_undo_stack(Path, BackupPath) ->
    case whereis(coding_agent_undo) of
        undefined -> 
            ok;
        _Pid ->
            Op = #{
                type => edit,
                description => iolist_to_binary(io_lib:format("Edit ~s", [filename:basename(Path)])),
                files => [{Path, BackupPath}]
            },
            coding_agent_undo:push(Op, #{})
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

resolve_conflict_lines([], _Strategy, _CurrentBlock, _InConflict, Acc) ->
    lists:reverse(Acc);
resolve_conflict_lines([Line | Rest], Strategy, CurrentBlock, InConflict, Acc) ->
    case {InConflict, binary:match(Line, <<"<<<<<<<">>)} of
        {false, nomatch} ->
            resolve_conflict_lines(Rest, Strategy, [], false, [Line | Acc]);
        {false, _} ->
            resolve_conflict_lines(Rest, Strategy, [], true, Acc);
        {true, _} ->
            case binary:match(Line, <<"=======">>) of
                nomatch ->
                    resolve_conflict_lines(Rest, Strategy, [Line | CurrentBlock], true, Acc);
                _ ->
                    {Ours, _Rest1} = collect_ours_section(CurrentBlock, []),
                    {Theirs, Rest2} = collect_theirs_section(Rest, []),
                    ResolvedLine = resolve_conflict_block(Ours, Theirs, Strategy),
                    resolve_conflict_lines(Rest2, Strategy, [], false, [ResolvedLine | Acc])
            end
    end.

collect_ours_section([], Acc) -> {lists:reverse(Acc), []};
collect_ours_section([Line | Rest], Acc) ->
    case binary:match(Line, <<"=======">>) of
        nomatch -> collect_ours_section(Rest, [Line | Acc]);
        _ -> {lists:reverse(Acc), Rest}
    end.

collect_theirs_section([], Acc) -> {lists:reverse(Acc), []};
collect_theirs_section([Line | Rest], Acc) ->
    case binary:match(Line, <<">>>>>>>">>) of
        nomatch -> collect_theirs_section(Rest, [Line | Acc]);
        _ -> {lists:reverse(Acc), Rest}
    end.

resolve_conflict_block(Ours, _Theirs, ours) ->
    iolist_to_binary(lists:join(<<"\n">>, Ours));
resolve_conflict_block(_Ours, Theirs, theirs) ->
    iolist_to_binary(lists:join(<<"\n">>, Theirs));
resolve_conflict_block(Ours, Theirs, both) ->
    All = Ours ++ Theirs,
    iolist_to_binary(lists:join(<<"\n">>, All));
resolve_conflict_block(Ours, Theirs, smart) ->
    case {Ours, Theirs} of
        {[], Theirs} -> iolist_to_binary(lists:join(<<"\n">>, Theirs));
        {Ours, []} -> iolist_to_binary(lists:join(<<"\n">>, Ours));
        {Ours, Theirs} ->
            OursContent = iolist_to_binary(lists:join(<<"\n">>, Ours)),
            TheirsContent = iolist_to_binary(lists:join(<<"\n">>, Theirs)),
            HasImport = fun(C) -> binary:match(C, <<"import">>) =/= nomatch 
                                      orelse binary:match(C, <<"-include">>) =/= nomatch end,
            case {byte_size(TheirsContent) > byte_size(OursContent),
                  HasImport(TheirsContent), HasImport(OursContent)} of
                {true, _, _} -> TheirsContent;
                {false, true, false} -> TheirsContent;
                {false, false, true} -> OursContent;
                _ -> OursContent
            end
    end.
