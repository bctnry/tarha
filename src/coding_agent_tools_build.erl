-module(coding_agent_tools_build).
-export([execute/2]).

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

execute(<<"detect_project">>, Args) ->
    Path = maps:get(<<"path">>, Args, <<".">>),
    detect_project_impl(binary_to_list(Path)).

%% Internal helpers

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
    coding_agent_tools:report_progress(OpName, <<"detecting">>, #{}),
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
            coding_agent_tools:report_progress(OpName, <<"running">>, #{command => list_to_binary(FinalCmd)}),
            Result = coding_agent_tools:run_command_impl(FinalCmd, 120000, "."),
            Result#{<<"command">> => list_to_binary(FinalCmd)};
        [] ->
            #{<<"success">> => false, <<"error">> => <<"No suitable build/test tool found">>}
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