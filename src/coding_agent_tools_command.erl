-module(coding_agent_tools_command).
-export([execute/2, http_request/1, http_request/2]).

execute(<<"run_command">>, #{<<"command">> := Command} = Args) ->
    case coding_agent_tools:safety_check(<<"run_command">>, Args) of
        skip -> #{<<"success">> => false, <<"error">> => <<"Operation skipped by safety check">>};
        {modify, NewArgs} -> coding_agent_tools:execute(<<"run_command">>, NewArgs);
        proceed ->
            Timeout = maps:get(<<"timeout">>, Args, 30000),
            Cwd = maps:get(<<"cwd">>, Args, <<".">>),
            CwdStr = binary_to_list(Cwd),
            coding_agent_tools:report_progress(<<"run_command">>, <<"starting">>, #{command => Command}),
            Result = coding_agent_tools:run_command_impl(binary_to_list(Command), Timeout, CwdStr),
            coding_agent_tools:log_operation(<<"run_command">>, Command, Result),
            coding_agent_tools:report_progress(<<"run_command">>, <<"complete">>, #{}),
            Result
    end;

execute(<<"http_request">>, Args) ->
    http_request_impl(Args);

execute(<<"execute_parallel">>, #{<<"calls">> := Calls}) ->
    execute_parallel_impl(Calls);

execute(<<"fetch_docs">>, Args) ->
    Url = maps:get(<<"url">>, Args),
    Format = maps:get(<<"format">>, Args, <<"text">>),
    coding_agent_tools:report_progress(<<"fetch_docs">>, <<"starting">>, #{url => Url}),
    case http_request_impl(Args#{<<"response_format">> => Format}) of
        #{<<"success">> := false} = Error ->
            Error;
        #{<<"body">> := Body} = Result ->
            TextBody = case Format of
                <<"html">> -> strip_html(Body);
                _ -> Body
            end,
            MaxSize = 20000,
            Trimmed = case byte_size(TextBody) of
                Size when Size > MaxSize ->
                    <<TrimmedBytes:MaxSize/binary, _/binary>> = TextBody,
                    <<TrimmedBytes/binary, "... (truncated)">>;
                _ -> TextBody
            end,
            coding_agent_tools:report_progress(<<"fetch_docs">>, <<"complete">>, #{}),
            Result#{<<"content">> => Trimmed, <<"format">> => Format}
    end;

execute(<<"load_context">>, #{<<"paths">> := Paths} = Args) ->
    MaxSize = maps:get(<<"max_total_size">>, Args, 50000),
    coding_agent_tools:report_progress(<<"load_context">>, <<"starting">>, #{}),
    {Content, FileInfos, TotalSize} = load_files(Paths, MaxSize, <<>>, [], 0),
    coding_agent_tools:report_progress(<<"load_context">>, <<"complete">>, #{}),
    #{<<"success">> => true, <<"content">> => Content,
      <<"files">> => FileInfos, <<"total_size">> => TotalSize}.

%% HTTP Request API

http_request(Url) ->
    http_request(Url, #{}).

http_request(Url, Opts) when is_list(Url) ->
    http_request(list_to_binary(Url), Opts);
http_request(Url, Opts) when is_binary(Url), is_map(Opts) ->
    Method = maps:get(<<"method">>, Opts, <<"GET">>),
    Headers = maps:get(<<"headers">>, Opts, #{}),
    Body = maps:get(<<"body">>, Opts, undefined),
    Timeout = maps:get(<<"timeout">>, Opts, 30000),
    FollowRedirect = maps:get(<<"follow_redirect">>, Opts, true),
    ResponseFormat = maps:get(<<"response_format">>, Opts, <<"auto">>),
    http_request_impl(Url, Method, Headers, Body, Timeout, FollowRedirect, ResponseFormat).

%% Internal helpers

strip_html(Bin) when is_binary(Bin) ->
    % Basic HTML tag stripping
    re:replace(Bin, "<[^>]+>", "", [global, {return, binary}]);
strip_html(Text) ->
    iolist_to_binary(Text).

load_files([], _MaxSize, Acc, Infos, TotalSize) ->
    {Acc, lists:reverse(Infos), TotalSize};
load_files([Path | Rest], MaxSize, Acc, Infos, TotalSize) when TotalSize < MaxSize ->
    PathStr = binary_to_list(Path),
    case file:read_file(PathStr) of
        {ok, Content} ->
            Header = iolist_to_binary([<<"\n--- ">>, Path, <<" ---\n">>]),
            NewAcc = iolist_to_binary([Acc, Header, Content]),
            NewSize = TotalSize + byte_size(Content),
            Info = #{<<"path">> => Path, <<"size">> => byte_size(Content)},
            load_files(Rest, MaxSize, NewAcc, [Info | Infos], NewSize);
        {error, _} ->
            load_files(Rest, MaxSize, Acc, Infos, TotalSize)
    end;
load_files(_, _MaxSize, Acc, Infos, TotalSize) ->
    {Acc, lists:reverse(Infos), TotalSize}.

http_request_impl(Args) when is_map(Args) ->
    Url = maps:get(<<"url">>, Args),
    Method = maps:get(<<"method">>, Args, <<"GET">>),
    Headers = maps:get(<<"headers">>, Args, #{}),
    Body = maps:get(<<"body">>, Args, undefined),
    Timeout = maps:get(<<"timeout">>, Args, 30000),
    FollowRedirect = maps:get(<<"follow_redirect">>, Args, true),
    ResponseFormat = maps:get(<<"response_format">>, Args, <<"auto">>),
    http_request_impl(Url, Method, Headers, Body, Timeout, FollowRedirect, ResponseFormat).

http_request_impl(Url, Method, Headers, Body, Timeout, FollowRedirect, ResponseFormat) ->
    case application:ensure_all_started(hackney) of
        {ok, _} -> ok;
        _ -> ok
    end,

    coding_agent_tools:report_progress(<<"http_request">>, <<"starting">>, #{url => Url, method => Method}),

    MethodAtom = case Method of
        <<"GET">> -> get;
        <<"POST">> -> post;
        <<"PUT">> -> put;
        <<"DELETE">> -> delete;
        <<"PATCH">> -> patch;
        <<"HEAD">> -> head;
        <<"OPTIONS">> -> options;
        _ -> get
    end,

    HeaderList = maps:fold(fun(K, V, Acc) ->
        [{iolist_to_binary(K), iolist_to_binary(V)} | Acc]
    end, [], Headers),

    ReqOpts = [{recv_timeout, Timeout}],
    ReqOpts1 = case FollowRedirect of
        true -> [{follow_redirect, true} | ReqOpts];
        false -> ReqOpts
    end,

    Result = case MethodAtom of
        get ->
            hackney:request(get, Url, HeaderList, <<>>, ReqOpts1);
        head ->
            hackney:request(head, Url, HeaderList, <<>>, ReqOpts1);
        _ when Body =:= undefined; Body =:= nil ->
            hackney:request(MethodAtom, Url, HeaderList, <<>>, ReqOpts1);
        _ ->
            hackney:request(MethodAtom, Url, HeaderList, Body, ReqOpts1)
    end,

    case Result of
        {ok, StatusCode, RespHeaders, RespBody} when StatusCode >= 200, StatusCode < 300 ->
            process_http_response(StatusCode, RespHeaders, RespBody, ResponseFormat, Url);
        {ok, StatusCode, RespHeaders, RespBody} ->
            process_http_response(StatusCode, RespHeaders, RespBody, ResponseFormat, Url);
        {error, Reason} ->
            #{
                <<"success">> => false,
                <<"error">> => iolist_to_binary(io_lib:format("HTTP request failed: ~p", [Reason]))
            }
    end.

process_http_response(StatusCode, RespHeaders, RespBody, ResponseFormat, Url) ->
    DetectedFormat = case ResponseFormat of
        <<"auto">> -> detect_response_format(RespHeaders, RespBody);
        Other -> Other
    end,

    SafeBody = coding_agent_tools:safe_binary(RespBody, 100000),

    ParsedBody = case DetectedFormat of
        <<"json">> ->
            case jsx:is_json(SafeBody) of
                true -> jsx:decode(SafeBody, [return_maps]);
                false -> SafeBody
            end;
        _ -> SafeBody
    end,

    HeaderMap = lists:foldl(fun({K, V}, Acc) ->
        Acc#{iolist_to_binary(K) => iolist_to_binary(V)}
    end, #{}, RespHeaders),

    #{
        <<"success">> => true,
        <<"status">> => StatusCode,
        <<"headers">> => HeaderMap,
        <<"body">> => ParsedBody,
        <<"url">> => Url,
        <<"format">> => DetectedFormat
    }.

detect_response_format(Headers, _Body) ->
    ContentType = case lists:keyfind(<<"content-type">>, 1, Headers) of
        {_, CT} -> string:lowercase(CT);
        false -> <<"unknown">>
    end,
    IsJson = binary:match(ContentType, <<"application/json">>) =/= nomatch,
    IsText = binary:match(ContentType, <<"text/">>) =/= nomatch,
    IsImage = binary:match(ContentType, <<"image/">>) =/= nomatch,
    case {IsJson, IsText, IsImage} of
        {true, _, _} -> <<"json">>;
        {_, true, _} -> <<"text">>;
        {_, _, true} -> <<"binary">>;
        _ -> <<"text">>
    end.

execute_parallel_impl(Calls) when is_list(Calls) ->
    Parent = self(),
    Pids = lists:map(fun(#{<<"name">> := Name, <<"args">> := Args}) ->
        spawn_link(fun() ->
            Result = coding_agent_tools:execute(Name, Args),
            Parent ! {parallel_result, self(), Name, Result}
        end)
    end, Calls),
    Results = collect_parallel_results(Pids, #{}),
    #{
        <<"success">> => true,
        <<"results">> => Results,
        <<"count">> => length(Calls)
    };
execute_parallel_impl(Calls) ->
    #{<<"success">> => false, <<"error">> => <<"calls must be an array">>}.

collect_parallel_results([], Results) ->
    Results;
collect_parallel_results(Pids, Results) ->
    receive
        {parallel_result, Pid, Name, Result} ->
            NewPids = lists:delete(Pid, Pids),
            collect_parallel_results(NewPids, Results#{Name => Result})
    after 120000 ->
        #{<<"error">> => <<"timeout">>}
    end.