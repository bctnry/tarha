-module(coding_agent_lsp).
-behaviour(gen_server).
-export([start_link/1, start_link/2, stop/1]).
-export([definition/3, references/3, hover/3, completion/3, symbols/2, diagnostics/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    project_root :: string(),
    lsp_servers :: #{atom() => pid()},
    file_cache :: #{string() => #{version => integer(), content => binary()}}
}).

-define(LSP_TIMEOUT, 30000).

start_link(ProjectRoot) ->
    start_link(ProjectRoot, #{}).

start_link(ProjectRoot, Options) when is_list(ProjectRoot) ->
    gen_server:start_link(?MODULE, [ProjectRoot, Options], []).

stop(Pid) ->
    gen_server:stop(Pid).

% LSP Operations
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

init([ProjectRoot, _Options]) ->
    process_flag(trap_exit, true),
    {ok, #state{
        project_root = ProjectRoot,
        lsp_servers = #{},
        file_cache = #{}
    }}.

handle_call({definition, FilePath, {Line, Char}}, _From, State) ->
    case request_lsp(FilePath, definition, Line, Char, State) of
        {ok, Locations} -> {reply, {ok, Locations}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({references, FilePath, {Line, Char}}, _From, State) ->
    case request_lsp(FilePath, references, Line, Char, State) of
        {ok, Locations} -> {reply, {ok, Locations}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({hover, FilePath, {Line, Char}}, _From, State) ->
    case request_lsp(FilePath, hover, Line, Char, State) of
        {ok, HoverInfo} -> {reply, {ok, HoverInfo}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({completion, FilePath, {Line, Char}}, _From, State) ->
    case request_lsp(FilePath, completion, Line, Char, State) of
        {ok, Items} -> {reply, {ok, Items}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({symbols, FilePath}, _From, State) ->
    case request_lsp(FilePath, symbols, nil, nil, State) of
        {ok, Symbols} -> {reply, {ok, Symbols}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({diagnostics, FilePath}, _From, State) ->
    case request_lsp(FilePath, diagnostics, nil, nil, State) of
        {ok, Diags} -> {reply, {ok, Diags}, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

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

% Internal - Simplified LSP implementation using pattern matching on files
% In production, would use actual LSP servers (erlang_ls, elixir-ls, etc.)
request_lsp(FilePath, definition, Line, Char, _State) ->
    {ok, #{
        file => list_to_binary(FilePath),
        line => Line,
        character => Char,
        goto => find_definition(FilePath, Line, Char)
    }};
request_lsp(FilePath, references, Line, Char, _State) ->
    {ok, #{
        file => list_to_binary(FilePath),
        line => Line,
        character => Char,
        references => find_references(FilePath, Line, Char)
    }};
request_lsp(FilePath, hover, Line, Char, State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            {ok, #{
                file => list_to_binary(FilePath),
                line => Line,
                character => Char,
                hover => get_hover_info(FilePath, Content, Line, Char, State)
            }};
        {error, Reason} ->
            {error, file:format_error(Reason)}
    end;
request_lsp(FilePath, completion, Line, Char, _State) ->
    {ok, #{
        file => list_to_binary(FilePath),
        line => Line,
        character => Char,
        completions => get_completions(FilePath, Line, Char)
    }};
request_lsp(FilePath, symbols, nil, nil, _State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            {ok, #{
                file => list_to_binary(FilePath),
                symbols => extract_symbols(FilePath, Content)
            }};
        {error, Reason} ->
            {error, file:format_error(Reason)}
    end;
request_lsp(FilePath, diagnostics, nil, nil, _State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            {ok, #{
                file => list_to_binary(FilePath),
                diagnostics => check_syntax(FilePath, Content)
            }};
        {error, Reason} ->
            {error, file:format_error(Reason)}
    end.

% Simplified implementations - in production would connect to actual LSP servers
find_definition(FilePath, Line, _Char) ->
    % Read file and find function definition
    case file:read_file(FilePath) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n">>, [global]),
            case Line =< length(Lines) of
                true -> #{location => FilePath, line => Line, found => true};
                false -> #{found => false}
            end;
        _ -> #{found => false}
    end.

find_references(FilePath, _Line, _Char) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            % Simplified - return current file
            #{files => [list_to_binary(FilePath)]};
        _ -> #{files => []}
    end.

get_hover_info(FilePath, Content, Line, Char, _State) ->
    % Extract line and word at position
    Lines = binary:split(Content, <<"\n">>, [global]),
    case lists:nth(min(Line, length(Lines)), Lines) of
        LineContent when is_binary(LineContent) ->
            Word = extract_word(LineContent, Char),
            #{
                contents => LineContent,
                word => Word,
                type => detect_type(Word, FilePath)
            };
        _ ->
            #{contents => <<>>}
    end.

get_completions(FilePath, _Line, _Char) ->
    % Return language-specific completions
    case filename:extension(FilePath) of
        ".erl" -> get_erlang_completions();
        ".ex" -> get_elixir_completions();
        _ -> []
    end.

get_erlang_completions() ->
    Builtins = [<<"module">>, <<"export">>, <<"import">>, <<"include">>, 
                 <<"define">>, <<"record">>, <<"type">>, <<"spec">>,
                 <<"if">>, <<"case">>, <<"receive">>, <<"try">>, <<"catch">>,
                 <<"fun">>, <<"spawn">>, <<"self">>, <<"node">>],
    lists:map(fun(B) -> #{label => B, kind => keyword} end, Builtins).

get_elixir_completions() ->
    Builtins = [<<"def">>, <<"defp">>, <<"defmodule">>, <<"defstruct">>,
                 <<"use">>, <<"import">>, <<"alias">>, <<"require">>,
                 <<"if">>, <<"case">>, <<"cond">>, <<"with">>, <<"for">>],
    lists:map(fun(B) -> #{label => B, kind => keyword} end, Builtins).

extract_word(LineContent, Char) ->
    Words = binary:split(LineContent, <<" ">>, [global]),
    find_word_at_char(Words, Char, 0).

find_word_at_char([], _Char, _Pos) -> <<>>;
find_word_at_char([Word | Rest], Char, Pos) ->
    WordLen = byte_size(Word),
    case Char >= Pos andalso Char < Pos + WordLen of
        true -> Word;
        false -> find_word_at_char(Rest, Char, Pos + WordLen + 1)
    end.

detect_type(Word, _FilePath) ->
    case Word of
        <<$:, _/binary>> -> atom;
        <<$#, _/binary>> -> variable;
        _ when is_binary(Word) -> 
            case binary:first(Word) of
                $A when $A >= $A, $A =< $Z -> variable;
                _ -> function
            end;
        _ -> unknown
    end.

extract_symbols(FilePath, Content) ->
    Ext = filename:extension(FilePath),
    extract_symbols_by_ext(Ext, Content).

extract_symbols_by_ext(".erl", Content) ->
    % Extract functions from Erlang module
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^([a-z][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, #{name => Name, kind => function}};
            nomatch -> false
        end
    end, Lines);
extract_symbols_by_ext(".ex", Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^\\s*defp?\\s+([a-z_][a-zA-Z0-9_?!]*)", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, #{name => Name, kind => function}};
            nomatch -> false
        end
    end, Lines);
extract_symbols_by_ext(_, _) ->
    [].

check_syntax(_FilePath, _Content) ->
    % Simplified - in production would use actual parser/compiler
    [].