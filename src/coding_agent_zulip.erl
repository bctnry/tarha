-module(coding_agent_zulip).
-behaviour(gen_server).
-export([start_link/0, start_link/1, stop/0, send_stream/3, send_private/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    site :: string(),
    bot_email :: string(),
    api_key :: string(),
    queue_id :: binary() | undefined,
    last_event_id :: integer() | undefined
}).

%% API

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

stop() ->
    gen_server:stop(?MODULE).

send_stream(Stream, Topic, Content) when is_binary(Stream), is_binary(Topic), is_binary(Content) ->
    gen_server:call(?MODULE, {send_stream, Stream, Topic, Content}, 30000);
send_stream(Stream, Topic, Content) ->
    send_stream(iolist_to_binary(Stream), iolist_to_binary(Topic), iolist_to_binary(Content)).

send_private(ToEmails, Content) when is_list(ToEmails), is_binary(Content) ->
    gen_server:call(?MODULE, {send_private, ToEmails, Content}, 30000);
send_private(ToEmails, Content) when is_list(ToEmails) ->
    send_private(ToEmails, iolist_to_binary(Content)).

%% gen_server callbacks

init([Options]) ->
    Site = proplists:get_value(site, Options, ""),
    BotEmail = proplists:get_value(bot_email, Options, ""),
    ApiKey = proplists:get_value(api_key, Options, ""),

    case {Site, BotEmail, ApiKey} of
        {"", _, _} ->
            {stop, {error, missing_site}};
        {_, "", _} ->
            {stop, {error, missing_bot_email}};
        {_, _, ""} ->
            {stop, {error, missing_api_key}};
        _ when is_binary(Site), is_binary(BotEmail), is_binary(ApiKey) ->
            io:format("[zulip] Starting client for ~s~n", [Site]),
            {ok, #state{site = Site, bot_email = BotEmail, api_key = ApiKey}};
        _ ->
            {stop, {error, invalid_config}}
    end.

handle_call({send_stream, Stream, Topic, Content}, _From, State) ->
    Result = do_send_stream(State, Stream, Topic, Content),
    {reply, Result, State};

handle_call({send_private, ToEmails, Content}, _From, State) ->
    Result = do_send_private(State, ToEmails, Content),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

do_send_stream(State, Stream, Topic, Content) ->
    Url = iolist_to_binary([State#state.site, "/api/v1/messages"]),
    Auth = base64:encode(iolist_to_binary([State#state.bot_email, ":", State#state.api_key])),
    Headers = [
        {<<"Authorization">>, iolist_to_binary(["Basic ", Auth])},
        {<<"Content-Type">>, <<"application/json">>}
    ],
    Body = jsx:encode(#{
        <<"type">> => <<"stream">>,
        <<"to">> => Stream,
        <<"topic">> => Topic,
        <<"content">> => Content
    }),
    
    case hackney:request(post, Url, Headers, Body, [with_body]) of
        {ok, 200, _Headers, RespBody} ->
            case jsx:is_json(RespBody) of
                true ->
                    Data = jsx:decode(RespBody, [return_maps]),
                    case maps:get(<<"result">>, Data, <<"error">>) of
                        <<"success">> -> {ok, maps:get(<<"id">>, Data, undefined)};
                        <<"error">> -> {error, maps:get(<<"msg">>, Data, <<"unknown error">>)}
                    end;
                false ->
                    {error, invalid_response}
            end;
        {ok, Status, _Headers, RespBody} ->
            {error, {http_error, Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

do_send_private(State, ToEmails, Content) ->
    Url = iolist_to_binary([State#state.site, "/api/v1/messages"]),
    Auth = base64:encode(iolist_to_binary([State#state.bot_email, ":", State#state.api_key])),
    Headers = [
        {<<"Authorization">>, iolist_to_binary(["Basic ", Auth])},
        {<<"Content-Type">>, <<"application/json">>}
    ],
    Body = jsx:encode(#{
        <<"type">> => <<"private">>,
        <<"to">> => ToEmails,
        <<"content">> => Content
    }),
    
    case hackney:request(post, Url, Headers, Body, [with_body]) of
        {ok, 200, _Headers, RespBody} ->
            case jsx:is_json(RespBody) of
                true ->
                    Data = jsx:decode(RespBody, [return_maps]),
                    case maps:get(<<"result">>, Data, <<"error">>) of
                        <<"success">> -> {ok, maps:get(<<"id">>, Data, undefined)};
                        <<"error">> -> {error, maps:get(<<"msg">>, Data, <<"unknown error">>)}
                    end;
                false ->
                    {error, invalid_response}
            end;
        {ok, Status, _Headers, RespBody} ->
            {error, {http_error, Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.
