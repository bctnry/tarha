-module(coding_agent_ollama).
-export([generate/2, generate_stream/2, chat/2, chat_with_tools/3, chat_stream/3, chat_stream/4]).
-export([count_tokens/1, truncate_messages/2]).

generate(Model, Prompt) ->
    generate(Model, Prompt, #{}).

generate(Model, Prompt, Opts) when is_list(Model) ->
    generate(list_to_binary(Model), Prompt, Opts);
generate(Model, Prompt, _Opts) when is_binary(Model) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/generate",
    PromptBin = iolist_to_binary(Prompt),
    
    Body = jsx:encode(#{
        model => Model,
        prompt => PromptBin,
        stream => false
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            {ok, jsx:decode(RespBody, [return_maps])};
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {status, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

generate_stream(Model, Prompt) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/generate",
    PromptBin = iolist_to_binary(Prompt),
    
    Body = jsx:encode(#{
        model => Model,
        prompt => PromptBin,
        stream => true
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [{stream, self()}]) of
        {ok, _RequestId} ->
            collect_stream();
        {error, Reason} ->
            {error, Reason}
    end.

chat(Model, Messages) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        stream => false
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            {ok, jsx:decode(RespBody, [return_maps])};
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {status, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

chat_with_tools(Model, Messages, Tools) when is_list(Model) ->
    chat_with_tools(list_to_binary(Model), Messages, Tools);
chat_with_tools(Model, Messages, Tools) when is_binary(Model) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        tools => Tools,
        think => true,
        stream => false
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:request(post, Url, Headers, Body, [{recv_timeout, 300000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            {ok, jsx:decode(RespBody, [return_maps])};
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {status, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

collect_stream() ->
    collect_stream(<<>>, []).

collect_stream(Acc, Chunks) ->
    receive
        {hackney_response, _Ref, {done, _}} ->
            {ok, lists:reverse(Chunks)};
        {hackney_response, _Ref, Data} ->
            case jsx:is_json(Data) of
                true ->
                    Chunk = jsx:decode(Data, [return_maps]),
                    collect_stream(Acc, [Chunk | Chunks]);
                false ->
                    collect_stream(Acc, Chunks)
            end;
        _ ->
            collect_stream(Acc, Chunks)
    after 30000 ->
        {error, timeout}
    end.

% Streaming support with callback
chat_stream(Model, Messages, Tools) ->
    chat_stream(Model, Messages, Tools, fun(_, _) -> ok end).

chat_stream(Model, Messages, Tools, Callback) when is_list(Model) ->
    chat_stream(list_to_binary(Model), Messages, Tools, Callback);
chat_stream(Model, Messages, Tools, Callback) when is_binary(Model) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        tools => Tools,
        think => true,
        stream => true
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [{stream, self()}]) of
        {ok, _RequestId} ->
            collect_chat_stream(Callback, #{}, <<>>, <<>>);
        {error, Reason} ->
            {error, Reason}
    end.

collect_chat_stream(Callback, ResponseAcc, ThinkingAcc, ContentAcc) ->
    receive
        {hackney_response, _Ref, {done, _}} ->
            {ok, #{
                message => ResponseAcc,
                thinking => ThinkingAcc,
                content => ContentAcc
            }};
        {hackney_response, _Ref, Data} ->
            case jsx:is_json(Data) of
                true ->
                    Chunk = jsx:decode(Data, [return_maps]),
                    Msg = maps:get(<<"message">>, Chunk, #{}),
                    
                    % Extract thinking
                    Thinking = maps:get(<<"thinking">>, Msg, <<>>),
                    NewThinking = case Thinking of
                        <<>> -> ThinkingAcc;
                        _ -> <<ThinkingAcc/binary, Thinking/binary>>
                    end,
                    
                    % Extract content
                    Content = maps:get(<<"content">>, Msg, <<>>),
                    NewContent = case Content of
                        <<>> -> ContentAcc;
                        _ -> <<ContentAcc/binary, Content/binary>>
                    end,
                    
                    % Call callback with chunk
                    Callback(Chunk, #{
                        thinking => Thinking,
                        content => Content,
                        thinking_acc => NewThinking,
                        content_acc => NewContent
                    }),
                    
                    NewAcc = maps:merge(ResponseAcc, Msg),
                    collect_chat_stream(Callback, NewAcc, NewThinking, NewContent);
                false ->
                    collect_chat_stream(Callback, ResponseAcc, ThinkingAcc, ContentAcc)
            end;
        _ ->
            collect_chat_stream(Callback, ResponseAcc, ThinkingAcc, ContentAcc)
    after 300000 ->
        {error, timeout}
    end.

% Token estimation (approximate: ~4 chars per token for English, ~6 for code)
count_tokens(Text) when is_binary(Text) ->
    % Rough estimate: divide by 4 for English, 6 for code
    max(1, byte_size(Text) div 4);
count_tokens(Text) when is_list(Text) ->
    try
        count_tokens(iolist_to_binary(Text))
    catch
        _:_ -> max(1, length(Text) div 4)  % Fallback estimate
    end;
count_tokens(Messages) when is_list(Messages) ->
    lists:foldl(fun(Msg, Acc) ->
        try
            case Msg of
                #{<<"content">> := Content} when is_binary(Content), Content =/= <<>>, Content =/= nil ->
                    Acc + count_tokens(Content);
                #{<<"content">> := nil} ->
                    Acc + 5;
                #{<<"content">> := <<>>} ->
                    Acc + 5;
                #{<<"content">> := Content} ->
                    try
                        Acc + count_tokens(Content)
                    catch
                        _:_ -> Acc + 50
                    end;
                #{<<"tool_calls">> := _TCs} ->
                    Acc + 100;  % Estimate for tool calls
                _ ->
                    Acc + 10
            end
        catch
            _:_ -> Acc + 10
        end
    end, 0, Messages).

% Truncate messages to fit within token limit
truncate_messages(Messages, MaxTokens) ->
    truncate_messages(Messages, MaxTokens, []).

truncate_messages([], _MaxTokens, Acc) ->
    lists:reverse(Acc);
truncate_messages([Msg | Rest], MaxTokens, Acc) ->
    MsgTokens = count_tokens(Msg),
    CurrentTokens = count_tokens(Acc),
    case CurrentTokens + MsgTokens > MaxTokens of
        true ->
            % Would exceed limit, stop adding
            lists:reverse(Acc);
        false ->
            truncate_messages(Rest, MaxTokens, [Msg | Acc])
    end.