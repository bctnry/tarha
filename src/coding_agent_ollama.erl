-module(coding_agent_ollama).
-export([generate/2, generate_stream/2, chat/2, chat_with_tools/3, chat_stream/3, chat_stream/4]).
-export([chat_with_tools_cancellable/4, chat_stream_cancellable/5]).
-export([count_tokens/1, count_tokens_accurate/2, truncate_messages/2]).
-export([start_token_cache/0, clear_token_cache/0]).
-export([get_model_info/1, get_model_context_length/1, get_model_context_length/2]).
-export([show_model/2, get_model_capabilities/1]).
-export([list_models/0, switch_model/1, get_current_model/0]).
-export([get_token_stats/0, model_supports_thinking/1, model_supports_tools/1]).

-define(MAX_RETRIES, 20).
-define(RETRY_DELAY_BASE, 5000).  % 5 second base.
-define(RETRY_DELAY_MAX, 60000).  % 1 minute maximum.
-define(TOKEN_CACHE_TABLE, coding_agent_token_cache).
-define(TOKEN_CACHE_MAX_SIZE, 10000).  % Max cached entries

%% Token counting strategies:
%% 1. Accurate (count_tokens_accurate/2): Uses Ollama API to count tokens (when available)
%% 2. Fast estimate (count_tokens/1): Char-based heuristic (~4 chars/token for English, ~2.5 for code)

start_token_cache() ->
    case ets:whereis(?TOKEN_CACHE_TABLE) of
        undefined -> 
            ets:new(?TOKEN_CACHE_TABLE, [set, public, named_table, {read_concurrency, true}]),
            ok;
        _ -> ok
    end.

clear_token_cache() ->
    case ets:whereis(?TOKEN_CACHE_TABLE) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?TOKEN_CACHE_TABLE)
    end.

%% Get token cache table, create if needed
get_token_cache() ->
    case ets:whereis(?TOKEN_CACHE_TABLE) of
        undefined ->
            ets:new(?TOKEN_CACHE_TABLE, [set, public, named_table, {read_concurrency, true}]),
            ?TOKEN_CACHE_TABLE;
        T -> T
    end.

do_with_retry(Fun) ->
    do_with_retry(Fun, 0).

do_with_retry(Fun, RetryCount) when RetryCount >= ?MAX_RETRIES ->
    {error, max_retries_exceeded};
do_with_retry(Fun, RetryCount) ->
    Delay = min(?RETRY_DELAY_BASE * round(math:pow(2, RetryCount)), ?RETRY_DELAY_MAX),
    case Fun() of
        {ok, Result} ->
            {ok, Result};
        {error, {status, StatusCode, _Body}} when StatusCode =:= 408; StatusCode =:= 429; StatusCode >= 500 ->
            io:format("[ollama] HTTP ~p, retrying in ~pms (attempt ~p/~p)~n", 
                      [StatusCode, Delay, RetryCount + 1, ?MAX_RETRIES]),
            timer:sleep(Delay),
            do_with_retry(Fun, RetryCount + 1);
        {error, {status, StatusCode, Body}} ->
            {error, {http_error, StatusCode, Body}};
        {error, timeout} ->
            io:format("[ollama] Timeout, retrying in ~pms (attempt ~p/~p)~n", 
                      [Delay, RetryCount + 1, ?MAX_RETRIES]),
            timer:sleep(Delay),
            do_with_retry(Fun, RetryCount + 1);
        {error, Reason} ->
            io:format("[ollama] Error ~p, retrying in ~pms (attempt ~p/~p)~n", 
                      [Reason, Delay, RetryCount + 1, ?MAX_RETRIES]),
            timer:sleep(Delay),
            do_with_retry(Fun, RetryCount + 1)
    end.

generate(Model, Prompt) ->
    generate(Model, Prompt, #{}).

generate(Model, Prompt, Opts) when is_list(Model) ->
    generate(list_to_binary(Model), Prompt, Opts);
generate(Model, Prompt, _Opts) when is_binary(Model) ->
    do_with_retry(fun() -> do_generate(Model, Prompt) end).

do_generate(Model, Prompt) ->
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
    do_with_retry(fun() -> do_chat(Model, Messages) end).

do_chat(Model, Messages) ->
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
    do_with_retry(fun() -> do_chat_with_tools(Model, Messages, Tools) end).

do_chat_with_tools(Model, Messages, Tools) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    % Check if model supports thinking and tools
    SupportsThinking = model_supports_thinking(Model),
    SupportsTools = model_supports_tools(Model),
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        tools => case SupportsTools of true -> Tools; false -> [] end,
        think => SupportsThinking,
        stream => false
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:request(post, Url, Headers, Body, [{recv_timeout, 120000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            Resp = jsx:decode(RespBody, [return_maps]),
            %% Extract token counts from response
            PromptTokens = maps:get(<<"prompt_eval_count">>, Resp, undefined),
            CompletionTokens = maps:get(<<"eval_count">>, Resp, undefined),
            TokenInfo = #{
                prompt_tokens => PromptTokens,
                completion_tokens => CompletionTokens,
                total_tokens => case {PromptTokens, CompletionTokens} of
                    {P, C} when is_integer(P), is_integer(C) -> P + C;
                    _ -> undefined
                end
            },
            {ok, Resp#{token_info => TokenInfo}};
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
    after 120000 ->
        {error, timeout}
    end.

chat_stream(Model, Messages, Tools) ->
    chat_stream(Model, Messages, Tools, fun(_, _) -> ok end).

chat_stream(Model, Messages, Tools, Callback) when is_list(Model) ->
    chat_stream(list_to_binary(Model), Messages, Tools, Callback);
chat_stream(Model, Messages, Tools, Callback) when is_binary(Model) ->
    do_with_retry(fun() -> do_chat_stream(Model, Messages, Tools, Callback) end).

do_chat_stream(Model, Messages, Tools, Callback) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    SupportsThinking = model_supports_thinking(Model),
    SupportsTools = model_supports_tools(Model),
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        tools => case SupportsTools of true -> Tools; false -> [] end,
        think => SupportsThinking,
        stream => true
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [{stream, self()}]) of
        {ok, _StatusCode, _Headers, Ref} when is_reference(Ref) ->
            collect_chat_stream(Callback, #{}, <<>>, <<>>);
        {ok, _Ref} ->
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
    after 120000 ->
        {error, timeout}
    end.

%% Token estimation using character-based heuristics
%% For English text: ~4 chars/token (word-based tokenizers)
%% For code: ~2.5-3 chars/token (code is more dense)
%% We use a weighted approach based on content type
count_tokens(Text) when is_binary(Text), byte_size(Text) == 0 ->
    0;
count_tokens(Text) when is_binary(Text) ->
    %% Detect content type and apply appropriate ratio
    %% Code tends to have more symbols, shorter identifiers
    CodeRatio = estimate_code_ratio(Text),
    %% Code: ~2.5 chars/token, English: ~4 chars/token
    EffectiveRatio = 2.5 + (1.5 * (1 - CodeRatio)),
    max(1, round(byte_size(Text) / EffectiveRatio));
count_tokens(Text) when is_list(Text) ->
    try
        count_tokens(iolist_to_binary(Text))
    catch
        _:_ -> max(1, length(Text) div 3)  % Fallback estimate
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

%% Estimate how much of the text is code vs natural language
%% Returns a value between 0 (pure English) and 1 (pure code)
estimate_code_ratio(Text) when is_binary(Text) ->
    Size = byte_size(Text),
    if Size == 0 -> 0.0; true ->
        %% Count code-like patterns
        %% Code has: more brackets, semicolons, equals signs, etc.
        BracketCount = binary:matches(Text, [<<"{">>, <<"}">>, <<"[">>, <<"]">>, <<"(">>, <<")">>]),
        SemicolonCount = binary:matches(Text, <<";">>),
        EqualsCount = binary:matches(Text, <<"=">>),
        DotCount = binary:matches(Text, <<".">>),
        ArrowCount = binary:matches(Text, [<<"->">>, <<"=>">>, <<"::">>]),
        
        %% Total code indicators
        CodeIndicators = length(BracketCount) + length(SemicolonCount) + 
                        length(EqualsCount) + length(ArrowCount),
        
        %% Natural text has more dots and longer text
        NaturalIndicators = length(DotCount),
        
        %% Ratio based on density of code patterns
        %% Code: ~5-10% symbols, English: ~2-3% symbols
        CodeDensity = min(1.0, CodeIndicators / (Size / 100)),
        
        %% Also check for typical code keywords
        CodeKeywords = binary:matches(Text, [<<"function">>, <<"def ">>, <<"var ">>, 
                                             <<"const ">>, <<"let ">>, <<"if ">>, 
                                             <<"else ">>, <<"return ">>, <<"import ">>,
                                             <<"module ">>, <<"export ">>]),
        KeywordDensity = min(1.0, length(CodeKeywords) / (Size / 200)),
        
        %% Weighted combination
        (CodeDensity * 0.6 + KeywordDensity * 0.4)
    end.

%% Accurate token counting using Ollama API
%% This sends the text to the API and gets actual token count from prompt_eval_count
%% Caches results to avoid redundant API calls
count_tokens_accurate(Model, Text) when is_binary(Text) ->
    CacheKey = {Model, erlang:phash2(Text)},
    Table = get_token_cache(),
    
    %% Check cache first
    case ets:lookup(Table, CacheKey) of
        [{_, Count}] -> 
            {ok, Count};
        [] ->
            %% Make API call to get actual token count
            case get_token_count_from_api(Model, Text) of
                {ok, Count} ->
                    %% Cache the result (limit cache size)
                    CacheSize = ets:info(Table, size),
                    if CacheSize > ?TOKEN_CACHE_MAX_SIZE ->
                        ets:delete_all_objects(Table);
                    true -> ok
                    end,
                    ets:insert(Table, {CacheKey, Count}),
                    {ok, Count};
                {error, Reason} ->
                    %% Fall back to estimate on error
                    {error, Reason, count_tokens(Text)}
            end
    end;
count_tokens_accurate(Model, Text) when is_list(Text) ->
    count_tokens_accurate(Model, iolist_to_binary(Text));
count_tokens_accurate(Model, Messages) when is_list(Messages) ->
    %% For message lists, use estimate since API doesn't directly tokenize messages
    {ok, count_tokens(Messages)}.

%% Get actual token count by making a minimal API call
get_token_count_from_api(Model, Text) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/generate",
    
    %% Use num_predict: 0 to get token count without generating
    Body = jsx:encode(#{
        model => Model,
        prompt => Text,
        stream => false,
        options => #{num_predict => 0}
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [{recv_timeout, 10000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            try jsx:decode(RespBody, [return_maps]) of
                Resp ->
                    %% prompt_eval_count is the actual token count
                    case Resp of
                        #{<<"prompt_eval_count">> := Count} when is_integer(Count) ->
                            {ok, Count};
                        _ ->
                            %% Fall back to estimate if API doesn't return count
                            {error, no_token_count}
                    end
            catch
                _:_ -> {error, parse_error}
            end;
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {http_error, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

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

%% Model info functions - get context length from Ollama API

-define(DEFAULT_CONTEXT_LENGTH, 32768).

get_model_context_length(Model) ->
    get_model_context_length(Model, ?DEFAULT_CONTEXT_LENGTH).

get_model_context_length(Model, Default) when is_binary(Model) ->
    case get_model_info(Model) of
        {ok, ModelInfo} when is_map(ModelInfo) ->
            extract_context_length_from_model_info(ModelInfo, Default);
        _ ->
            Default
    end;
get_model_context_length(Model, Default) when is_list(Model) ->
    get_model_context_length(list_to_binary(Model), Default).

extract_context_length_from_model_info(ModelInfo, Default) ->
    Keys = [<<"context_length">>, <<"num_ctx">>, <<"n_ctx">>],
    
    TopLevel = find_first_key(ModelInfo, Keys),
    
    NestedModelInfo = case maps:get(<<"model_info">>, ModelInfo, undefined) of
        MI when is_map(MI) -> find_first_key(MI, Keys);
        _ -> undefined
    end,
    
    ParamsCtx = case maps:get(<<"parameters">>, ModelInfo, undefined) of
        P when is_map(P) -> find_first_key(P, Keys);
        _ -> undefined
    end,
    
    DetailsCtx = case maps:get(<<"details">>, ModelInfo, undefined) of
        D when is_map(D) -> find_first_key(D, Keys);
        _ -> undefined
    end,
    
    case find_first([TopLevel, NestedModelInfo, ParamsCtx, DetailsCtx]) of
        Len when is_integer(Len), Len > 0 -> Len;
        _ -> Default
    end.

find_first_key(Map, Keys) when is_map(Map) ->
    lists:foldl(fun(Key, Acc) ->
        case Acc of
            undefined -> maps:get(Key, Map, undefined);
            _ -> Acc
        end
    end, undefined, Keys);
find_first_key(_, _) ->
    undefined.

find_first([undefined | Rest]) ->
    find_first(Rest);
find_first([Value | _]) ->
    Value;
find_first([]) ->
    undefined.

get_model_info(Model) ->
    show_model(Model, #{}).

show_model(Model, Opts) when is_binary(Model), is_map(Opts) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/show",
    Body0 = #{model => Model},
    Body = case maps:get(<<"verbose">>, Opts, undefined) of
        true -> Body0#{verbose => true};
        _ -> Body0
    end,
    EncodedBody = jsx:encode(Body),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(Url, Headers, EncodedBody, [{recv_timeout, 10000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            try jsx:decode(RespBody, [return_maps]) of
                Resp -> {ok, Resp}
            catch
                _:_ -> {error, parse_error}
            end;
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {http_error, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end;
show_model(Model, Opts) when is_list(Model) ->
    show_model(list_to_binary(Model), Opts).

%% Model management functions

list_models() ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/tags",
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:get(Url, Headers, <<>>, [{recv_timeout, 10000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            try jsx:decode(RespBody, [return_maps]) of
                #{<<"models">> := Models} ->
                    ModelList = lists:map(fun(#{<<"name">> := Name} = M) ->
                        #{
                            name => Name,
                            size => maps:get(<<"size">>, M, undefined),
                            digest => maps:get(<<"digest">>, M, undefined),
                            modified_at => maps:get(<<"modified_at">>, M, undefined),
                            details => maps:get(<<"details">>, M, undefined)
                        }
                    end, Models),
                    {ok, ModelList};
                Resp ->
                    {error, {unexpected_response, Resp}}
            catch
                _:_ -> {error, parse_error}
            end;
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {http_error, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

switch_model(Model) when is_binary(Model) ->
    OldModel = get_current_model(),
    application:set_env(coding_agent, ollama_model, binary_to_list(Model)),
    {ok, OldModel, binary_to_list(Model)};
switch_model(Model) when is_list(Model) ->
    switch_model(list_to_binary(Model)).

get_current_model() ->
    case application:get_env(coding_agent, ollama_model) of
        {ok, Model} when is_list(Model) -> list_to_binary(Model);
        {ok, Model} when is_binary(Model) -> Model;
        undefined -> <<"glm-5:cloud">>
    end.

%% Get global token statistics
get_token_stats() ->
    #{prompt_tokens => 0, completion_tokens => 0, estimated_tokens => 0}.

%% ============================================================================
%% Cancellable API - these versions support cancellation via request registry
%% ============================================================================

%% @doc Chat with tools that can be cancelled by session ID
%% Spawns a worker process to allow cancellation via halt/1
-spec chat_with_tools_cancellable(binary(), binary(), list(), list()) -> 
    {ok, map()} | {error, term()}.
chat_with_tools_cancellable(SessionId, Model, Messages, Tools) when is_binary(SessionId) ->
    Parent = self(),
    Ref = make_ref(),
    
    %% Spawn worker process for the request
    WorkerPid = spawn_link(fun() ->
        Result = do_chat_with_tools(Model, Messages, Tools),
        Parent ! {chat_result, Ref, Result}
    end),
    
    %% Register for cancellation
    case coding_agent_request_registry:register(SessionId, Ref) of
        ok ->
            %% Wait for result or cancellation
            Result = receive
                {chat_result, Ref, R} ->
                    R;
                {request_halted, SessionId, _} ->
                    unlink(WorkerPid),
                    exit(WorkerPid, kill),
                    {error, halted}
            after 300000 ->
                exit(WorkerPid, kill),
                {error, timeout}
            end,
            coding_agent_request_registry:unregister(SessionId),
            Result;
        {error, already_exists} ->
            exit(WorkerPid, kill),
            {error, request_already_in_progress}
    end.

%% @doc Streaming chat with cancellation support
%% Returns {ok, Ref} where Ref can be used to cancel the request
-spec chat_stream_cancellable(binary(), binary(), list(), fun(), binary()) -> 
    {ok, reference()} | {error, term()}.
chat_stream_cancellable(SessionId, Model, Messages, Tools, Callback) when is_binary(SessionId) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/chat",
    
    SupportsThinking = model_supports_thinking(Model),
    
    Body = jsx:encode(#{
        model => Model,
        messages => Messages,
        tools => Tools,
        think => SupportsThinking,
        stream => true
    }),
    
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    
    case hackney:post(Url, Headers, Body, [{stream, self()}]) of
        {ok, _StatusCode, _Headers, Ref} when is_reference(Ref) ->
            %% Register the request for cancellation
            case coding_agent_request_registry:register(SessionId, Ref) of
                ok ->
                    Result = collect_chat_stream_cancellable(SessionId, Callback, #{}, <<>>, <<>>),
                    coding_agent_request_registry:unregister(SessionId),
                    Result;
                {error, already_exists} ->
                    hackney_manager:cancel_request(Ref),
                    {error, request_already_in_progress}
            end;
        {ok, _Ref} ->
            {error, invalid_reference};
        {error, Reason} ->
            {error, Reason}
    end.

%% Collect stream with cancellation support
collect_chat_stream_cancellable(SessionId, Callback, ResponseAcc, ThinkingAcc, ContentAcc) ->
    receive
        {request_halted, SessionId, _Ref} ->
            {error, halted};
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
                    collect_chat_stream_cancellable(SessionId, Callback, NewAcc, NewThinking, NewContent);
                false ->
                    collect_chat_stream_cancellable(SessionId, Callback, ResponseAcc, ThinkingAcc, ContentAcc)
            end;
        _ ->
            collect_chat_stream_cancellable(SessionId, Callback, ResponseAcc, ThinkingAcc, ContentAcc)
    after 120000 ->
        {error, timeout}
    end.

%% @doc Check if model supports thinking mode
%% Queries the model's capabilities from Ollama API
model_supports_thinking(Model) when is_binary(Model) ->
    case get_model_capabilities(Model) of
        {ok, Capabilities} ->
            lists:member(<<"thinking">>, Capabilities);
        {error, _} ->
            false
    end;
model_supports_thinking(Model) when is_list(Model) ->
    model_supports_thinking(list_to_binary(Model));
model_supports_thinking(_) ->
    false.

%% @doc Check if model supports tool calling
%% Queries the model's capabilities from Ollama API
model_supports_tools(Model) when is_binary(Model) ->
    case get_model_capabilities(Model) of
        {ok, Capabilities} ->
            lists:member(<<"tools">>, Capabilities);
        {error, _} ->
            false
    end;
model_supports_tools(Model) when is_list(Model) ->
    model_supports_tools(list_to_binary(Model));
model_supports_tools(_) ->
    false.

%% @doc Get model capabilities from Ollama API
get_model_capabilities(Model) when is_binary(Model) ->
    Host = application:get_env(coding_agent, ollama_host, "http://localhost:11434"),
    Url = Host ++ "/api/show",
    Body = jsx:encode(#{name => Model}),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(Url, Headers, Body, [{recv_timeout, 5000}, with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            try jsx:decode(RespBody, [return_maps]) of
                Resp -> 
                    Capabilities = maps:get(<<"capabilities">>, Resp, []),
                    {ok, Capabilities}
            catch
                _:_ -> {error, parse_error}
            end;
        {ok, StatusCode, _RespHeaders, RespBody} ->
            {error, {http_error, StatusCode, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.
