-module(coding_agent_index).
-behaviour(gen_server).
-export([start_link/1, start_link/2, stop/1]).
-export([index_file/2, index_directory/2, search/2, search/3, similar/2, stats/1]).
-export([clear/1, rebuild/1]).
-export([invalidate/2, get_module_info/2, find_definition/2, find_references/2, get_callers/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Code intelligence index for the coding agent.
%% Parses Erlang/Elixir modules for structure, builds cross-reference maps,
%% caches to .tarha/index/, and supports incremental updates.

-record(state, {
    project_root :: string(),
    %% Per-file index: FilePath -> #{module, exports, functions, records, types, imports, mtime, ...}
    file_index :: #{string() => map()},
    %% Module name -> FilePath (for definition lookups)
    module_map :: #{atom() => string()},
    %% Function {Name, Arity} -> [{FilePath, Line}] (for definition lookups)
    fun_defs :: {{atom(), non_neg_integer()}, [{string(), non_neg_integer()}]},
    %% Cross-reference: FilePath -> [CalledModule] (which modules this file uses)
    xref_calls :: #{string() => [atom()]},
    %% Reverse xref: Module -> [FilePath] (which files call this module)
    xref_called_by :: #{atom() => [string()]},
    %% N-gram index for fuzzy search
    ngram_index :: #{binary() => [string()]},
    %% Symbol -> Files
    symbol_index :: #{atom() => [string()]}
}).

-define(DEFAULT_NGRAM_SIZE, 3).
-define(MAX_INDEXED_FILES, 10000).
-define(INDEX_DIR, ".tarha/index").

%%===================================================================
%% API
%%===================================================================

start_link(ProjectRoot) ->
    start_link(ProjectRoot, #{}).

start_link(ProjectRoot, _Options) when is_list(ProjectRoot) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [ProjectRoot], []).

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
    gen_server:call(Pid, rebuild, 30000).

%% @doc Invalidate index for a single file (for incremental updates after edit)
invalidate(Pid, FilePath) ->
    gen_server:call(Pid, {invalidate, FilePath}, 5000).

%% @doc Get parsed module info for a file
get_module_info(Pid, FilePath) ->
    gen_server:call(Pid, {get_module_info, FilePath}, 5000).

%% @doc Find where a function is defined
find_definition(Pid, FunName) when is_atom(FunName) ->
    gen_server:call(Pid, {find_definition, FunName}, 10000);
find_definition(Pid, FunName) when is_binary(FunName) ->
    case safe_binary_to_existing_atom(FunName) of
        {ok, Atom} -> find_definition(Pid, Atom);
        {error, _} -> {ok, []}
    end.

%% @doc Find all references to a module/function
find_references(Pid, FunName) when is_atom(FunName) ->
    gen_server:call(Pid, {find_references, FunName}, 10000);
find_references(Pid, FunName) when is_binary(FunName) ->
    case safe_binary_to_existing_atom(FunName) of
        {ok, Atom} -> find_references(Pid, Atom);
        {error, _} -> {ok, []}
    end.

%% @doc Find all callers of a module
get_callers(Pid, Module) when is_atom(Module) ->
    gen_server:call(Pid, {get_callers, Module}, 10000);
get_callers(Pid, Module) when is_binary(Module) ->
    case safe_binary_to_existing_atom(Module) of
        {ok, Atom} -> get_callers(Pid, Atom);
        {error, _} -> {ok, []}
    end.

%% @doc Safely convert binary to existing atom
safe_binary_to_existing_atom(Binary) when is_binary(Binary) ->
    try binary_to_existing_atom(Binary, utf8) of
        Atom -> {ok, Atom}
    catch
        error:badarg -> {error, not_found}
    end;
safe_binary_to_existing_atom(_) -> {error, invalid_input}.

%%===================================================================
%% gen_server callbacks
%%===================================================================

init([ProjectRoot]) ->
    process_flag(trap_exit, true),
    State = #state{
        project_root = ProjectRoot,
        file_index = #{},
        module_map = #{},
        fun_defs = #{},
        xref_calls = #{},
        xref_called_by = #{},
        ngram_index = #{},
        symbol_index = #{}
    },
    %% Try loading cached index from disk
    LoadedState = load_index_from_disk(State),
    {ok, LoadedState}.

handle_call({index_file, FilePath}, _From, State) ->
    case do_index_file(FilePath, State) of
        {ok, NewState} ->
            persist_index(NewState),
            {reply, ok, NewState};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({index_directory, DirPath}, _From, State) ->
    case do_index_directory(DirPath, State) of
        {ok, NewState} ->
            persist_index(NewState),
            {reply, ok, NewState};
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
        total_files => map_size(State#state.file_index),
        total_modules => map_size(State#state.module_map),
        total_symbols => map_size(State#state.symbol_index),
        total_ngrams => map_size(State#state.ngram_index),
        total_xref_entries => map_size(State#state.xref_calls)
    },
    {reply, {ok, Stats}, State};

handle_call(clear, _From, State) ->
    NewState = State#state{
        file_index = #{}, module_map = #{}, fun_defs = #{},
        xref_calls = #{}, xref_called_by = #{},
        ngram_index = #{}, symbol_index = #{}
    },
    {reply, ok, NewState};

handle_call(rebuild, _From, State = #state{project_root = Root}) ->
    CleanState = State#state{
        file_index = #{}, module_map = #{}, fun_defs = #{},
        xref_calls = #{}, xref_called_by = #{},
        ngram_index = #{}, symbol_index = #{}
    },
    case do_index_directory(Root, CleanState) of
        {ok, NewState} ->
            persist_index(NewState),
            {reply, ok, NewState};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;

handle_call({invalidate, FilePath}, _From, State) ->
    NewState = do_invalidate_file(FilePath, State),
    {reply, ok, NewState};

handle_call({get_module_info, FilePath}, _From, State) ->
    Result = case maps:get(FilePath, State#state.file_index, undefined) of
        undefined -> {error, not_indexed};
        Info -> {ok, Info}
    end,
    {reply, Result, State};

handle_call({find_definition, FunName}, _From, State) ->
    Results = maps:get(FunName, State#state.fun_defs, []),
    {reply, {ok, Results}, State};

handle_call({find_references, FunName}, _From, State) ->
    Results = search_fun_references(FunName, State),
    {reply, {ok, Results}, State};

handle_call({get_callers, Module}, _From, State) ->
    Results = maps:get(Module, State#state.xref_called_by, []),
    {reply, {ok, Results}, State};

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
%% Internal: File indexing
%%===================================================================

do_index_file(FilePath, State) ->
    case file:read_file(FilePath) of
        {ok, Content} ->
            Ext = filename:extension(FilePath),
            {ParsedInfo, Symbols, Ngrams} = case Ext of
                ".erl" ->
                    {parse_erlang_module(FilePath, Content),
                     extract_erlang_symbols(Content),
                     compute_ngrams(Content)};
                ".hrl" ->
                    {parse_erlang_header(FilePath, Content),
                     extract_erlang_symbols(Content),
                     compute_ngrams(Content)};
                ".ex" ->
                    {parse_elixir_module(FilePath, Content),
                     extract_elixir_symbols(Content),
                     compute_ngrams(Content)};
                ".exs" ->
                    {#{filepath => FilePath, language => elixir},
                     extract_elixir_symbols(Content),
                     compute_ngrams(Content)};
                _ ->
                    {#{filepath => FilePath, language => detect_language(FilePath)},
                     [],
                     compute_ngrams(Content)}
            end,
            FileData = ParsedInfo#{
                filepath => FilePath,
                symbols => Symbols,
                mtime => filelib:last_modified(FilePath)
            },
            %% Remove old data for this file first
            CleanState = do_invalidate_file(FilePath, State),
            %% Update all indices
            NewFileIndex = maps:put(FilePath, FileData, CleanState#state.file_index),
            NewModuleMap = case maps:get(module, ParsedInfo, undefined) of
                undefined -> CleanState#state.module_map;
                Mod -> maps:put(Mod, FilePath, CleanState#state.module_map)
            end,
            NewFunDefs = update_fun_defs(FilePath, maps:get(functions, ParsedInfo, []), CleanState#state.fun_defs),
            NewXrefCalls = case maps:get(calls, ParsedInfo, undefined) of
                undefined -> CleanState#state.xref_calls;
                Calls -> maps:put(FilePath, Calls, CleanState#state.xref_calls)
            end,
            NewXrefCalledBy = case maps:get(calls, ParsedInfo, undefined) of
                undefined -> CleanState#state.xref_called_by;
                CalledCalls ->
                    lists:foldl(fun(CalledMod, Acc) ->
                        maps:update_with(CalledMod, fun(Files) -> [FilePath | lists:delete(FilePath, Files)] end, [FilePath], Acc)
                    end, CleanState#state.xref_called_by, CalledCalls)
            end,
            NewSymbolIndex = update_symbol_index(FilePath, Symbols, CleanState#state.symbol_index),
            NewNgramIndex = update_ngram_index(FilePath, Ngrams, CleanState#state.ngram_index),
            {ok, CleanState#state{
                file_index = NewFileIndex,
                module_map = NewModuleMap,
                fun_defs = NewFunDefs,
                xref_calls = NewXrefCalls,
                xref_called_by = NewXrefCalledBy,
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
    SortedFiles = lists:sort(Files),
    IndexFun = fun(FilePath, AccState) ->
        %% Skip files that haven't changed (mtime check)
        case maps:get(FilePath, AccState#state.file_index, undefined) of
            #{mtime := OldMTime} ->
                case filelib:last_modified(FilePath) of
                    OldMTime -> AccState;  %% Unchanged, skip
                    0 -> AccState;           %% File deleted
                    _NewMTime -> 
                        case do_index_file(FilePath, AccState) of
                            {ok, S} -> S;
                            {error, _} -> AccState
                        end
                end;
            _ ->
                case do_index_file(FilePath, AccState) of
                    {ok, S} -> S;
                    {error, _} -> AccState
                end
        end
    end,
    FinalState = lists:foldl(IndexFun, State, lists:sublist(SortedFiles, ?MAX_INDEXED_FILES)),
    {ok, FinalState}.

do_invalidate_file(FilePath, State) ->
    %% Remove from file_index
    NewFileIndex = maps:remove(FilePath, State#state.file_index),
    %% Remove from module_map
    OldModule = case maps:get(FilePath, State#state.file_index, undefined) of
        undefined -> undefined;
        #{module := Mod} -> Mod;
        _ -> undefined
    end,
    NewModuleMap = case OldModule of
        undefined -> State#state.module_map;
        _ when is_atom(OldModule) ->
            case maps:get(OldModule, State#state.module_map, undefined) of
                FilePath -> maps:remove(OldModule, State#state.module_map);
                _ -> State#state.module_map
            end
    end,
    %% Remove from fun_defs
    NewFunDefs = maps:map(fun(_Key, Locations) ->
        lists:filter(fun({FP, _Line}) -> FP =/= FilePath end, Locations)
    end, State#state.fun_defs),
    %% Remove from xref
    NewXrefCalls = maps:remove(FilePath, State#state.xref_calls),
    NewXrefCalledBy = maps:map(fun(_Mod, Files) ->
        lists:delete(FilePath, Files)
    end, State#state.xref_called_by),
    %% Remove from symbol_index
    NewSymbolIndex = maps:map(fun(_Sym, Files) ->
        lists:delete(FilePath, Files)
    end, State#state.symbol_index),
    %% Remove from ngram_index
    NewNgramIndex = maps:map(fun(_NG, Files) ->
        lists:delete(FilePath, Files)
    end, State#state.ngram_index),
    State#state{
        file_index = NewFileIndex,
        module_map = NewModuleMap,
        fun_defs = NewFunDefs,
        xref_calls = NewXrefCalls,
        xref_called_by = NewXrefCalledBy,
        symbol_index = NewSymbolIndex,
        ngram_index = NewNgramIndex
    }.

%%===================================================================
%% Internal: Erlang parsing
%%===================================================================

parse_erlang_module(_FilePath, Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    ModuleName = extract_module_name(Lines),
    Exports = extract_exports(Lines),
    Imports = extract_imports(Lines),
    Includes = extract_includes(Lines),
    Functions = extract_functions(Lines),
    Records = extract_records(Lines),
    Types = extract_types(Lines),
    Specs = extract_specs(Lines),
    Calls = extract_calls(ModuleName, Content),
    #{module => ModuleName,
      language => erlang,
      exports => Exports,
      imports => Imports,
      includes => Includes,
      functions => Functions,
      records => Records,
      types => Types,
      specs => Specs,
      calls => Calls}.

parse_erlang_header(FilePath, Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    Records = extract_records(Lines),
    Types = extract_types(Lines),
    Defines = extract_defines(Lines),
    #{filepath => FilePath,
      language => erlang_header,
      records => Records,
      types => Types,
      defines => Defines}.

extract_module_name(Lines) ->
    case lists:search(fun(Line) ->
        re:run(Line, "^-module\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)\\s*\\)", [{capture, [1], binary}]) =/= nomatch
    end, Lines) of
        {value, Line} ->
            {match, [Name]} = re:run(Line, "^-module\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)\\s*\\)", [{capture, [1], binary}]),
            binary_to_atom(Name, utf8);
        false -> undefined
    end.

extract_exports(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-export\\s*\\(\\s*\\[(.+)\\]\\s*\\)\\.", [{capture, [1], binary}]) of
            {match, [ExportStr]} ->
                Funs = parse_fun_list(ExportStr),
                {true, Funs};
            nomatch -> false
        end
    end, Lines).

parse_fun_list(Bin) ->
    %% Parse "fun1/0, fun2/1, ..." format
    Parts = binary:split(Bin, <<",">>, [global, trim_all]),
    lists:filtermap(fun(Part) ->
        case re:run(Part, "\\s*([a-z_][a-zA-Z0-9_@]*)\\s*/\\s*([0-9]+)\\s*", [{capture, [1, 2], binary}]) of
            {match, [Name, Arity]} ->
                try
                    {true, {binary_to_atom(Name, utf8), binary_to_integer(Arity)}}
                catch
                    error:badarg -> false
                end;
            _ -> false
        end
    end, Parts).

extract_imports(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-import\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)\\s*,", [{capture, [1], binary}]) of
            {match, [Mod]} -> {true, binary_to_atom(Mod, utf8)};
            _ -> false
        end
    end, Lines).

extract_includes(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-include_lib\\s*\\(\\s*\"([^\"]+)\"\\s*\\)", [{capture, [1], binary}]) of
            {match, [Path]} -> {true, {include_lib, Path}};
            _ ->
                case re:run(Line, "^-include\\s*\\(\\s*\"([^\"]+)\"\\s*\\)", [{capture, [1], binary}]) of
                    {match, [Path]} -> {true, {include, Path}};
                    _ -> false
                end
        end
    end, Lines).

extract_functions(Lines) ->
    lists:filtermap(fun({LineNum, Line}) ->
        case re:run(Line, "^([a-z_][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} ->
                %% Count commas in args to estimate arity (rough)
                Arity = estimate_arity(Line),
                {true, {binary_to_atom(Name, utf8), Arity, LineNum}};
            _ -> false
        end
    end, lists:enumerate(1, Lines)).

estimate_arity(Line) ->
    %% Find the opening paren and count commas until closing paren
    case re:run(Line, "([a-z_][a-zA-Z0-9_@]*)\\s*\\(([^)]*)\\)", [{capture, [2], binary}]) of
        {match, [Args]} ->
            case Args of
                <<>> -> 0;
                _ ->
                    %% Count top-level commas
                    Commas = length(binary:matches(Args, <<",">>)),
                    Commas + 1
            end;
        _ -> 0
    end.

extract_records(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-record\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)\\s*,", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, binary_to_atom(Name, utf8)};
            _ -> false
        end
    end, Lines).

extract_types(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-type\\s+([a-z_][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, binary_to_atom(Name, utf8)};
            _ ->
                case re:run(Line, "^-opaque\\s+([a-z_][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
                    {match, [Name]} -> {true, binary_to_atom(Name, utf8)};
                    _ -> false
                end
        end
    end, Lines).

extract_specs(Lines) ->
    lists:filtermap(fun({LineNum, Line}) ->
        case re:run(Line, "^-spec\\s+([a-z_][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, {binary_to_atom(Name, utf8), LineNum}};
            _ -> false
        end
    end, lists:enumerate(1, Lines)).

extract_defines(Lines) ->
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^-define\\s*\\(\\s*([A-Z_][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, binary_to_atom(Name, utf8)};
            _ -> false
        end
    end, Lines).

extract_calls(ModuleName, Content) ->
    %% Find all module:fun() calls that reference other modules
    {ok, MP} = re:compile("([a-z_][a-zA-Z0-9_@]*):([a-z_][a-zA-Z0-9_@]*)\\s*\\("),
    case re:run(Content, MP, [global, {capture, [1], binary}]) of
        {match, Matches} ->
            CalledModules = lists:usort([binary_to_atom(M, utf8) || [M] <- Matches, M =/= atom_to_binary(ModuleName, utf8)]),
            CalledModules;
        nomatch -> []
    end.

%%===================================================================
%% Internal: Elixir parsing
%%===================================================================

parse_elixir_module(_FilePath, Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    ModuleName = extract_ex_module_name(Lines),
    Functions = extract_ex_functions(Lines),
    Calls = extract_ex_calls(ModuleName, Content),
    #{module => ModuleName,
      language => elixir,
      functions => Functions,
      calls => Calls}.

extract_ex_module_name(Lines) ->
    case lists:search(fun(Line) ->
        re:run(Line, "defmodule\\s+([A-Z][a-zA-Z0-9\\.]*)", [{capture, [1], binary}]) =/= nomatch
    end, Lines) of
        {value, Line} ->
            {match, [Name]} = re:run(Line, "defmodule\\s+([A-Z][a-zA-Z0-9\\.]*)", [{capture, [1], binary}]),
            binary_to_atom(Name, utf8);
        false -> undefined
    end.

extract_ex_functions(Lines) ->
    lists:filtermap(fun({LineNum, Line}) ->
        case re:run(Line, "^\\s*defp?\\s+([a-z_][a-zA-Z0-9_?!]*)", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, {binary_to_atom(Name, utf8), 0, LineNum}};
            _ -> false
        end
    end, lists:enumerate(1, Lines)).

extract_ex_calls(_ModuleName, Content) ->
    {ok, MP} = re:compile("([A-Z][a-zA-Z0-9\\.]*)\\.([a-z_][a-zA-Z0-9_?!]*)\\s*\\("),
    case re:run(Content, MP, [global, {capture, [1], binary}]) of
        {match, Matches} ->
            lists:usort([binary_to_atom(M, utf8) || [M] <- Matches]);
        nomatch -> []
    end.

%%===================================================================
%% Internal: Symbol extraction (for symbol index)
%%===================================================================

extract_erlang_symbols(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    lists:filtermap(fun(Line) ->
        case re:run(Line, "^([a-z][a-zA-Z0-9_@]*)\\s*\\(", [{capture, [1], binary}]) of
            {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => function}};
            _ ->
                case re:run(Line, "^-record\\s*\\(\\s*([a-z][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
                    {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => record}};
                    _ ->
                        case re:run(Line, "^-define\\s*\\(\\s*([A-Z][a-zA-Z0-9_@]*)", [{capture, [1], binary}]) of
                            {match, [Name]} -> {true, #{name => binary_to_atom(Name, utf8), kind => macro}};
                            _ -> false
                        end
                end
        end
    end, Lines).

extract_elixir_symbols(Content) ->
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
    end, Lines).

%%===================================================================
%% Internal: Index helpers
%%===================================================================

update_fun_defs(FilePath, Functions, FunDefs) ->
    lists:foldl(fun({Name, Arity, Line}, Acc) ->
        Key = {Name, Arity},
        maps:update_with(Key, fun(Locs) -> [{FilePath, Line} | lists:keydelete(FilePath, 1, Locs)] end, [{FilePath, Line}], Acc)
    end, FunDefs, Functions).

update_symbol_index(FilePath, Symbols, SymbolIndex) ->
    lists:foldl(fun(#{name := Name}, Acc) ->
        maps:update_with(Name, fun(Files) -> [FilePath | lists:delete(FilePath, Files)] end, [FilePath], Acc)
    end, SymbolIndex, Symbols).

update_ngram_index(FilePath, Ngrams, NgramIndex) ->
    UniqueNgrams = lists:usort(Ngrams),
    lists:foldl(fun(Ngram, Acc) ->
        maps:update_with(Ngram, fun(Files) -> [FilePath | lists:delete(FilePath, Files)] end, [FilePath], Acc)
    end, NgramIndex, UniqueNgrams).

compute_ngrams(Content) when is_binary(Content) ->
    AlphaContent = re:replace(Content, "[^a-zA-Z0-9_]", " ", [global, {return, binary}]),
    Words = binary:split(AlphaContent, <<" ">>, [global, trim_all]),
    lists:flatmap(fun(Word) ->
        case byte_size(Word) >= ?DEFAULT_NGRAM_SIZE of
            true -> [binary:part(Word, I, ?DEFAULT_NGRAM_SIZE)
                    || I <- lists:seq(0, byte_size(Word) - ?DEFAULT_NGRAM_SIZE)];
            false -> []
        end
    end, Words);
compute_ngrams(Content) when is_list(Content) ->
    compute_ngrams(iolist_to_binary(Content)).

detect_language(FilePath) ->
    case filename:extension(FilePath) of
        ".erl" -> erlang;
        ".hrl" -> erlang;
        ".ex" -> elixir;
        ".exs" -> elixir;
        ".py" -> python;
        ".js" -> javascript;
        ".ts" -> typescript;
        ".go" -> golang;
        ".rs" -> rust;
        _ -> unknown
    end.

%%===================================================================
%% Internal: Search
%%===================================================================

do_search(Query, _Options, State) ->
    QueryBin = iolist_to_binary(Query),
    SymbolResults = search_symbols(Query, State#state.symbol_index),
    NgramResults = search_ngrams(QueryBin, State#state.ngram_index),
    ModuleResults = search_modules(Query, State#state.module_map),
    AllResults = SymbolResults ++ NgramResults ++ ModuleResults,
    rank_results(Query, AllResults, State#state.file_index).

search_symbols(Query, SymbolIndex) ->
    QueryLower = string:lowercase(iolist_to_binary(Query)),
    maps:fold(fun(Symbol, Files, Acc) ->
        SymbolBin = atom_to_binary(Symbol, utf8),
        case string:find(string:lowercase(SymbolBin), QueryLower) of
            nomatch -> Acc;
            _ -> [{File, Symbol} || File <- Files] ++ Acc
        end
    end, [], SymbolIndex).

search_ngrams(Query, NgramIndex) ->
    QueryNgrams = compute_ngrams(Query),
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

search_modules(Query, ModuleMap) ->
    QueryLower = string:lowercase(iolist_to_binary(Query)),
    maps:fold(fun(Mod, FilePath, Acc) ->
        ModBin = atom_to_binary(Mod, utf8),
        case string:find(string:lowercase(ModBin), QueryLower) of
            nomatch -> Acc;
            _ -> [{FilePath, Mod} | Acc]
        end
    end, [], ModuleMap).

search_fun_references(FunName, State) ->
    %% Search for FunName in all indexed files' content
    FunBin = atom_to_binary(FunName, utf8),
    Pattern = <<FunBin/binary, "\\s*\\(">>,
    {ok, MP} = re:compile(Pattern),
    maps:fold(fun(FilePath, FileData, Acc) ->
        _Content = maps:get(content, FileData, <<>>),
        %% Content might not be stored; read from disk
        case file:read_file(FilePath) of
            {ok, FileContent} ->
                case re:run(FileContent, MP, [global]) of
                    {match, Matches} ->
                        [{FilePath, length(Matches)} | Acc];
                    nomatch -> Acc
                end;
            _ -> Acc
        end
    end, [], State#state.file_index).

rank_results(Query, Results, _Index) ->
    _QueryLower = string:lowercase(iolist_to_binary(Query)),
    Normalized = lists:map(fun
        ({File, Score}) when is_list(File), is_number(Score) -> {File, Score};
        ({File, _Symbol}) when is_list(File) -> {File, 1};
        (File) when is_list(File) -> {File, 1}
    end, Results),
    Merged = merge_scores(Normalized),
    lists:sort(fun({_, ScoreA}, {_, ScoreB}) -> ScoreA > ScoreB end, Merged).

merge_scores(ScoredList) ->
    Merged = lists:foldl(fun({File, Score}, Acc) ->
        maps:update_with(File, fun(S) -> S + Score end, Score, Acc)
    end, #{}, ScoredList),
    maps:to_list(Merged).

do_find_similar(FilePath, State) ->
    case maps:get(FilePath, State#state.file_index, undefined) of
        undefined -> [];
        FileData ->
            Symbols = maps:get(symbols, FileData, []),
            SimilarBySymbols = lists:flatmap(fun(#{name := Name}) ->
                case maps:get(Name, State#state.symbol_index, undefined) of
                    undefined -> [];
                    Files -> lists:delete(FilePath, Files)
                end
            end, Symbols),
            AllFiles = lists:usort(SimilarBySymbols),
            AllFiles -- [FilePath]
    end.

%%===================================================================
%% Internal: Persistence
%%===================================================================

load_index_from_disk(State) ->
    IndexFile = filename:join(?INDEX_DIR, "index.term"),
    case file:read_file(IndexFile) of
        {ok, Bin} ->
            try
                Term = binary_to_term(Bin),
                State#state{
                    file_index = maps:get(file_index, Term, #{}),
                    module_map = maps:get(module_map, Term, #{}),
                    fun_defs = maps:get(fun_defs, Term, #{}),
                    xref_calls = maps:get(xref_calls, Term, #{}),
                    xref_called_by = maps:get(xref_called_by, Term, #{}),
                    symbol_index = maps:get(symbol_index, Term, #{}),
                    ngram_index = maps:get(ngram_index, Term, #{})
                }
            catch
                _:_ -> State
            end;
        _ -> State
    end.

persist_index(State) ->
    try
        filelib:ensure_dir(filename:join(?INDEX_DIR, "index.term") ++ "/.."),
        Term = #{
            file_index => State#state.file_index,
            module_map => State#state.module_map,
            fun_defs => State#state.fun_defs,
            xref_calls => State#state.xref_calls,
            xref_called_by => State#state.xref_called_by,
            symbol_index => State#state.symbol_index,
            ngram_index => State#state.ngram_index
        },
        IndexFile = filename:join(?INDEX_DIR, "index.term"),
        ok = file:write_file(IndexFile, term_to_binary(Term)),
        ok
    catch
        _:_ -> ok
    end.
