-module(coding_agent_ansi_test).
-include_lib("eunit/include/eunit.hrl").

%% NO_COLOR suppresses all ANSI codes
no_color_test() ->
    os:putenv("NO_COLOR", "1"),
    ?assertEqual("hello", coding_agent_ansi:bright_red("hello")),
    ?assertEqual("hello", coding_agent_ansi:bold("hello")),
    ?assertEqual("hello", coding_agent_ansi:dim("hello")),
    ?assertEqual("", coding_agent_ansi:reset()),
    os:unsetenv("NO_COLOR").

%% Color functions wrap text with ANSI codes when NO_COLOR is not set
with_color_test() ->
    os:unsetenv("NO_COLOR"),
    Result = coding_agent_ansi:bright_red("hello"),
    ?assertNotEqual("hello", Result),
    ?assertNotEqual(nomatch, string:find(Result, "hello")),
    ?assertNotEqual(nomatch, string:find(Result, "\e[")).

%% Strip removes ANSI codes
strip_string_test() ->
    Colored = "\e[1;31mhello\e[0m",
    ?assertEqual("hello", coding_agent_ansi:strip(Colored)).

strip_binary_test() ->
    Colored = <<"\e[1;31mhello\e[0m">>,
    ?assertEqual(<<"hello">>, coding_agent_ansi:strip(Colored)).

%% Binary inputs work (ensure_list converts)
binary_input_test() ->
    os:unsetenv("NO_COLOR"),
    Result = coding_agent_ansi:bright_magenta(<<"session-id">>),
    ?assert(is_list(Result)),
    ?assertNotEqual(nomatch, string:find(Result, "session-id")).

%% All color functions exist and accept strings
all_colors_test() ->
    os:unsetenv("NO_COLOR"),
    Funs = [fun coding_agent_ansi:black/1, fun coding_agent_ansi:red/1,
             fun coding_agent_ansi:green/1, fun coding_agent_ansi:yellow/1,
             fun coding_agent_ansi:blue/1, fun coding_agent_ansi:magenta/1,
             fun coding_agent_ansi:cyan/1, fun coding_agent_ansi:white/1,
             fun coding_agent_ansi:bright_red/1, fun coding_agent_ansi:bright_green/1,
             fun coding_agent_ansi:bright_yellow/1, fun coding_agent_ansi:bright_blue/1,
             fun coding_agent_ansi:bright_magenta/1, fun coding_agent_ansi:bright_cyan/1,
             fun coding_agent_ansi:bright_white/1],
    lists:foreach(fun(F) ->
        Result = F("x"),
        ?assertNotEqual("x", Result)
    end, Funs).

%% Background color functions exist and accept strings
bg_colors_test() ->
    os:unsetenv("NO_COLOR"),
    Funs = [fun coding_agent_ansi:bg_red/1, fun coding_agent_ansi:bg_green/1,
             fun coding_agent_ansi:bg_yellow/1, fun coding_agent_ansi:bg_blue/1,
             fun coding_agent_ansi:bg_magenta/1, fun coding_agent_ansi:bg_cyan/1,
             fun coding_agent_ansi:bg_white/1],
    lists:foreach(fun(F) ->
        Result = F("x"),
        ?assertNotEqual("x", Result)
    end, Funs).

%% Cursor functions respect NO_COLOR
cursor_no_color_test() ->
    os:putenv("NO_COLOR", "1"),
    ?assertEqual("", coding_agent_ansi:clear_line()),
    ?assertEqual("", coding_agent_ansi:cursor_up(1)),
    ?assertEqual("", coding_agent_ansi:cursor_down(1)),
    ?assertEqual("", coding_agent_ansi:save_cursor()),
    ?assertEqual("", coding_agent_ansi:restore_cursor()),
    os:unsetenv("NO_COLOR").

%% Cursor functions produce escape codes when color is enabled
cursor_with_color_test() ->
    os:unsetenv("NO_COLOR"),
    ?assertNotEqual("", coding_agent_ansi:clear_line()),
    ?assertNotEqual("", coding_agent_ansi:cursor_up(1)),
    ?assertNotEqual("", coding_agent_ansi:cursor_down(1)),
    ?assertNotEqual("", coding_agent_ansi:save_cursor()),
    ?assertNotEqual("", coding_agent_ansi:restore_cursor()).

%% Cursor guards: zero/negative returns empty
cursor_guard_test() ->
    os:unsetenv("NO_COLOR"),
    ?assertEqual("", coding_agent_ansi:cursor_up(0)),
    ?assertEqual("", coding_agent_ansi:cursor_down(-1)).