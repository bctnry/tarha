-module(coding_agent_tools_git).
-export([execute/2]).

execute(<<"git_status">>, _Args) ->
    coding_agent_tools:report_progress(<<"git_status">>, <<"starting">>, #{}),
    Result = run_git_command("git status --short"),
    coding_agent_tools:report_progress(<<"git_status">>, <<"complete">>, #{}),
    Result;

execute(<<"git_diff">>, Args) ->
    File = maps:get(<<"file">>, Args, undefined),
    Staged = maps:get(<<"staged">>, Args, false),
    Cmd = case {Staged, File} of
        {true, undefined} -> "git diff --cached";
        {true, F} -> "git diff --cached " ++ binary_to_list(F);
        {false, undefined} -> "git diff";
        {false, F} -> "git diff " ++ binary_to_list(F)
    end,
    coding_agent_tools:report_progress(<<"git_diff">>, <<"starting">>, #{command => list_to_binary(Cmd)}),
    Result = run_git_command(Cmd),
    coding_agent_tools:report_progress(<<"git_diff">>, <<"complete">>, #{}),
    Result;

execute(<<"git_log">>, Args) ->
    Count = maps:get(<<"count">>, Args, 10),
    Format = maps:get(<<"format">>, Args, <<"oneline">>),
    Cmd = "git log --max-count=" ++ integer_to_list(Count) ++ " --format=" ++ binary_to_list(Format),
    coding_agent_tools:report_progress(<<"git_log">>, <<"starting">>, #{count => Count}),
    Result = run_git_command(Cmd),
    coding_agent_tools:report_progress(<<"git_log">>, <<"complete">>, #{}),
    Result;

execute(<<"git_add">>, #{<<"files">> := Files}) ->
    FileList = string:join([binary_to_list(F) || F <- Files], " "),
    Cmd = "git add " ++ FileList,
    coding_agent_tools:report_progress(<<"git_add">>, <<"starting">>, #{files => Files}),
    Result = run_git_command(Cmd),
    coding_agent_tools:report_progress(<<"git_add">>, <<"complete">>, #{}),
    Result;

execute(<<"git_commit">>, #{<<"message">> := Msg} = Args) ->
    case coding_agent_tools:safety_check(<<"git_commit">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> execute(<<"git_commit">>, NewArgs);
        proceed ->
            Cmd = "git commit -m '" ++ binary_to_list(Msg) ++ "'",
            coding_agent_tools:report_progress(<<"git_commit">>, <<"starting">>, #{}),
            Result = run_git_command(Cmd),
            coding_agent_tools:log_operation(<<"git_commit">>, Msg, Result),
            coding_agent_tools:report_progress(<<"git_commit">>, <<"complete">>, #{}),
            Result
    end;

execute(<<"git_branch">>, #{<<"action">> := Action} = Args) ->
    Name = maps:get(<<"name">>, Args, undefined),
    Cmd = case {Action, Name} of
        {<<"create">>, N} -> "git checkout -b " ++ binary_to_list(N);
        {<<"switch">>, N} -> "git checkout " ++ binary_to_list(N);
        {<<"list">>, _} -> "git branch";
        {<<"delete">>, N} -> "git branch -d " ++ binary_to_list(N);
        _ -> "git branch"
    end,
    coding_agent_tools:report_progress(<<"git_branch">>, <<"starting">>, #{action => Action}),
    Result = run_git_command(Cmd),
    coding_agent_tools:report_progress(<<"git_branch">>, <<"complete">>, #{}),
    Result.

%% Internal helpers

run_git_command(Cmd) ->
    case os:cmd(Cmd ++ " 2>&1") of
        [] -> #{<<"success">> => true, <<"output">> => <<"">>};
        Result ->
            CleanResult = coding_agent_tools:clean_output(Result),
            #{<<"success">> => true, <<"output">> => CleanResult}
    end.