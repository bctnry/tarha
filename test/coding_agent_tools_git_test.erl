-module(coding_agent_tools_git_test).
-include_lib("eunit/include/eunit.hrl").

%% Read-only git operations that work in any git repo
git_status_test() ->
    Result = coding_agent_tools:execute(<<"git_status">>, #{}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_log_test() ->
    Result = coding_agent_tools:execute(<<"git_log">>, #{<<"count">> => 5}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_branch_list_test() ->
    Result = coding_agent_tools:execute(<<"git_branch">>, #{<<"action">> => <<"list">>}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_diff_test() ->
    Result = coding_agent_tools:execute(<<"git_diff">>, #{}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_stash_list_test() ->
    Result = coding_agent_tools:execute(<<"git_stash">>, #{<<"action">> => <<"list">>}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_remote_list_test() ->
    Result = coding_agent_tools:execute(<<"git_remote">>, #{<<"action">> => <<"list">>}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

git_tag_list_test() ->
    Result = coding_agent_tools:execute(<<"git_tag">>, #{<<"action">> => <<"list">>}),
    ?assertEqual(true, maps:get(<<"success">>, Result)).