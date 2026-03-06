-module(coding_agent_self).
-behaviour(gen_server).
-export([start_link/0, reload_module/1, reload_all/0, get_modules/0, analyze_self/0, create_checkpoint/0, restore_checkpoint/1, list_checkpoints/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {}).
-define(CHECKPOINT_DIR, ".coding_agent_checkpoints").
-define(MODULES, [coding_agent_app, coding_agent_sup, coding_agent_ollama, coding_agent_tools, coding_agent, coding_agent_session_sup, coding_agent_session, coding_agent_stream, coding_agent_lsp, coding_agent_index, coding_agent_self]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
reload_module(M) -> gen_server:call(?MODULE, {reload_module, M}).
reload_all() -> gen_server:call(?MODULE, reload_all).
get_modules() -> gen_server:call(?MODULE, get_modules).
analyze_self() -> gen_server:call(?MODULE, analyze_self, 60000).
create_checkpoint() -> gen_server:call(?MODULE, create_checkpoint).
restore_checkpoint(Id) -> gen_server:call(?MODULE, {restore_checkpoint, Id}).
list_checkpoints() -> gen_server:call(?MODULE, list_checkpoints).

init([]) -> filelib:ensure_dir(?CHECKPOINT_DIR ++ "/"), {ok, #state{}}.

handle_call({reload_module, M}, _From, S) -> {reply, do_reload(M), S};
handle_call(reload_all, _From, S) -> {reply, [{M, do_reload(M)} || M <- ?MODULES], S};
handle_call(get_modules, _From, S) -> {reply, [mod_info(M) || M <- ?MODULES], S};
handle_call(analyze_self, _From, S) -> {reply, analyze(), S};
handle_call(create_checkpoint, _From, S) -> {reply, checkpoint(), S};
handle_call({restore_checkpoint, Id}, _From, S) -> {reply, restore(Id), S};
handle_call(list_checkpoints, _From, S) -> {reply, checkpoints(), S};
handle_call(_, _From, S) -> {reply, {error, unknown}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

do_reload(M) ->
    code:soft_purge(M),
    case code:load_file(M) of
        {module, M} -> #{success => true, module => M};
        {error, E} -> #{success => false, error => atom_to_binary(E, utf8)}
    end.

mod_info(M) ->
    #{name => M, loaded => code:is_loaded(M) =/= false, path => case code:which(M) of non_existing -> undefined; P -> list_to_binary(P) end}.

analyze() ->
    #{modules => [analyze_mod(M) || M <- ?MODULES]}.

analyze_mod(M) ->
    case code:which(M) of
        Beam when is_list(Beam) -> #{module => M, loaded => true, path => list_to_binary(Beam)};
        _ -> #{module => M, loaded => false}
    end.

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
        true -> code:soft_purge(M), code:load_file(M);
        false -> ok
    end.

checkpoints() ->
    case filelib:is_dir(?CHECKPOINT_DIR) of
        false -> [];
        true -> [#{id => list_to_binary(filename:basename(D))} || D <- filelib:wildcard(filename:join(?CHECKPOINT_DIR, "*"))]
    end.