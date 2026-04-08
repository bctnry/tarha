-module(coding_agent_tools_search).
-export([execute/2]).

execute(<<"grep_files">>, Args) ->
    Pattern = maps:get(<<"pattern">>, Args),
    Path = maps:get(<<"path">>, Args, <<".">>),
    CaseInsensitive = maps:get(<<"case_insensitive">>, Args, false),

    PathStr = binary_to_list(Path),
    PatternStr = binary_to_list(Pattern),
    Cmd = case CaseInsensitive of
        true -> "grep -rn -i " ++ PatternStr ++ " " ++ PathStr ++ " 2>/dev/null";
        false -> "grep -rn " ++ PatternStr ++ " " ++ PathStr ++ " 2>/dev/null"
    end,

    coding_agent_tools:report_progress(<<"grep_files">>, <<"starting">>, #{pattern => Pattern, path => Path}),
    Result = os:cmd(Cmd),
    CleanResult = coding_agent_tools:clean_output(string:trim(Result, trailing)),
    LimitedResult = limit_grep_output(CleanResult, 500),
    coding_agent_tools:report_progress(<<"grep_files">>, <<"complete">>, #{}),
    #{<<"success">> => true, <<"output">> => LimitedResult, <<"pattern">> => Pattern, <<"path">> => Path};

execute(<<"find_files">>, #{<<"pattern">> := Pattern} = Args) ->
    Path = maps:get(<<"path">>, Args, <<".">>),
    FileType = maps:get(<<"type">>, Args, <<"all">>),

    PathStr = binary_to_list(Path),
    PatternStr = binary_to_list(Pattern),

    Cmd = case FileType of
        <<"directory">> -> "find " ++ PathStr ++ " -type d -name '" ++ PatternStr ++ "' 2>/dev/null";
        <<"file">> -> "find " ++ PathStr ++ " -type f -name '" ++ PatternStr ++ "' 2>/dev/null";
        _ -> "find " ++ PathStr ++ " -name '" ++ PatternStr ++ "' 2>/dev/null"
    end,

    coding_agent_tools:report_progress(<<"find_files">>, <<"starting">>, #{pattern => Pattern, path => Path}),
    Result = os:cmd(Cmd),
    CleanResult = coding_agent_tools:clean_output(string:trim(Result, trailing)),
    coding_agent_tools:report_progress(<<"find_files">>, <<"complete">>, #{}),
    #{<<"success">> => true, <<"output">> => CleanResult, <<"pattern">> => Pattern, <<"path">> => Path}.

%% Internal helpers

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