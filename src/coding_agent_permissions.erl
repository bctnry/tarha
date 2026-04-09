-module(coding_agent_permissions).
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([check/2, allow/1, allow/2, deny/1, deny/2, set_mode/1, get_mode/0, get_rules/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_MODE, ask).
-define(RULES_TABLE, coding_agent_permission_rules).

-record(rule, {
    pattern :: binary(),
    decision :: allow | deny | ask,
    source :: cli | session | project | user
}).

-record(state, {
    mode :: ask | auto | plan,
    session_rules :: [#rule{}]
}).

start_link() ->
    start_link(?DEFAULT_MODE).

start_link(Mode) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Mode], []).

init([Mode]) ->
    ets:new(?RULES_TABLE, [named_table, public, ordered_set]),
    load_rules_from_config(),
    {ok, #state{mode = Mode, session_rules = []}}.

handle_call({check, ToolName, Args}, _From, State = #state{mode = Mode}) ->
    Decision = case Mode of
        auto -> {allow, auto_mode};
        plan ->
            case is_readonly_tool(ToolName) of
                true -> {allow, plan_readonly};
                false -> {deny, plan_mode}
            end;
        meticulous ->
            case is_readonly_tool(ToolName) of
                true -> {allow, meticulous_readonly};
                false -> {deny, meticulous_mode}
            end;
        bypassPermissions -> {allow, bypass};
        ask ->
            case check_rules(ToolName, Args, State) of
                {allow, Reason} -> {allow, Reason};
                {deny, Reason} -> {deny, Reason};
                ask -> ask
            end
    end,
    {reply, Decision, State};

handle_call(get_mode, _From, State = #state{mode = Mode}) ->
    {reply, Mode, State};

handle_call(get_rules, _From, State) ->
    Rules = ets:tab2list(?RULES_TABLE),
    {reply, Rules, State};

handle_call(reset, _From, _State) ->
    ets:delete_all_objects(?RULES_TABLE),
    {reply, ok, #state{mode = ?DEFAULT_MODE, session_rules = []}};

handle_call({set_mode, Mode}, _From, State) ->
    {reply, ok, State#state{mode = Mode}};

handle_call({add_rule, Pattern, Decision, Source}, _From, State = #state{session_rules = Rules}) ->
    Rule = #rule{pattern = Pattern, decision = Decision, source = Source},
    NewRules = [Rule | Rules],
    {reply, ok, State#state{session_rules = NewRules}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({add_session_rule, Pattern, Decision}, State = #state{session_rules = Rules}) ->
    Rule = #rule{pattern = Pattern, decision = Decision, source = session},
    {noreply, State#state{session_rules = [Rule | Rules]}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

check(ToolName, Args) ->
    gen_server:call(?MODULE, {check, ToolName, Args}, 5000).

allow(Pattern) ->
    gen_server:call(?MODULE, {add_rule, Pattern, allow, session}, 5000).

allow(Pattern, Source) ->
    gen_server:call(?MODULE, {add_rule, Pattern, allow, Source}, 5000).

deny(Pattern) ->
    gen_server:call(?MODULE, {add_rule, Pattern, deny, session}, 5000).

deny(Pattern, Source) ->
    gen_server:call(?MODULE, {add_rule, Pattern, deny, Source}, 5000).

set_mode(Mode) ->
    gen_server:call(?MODULE, {set_mode, Mode}, 5000).

get_mode() ->
    gen_server:call(?MODULE, get_mode, 5000).

get_rules() ->
    gen_server:call(?MODULE, get_rules, 5000).

reset() ->
    gen_server:call(?MODULE, reset, 5000).

check_rules(ToolName, Args, #state{session_rules = SessionRules}) ->
    AllRules = SessionRules ++ ets:tab2list(?RULES_TABLE),
    check_rules_ordered(ToolName, Args, AllRules).

check_rules_ordered(_ToolName, _Args, []) ->
    ask;
check_rules_ordered(ToolName, Args, [#rule{pattern = Pattern, decision = Decision} | Rest]) ->
    case match_pattern(Pattern, ToolName, Args) of
        true -> {Decision, {matched, Pattern}};
        false -> check_rules_ordered(ToolName, Args, Rest)
    end.

match_pattern(Pattern, ToolName, _Args) ->
    PatternAsList = binary_to_list(Pattern),
    ToolNameAsList = binary_to_list(ToolName),
    case lists:suffix(PatternAsList, ToolNameAsList) of
        true when Pattern =:= ToolName -> true;
        true -> true;
        _ ->
            HasParen = lists:any(fun(C) -> C =:= $( end, PatternAsList),
            case HasParen of
                true ->
                    PatternPrefix = hd(string:tokens(PatternAsList, "(")),
                    lists:prefix(PatternPrefix, ToolNameAsList);
                false ->
                    binary:match(ToolName, Pattern) =/= nomatch
            end
    end.

is_readonly_tool(ToolName) ->
    lists:member(ToolName, [
        <<"read_file">>, <<"list_files">>, <<"file_exists">>,
        <<"grep_files">>, <<"find_files">>, <<"find_references">>, <<"get_callers">>,
        <<"git_status">>, <<"git_log">>, <<"git_diff">>,
        <<"detect_project">>, <<"list_models">>, <<"show_model">>,
        <<"list_backups">>, <<"undo_history">>, <<"undo_edit">>,
        <<"list_skills">>, <<"load_skill">>,
        <<"get_self_modules">>, <<"analyze_self">>, <<"list_checkpoints">>,
        <<"review_changes">>, <<"http_request">>, <<"fetch_docs">>, <<"load_context">>,
        <<"hello">>
    ]).

load_rules_from_config() ->
    ConfigFile = filename:join([coding_agent_config:workspace(), ".tarha", "permissions.yaml"]),
    case filelib:is_file(ConfigFile) of
        true ->
            case yamerl_constr:file(ConfigFile) of
                [{Config}] when is_list(Config) ->
                    Rules = proplists:get_value("rules", Config, []),
                    lists:foreach(fun(RuleProps) ->
                        Pattern = list_to_binary(proplists:get_value("pattern", RuleProps, "*")),
                        DecisionStr = proplists:get_value("decision", RuleProps, "ask"),
                        Decision = case DecisionStr of
                            "allow" -> allow;
                            "deny" -> deny;
                            _ -> ask
                        end,
                        ets:insert(?RULES_TABLE, {Pattern, Decision, project})
                    end, Rules);
                _ -> ok
            end;
        false -> ok
    end.