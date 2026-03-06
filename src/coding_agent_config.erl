-module(coding_agent_config).
-export([load/1, get/2, get/3, zulip_config/0, set_zulip/3, default/0]).

-record(config, {
    ollama_host :: string(),
    ollama_model :: string(),
    zulip_enabled :: boolean(),
    zulip_site :: string(),
    zulip_email :: string(),
    zulip_key :: string(),
    zulip_user_allowlist :: [string()],
    zulip_stream_allowlist :: [string()],
    zulip_group_policy :: open | mention | allowlist
}).

load(File) ->
    case file:read_file(File) of
        {ok, Content} ->
            case jsx:is_json(Content) of
                true ->
                    Data = jsx:decode(Content, [return_maps]),
                    {ok, parse_config(Data)};
                false ->
                    {error, invalid_json}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

default() ->
    #config{
        ollama_host = "http://localhost:11434",
        ollama_model = "glm-5:cloud",
        zulip_enabled = false,
        zulip_site = "",
        zulip_email = "",
        zulip_key = "",
        zulip_user_allowlist = [],
        zulip_stream_allowlist = [],
        zulip_group_policy = open
    }.

get(Key, Config) when is_atom(Key) ->
    get(Key, Config, undefined).

get(ollama_host, #config{ollama_host = V}, _) -> V;
get(ollama_model, #config{ollama_model = V}, _) -> V;
get(zulip_enabled, #config{zulip_enabled = V}, _) -> V;
get(zulip_site, #config{zulip_site = V}, _) -> V;
get(zulip_email, #config{zulip_email = V}, _) -> V;
get(zulip_key, #config{zulip_key = V}, _) -> V;
get(zulip_user_allowlist, #config{zulip_user_allowlist = V}, _) -> V;
get(zulip_stream_allowlist, #config{zulip_stream_allowlist = V}, _) -> V;
get(zulip_group_policy, #config{zulip_group_policy = V}, _) -> V;
get(_, _, Default) -> Default.

zulip_config() ->
    #{
        site => application:get_env(coding_agent, zulip_site, ""),
        email => application:get_env(coding_agent, zulip_email, ""),
        key => application:get_env(coding_agent, zulip_key, ""),
        user_allowlist => application:get_env(coding_agent, zulip_user_allowlist, []),
        stream_allowlist => application:get_env(coding_agent, zulip_stream_allowlist, []),
        group_policy => application:get_env(coding_agent, zulip_group_policy, open)
    }.

set_zulip(Site, Email, Key) ->
    application:set_env(coding_agent, zulip_site, Site),
    application:set_env(coding_agent, zulip_email, Email),
    application:set_env(coding_agent, zulip_key, Key),
    application:set_env(coding_agent, zulip_enabled, true),
    ok.

parse_config(Data) ->
    #config{
        ollama_host = get_nested(<<"ollama">>, <<"host">>, Data, "http://localhost:11434"),
        ollama_model = get_nested(<<"ollama">>, <<"model">>, Data, "glm-5:cloud"),
        zulip_enabled = get_nested(<<"zulip">>, <<"enabled">>, Data, false),
        zulip_site = get_nested(<<"zulip">>, <<"site">>, Data, ""),
        zulip_email = get_nested(<<"zulip">>, <<"bot_email">>, Data, ""),
        zulip_key = get_nested(<<"zulip">>, <<"api_key">>, Data, ""),
        zulip_user_allowlist = get_nested_list(<<"zulip">>, <<"user_allowlist">>, Data),
        zulip_stream_allowlist = get_nested_list(<<"zulip">>, <<"stream_allowlist">>, Data),
        zulip_group_policy = parse_group_policy(get_nested(<<"zulip">>, <<"group_policy">>, Data, <<"open">>))
    }.

get_nested(Section, Key, Data, Default) ->
    case maps:get(Section, Data, #{}) of
        SecMap when is_map(SecMap) ->
            maps:get(Key, SecMap, Default);
        _ ->
            Default
    end.

get_nested_list(Section, Key, Data) ->
    case maps:get(Section, Data, #{}) of
        SecMap when is_map(SecMap) ->
            case maps:get(Key, SecMap, []) of
                List when is_list(List) -> [iolist_to_binary(L) || L <- List];
                _ -> []
            end;
        _ ->
            []
    end.

parse_group_policy(<<"open">>) -> open;
parse_group_policy(<<"mention">>) -> mention;
parse_group_policy(<<"allowlist">>) -> allowlist;
parse_group_policy(_) -> open.