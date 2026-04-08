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
    #{<<"success">> => true, <<"output">> => CleanResult, <<"pattern">> => Pattern, <<"path">> => Path};

execute(<<"find_references">>, Args) ->
    Symbol = maps:get(<<"symbol">>, Args),
    FilePath = maps:get(<<"file">>, Args, undefined),

    coding_agent_tools:report_progress(<<"find_references">>, <<"starting">>, #{symbol => Symbol}),

    Result = case whereis(coding_agent_index) of
        undefined ->
            find_references_grep(Symbol);
        Pid when is_pid(Pid) ->
            try
                {ok, Refs} = coding_agent_index:find_references(Pid, Symbol),
                iolist_to_binary([[list_to_binary(F), <<"::">>, integer_to_binary(L), <<"\n">>]
                                 || {F, L} <- Refs])
            catch _:_ ->
                find_references_grep(Symbol)
            end
    end,

    CleanResult = coding_agent_tools:clean_output(string:trim(binary_to_list(iolist_to_binary(Result)), trailing)),
    LimitedResult = limit_grep_output(iolist_to_binary(CleanResult), 200),
    Lines = binary:split(LimitedResult, <<"\n">>, [global, trim_all]),
    Count = length(Lines),

    coding_agent_tools:report_progress(<<"find_references">>, <<"complete">>, #{count => Count}),
    #{<<"success">> => true, <<"references">> => LimitedResult, <<"symbol">> => Symbol, <<"count">> => Count,
      <<"file">> => FilePath};

execute(<<"get_callers">>, Args) ->
    Module = maps:get(<<"module">>, Args),
    Function = maps:get(<<"function">>, Args, undefined),

    coding_agent_tools:report_progress(<<"get_callers">>, <<"starting">>, #{module => Module}),

    Result = case whereis(coding_agent_index) of
        undefined ->
            get_callers_grep(Module, Function);
        Pid when is_pid(Pid) ->
            try
                ModAtom = binary_to_existing_atom(Module, utf8),
                {ok, Callers} = coding_agent_index:get_callers(Pid, ModAtom),
                iolist_to_binary([[list_to_binary(F), <<"::">>, integer_to_binary(L), <<"\n">>]
                                 || {F, L} <- Callers])
            catch _:_ ->
                get_callers_grep(Module, Function)
            end
    end,

    CleanResult = coding_agent_tools:clean_output(string:trim(binary_to_list(iolist_to_binary(Result)), trailing)),
    LimitedResult = limit_grep_output(iolist_to_binary(CleanResult), 200),
    Lines = binary:split(LimitedResult, <<"\n">>, [global, trim_all]),
    Count = length(Lines),

    coding_agent_tools:report_progress(<<"get_callers">>, <<"complete">>, #{count => Count}),
    #{<<"success">> => true, <<"callers">> => LimitedResult, <<"module">> => Module, <<"count">> => Count}.

%% Internal helpers

find_references_grep(Symbol) ->
    SymbolStr = binary_to_list(Symbol),
    Cmd = "grep -rn --include='*.erl' --include='*.hrl' --include='*.ex' --include='*.py' --include='*.js' -w '"
           ++ SymbolStr ++ "' . 2>/dev/null",
    os:cmd(Cmd).

get_callers_grep(Module, undefined) ->
    ModStr = binary_to_list(Module),
    Cmd = "grep -rn --include='*.erl' -e '" ++ ModStr ++ ":' . 2>/dev/null",
    os:cmd(Cmd);
get_callers_grep(Module, Function) ->
    ModStr = binary_to_list(Module),
    FunStr = binary_to_list(Function),
    Cmd = "grep -rn --include='*.erl' -e '" ++ ModStr ++ ":" ++ FunStr ++ "' . 2>/dev/null",
    os:cmd(Cmd).

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
