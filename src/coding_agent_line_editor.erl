%%%-------------------------------------------------------------------
%%% @doc Line Editor with history and cursor support
%%% Implements readline-like functionality for the REPL:
%%% - Arrow up/down: navigate history  
%%% - Arrow left/right: move cursor
%%% - Home/End: jump to start/end
%%% - Backspace/Delete: delete characters
%%% - Ctrl+A/E: jump to start/end
%%% - Ctrl+U: clear line
%%% - Ctrl+L: clear screen
%%%
%%% Uses a port program (shell script) to read raw terminal input.
%%% @end
%%%-------------------------------------------------------------------
-module(coding_agent_line_editor).
-export([read_line/2, read_line/3]).
-export([test_raw_mode/0]).

-define(MAX_HISTORY, 500).

%% History state stored in process dictionary
-define(HIST_INDEX, {coding_agent_line_editor, hist_index}).
-define(HIST_SAVED, {coding_agent_line_editor, hist_saved}).

%% @doc Read a line with prompt and history
read_line(Prompt, History) ->
    read_line(Prompt, History, "").

%% @doc Read a line with prompt, history, and initial content
read_line(Prompt, History, Initial) ->
    case has_tty() of
        true -> fancy_read_line(Prompt, History, Initial);
        false -> simple_read_line(Prompt, History)
    end.

simple_read_line(Prompt, _History) ->
    io:format("~ts", [Prompt]),
    case io:get_line("") of
        eof -> {error, eof};
        Line when is_list(Line) ->
            {ok, string:trim(Line, trailing, "\n\r")};
        _ -> {error, unknown}
    end.

has_tty() ->
    case io:columns() of
        {ok, _} -> true;
        _ -> false
    end.

fancy_read_line(Prompt, History, Initial) ->
    % Initialize history navigation state
    put(?HIST_INDEX, -1),  % -1 means not navigating history
    put(?HIST_SAVED, Initial),
    
    % Write prompt
    io:format("~ts", [Prompt]),
    io:format("", []),  % Flush
    
    % Initial buffer content  
    InitBin = case is_list(Initial) of
        true -> list_to_binary(Initial);
        false when is_binary(Initial) -> Initial;
        false -> <<"">>
    end,
    
    % If there's initial content, display it
    case InitBin of
        <<>> -> ok;
        _ -> io:format("~ts", [InitBin])
    end,
    
    % Save current terminal settings
    OldStty = os:cmd("stty -g 2>/dev/null"),
    
    % Enable raw mode
    os:cmd("stty raw -echo 2>/dev/null || stty -icanon -echo 2>/dev/null"),
    
    try
        do_read(Prompt, History, InitBin, byte_size(InitBin))
    after
        % Restore terminal settings
        case OldStty of
            "" -> 
                os:cmd("stty cooked echo 2>/dev/null || stty icanon echo 2>/dev/null");
            _ ->
                os:cmd("stty " ++ string:trim(OldStty))
        end,
        % Clean up process dictionary
        erase(?HIST_INDEX),
        erase(?HIST_SAVED)
    end.

%% Test raw mode
test_raw_mode() ->
    io:format("Testing raw mode. Press keys (Ctrl+C to exit):~n"),
    OldStty = os:cmd("stty -g 2>/dev/null"),
    os:cmd("stty raw -echo 2>/dev/null"),
    try
        test_read_loop()
    after
        case OldStty of
            "" -> os:cmd("stty cooked echo 2>/dev/null");
            _ -> os:cmd("stty " ++ string:trim(OldStty))
        end
    end.

test_read_loop() ->
    case raw_read_char() of
        {ok, 3} -> % Ctrl+C
            io:format("~nExiting~n");
        {ok, 10} -> % Enter
            io:format("~nEnter pressed~n");
        {ok, Char} ->
            io:format("Got char: ~p~n", [Char]),
            test_read_loop();
        eof ->
            io:format("~nEOF~n");
        {error, Reason} ->
            io:format("~nError: ~p~n", [Reason])
    end.

%%-------------------------------------------------------------------
%%% Internal functions  
%%-------------------------------------------------------------------

%% Read a single raw character
raw_read_char() ->
    case file:read(standard_io, 1) of
        {ok, <<Char:8>>} -> {ok, Char};
        {ok, Data} when is_binary(Data), byte_size(Data) > 0 -> {ok, binary:first(Data)};
        Other -> Other
    end.

%% Read escape sequence
raw_read_escape() ->
    case raw_read_char() of
        {ok, $[} ->
            % CSI sequence
            case raw_read_char() of
                {ok, $A} -> up;
                {ok, $B} -> down;
                {ok, $C} -> right;
                {ok, $D} -> left;
                {ok, $H} -> home;
                {ok, $F} -> 'end';
                {ok, $1} ->
                    % ESC [ 1 ~ (home on some terminals)
                    _ = raw_read_char(),
                    home;
                {ok, $3} ->
                    % ESC [ 3 ~ (delete)
                    _ = raw_read_char(),
                    del;
                {ok, $4} ->
                    % ESC [ 4 ~ (end on some terminals)
                    _ = raw_read_char(),
                    'end';
                _ -> unknown
            end;
        {ok, $O} ->
            % Alternative escape sequences
            case raw_read_char() of
                {ok, $H} -> home;
                {ok, $F} -> 'end';
                _ -> unknown
            end;
        _ ->
            unknown
    end.

%% Main read loop
do_read(Prompt, History, Buffer, CursorPos) ->
    case raw_read_char() of
        {ok, Char} ->
            handle_char(Char, Prompt, History, Buffer, CursorPos);
        eof ->
            case Buffer of
                <<>> -> {error, eof};
                _ -> {ok, binary_to_list(Buffer)}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Handle character input
handle_char(10, _Prompt, _History, Buffer, _CursorPos) ->
    %% Enter - submit line
    io:format("~n", []),
    {ok, binary_to_list(Buffer)};

handle_char(13, _Prompt, _History, Buffer, _CursorPos) ->
    %% Carriage return - submit line
    io:format("~n", []),
    {ok, binary_to_list(Buffer)};

handle_char(27, Prompt, History, Buffer, CursorPos) ->
    %% Escape sequence - read next chars
    case raw_read_escape() of
        up ->
            %% Arrow up - previous history (older, higher index in list)
            NewBuffer = prev_history(Prompt, History, Buffer),
            do_read(Prompt, History, NewBuffer, byte_size(NewBuffer));
        down ->
            %% Arrow down - next history (newer, lower index in list)
            NewBuffer = next_history(Prompt, History, Buffer),
            do_read(Prompt, History, NewBuffer, byte_size(NewBuffer));
        left ->
            %% Arrow left - move cursor left
            NewCursor = max(0, CursorPos - 1),
            move_cursor(Prompt, Buffer, CursorPos, NewCursor),
            do_read(Prompt, History, Buffer, NewCursor);
        right ->
            %% Arrow right - move cursor right
            NewCursor = min(byte_size(Buffer), CursorPos + 1),
            move_cursor(Prompt, Buffer, CursorPos, NewCursor),
            do_read(Prompt, History, Buffer, NewCursor);
        home ->
            %% Home - beginning of line
            move_cursor(Prompt, Buffer, CursorPos, 0),
            do_read(Prompt, History, Buffer, 0);
        'end' ->
            %% End - end of line
            move_cursor(Prompt, Buffer, CursorPos, byte_size(Buffer)),
            do_read(Prompt, History, Buffer, byte_size(Buffer));
        del ->
            %% Delete key - delete char at cursor
            NewBuffer = delete_char(Buffer, CursorPos),
            redraw_line(Prompt, NewBuffer, CursorPos),
            do_read(Prompt, History, NewBuffer, CursorPos);
        unknown ->
            %% Unknown escape sequence, ignore
            do_read(Prompt, History, Buffer, CursorPos)
    end;

handle_char(127, Prompt, History, Buffer, CursorPos) ->
    %% Backspace (DEL key on Mac) - delete char before cursor
    case CursorPos of
        0 -> 
            do_read(Prompt, History, Buffer, CursorPos);
        _ ->
            NewBuffer = backspace_char(Buffer, CursorPos),
            NewCursor = CursorPos - 1,
            redraw_line(Prompt, NewBuffer, NewCursor),
            do_read(Prompt, History, NewBuffer, NewCursor)
    end;

handle_char(8, Prompt, History, Buffer, CursorPos) ->
    %% Backspace (Ctrl+H) - delete char before cursor
    case CursorPos of
        0 -> 
            do_read(Prompt, History, Buffer, CursorPos);
        _ ->
            NewBuffer = backspace_char(Buffer, CursorPos),
            NewCursor = CursorPos - 1,
            redraw_line(Prompt, NewBuffer, NewCursor),
            do_read(Prompt, History, NewBuffer, NewCursor)
    end;

handle_char(1, _Prompt, History, Buffer, CursorPos) ->
    %% Ctrl+A - beginning of line
    move_cursor(_Prompt, Buffer, CursorPos, 0),
    do_read(_Prompt, History, Buffer, 0);

handle_char(5, _Prompt, History, Buffer, CursorPos) ->
    %% Ctrl+E - end of line
    move_cursor(_Prompt, Buffer, CursorPos, byte_size(Buffer)),
    do_read(_Prompt, History, Buffer, byte_size(Buffer));

handle_char(11, Prompt, History, Buffer, CursorPos) ->
    %% Ctrl+K - delete to end of line
    <<Start:CursorPos/binary, _/binary>> = Buffer,
    redraw_line(Prompt, Start, CursorPos),
    do_read(Prompt, History, Start, CursorPos);

handle_char(21, Prompt, History, _Buffer, _CursorPos) ->
    %% Ctrl+U - clear entire line
    redraw_line(Prompt, <<"">>, 0),
    do_read(Prompt, History, <<"">>, 0);

handle_char(12, Prompt, History, Buffer, CursorPos) ->
    %% Ctrl+L - clear screen
    io:format("\e[2J\e[H", []),
    io:format("~ts", [Prompt]),
    case Buffer of
        <<>> -> ok;
        _ -> io:format("~ts", [Buffer])
    end,
    move_cursor(Prompt, Buffer, byte_size(Buffer), CursorPos),
    do_read(Prompt, History, Buffer, CursorPos);

handle_char(3, Prompt, History, _Buffer, _CursorPos) ->
    %% Ctrl+C - cancel current input
    io:format("^C~n", []),
    io:format("~ts", [Prompt]),
    % Reset history navigation
    put(?HIST_INDEX, -1),
    do_read(Prompt, History, <<"">>, 0);

handle_char(Char, Prompt, History, Buffer, CursorPos) when Char >= 32, Char < 127 ->
    %% Printable ASCII character - insert at cursor position
    NewBuffer = insert_char(Buffer, CursorPos, Char),
    NewCursor = CursorPos + 1,
    redraw_line(Prompt, NewBuffer, NewCursor),
    % Reset history navigation when user types
    put(?HIST_INDEX, -1),
    do_read(Prompt, History, NewBuffer, NewCursor);

handle_char(_Char, Prompt, History, Buffer, CursorPos) ->
    %% Ignore other control characters (including extended UTF-8 for now)
    do_read(Prompt, History, Buffer, CursorPos).

%%-------------------------------------------------------------------
%%% History navigation
%%-------------------------------------------------------------------

%% History is stored as a list with most recent first
%% Index -1 = not navigating (current input)
%% Index 0 = most recent history item
%% Index N = Nth most recent

prev_history(Prompt, History, CurrentBuffer) ->
    HistIndex = get(?HIST_INDEX),
    
    case HistIndex of
        -1 ->
            % Not currently navigating - save current buffer and go to oldest
            put(?HIST_SAVED, CurrentBuffer),
            case History of
                [] -> CurrentBuffer;
                [Oldest | _] ->
                    put(?HIST_INDEX, 0),
                    HistBin = to_binary(Oldest),
                    redraw_line(Prompt, HistBin, byte_size(HistBin)),
                    HistBin
            end;
        _ when length(History) =:= 0 ->
            CurrentBuffer;
        N when N >= length(History) - 1 ->
            % Already at oldest - stay there
            CurrentBuffer;
        N ->
            % Go to next older item
            NewIndex = N + 1,
            put(?HIST_INDEX, NewIndex),
            HistItem = lists:nth(NewIndex + 1, History),
            HistBin = to_binary(HistItem),
            redraw_line(Prompt, HistBin, byte_size(HistBin)),
            HistBin
    end.

next_history(Prompt, History, CurrentBuffer) ->
    HistIndex = get(?HIST_INDEX),
    
    case HistIndex of
        -1 ->
            % Not navigating - nothing to do
            CurrentBuffer;
        0 ->
            % At most recent - go back to saved
            put(?HIST_INDEX, -1),
            HistSaved = get(?HIST_SAVED),
            SavedBin = to_binary(HistSaved),
            redraw_line(Prompt, SavedBin, byte_size(SavedBin)),
            SavedBin;
        N ->
            % Go to newer item
            NewIndex = N - 1,
            put(?HIST_INDEX, NewIndex),
            case NewIndex of
                -1 ->
                    % Back to saved buffer
                    HistSaved = get(?HIST_SAVED),
                    SavedBin = to_binary(HistSaved),
                    redraw_line(Prompt, SavedBin, byte_size(SavedBin)),
                    SavedBin;
                _ ->
                    HistItem = lists:nth(NewIndex + 1, History),
                    HistBin = to_binary(HistItem),
                    redraw_line(Prompt, HistBin, byte_size(HistBin)),
                    HistBin
            end
    end.

to_binary(Str) when is_binary(Str) -> Str;
to_binary(Str) when is_list(Str) -> list_to_binary(Str);
to_binary(Other) -> iolist_to_binary(Other).

%%-------------------------------------------------------------------
%%% Buffer operations
%%-------------------------------------------------------------------

%% Insert character at position
insert_char(Buffer, Pos, Char) when Pos >= byte_size(Buffer) ->
    <<Buffer/binary, Char>>;
insert_char(Buffer, Pos, Char) ->
    <<Before:Pos/binary, After/binary>> = Buffer,
    <<Before/binary, Char, After/binary>>.

%% Delete character at position
delete_char(Buffer, Pos) when Pos >= byte_size(Buffer) ->
    Buffer;
delete_char(Buffer, Pos) ->
    <<Before:Pos/binary, _:8, After/binary>> = Buffer,
    <<Before/binary, After/binary>>.

%% Delete character before position (backspace)
backspace_char(Buffer, Pos) when Pos =< 0 ->
    Buffer;
backspace_char(Buffer, Pos) ->
    DeletePos = Pos - 1,
    <<Before:DeletePos/binary, _:8, After/binary>> = Buffer,
    <<Before/binary, After/binary>>.

%%-------------------------------------------------------------------
%%% Display operations
%%-------------------------------------------------------------------

%% Redraw the entire line
redraw_line(Prompt, Buffer, CursorPos) ->
    %% Move to start of line
    io:format("\r", []),
    %% Clear from cursor to end of line
    io:format("\e[K", []),
    %% Write prompt
    io:format("~ts", [Prompt]),
    %% Write buffer
    case Buffer of
        <<>> -> ok;
        _ -> io:format("~ts", [Buffer])
    end,
    %% Move cursor to correct position
    PromptLen = visible_length(Prompt),
    CursorVisual = PromptLen + CursorPos,
    %% Move cursor back to beginning, then to position
    case CursorVisual of
        0 -> 
            io:format("\r", []);
        _ -> 
            io:format("\r\e[~pC", [CursorVisual])
    end.

%% Move cursor from OldPos to NewPos
move_cursor(Prompt, _Buffer, OldPos, NewPos) ->
    PromptLen = visible_length(Prompt),
    OldVisual = PromptLen + OldPos,
    NewVisual = PromptLen + NewPos,
    Delta = NewVisual - OldVisual,
    if
        Delta =:= 0 -> ok;
        Delta > 0 ->
            io:format("\e[~pC", [Delta]);
        true ->
            io:format("\e[~pD", [abs(Delta)])
    end.

%% Calculate visible string length (excluding ANSI codes)
visible_length(Str) when is_binary(Str) ->
    visible_length(binary_to_list(Str));
visible_length(Str) when is_list(Str) ->
    % Remove ANSI escape sequences
    NoAnsi = re:replace(Str, "\e\[[0-9;]*m", "", [global, {return, list}]),
    length(unicode:characters_to_list(NoAnsi, utf8)).