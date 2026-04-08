-module(coding_agent_lsp).
-behaviour(gen_server).
-export([start_link/1, start_link/2, stop/1]).
-export([definition/3, references/3, hover/3, completion/3, symbols/2, diagnostics/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Code intelligence LSP-like interface backed by coding_agent_index.
%% Provides definition lookup, reference finding, hover info, symbol listing,
%% and diagnostics by querying the persistent index.

-record(state, {
    project_root :: string()
}).

-define(LSP_TIMEOUT, 30000).

start_link(ProjectRoot) ->
    start_link(ProjectRoot, #{}).

start_link(ProjectRoot, _Options) when is_list(ProjectRoot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ProjectRoot], []).

stop(Pid) ->
    gen_server:stop(Pid).

%%===================================================================
%% LSP Operations
%%===================================================================

definition(Pid, FilePath, Position) ->
    gen_server:call(Pid, {definition, FilePath, Position}, ?LSP_TIMEOUT).

references(Pid, FilePath, Position) ->
    gen_server:call(Pid, {references, FilePath, Position}, ?LSP_TIMEOUT).

hover(Pid, FilePath, Position) ->
    gen_server:call(Pid, {hover, FilePath, Position}, ?LSP_TIMEOUT).

completion(Pid, FilePath, Position) ->
    gen_server:call(Pid, {completion, FilePath, Position}, ?LSP_TIMEOUT).

symbols(Pid, FilePath) ->
    gen_server:call(Pid, {symbols, FilePath}, ?LSP_TIMEOUT).

diagnostics(Pid, FilePath) ->
    gen_server:call(Pid, {diagnostics, FilePath}, ?LSP_TIMEOUT).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([ProjectRoot, _Options]) ->
    process_flag(trap_exit, true),
    {ok, #state{project_root = ProjectRoot}}.

handle_call({definition, FilePath, {Line, _Char}}, _From, State) ->
    Result = do_definition(FilePath, Line, State),
    {reply, {ok, Result}, State};

handle_call({references, FilePath, {Line, _Char}}, _From, State) ->
    Result = do_references(FilePath, Line, State),
    {reply, {ok, Result}, State};

handle_call({hover, FilePath, {Line, Char}}, _From, State) ->
    Result = do_hover(FilePath, Line, Char, State),
    {reply, {ok, Result}, State};

handle_call({completion, FilePath, {_Line, _Char}}, _From, State) ->
    Result = do_completion(FilePath, State),
    {reply, {ok, Result}, State};

handle_call({symbols, FilePath}, _From, State) ->
    Result = do_symbols(FilePath, State),
    {reply, {ok, Result}, State};

handle_call({diagnostics, FilePath}, _From, State) ->
    Result = do_diagnostics(FilePath, State),
    {reply, {ok, Result}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal: Definition lookup
%%===================================================================

do_definition(FilePath, Line, _State) ->
    case get_index_pid() of
        undefined -> #{found => false, reason => index_not_started};
        Pid ->
            case file:read_file(FilePath) of
                {ok, Content} ->
                    Word = get_word_at_line(Content, Line),
                    case Word of
                        <<>> -> #{found => false, reason => no_word_at_position};
                        _ ->
                            %% Try Module:Function format first
                            case binary:split(Word, <<":">>) of
                                [ModBin, FunBin] ->
                                    Mod = try binary_to_existing_atom(ModBin, utf8) catch _:_ -> undefined end,
                                    case {Mod, find_module_file(Pid, Mod)} of
                                        {undefined, _} ->
                                            search_fun_in_index(Pid, FunBin);
                                        {_, ModFile} when is_list(ModFile) ->
                                            #{found => true, file => list_to_binary(ModFile),
                                              symbol => FunBin, module => ModBin}
                                    end;
                                _ ->
                                    search_fun_in_index(Pid, Word)
                            end
                    end;
                _ -> #{found => false, reason => file_read_error}
            end
    end.

search_fun_in_index(Pid, Word) ->
    try
        FunName = binary_to_existing_atom(Word, utf8),
        case coding_agent_index:find_definition(Pid, FunName) of
            {ok, []} -> #{found => false, symbol => Word};
            {ok, Locations} ->
                [{DefFile, DefLine} | _] = Locations,
                #{found => true, file => list_to_binary(DefFile),
                  line => DefLine, symbol => Word, locations => format_locations(Locations)}
        end
    catch
        _:_ -> #{found => false, symbol => Word}
    end.

find_module_file(Pid, Mod) when is_atom(Mod) ->
    case coding_agent_index:get_module_info(Pid, atom_to_list(Mod) ++ ".erl") of
        {ok, _} -> atom_to_list(Mod) ++ ".erl";
        _ -> undefined
    end;
find_module_file(_, _) -> undefined.

format_locations(Locations) ->
    lists:map(fun({F, L}) -> #{file => list_to_binary(F), line => L} end, Locations).

%%===================================================================
%% Internal: Reference finding
%%===================================================================

do_references(FilePath, Line, _State) ->
    case get_index_pid() of
        undefined -> #{references => [], reason => index_not_started};
        Pid ->
            case file:read_file(FilePath) of
                {ok, Content} ->
                    Word = get_word_at_line(Content, Line),
                    case Word of
                        <<>> -> #{references => [], symbol => <<>>};
                        _ ->
                            try
                                FunName = binary_to_existing_atom(Word, utf8),
                                {ok, Refs} = coding_agent_index:find_references(Pid, FunName),
                                #{symbol => Word, references => format_locations(Refs)}
                            catch
                                _:_ ->
                                    %% Fallback: grep for the word
                                    GrepCmd = "grep -rn " ++ binary_to_list(Word) ++ " --include='*.erl' --include='*.hrl' . 2>/dev/null | head -20",
                                    GrepResult = os:cmd(GrepCmd),
                                    RefLocations = parse_grep_output(GrepResult),
                                    #{symbol => Word, references => RefLocations}
                            end
                    end;
                _ -> #{references => []}
            end
    end.

parse_grep_output(Output) ->
    Lines = string:tokens(Output, "\n"),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^([^:]+):([0-9]+):", [{capture, [1, 2], binary}]) of
            {match, [File, LineNum]} ->
                {true, #{file => File, line => binary_to_integer(LineNum)}};
            _ -> false
        end
    end, Lines).

%%===================================================================
%% Internal: Hover info
%%===================================================================

do_hover(FilePath, Line, _Char, _State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            case Line =< length(Lines) andalso Line > 0 of
                true ->
                    LineContent = lists:nth(Line, Lines),
                    Word = extract_word_at_pos(LineContent, _Char),
                    SpecInfo = find_spec_for_word(FilePath, Word, Content),
                    #{contents => LineContent,
                      word => Word,
                      spec => SpecInfo};
                false ->
                    #{contents => <<>>, word => <<>>}
            end;
        _ ->
            #{contents => <<>>, word => <<>>}
    end.

find_spec_for_word(_FilePath, Word, Content) ->
    case Word of
        <<>> -> none;
        _ ->
            %% Look for -spec for this function in the file
            SpecPattern = <<"-spec\\s+", Word/binary, "\\s*\\(">>,
            case re:run(Content, SpecPattern, [{capture, none}]) of
                match ->
                    %% Extract the full spec line(s)
                    SpecLines = extract_spec_lines(Word, Content),
                    #{has_spec => true, spec => SpecLines};
                nomatch ->
                    #{has_spec => false}
            end
    end.

extract_spec_lines(Word, Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    SpecStart = <<"-spec ", Word/binary>>,
    lists:filter(fun(Line) ->
        case binary:match(Line, SpecStart) of
            nomatch -> false;
            _ -> true
        end
    end, Lines).

%%===================================================================
%% Internal: Completion
%%===================================================================

do_completion(FilePath, _State) ->
    case get_index_pid() of
        undefined -> get_keyword_completions(FilePath);
        Pid ->
            %% Get module exports from index
            case coding_agent_index:get_module_info(Pid, FilePath) of
                {ok, #{exports := Exports}} ->
                    ExportCompletions = lists:map(fun({Name, Arity}) ->
                        Label = iolist_to_binary(io_lib:format("~s/~p", [atom_to_binary(Name, utf8), Arity])),
                        #{label => Label, kind => function, detail => <<"export">>}
                    end, Exports),
                    KeywordCompletions = get_keyword_completions(FilePath),
                    ExportCompletions ++ KeywordCompletions;
                _ ->
                    get_keyword_completions(FilePath)
            end
    end.

get_keyword_completions(FilePath) ->
    case filename:extension(FilePath) of
        ".erl" ->
            Builtins = [<<"module">>, <<"export">>, <<"import">>, <<"include">>,
                        <<"define">>, <<"record">>, <<"type">>, <<"spec">>,
                        <<"if">>, <<"case">>, <<"receive">>, <<"try">>, <<"catch">>,
                        <<"fun">>, <<"spawn">>, <<"self">>, <<"node">>],
            lists:map(fun(B) -> #{label => B, kind => keyword} end, Builtins);
        ".ex" ->
            Builtins = [<<"def">>, <<"defp">>, <<"defmodule">>, <<"defstruct">>,
                        <<"use">>, <<"import">>, <<"alias">>, <<"require">>,
                        <<"if">>, <<"case">>, <<"cond">>, <<"with">>, <<"for">>],
            lists:map(fun(B) -> #{label => B, kind => keyword} end, Builtins);
        _ -> []
    end.

%%===================================================================
%% Internal: Symbols
%%===================================================================

do_symbols(FilePath, _State) ->
    case get_index_pid() of
        undefined -> [];
        Pid ->
            case coding_agent_index:get_module_info(Pid, FilePath) of
                {ok, Info} ->
                    Module = maps:get(module, Info, undefined),
                    Functions = format_function_symbols(maps:get(functions, Info, [])),
                    Exports = format_export_symbols(maps:get(exports, Info, [])),
                    Records = format_record_symbols(maps:get(records, Info, [])),
                    Types = format_type_symbols(maps:get(types, Info, [])),
                    Specs = maps:get(specs, Info, []),
                    #{module => format_atom(Module),
                      functions => Functions,
                      exports => Exports,
                      records => Records,
                      types => Types,
                      specs => Specs};
                _ ->
                    []
            end
    end.

format_function_symbols(Funs) ->
    lists:map(fun({Name, Arity, Line}) ->
        #{name => format_atom(Name), arity => Arity, line => Line, kind => function}
    end, Funs).

format_export_symbols(Exports) ->
    lists:map(fun({Name, Arity}) ->
        #{name => format_atom(Name), arity => Arity, kind => export}
    end, Exports).

format_record_symbols(Records) ->
    lists:map(fun(Name) ->
        #{name => format_atom(Name), kind => record}
    end, Records).

format_type_symbols(Types) ->
    lists:map(fun(Name) ->
        #{name => format_atom(Name), kind => type}
    end, Types).

format_atom(undefined) -> null;
format_atom(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8).

%%===================================================================
%% Internal: Diagnostics
%%===================================================================

do_diagnostics(_FilePath, _State) ->
    %% Run rebar3 compile and parse errors/warnings
    Result = os:cmd("rebar3 compile 2>&1"),
    parse_diagnostics(Result).

parse_diagnostics(Output) ->
    Lines = string:tokens(Output, "\n"),
    lists:filtermap(fun(Line) ->
        %% Match rebar3 compile errors/warnings
        case re:run(Line, "src/([^:]+):(\\d+):(\\d+):\\s*(Warning|Error):\\s*(.+)", [{capture, [1, 2, 3, 4, 5], binary}]) of
            {match, [File, LineNum, Col, Severity, Message]} ->
                {true, #{
                    file => <<"src/", File/binary>>,
                    line => binary_to_integer(LineNum),
                    column => binary_to_integer(Col),
                    severity => case Severity of
                        <<"Warning">> -> warning;
                        <<"Error">> -> error
                    end,
                    message => Message
                }};
            _ ->
                %% Try alternate format: "Compiling src/X.erl failed"
                case re:run(Line, "Compiling\\s+(src/[^\\s]+)\\s+failed", [{capture, [1], binary}]) of
                    {match, [File]} ->
                        {true, #{file => File, severity => error, message => <<"Compilation failed">>}};
                    _ -> false
                end
        end
    end, Lines).

%%===================================================================
%% Internal: Helpers
%%===================================================================

get_index_pid() ->
    case erlang:whereis(coding_agent_index) of
        undefined -> undefined;
        Pid when is_pid(Pid) -> Pid
    end.

get_word_at_line(Content, Line) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    case Line > 0 andalso Line =< length(Lines) of
        true ->
            LineContent = lists:nth(Line, Lines),
            extract_first_identifier(LineContent);
        false -> <<>>
    end.

extract_first_identifier(Line) ->
    %% Find the identifier near the cursor - extract last identifier before a paren
    case re:run(Line, "([a-zA-Z_][a-zA-Z0-9_@]*):([a-zA-Z_][a-zA-Z0-9_@]*)", [{capture, [1, 2], binary}]) of
        {match, [Mod, Fn]} -> <<Mod/binary, ":", Fn/binary>>;
        _ ->
            case re:run(Line, "([a-z_][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
                {match, [Name]} -> Name;
                _ ->
                    case re:run(Line, "([A-Z_][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
                        {match, [Name]} -> Name;
                        _ -> <<>>
                    end
            end
    end.

extract_word_at_pos(LineContent, Char) ->
    %% Extract identifier at or before the given character position
    Prefix = case Char > 0 of
        true ->
            Len = min(Char, byte_size(LineContent)),
            binary:part(LineContent, 0, Len);
        false -> <<>>
    end,
    case re:run(Prefix, "([a-zA-Z_][a-zA-Z0-9_@]*)$", [{capture, [1], binary}]) of
        {match, [Word]} -> Word;
        _ ->
            case re:run(Prefix, "([a-zA-Z_][a-zA-Z0-9_@]*):([a-zA-Z_][a-zA-Z0-9_@]*)$", [{capture, [2], binary}]) of
                {match, [Fn]} -> Fn;
                _ -> <<>>
            end
    end.
