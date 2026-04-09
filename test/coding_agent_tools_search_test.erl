-module(coding_agent_tools_search_test).
-include_lib("eunit/include/eunit.hrl").

%% Grep files in src/
grep_files_test() ->
    Result = coding_agent_tools:execute(<<"grep_files">>, #{
        <<"pattern">> => <<"coding_agent">>,
        <<"path">> => <<"src">>
    }),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Find .erl files in src/
find_files_test() ->
    Result = coding_agent_tools:execute(<<"find_files">>, #{
        <<"pattern">> => <<"*.erl">>,
        <<"path">> => <<"src">>
    }),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Grep with no matches still succeeds
grep_no_matches_test() ->
    Result = coding_agent_tools:execute(<<"grep_files">>, #{
        <<"pattern">> => <<"ZZZ_NO_MATCH_ZZZ">>,
        <<"path">> => <<"src">>
    }),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Find with non-matching pattern
find_no_matches_test() ->
    Result = coding_agent_tools:execute(<<"find_files">>, #{
        <<"pattern">> => <<"*.xyz123">>,
        <<"path">> => <<"src">>
    }),
    ?assertEqual(true, maps:get(<<"success">>, Result)).

%% Grep missing pattern arg — dispatch may crash, so catch
grep_missing_pattern_test() ->
    Result = (catch coding_agent_tools:execute(<<"grep_files">>, #{})),
    ?assertNotMatch(#{<<"success">> := true}, Result).