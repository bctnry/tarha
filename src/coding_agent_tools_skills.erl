-module(coding_agent_tools_skills).
-export([execute/2]).

execute(<<"list_skills">>, Args) ->
    AvailableOnly = maps:get(<<"available_only">>, Args, false),
    coding_agent_tools:report_progress(<<"list_skills">>, <<"starting">>, #{}),
    case coding_agent_skills:list_skills(AvailableOnly) of
        {ok, Skills} ->
            Result = #{
                <<"success">> => true,
                <<"skills">> => Skills,
                <<"count">> => length(Skills)
            },
            coding_agent_tools:report_progress(<<"list_skills">>, <<"complete">>, #{count => length(Skills)}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => coding_agent_tools:safe_binary(Reason)},
            coding_agent_tools:report_progress(<<"list_skills">>, <<"error">>, #{reason => Reason}),
            Result
    end;

execute(<<"load_skill">>, #{<<"name">> := Name}) ->
    coding_agent_tools:report_progress(<<"load_skill">>, <<"starting">>, #{name => Name}),
    case coding_agent_skills:load_skill(Name) of
        {ok, Content} ->
            Result = #{
                <<"success">> => true,
                <<"name">> => Name,
                <<"content">> => coding_agent_tools:safe_binary(Content)
            },
            coding_agent_tools:report_progress(<<"load_skill">>, <<"complete">>, #{name => Name}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => coding_agent_tools:safe_binary(Reason)},
            coding_agent_tools:report_progress(<<"load_skill">>, <<"error">>, #{reason => Reason}),
            Result
    end.