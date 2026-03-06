-module(coding_agent_cli).
-export([main/1]).

main([]) ->
    io:format("Usage: coding_agent_cli <command> [args]~n"),
    io:format("Commands:~n"),
    io:format("  ask <question>                 - Ask a question~n"),
    io:format("  code <language> <description>   - Generate code~n"),
    io:format("  analyze <file> <question>      - Analyze a file~n"),
    io:format("  explain <code>                 - Explain code~n");

main(["ask", Question]) ->
    start_app(),
    case coding_agent:ask(Question) of
        {ok, #{<<"response">> := Response}} ->
            io:format("~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end,
    stop_app();

main(["code", Language | DescriptionParts]) ->
    start_app(),
    Description = string:join(DescriptionParts, " "),
    case coding_agent:generate_code(Language, Description) of
        {ok, #{<<"response">> := Response}} ->
            io:format("~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end,
    stop_app();

main(["analyze", File, Question]) ->
    start_app(),
    case coding_agent:analyze_file(File, Question) of
        {ok, #{<<"response">> := Response}} ->
            io:format("~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end,
    stop_app();

main([_ | _]) ->
    io:format("Unknown command. Use without arguments for help.~n").

start_app() ->
    application:ensure_all_started(coding_agent).

stop_app() ->
    application:stop(coding_agent).