-module(coding_agent_tools_model).
-export([execute/2]).

execute(<<"list_models">>, _Args) ->
    coding_agent_tools:report_progress(<<"list_models">>, <<"starting">>, #{}),
    case coding_agent_ollama:list_models() of
        {ok, Models} ->
            Result = #{<<"success">> => true, <<"models">> => Models, <<"count">> => length(Models)},
            coding_agent_tools:report_progress(<<"list_models">>, <<"complete">>, #{count => length(Models)}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => coding_agent_tools:safe_binary(Reason)},
            coding_agent_tools:report_progress(<<"list_models">>, <<"error">>, #{reason => Reason}),
            Result
    end;

execute(<<"switch_model">>, #{<<"model">> := Model}) ->
    coding_agent_tools:report_progress(<<"switch_model">>, <<"starting">>, #{model => Model}),
    case coding_agent_ollama:switch_model(Model) of
        {ok, OldModel, NewModel} ->
            Result = #{<<"success">> => true, <<"old_model">> => OldModel, <<"new_model">> => NewModel},
            coding_agent_tools:log_operation(<<"switch_model">>, Model, Result),
            coding_agent_tools:report_progress(<<"switch_model">>, <<"complete">>, #{old => OldModel, new => NewModel}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => coding_agent_tools:safe_binary(Reason)},
            coding_agent_tools:report_progress(<<"switch_model">>, <<"error">>, #{reason => Reason}),
            Result
    end;

execute(<<"show_model">>, #{<<"model">> := Model} = Args) ->
    Verbose = maps:get(<<"verbose">>, Args, false),
    Opts = #{verbose => Verbose},
    coding_agent_tools:report_progress(<<"show_model">>, <<"starting">>, #{model => Model, verbose => Verbose}),
    case coding_agent_ollama:show_model(Model, Opts) of
        {ok, ModelInfo} ->
            Details = maps:get(<<"details">>, ModelInfo, #{}),
            Capabilities = maps:get(<<"capabilities">>, ModelInfo, []),
            Parameters = maps:get(<<"parameters">>, ModelInfo, undefined),
            ModelInfoMap = maps:get(<<"model_info">>, ModelInfo, #{}),

            Result = #{
                <<"success">> => true,
                <<"model">> => Model,
                <<"details">> => Details,
                <<"capabilities">> => Capabilities,
                <<"parameters">> => Parameters,
                <<"model_info">> => ModelInfoMap,
                <<"license">> => maps:get(<<"license">>, ModelInfo, undefined),
                <<"modified_at">> => maps:get(<<"modified_at">>, ModelInfo, undefined),
                <<"template">> => maps:get(<<"template">>, ModelInfo, undefined)
            },
            coding_agent_tools:report_progress(<<"show_model">>, <<"complete">>, #{model => Model}),
            Result;
        {error, Reason} ->
            Result = #{<<"success">> => false, <<"error">> => coding_agent_tools:safe_binary(Reason)},
            coding_agent_tools:report_progress(<<"show_model">>, <<"error">>, #{reason => Reason}),
            Result
    end.