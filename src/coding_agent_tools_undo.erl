-module(coding_agent_tools_undo).
-export([execute/2]).

-define(BACKUP_DIR, ".tarha/backups").

execute(<<"undo_edit">>, #{<<"path">> := Path}) ->
    PathStr = coding_agent_tools:sanitize_path(Path),
    case restore_backup_internal(PathStr) of
        {ok, RestoredPath} ->
            coding_agent_tools:log_operation(<<"undo_edit">>, Path, #{<<"restored">> => Path}),
            #{<<"success">> => true, <<"path">> => list_to_binary(RestoredPath)};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"list_backups">>, _Args) ->
    Backups = list_backups_impl(),
    #{<<"success">> => true, <<"backups">> => Backups};

execute(<<"undo">>, Args) ->
    N = maps:get(<<"count">>, Args, 1),
    case coding_agent_undo:undo(N) of
        {ok, Results} ->
            #{<<"success">> => true, <<"results">> => format_undo_results(Results)};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"redo">>, Args) ->
    N = maps:get(<<"count">>, Args, 1),
    case coding_agent_undo:redo(N) of
        {ok, Results} ->
            #{<<"success">> => true, <<"results">> => format_undo_results(Results)};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"undo_history">>, Args) ->
    Limit = maps:get(<<"limit">>, Args, 20),
    case coding_agent_undo:get_history(Limit) of
        {ok, History} ->
            #{<<"success">> => true, <<"history">> => History};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"begin_transaction">>, _Args) ->
    case coding_agent_undo:begin_transaction() of
        {ok, Id} ->
            #{<<"success">> => true, <<"transaction_id">> => Id};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"end_transaction">>, _Args) ->
    case coding_agent_undo:end_transaction() of
        {ok, Id} ->
            #{<<"success">> => true, <<"transaction_id">> => Id};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end;

execute(<<"cancel_transaction">>, _Args) ->
    case coding_agent_undo:cancel_transaction() of
        {ok, Id} ->
            #{<<"success">> => true, <<"transaction_id">> => Id};
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Internal helpers

format_undo_results(Results) when is_list(Results) ->
    lists:map(fun
        ({ok, OpId}) -> #{<<"status">> => <<"ok">>, <<"operation_id">> => OpId};
        ({error, Path, Reason}) -> #{<<"status">> => <<"error">>, <<"path">> => list_to_binary(Path), <<"reason">> => list_to_binary(io_lib:format("~p", [Reason]))};
        ({error, Err}) -> #{<<"status">> => <<"error">>, <<"reason">> => list_to_binary(io_lib:format("~p", [Err]))}
    end, Results);
format_undo_results(_) ->
    [].

restore_backup_internal(Path) ->
    BackupDir = ?BACKUP_DIR,
    Basename = filename:basename(Path),
    case filelib:wildcard(filename:join(BackupDir, "*_" ++ Basename)) of
        [Latest | _] ->
            case file:copy(Latest, Path) of
                {ok, _} -> {ok, Path};
                {error, Reason} -> {error, file:format_error(Reason)}
            end;
        [] -> {error, "No backup found"}
    end.

list_backups_impl() ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> [];
        true ->
            Files = filelib:wildcard(filename:join(BackupDir, "*")),
            lists:map(fun(F) ->
                #{<<"path">> => list_to_binary(F), <<"name">> => list_to_binary(filename:basename(F))}
            end, Files)
    end.