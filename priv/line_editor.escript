#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% Line editor helper for raw terminal input
%% This runs as a port program, reading raw characters from stdin
%% and sending them to Erlang for processing

main(_Args) ->
    % Set terminal to raw mode
    os:cmd("stty raw -echo"),
    
    % Read characters and output them
    read_loop(),
    
    % Restore terminal
    os:cmd("stty cooked echo").

read_loop() ->
    case file:read(standard_io, 1) of
        {ok, <<10>>} ->
            % Enter - end line
            io:format("~n"),
            ok;
        {ok, <<3>>} ->
            % Ctrl+C - exit
            ok;
        {ok, Char} when is_binary(Char) ->
            % Echo the character back
            file:write(standard_io, Char),
            read_loop();
        eof ->
            ok;
        _ ->
            read_loop()
    end.