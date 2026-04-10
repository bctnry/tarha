-module(coding_agent_self).
-behaviour(gen_server).
-export([start_link/0, reload_module/1, reload_module/2, reload_all/0, rollback/1, rollback_latest/0, 
         get_modules/0, get_versions/1, analyze_self/0, create_checkpoint/0, restore_checkpoint/1, list_checkpoints/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {versions = #{} :: #{atom() => [{binary(), integer()}]}}).  % module => [{VersionPath, Timestamp}]
-define(VERSIONS_DIR, ".tarha/versions").
-define(CHECKPOINT_DIR, ".tarha/checkpoints").
-define(MAX_VERSIONS, 5).  % Keep last 5 versions per module
-define(MODULES, [coding_agent_app, coding_agent_sup, coding_agent_ollama, coding_agent_tools, coding_agent,
                  coding_agent_session_sup, coding_agent_session, coding_agent_stream, coding_agent_lsp,
                  coding_agent_index, coding_agent_self, coding_agent_healer, coding_agent_process_monitor,
                  coding_agent_conv_memory, coding_agent_skills, coding_agent_cli, coding_agent_repl,
                  coding_agent_undo, coding_agent_request_registry]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
reload_module(M) -> reload_module(M, #{rollback_on_crash => true}).
reload_module(M, Opts) -> gen_server:call(?MODULE, {reload_module, M, Opts}).
reload_all() -> gen_server:call(?MODULE, reload_all, 120000).
rollback(M) -> gen_server:call(?MODULE, {rollback, M}).
rollback_latest() -> gen_server:call(?MODULE, rollback_latest).
get_modules() -> gen_server:call(?MODULE, get_modules).
get_versions(M) -> gen_server:call(?MODULE, {get_versions, M}).
analyze_self() -> gen_server:call(?MODULE, analyze_self, 60000).
create_checkpoint() -> gen_server:call(?MODULE, create_checkpoint).
restore_checkpoint(Id) -> gen_server:call(?MODULE, {restore_checkpoint, Id}).
list_checkpoints() -> gen_server:call(?MODULE, list_checkpoints).

init([]) ->
    filelib:ensure_dir(?VERSIONS_DIR ++ "/"),
    filelib:ensure_dir(?CHECKPOINT_DIR ++ "/"),
    {ok, #state{}}.

handle_call({reload_module, M, Opts}, _From, State) -> 
    {Reply, NewState} = do_reload_with_version(M, Opts, State),
    {reply, Reply, NewState};
handle_call(reload_all, _From, State) -> 
    {Results, NewState} = lists:mapfoldl(fun(M, S) -> 
        {Reply, S2} = do_reload_with_version(M, #{}, S), 
        {{M, Reply}, S2} 
    end, State, ?MODULES),
    {reply, Results, NewState};
handle_call({rollback, M}, _From, State) -> 
    {Reply, NewState} = do_rollback(M, State),
    {reply, Reply, NewState};
handle_call(rollback_latest, _From, State) ->
    {Reply, NewState} = do_rollback_latest(State),
    {reply, Reply, NewState};
handle_call(get_modules, _From, S) -> 
    Modules = [mod_info(M, S) || M <- ?MODULES],
    {reply, Modules, S};
handle_call({get_versions, M}, _From, State) -> 
    Versions = maps:get(M, State#state.versions, []),
    {reply, Versions, State};
handle_call(analyze_self, _From, S) -> {reply, analyze(), S};
handle_call(create_checkpoint, _From, S) -> {reply, checkpoint(), S};
handle_call({restore_checkpoint, Id}, _From, S) -> {reply, restore(Id), S};
handle_call(list_checkpoints, _From, S) -> {reply, checkpoints(), S};
handle_call(_, _From, S) -> {reply, {error, unknown}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

%% Versioned reload with automatic backup

do_reload_with_version(M, Opts, State) ->
    case code:which(M) of
        non_existing ->
            {#{success => false, error => <<"module not loaded">>}, State};
        CurrentBeam ->
            % Archive current version
            ArchiveResult = archive_version(M, CurrentBeam),
            case ArchiveResult of
                {ok, ArchivedPath} ->
                    % Load new version
                    case code:load_file(M) of
                        {module, M} ->
                            % Update version tracking
                            Timestamp = erlang:system_time(millisecond),
                            Versions = maps:get(M, State#state.versions, []),
                            NewVersions = [{ArchivedPath, Timestamp} | Versions],
                            TrimmedVersions = lists:sublist(NewVersions, ?MAX_VERSIONS),
                            NewState = State#state{versions = maps:put(M, TrimmedVersions, State#state.versions)},
                            
                            % Setup crash monitoring if requested
                            case maps:get(rollback_on_crash, Opts, true) of
                                true -> setup_rollback_monitor(M, ArchivedPath);
                                false -> ok
                            end,
                            
                            io:format("[self] Reloaded ~p (archived: ~s)~n", [M, ArchivedPath]),
                            {#{success => true, module => M, archived => ArchivedPath}, NewState};
                        {error, Reason} ->
                            io:format("[self] Failed to reload ~p: ~p~n", [M, Reason]),
                            ErrorMsg = case Reason of
                                not_purged -> <<"module has old processes, cannot purge">>;
                                _ -> iolist_to_binary(io_lib:format("~p", [Reason]))
                            end,
                            {#{success => false, error => ErrorMsg}, State}
                    end;
                {error, Reason} ->
                    io:format("[self] Failed to archive ~p: ~p~n", [M, Reason]),
                    % Try to load anyway
                    case code:load_file(M) of
                        {module, M} -> {#{success => true, module => M, archived => false}, State};
                        {error, Reason2} ->
                            ErrorMsg = case Reason2 of
                                not_purged -> <<"module has old processes, cannot purge">>;
                                _ -> iolist_to_binary(io_lib:format("~p", [Reason2]))
                            end,
                            {#{success => false, error => ErrorMsg}, State}
                    end
            end
    end.

archive_version(M, BeamPath) ->
    Timestamp = integer_to_binary(erlang:system_time(millisecond)),
    VersionDir = filename:join(?VERSIONS_DIR, atom_to_list(M)),
    filelib:ensure_dir(VersionDir ++ "/"),
    VersionPath = filename:join(VersionDir, binary_to_list(<<"v", Timestamp/binary, ".beam">>)),
    case file:copy(BeamPath, VersionPath) of
        {ok, _} -> {ok, list_to_binary(VersionPath)};
        {error, Reason} -> {error, Reason}
    end.

setup_rollback_monitor(M, ArchivedPath) ->
    % Store archived path in process dictionary for crash recovery
    put({rollback_version, M}, ArchivedPath),
    ok.

%% Rollback to previous version

do_rollback(M, State) ->
    Versions = maps:get(M, State#state.versions, []),
    case Versions of
        [] -> 
            {{error, no_previous_version}, State};
        [{ArchivedPath, _Timestamp} | Rest] ->
            case restore_version(M, ArchivedPath) of
                ok ->
                    io:format("[self] Rolled back ~p to ~s~n", [M, ArchivedPath]),
                    NewVersions = maps:put(M, Rest, State#state.versions),
                    {#{success => true, module => M, restored => ArchivedPath}, State#state{versions = NewVersions}};
                {error, Reason} ->
                    io:format("[self] Rollback failed for ~p: ~p~n", [M, Reason]),
                    {{error, Reason}, State}
            end
    end.

do_rollback_latest(State) ->
    % Find the module with the most recent crash
    AllVersions = lists:flatten([
        [{M, Path, Ts} || {Path, Ts} <- Versions]
        || {M, Versions} <- maps:to_list(State#state.versions)
    ]),
    case AllVersions of
        [] -> {{error, no_versions}, State};
        _ ->
            % Sort by timestamp (newest first)
            Sorted = lists:sort(fun({_, _, Ts1}, {_, _, Ts2}) -> Ts1 > Ts2 end, AllVersions),
            [{M, _Path, _} | _] = Sorted,
            do_rollback(M, State)
    end.

restore_version(M, VersionPath) ->
    case filelib:is_file(VersionPath) of
        true ->
            % Purge current version
            code:soft_purge(M),
            % Load archived version
            case code:load_abs(filename:rootname(VersionPath)) of
                {module, M} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        false ->
            {error, version_not_found}
    end.

%% Module info

mod_info(M, State) ->
    #{
        name => M, 
        loaded => code:is_loaded(M) =/= false,
        path => case code:which(M) of 
            non_existing -> undefined; 
            P -> list_to_binary(P) 
        end,
        current_version => get_current_version_from_state(M, State)
    }.

get_current_version_from_state(M, State) ->
    Versions = maps:get(M, State#state.versions, []),
    case Versions of
        [{Path, _} | _] -> Path;
        _ -> undefined
    end.

analyze() ->
    #{modules => [analyze_mod(M) || M <- ?MODULES], 
      versions_dir => list_to_binary(?VERSIONS_DIR)}.

analyze_mod(M) ->
    case code:which(M) of
        Beam when is_list(Beam) -> #{module => M, loaded => true, path => list_to_binary(Beam)};
        _ -> #{module => M, loaded => false}
    end.

%% Checkpoint system (full snapshots)

checkpoint() ->
    filelib:ensure_dir(?CHECKPOINT_DIR ++ "/"),
    Id = integer_to_binary(erlang:system_time(millisecond)),
    Dir = filename:join(?CHECKPOINT_DIR, binary_to_list(Id)),
    file:make_dir(Dir),
    [backup_mod(M, Dir) || M <- ?MODULES],
    #{success => true, id => Id}.

backup_mod(M, Dir) ->
    case code:which(M) of
        Beam when is_list(Beam) -> file:copy(Beam, filename:join(Dir, filename:basename(Beam)));
        _ -> ok
    end.

restore(Id) ->
    Dir = filename:join(?CHECKPOINT_DIR, binary_to_list(Id)),
    case filelib:is_dir(Dir) of
        false -> #{success => false, error => <<"Checkpoint not found">>};
        true ->
            [restore_mod(M, Dir) || M <- ?MODULES],
            #{success => true}
    end.

restore_mod(M, Dir) ->
    Beam = filename:join(Dir, atom_to_list(M) ++ ".beam"),
    case filelib:is_file(Beam) of
        true -> code:soft_purge(M), code:load_abs(filename:rootname(Beam));
        false -> ok
    end.

checkpoints() ->
    case filelib:is_dir(?CHECKPOINT_DIR) of
        false -> [];
        true -> [#{id => list_to_binary(filename:basename(D))} || D <- filelib:wildcard(filename:join(?CHECKPOINT_DIR, "*"))]
    end.