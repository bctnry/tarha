-module(coding_agent_session_test).
-include_lib("eunit/include/eunit.hrl").

%% Session lifecycle: create, stats, clear, stop
create_session_test() ->
    application:ensure_all_started(coding_agent),
    {ok, {Id, Pid}} = coding_agent_session:new(),
    ?assert(is_binary(Id)),
    ?assert(is_pid(Pid)),
    coding_agent_session:stop_session(Id).

session_stats_test() ->
    application:ensure_all_started(coding_agent),
    {ok, {Id, _Pid}} = coding_agent_session:new(),
    {ok, Stats} = coding_agent_session:stats(Id),
    ?assert(maps:is_key(<<"model">>, Stats)),
    ?assert(maps:is_key(<<"message_count">>, Stats)),
    coding_agent_session:stop_session(Id).

clear_session_test() ->
    application:ensure_all_started(coding_agent),
    {ok, {Id, _Pid}} = coding_agent_session:new(),
    ok = coding_agent_session:clear(Id),
    coding_agent_session:stop_session(Id).

stop_session_test() ->
    application:ensure_all_started(coding_agent),
    {ok, {Id, Pid}} = coding_agent_session:new(),
    ok = coding_agent_session:stop_session(Id),
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)).

%% Stats on non-existent session returns error
stats_missing_session_test() ->
    application:ensure_all_started(coding_agent),
    Result = coding_agent_session:stats(<<"no-such-session">>),
    ?assertEqual({error, session_not_found}, Result).