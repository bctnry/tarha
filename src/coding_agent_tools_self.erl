-module(coding_agent_tools_self).
-export([execute/2]).

execute(<<"reload_module">>, #{<<"module">> := Module}) ->
    ModuleAtom = binary_to_existing_atom(Module, utf8),
    case coding_agent_self:reload_module(ModuleAtom) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"get_self_modules">>, _Args) ->
    {ok, Modules} = coding_agent_self:get_modules(),
    #{<<"success">> => true, <<"modules">> => Modules};

execute(<<"analyze_self">>, _Args) ->
    {ok, Analysis} = coding_agent_self:analyze_self(),
    #{<<"success">> => true, <<"analysis">> => Analysis};

execute(<<"deploy_module">>, #{<<"module">> := Module, <<"code">> := Code}) ->
    ModuleAtom = binary_to_existing_atom(Module, utf8),
    case coding_agent_self:deploy_improvement(ModuleAtom, Code) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"create_checkpoint">>, _Args) ->
    case coding_agent_self:create_checkpoint() of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"restore_checkpoint">>, #{<<"checkpoint_id">> := CheckpointId}) ->
    case coding_agent_self:restore_checkpoint(CheckpointId) of
        #{success := true} = Result -> Result;
        #{success := false, error := Error} -> #{<<"success">> => false, <<"error">> => Error}
    end;

execute(<<"list_checkpoints">>, _Args) ->
    {ok, Checkpoints} = coding_agent_self:list_checkpoints(),
    #{<<"success">> => true, <<"checkpoints">> => Checkpoints}.