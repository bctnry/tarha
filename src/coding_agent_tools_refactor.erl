-module(coding_agent_tools_refactor).
-export([execute/2]).

% Git workflow tools (smart_commit, resolve_merge_conflicts, review_changes)
execute(<<"smart_commit">>, Args) ->
    case coding_agent_tools:safety_check(<<"smart_commit">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> coding_agent_tools:execute(<<"smart_commit">>, NewArgs);
        proceed ->
            Preview = maps:get(<<"preview">>, Args, false),
            DiffCmd = "git diff --cached",
            StagedDiff = os:cmd(DiffCmd),
            case StagedDiff of
                [] ->
                    #{<<"success">> => false, <<"error">> => <<"No staged changes. Use git add first.">>};
                Diff ->
                    CommitMsg = generate_commit_message(Diff),
                    CoAuthoredBy = <<"\n\nCo-Authored-By: TriusAI Tarha <trius@canton.graphics>">>,
                    FullMsg = <<CommitMsg/binary, CoAuthoredBy/binary>>,
                    case Preview of
                        true ->
                            #{<<"success">> => true,
                              <<"preview">> => true,
                              <<"message">> => FullMsg,
                              <<"diff">> => coding_agent_tools:clean_output(string:trim(Diff, trailing))};
                        false ->
                            CommitCmd = "git commit -m '" ++ binary_to_list(FullMsg) ++ "'",
                            Result = os:cmd(CommitCmd ++ " 2>&1"),
                            #{<<"success">> => true,
                              <<"message">> => FullMsg,
                              <<"output">> => coding_agent_tools:clean_output(string:trim(Result, trailing))}
                    end
            end
    end;

execute(<<"resolve_merge_conflicts">>, Args) ->
    File = maps:get(<<"file">>, Args, undefined),
    Strategy = maps:get(<<"strategy">>, Args, <<"smart">>),

    ConflictFiles = case File of
        undefined ->
            Output = os:cmd("git diff --name-only --diff-filter=U 2>/dev/null"),
            string:tokens(Output, "\n");
        F ->
            [binary_to_list(F)]
    end,

    case ConflictFiles of
        [] ->
            #{<<"success">> => true, <<"message">> => <<"No merge conflicts found.">>};
        Files ->
            Results = lists:map(fun(FilePath) ->
                case coding_agent_tools:resolve_conflicts_in_file(FilePath, Strategy) of
                    {ok, Resolution} ->
                        #{<<"file">> => list_to_binary(FilePath),
                          <<"status">> => <<"resolved">>,
                          <<"strategy">> => Resolution};
                    {error, Reason} ->
                        #{<<"file">> => list_to_binary(FilePath),
                          <<"status">> => <<"failed">>,
                          <<"error">> => Reason}
                end
            end, Files),
            SuccessCount = length([R || R <- Results, maps:get(<<"status">>, R) == <<"resolved">>]),
            #{<<"success">> => true,
              <<"resolved_count">> => SuccessCount,
              <<"total_count">> => length(Files),
              <<"files">> => Results}
    end;

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
            Review = coding_agent_tools:analyze_diff(Diff),
            #{
                <<"success">> => true,
                <<"diff">> => coding_agent_tools:clean_output(string:trim(Diff, trailing)),
                <<"review">> => Review,
                <<"summary">> => generate_review_summary(Diff)
            }
    end;

% Test generation
execute(<<"generate_tests">>, #{<<"file">> := FilePath} = Args) ->
    PathStr = coding_agent_tools:sanitize_path(FilePath),
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
    end.

%% Internal helpers

generate_commit_message(Diff) ->
    Lines = string:split(Diff, "\n", all),
    AddedFiles = [Line || Line <- Lines, string:prefix(Line, "diff --git ") =/= nomatch],
    AddedCount = length(AddedFiles),
    ChangeType = detect_change_type(Diff),
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
        <<"issues">> => coding_agent_tools:detect_issues(Diff),
        <<"suggestions">> => coding_agent_tools:generate_suggestions(Diff)
    }.


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