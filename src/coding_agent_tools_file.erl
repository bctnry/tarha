-module(coding_agent_tools_file).
-export([execute/2]).

-include_lib("kernel/include/file.hrl").

-define(BACKUP_DIR, ".tarha/backups").
-define(MAX_BACKUPS, 50).

execute(<<"read_file">>, #{<<"path">> := Path}) ->
    coding_agent_tools:report_progress(<<"read_file">>, <<"starting">>, #{path => Path}),
    PathStr = sanitize_path(Path),
    case file:read_file(PathStr) of
        {ok, Content} ->
            SafeContent = coding_agent_tools:safe_binary(Content),
            Result = #{<<"success">> => true, <<"content">> => SafeContent},
            coding_agent_tools:log_operation(<<"read_file">>, Path, Result),
            coding_agent_tools:report_progress(<<"read_file">>, <<"complete">>, #{path => Path, size => byte_size(SafeContent)}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
            coding_agent_tools:log_operation(<<"read_file">>, Path, Result),
            Result
    end;

execute(<<"edit_file">>, #{<<"path">> := Path, <<"old_string">> := OldStr, <<"new_string">> := NewStr} = Args) ->
    case coding_agent_tools:safety_check(<<"edit_file">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> coding_agent_tools:execute(<<"edit_file">>, NewArgs);
        proceed ->
            coding_agent_tools:report_progress(<<"edit_file">>, <<"starting">>, #{path => Path}),
            PathStr = sanitize_path(Path),
            ReplaceAll = maps:get(<<"replace_all">>, Args, false),
            case file:read_file(PathStr) of
                {ok, Content} ->
                    ContentStr = binary_to_list(Content),
                    OldStrList = binary_to_list(OldStr),
                    NewStrList = binary_to_list(NewStr),
                    case coding_agent_tools:find_occurrences(ContentStr, OldStrList) of
                        0 ->
                            Result = #{<<"success">> => false, <<"error">> => <<"Old string not found in file">>},
                            coding_agent_tools:log_operation(<<"edit_file">>, Path, Result),
                            Result;
                        Count when Count > 1 andalso ReplaceAll =/= true ->
                            Result = #{<<"success">> => false, <<"error">> => iolist_to_binary(io_lib:format("Found ~b occurrences. Use replace_all to replace all.", [Count]))},
                            coding_agent_tools:log_operation(<<"edit_file">>, Path, Result),
                            Result;
                        _ ->
                            _ = create_backup_internal(PathStr),
                            NewContent = case ReplaceAll of
                                true -> coding_agent_tools:replace_all(ContentStr, OldStrList, NewStrList);
                                false -> string:replace(ContentStr, OldStrList, NewStrList)
                            end,
                            case file:write_file(PathStr, list_to_binary(NewContent)) of
                                ok ->
                                    Result = #{<<"success">> => true, <<"message">> => <<"File edited successfully">>},
                                    coding_agent_tools:log_operation(<<"edit_file">>, Path, Result),
                                    coding_agent_tools:report_progress(<<"edit_file">>, <<"complete">>, #{path => Path}),
                                    Result;
                                {error, Reason} ->
                                    restore_backup_internal(PathStr),
                                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                                    coding_agent_tools:log_operation(<<"edit_file">>, Path, Result),
                                    Result
                            end
                    end;
                {error, Reason} ->
                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                    coding_agent_tools:log_operation(<<"edit_file">>, Path, Result),
                    Result
            end
    end;

execute(<<"write_file">>, #{<<"path">> := Path, <<"content">> := Content} = Args) ->
    case coding_agent_tools:safety_check(<<"write_file">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> coding_agent_tools:execute(<<"write_file">>, NewArgs);
        proceed ->
            coding_agent_tools:report_progress(<<"write_file">>, <<"starting">>, #{path => Path}),
            PathStr = sanitize_path(Path),
            case filelib:is_file(PathStr) of
                true -> _ = create_backup_internal(PathStr);
                false -> ok
            end,
            case file:write_file(PathStr, Content) of
                ok ->
                    Result = #{<<"success">> => true, <<"message">> => <<"File written successfully">>},
                    coding_agent_tools:log_operation(<<"write_file">>, Path, Result),
                    coding_agent_tools:report_progress(<<"write_file">>, <<"complete">>, #{path => Path}),
                    Result;
                {error, Reason} ->
                    Result = #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))},
                    coding_agent_tools:log_operation(<<"write_file">>, Path, Result),
                    Result
            end
    end;

execute(<<"create_directory">>, #{<<"path">> := Path}) ->
    PathStr = sanitize_path(Path),
    case filelib:is_dir(PathStr) of
        true -> #{<<"success">> => true, <<"message">> => <<"Directory already exists">>};
        false ->
            case filelib:ensure_dir(PathStr ++ "/") of
                ok ->
                    case file:make_dir(PathStr) of
                        ok -> #{<<"success">> => true, <<"message">> => <<"Directory created">>};
                        {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
                    end;
                {error, Reason} -> #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
            end
    end;

execute(<<"list_files">>, Args) ->
    Path = maps:get(<<"path">>, Args, <<".">>),
    Recursive = maps:get(<<"recursive">>, Args, false),
    PathStr = sanitize_path(Path),
    coding_agent_tools:report_progress(<<"list_files">>, <<"starting">>, #{path => Path}),
    Result = list_files_impl(PathStr, Recursive),
    coding_agent_tools:report_progress(<<"list_files">>, <<"complete">>, #{}),
    Result;

execute(<<"file_exists">>, #{<<"path">> := Path}) ->
    PathStr = sanitize_path(Path),
    case filelib:is_file(PathStr) of
        true -> #{<<"success">> => true, <<"exists">> => true, <<"path">> => Path};
        false -> #{<<"success">> => true, <<"exists">> => false, <<"path">> => Path}
    end.

%% Internal helpers

sanitize_path(Path) when is_binary(Path) ->
    binary_to_list(Path);
sanitize_path(Path) when is_list(Path) ->
    Path.

list_files_impl(Path, Recursive) ->
    case file:list_dir(Path) of
        {ok, Files} ->
            FilesWithInfo = lists:filtermap(fun(F) ->
                FullPath = filename:join(Path, F),
                case file:read_file_info(FullPath) of
                    {ok, Info} ->
                        Type = case Info#file_info.type of
                            regular -> <<"file">>;
                            directory -> <<"directory">>;
                            _ -> <<"other">>
                        end,
                        {true, #{
                            <<"name">> => list_to_binary(F),
                            <<"type">> => Type,
                            <<"size">> => Info#file_info.size
                        }};
                    _ -> false
                end
            end, Files),
            case Recursive of
                true ->
                    Dirs = [filename:join(Path, F) || F <- Files, filelib:is_dir(filename:join(Path, F))],
                    SubFiles = lists:flatmap(fun(D) ->
                        case list_files_impl(D, true) of
                            #{<<"success">> := true, <<"files">> := Fs} -> Fs;
                            _ -> []
                        end
                    end, Dirs),
                    #{<<"success">> => true, <<"files">> => FilesWithInfo ++ SubFiles};
                false ->
                    #{<<"success">> => true, <<"files">> => FilesWithInfo}
            end;
        {error, Reason} ->
            #{<<"success">> => false, <<"error">> => list_to_binary(file:format_error(Reason))}
    end.

create_backup_internal(Path) ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> file:make_dir(BackupDir);
        true -> ok
    end,
    Timestamp = erlang:system_time(millisecond),
    BackupName = integer_to_list(Timestamp) ++ "_" ++ filename:basename(Path),
    BackupPath = filename:join(BackupDir, BackupName),
    case file:copy(Path, BackupPath) of
        {ok, _} ->
            cleanup_old_backups(),
            push_to_undo_stack(Path, BackupPath),
            {ok, BackupPath};
        {error, Reason} -> {error, file:format_error(Reason)}
    end.

push_to_undo_stack(Path, BackupPath) ->
    case whereis(coding_agent_undo) of
        undefined -> ok;
        _Pid ->
            Op = #{
                type => edit,
                description => iolist_to_binary(io_lib:format("Edit ~s", [filename:basename(Path)])),
                files => [{Path, BackupPath}]
            },
            coding_agent_undo:push(Op, #{})
    end.

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

cleanup_old_backups() ->
    BackupDir = ?BACKUP_DIR,
    case filelib:is_dir(BackupDir) of
        false -> ok;
        true ->
            Files = filelib:wildcard(filename:join(BackupDir, "*")),
            case length(Files) > ?MAX_BACKUPS of
                true ->
                    Sorted = lists:sort(Files),
                    ToDelete = lists:sublist(Sorted, length(Sorted) - ?MAX_BACKUPS),
                    lists:foreach(fun(F) -> file:delete(F) end, ToDelete);
                false -> ok
            end
    end.