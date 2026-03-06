-module(coding_agent_index).
-behaviour(gen_server).
-export([start_link/1, start_link/2, stop/1]).
-export([index_file/2, index_directory/2, search/2, search/3, similar/2, stats/1]).
-export([clear/1, rebuild/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    project_root :: string(),
    index :: #{string() => #{
        content => binary(),
        symbols => [map()],
        language => atom(),
        mtime => integer()
    }},
    symbol_index :: #{atom() => [string()]},  % Symbol -> Files
    ngram_index :: #{binary() => [string()]}   % N-gram -> Files
}).

-define(DEFAULT_NGRAM_SIZE, 3).
-define(MAXIndexed_FILES, 10000).

start_link(ProjectRoot) ->
    start_link(ProjectRoot, #{}).

start_link(ProjectRoot, _Options) when is_list(ProjectRoot) ->
    gen_server:start_link(?MODULE, [ProjectRoot], []).

stop(Pid) ->
    gen_server:stop(Pid).

index_file(Pid, FilePath) ->
    gen_server:call(Pid, {index_file, FilePath}, 60000).

index_directory(Pid, DirPath) ->
    gen_server:call(Pid, {index_directory, DirPath}, 120000).

search(Pid, Query) ->
    search(Pid, Query, #{}).

search(Pid, Query, Options) ->
    gen_server:call(Pid, {search, Query, Options}, 30000).

similar(Pid, FilePath) ->
    gen_server:call(Pid, {similar, FilePath}, 30000).

stats(Pid) ->
    gen_server:call(Pid, stats).

clear(Pid) ->
    gen_server:call(Pid, clear).

rebuild(Pid) ->
    gen_server:call(Pid, rebuild, 300000).

init([ProjectRoot]) ->
    process_flag(trap_exit, true),
    State = #state{
        project_root = ProjectRoot,
        index = #{},
        symbol_index = #{},
        ngram_index = #{}
    },
    {ok, State}.

handle_call({index_file, FilePath}, _From, State) ->
    case do_index_file(FilePath, State) of
        {ok, NewState} -> {reply, ok, NewState};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({index_directory, DirPath}, _From, State) ->
    case do_index_directory(DirPath, State) of
        {ok, NewState} -> {reply, ok, NewState};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({search, Query, Options}, _From, State) ->
    Results = do_search(Query, Options, State),
    {reply, {ok, Results}, State};

handle_call({similar, FilePath}, _From, State) ->
    Results = do_find_similar(FilePath, State),
    {reply, {ok, Results}, State};

handle_call(stats, _From, State) ->
    Stats = #{
        total_files => map_size(State#state.index),
        total_symbols => map_size(State#state.symbol_index),
        total_ngrams => map_size(State#state.ngram_index),
        indexed_files => maps:keys(State#state.index)
    },
    {reply, {ok, Stats}, State};

handle_call(clear, _From, State) ->
    NewState = State#state{
        index = #{},
        symbol_index = #{},
        ngram_index = #{}
    },
    {reply, ok, NewState};

handle_call(rebuild, _From, State = #state{project_root = Root}) ->
    case do_index_directory(Root, #state{project_root = Root, index = #{}, symbol_index = #{}, ngram_index = #{}}) of
        {ok, NewState} -> {reply, ok, NewState};
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

% Internal functions
do_index_file(FilePath, State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            Symbols = extract_symbols(FilePath, Content),
            Language = detect_language(FilePath),
            Ngrams = compute_ngrams(Content),
            
            % Update file index
            FileData = #{
                content => Content,
                symbols => Symbols,
                language => Language,
                mtime => erlang:system_time(second)
            },
            NewIndex = maps:put(FilePath, FileData, State#state.index),
            
            % Update symbol index
            NewSymbolIndex = update_symbol_index(FilePath, Symbols, State#state.symbol_index),
            
            % Update ngram index
            NewNgramIndex = update_ngram_index(FilePath, Ngrams, State#state.ngram_index),
            
            {ok, State#state{
                index = NewIndex,
                symbol_index = NewSymbolIndex,
                ngram_index = NewNgramIndex
            }};
        {error, Reason} ->
            {error, file:format_error(Reason)}
    end.

do_index_directory(DirPath, State) ->
    ExtFilter = [".erl", ".ex", ".exs", ".hrl", ".h", ".c", ".cpp", ".py", ".js", ".ts", ".go", ".rs"],
    Files = filelib:fold_files(DirPath, ".*", true, fun(F, Acc) ->
        case lists:member(filename:extension(F), ExtFilter) of
            true -> [F | Acc];
            false -> Acc
        end
    end, []),
    
    IndexPath = #state{index = #{}, symbol_index = #{}, ngram_index = #{}},
    IndexFun = fun(FilePath, AccState) ->
        case do_index_file(FilePath, AccState) of
            {ok, NewState} -> NewState;
            {error, _} -> AccState
        end
    end,
    
    FinalState = lists:foldl(IndexFun, IndexPath, lists:sublist(Files, ?MAXIndexed_FILES)),
    
    % Merge with existing state
    NewIndex = maps:merge(State#state.index, FinalState#state.index),
    NewSymbolIndex = maps:merge(State#state.symbol_index, FinalState#state.symbol_index),
    NewNgramIndex = maps:merge(State#state.ngram_index, FinalState#state.ngram_index),
    
    {ok, State#state{
        index = NewIndex,
        symbol_index = NewSymbolIndex,
        ngram_index = NewNgramIndex
    }}.

do_search(Query, Options, State) ->
    QueryBin = iolist_to_binary(Query),
    QueryNgrams = compute_ngrams(QueryBin),
    UseSemantic = maps:get(semantic, Options, true),
    UseSymbol = maps:get(symbol, Options, true),
    MaxResults = maps:get(limit, Options, 20),
    
    % N-gram search
    NgramResults = case UseSemantic of
        true -> search_ngrams(QueryNgrams, State#state.ngram_index);
        false -> []
    end,
    
    % Symbol search
    SymbolResults = case UseSymbol of
        true -> search_symbols(Query, State#state.symbol_index);
        false -> []
    end,
    
    % Combine and rank results
    AllResults = lists:umerge(NgramResults, SymbolResults),
    RankedResults = rank_results(Query, AllResults, State#state.index),
    
    lists:sublist(RankedResults, MaxResults).

search_ngrams(QueryNgrams, NgramIndex) ->
    FileScores = lists:foldl(fun(Ngram, Acc) ->
        case maps:get(Ngram, NgramIndex, undefined) of
            undefined -> Acc;
            Files -> 
                lists:foldl(fun(File, FileAcc) ->
                    maps:update_with(File, fun(V) -> V + 1 end, 1, FileAcc)
                end, Acc, Files)
        end
    end, #{}, QueryNgrams),
    
    lists:sort(fun({_, A}, {_, B}) -> A > B end, maps:to_list(FileScores)).

search_symbols(Query, SymbolIndex) ->
    QueryLower = string:lowercase(Query),
    MatchingSymbols = maps:fold(fun(Symbol, Files, Acc) ->
        SymbolLower = atom_to_list(Symbol),  % Symbol is stored as atom
        case string:find(string:lowercase(SymbolLower), QueryLower) of
            nomatch -> Acc;
            _ -> [{File, Symbol} || File <- Files] ++ Acc
        end
    end, [], SymbolIndex),
    
    lists:usort(fun({FileA, _}, {FileB, _}) -> FileA < FileB end, MatchingSymbols).

rank_results(Query, Results, Index) ->
    QueryLower = string:lowercase(ensure_string(Query)),
    
    % Results come in different formats from different searches
    % Normalize to [{File, Score}, ...]
    Normalized = lists:map(fun
        ({File, Score}) when is_list(File), is_number(Score) -> {File, Score};
        ({File, _Symbol}) when is_list(File) -> {File, 1};
        (File) when is_list(File) -> {File, 1}
    end, Results),
    
    lists:sort(fun({FileA, ScoreA}, {FileB, ScoreB}) ->
        FilenameBoostA = case string:find(string:lowercase(filename:basename(FileA)), QueryLower) of
            nomatch -> 0;
            _ -> 10
        end,
        FilenameBoostB = case string:find(string:lowercase(filename:basename(FileB)), QueryLower) of
            nomatch -> 0;
            _ -> 10
        end,
        (ScoreA + FilenameBoostA) > (ScoreB + FilenameBoostB)
    end, Normalized).

do_find_similar(FilePath, State) ->
    case maps:get(FilePath, State#state.index, undefined) of
        undefined -> [];
        FileData ->
            Symbols = maps:get(symbols, FileData, []),
            Content = maps:get(content, FileData, <<>>),
            
            % Find files with similar symbols
            SimilarBySymbols = lists:flatmap(fun(#{name := Name}) ->
                case maps:get(Name, State#state.symbol_index, undefined) of
                    undefined -> [];
                    Files -> lists:delete(FilePath, Files)
                end
            end, Symbols),
            
            % Find files with similar ngrams
            Ngrams = compute_ngrams(Content),
            SimilarByNgrams = search_ngrams(Ngrams, State#state.ngram_index),
            
            % Combine results
            AllFiles = lists:usort(SimilarBySymbols ++ [F || {F, _} <- SimilarByNgrams]),
            AllFiles -- [FilePath]
    end.

extract_symbols(FilePath, Content) ->
    Ext = filename:extension(FilePath),
    extract_symbols_by_ext(Ext, Content).

extract_symbols_by_ext(".erl", Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^([a-z][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => function, line => 0}};
            _ ->
                case re:run(Line, "-record\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
                    {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => record}};
                    _ ->
                        case re:run(Line, "-define\\s*\\(\\s*([A-Z][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
                            {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => macro}};
                            _ -> false
                        end
                end
        end
    end, Lines);

extract_symbols_by_ext(".ex", Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^\\s*defp?\\s+([a-z_][a-zA-Z0-9_?!]*)", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => function}};
            _ ->
                case re:run(Line, "defmodule\\s+([A-Z][a-zA-Z0-9\\.]*)", [{capture, [1], binary}]) of
                    {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => module}};
                    _ -> false
                end
        end
    end, Lines);

extract_symbols_by_ext(_, _) -> [].

detect_language(FilePath) ->
    Ext = filename:extension(FilePath),
    case Ext of
        ".erl" -> erlang;
        ".hrl" -> erlang;
        ".ex" -> elixir;
        ".exs" -> elixir;
        ".py" -> python;
        ".js" -> javascript;
        ".ts" -> typescript;
        ".go" -> golang;
        ".rs" -> rust;
        ".c" -> c;
        ".cpp" -> cpp;
        _ -> unknown
    end.

compute_ngrams(Content) when is_binary(Content) ->
    Binary = binary:replace(Content, <<" ">>, <<>>, [global]),
    Binary2 = binary:replace(Binary, <<"\n">>, <<>>, [global]),
    Words = binary:split(Binary2, <<" ">>, [global, trim_all]),
    lists:flatmap(fun(Word) ->
        case byte_size(Word) >= ?DEFAULT_NGRAM_SIZE of
            true -> [binary:part(Word, I, ?DEFAULT_NGRAM_SIZE) 
                    || I <- lists:seq(0, byte_size(Word) - ?DEFAULT_NGRAM_SIZE)];
            false -> []
        end
    end, Words);
compute_ngrams(Content) when is_list(Content) ->
    compute_ngrams(iolist_to_binary(Content)).

update_symbol_index(FilePath, Symbols, SymbolIndex) ->
    lists:foldl(fun(#{name := Name}, Acc) ->
        maps:update_with(Name, fun(Files) -> [FilePath | lists:delete(FilePath, Files)] end, [FilePath], Acc)
    end, SymbolIndex, Symbols).

update_ngram_index(FilePath, Ngrams, NgramIndex) ->
    UniqueNgrams = lists:usort(Ngrams),
    lists:foldl(fun(Ngram, Acc) ->
        maps:update_with(Ngram, fun(Files) -> [FilePath | lists:delete(FilePath, Files)] end, [FilePath], Acc)
    end, NgramIndex, UniqueNgrams).

ensure_string(Bin) when is_binary(Bin) -> binary_to_list(Bin);
ensure_string(Str) when is_list(Str) -> Str.