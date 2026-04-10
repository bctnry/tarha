-module(coding_agent_skills).
-export([start_link/0, start_link/1, stop/0]).
-export([list_skills/0, list_skills/1, load_skill/1, get_always_skills/0, build_skills_summary/0]).
-export([activate_conditional_skills/1, search_skills/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    workspace :: string(),
    workspace_skills :: string(),
    builtin_skills :: string() | undefined
}).

-define(SKILL_FILE, "SKILL.md").

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Options], []).

stop() ->
    gen_server:stop(?MODULE).

init([Options]) ->
    Workspace = proplists:get_value(workspace, Options, get_default_workspace()),
    WorkspaceSkills = filename:join([Workspace, ".tarha", "skills"]),
    BuiltinSkills = proplists:get_value(builtin_skills, Options, get_builtin_skills_dir()),
    {ok, #state{
        workspace = Workspace,
        workspace_skills = WorkspaceSkills,
        builtin_skills = BuiltinSkills
    }}.

get_default_workspace() ->
    case file:get_cwd() of
        {ok, Dir} -> Dir;
        _ -> "."
    end.

get_builtin_skills_dir() ->
    case code:lib_dir(coding_agent) of
        {error, _} -> undefined;
        LibDir -> filename:join([LibDir, "priv", "skills"])
    end.

handle_call(list_skills, _From, State) ->
    Skills = do_list_skills(State, false),
    {reply, {ok, Skills}, State};

handle_call({list_skills, FilterUnavailable}, _From, State) ->
    Skills = do_list_skills(State, FilterUnavailable),
    {reply, {ok, Skills}, State};

handle_call({load_skill, Name}, _From, State) ->
    Content = do_load_skill(Name, State),
    {reply, {ok, Content}, State};

handle_call(get_always_skills, _From, State) ->
    AlwaysSkills = do_get_always_skills(State),
    {reply, {ok, AlwaysSkills}, State};

handle_call(build_skills_summary, _From, State) ->
    Summary = do_build_skills_summary(State),
    {reply, {ok, Summary}, State};

handle_call({activate_conditional_skills, FilePaths}, _From, State) ->
    Activated = do_activate_conditional_skills(FilePaths, State),
    {reply, {ok, Activated}, State};

handle_call({search_skills, Query}, _From, State) ->
    Results = do_search_skills(Query, State),
    {reply, {ok, Results}, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

list_skills() ->
    gen_server:call(?MODULE, list_skills).

list_skills(FilterUnavailable) ->
    gen_server:call(?MODULE, {list_skills, FilterUnavailable}).

load_skill(Name) when is_binary(Name) ->
    load_skill(binary_to_list(Name));
load_skill(Name) when is_list(Name) ->
    gen_server:call(?MODULE, {load_skill, Name}).

get_always_skills() ->
    gen_server:call(?MODULE, get_always_skills).

build_skills_summary() ->
    gen_server:call(?MODULE, build_skills_summary).

activate_conditional_skills(FilePaths) when is_list(FilePaths) ->
    gen_server:call(?MODULE, {activate_conditional_skills, FilePaths});
activate_conditional_skills(FilePath) ->
    activate_conditional_skills([FilePath]).

search_skills(Query) when is_binary(Query); is_list(Query) ->
    gen_server:call(?MODULE, {search_skills, Query}).

do_list_skills(State, FilterUnavailable) ->
    AllSkills = list_all_skills(State),
    case FilterUnavailable of
        true -> lists:filter(fun(S) -> check_requirements(S) end, AllSkills);
        false -> AllSkills
    end.

list_all_skills(#state{workspace_skills = WSSkills, builtin_skills = BuiltinSkills}) ->
    WorkspaceSkills = list_skills_in_dir(WSSkills, workspace),
    BuiltinSkillsList = case BuiltinSkills of
        undefined -> [];
        Dir -> list_skills_in_dir(Dir, builtin)
    end,
    WorkspaceNames = [maps:get(name, S) || S <- WorkspaceSkills],
    FilteredBuiltin = lists:filter(fun(S) ->
        not lists:member(maps:get(name, S), WorkspaceNames)
    end, BuiltinSkillsList),
    WorkspaceSkills ++ FilteredBuiltin.

list_skills_in_dir(Dir, Source) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:filtermap(fun(Entry) ->
                SkillFile = filename:join([Dir, Entry, ?SKILL_FILE]),
                case filelib:is_file(SkillFile) of
                    true ->
                        {true, #{
                            name => iolist_to_binary(Entry),
                            path => iolist_to_binary(SkillFile),
                            source => Source
                        }};
                    false -> false
                end
            end, Entries);
        _ -> []
    end.

do_load_skill(Name, #state{workspace_skills = WSSkills, builtin_skills = BuiltinSkills}) ->
    NameStr = ensure_string(Name),
    WSkill = filename:join([WSSkills, NameStr, ?SKILL_FILE]),
    case file:read_file(WSkill) of
        {ok, Content} -> Content;
        _ ->
            case BuiltinSkills of
                undefined -> <<>>;
                Dir ->
                    BuiltinSkill = filename:join([Dir, NameStr, ?SKILL_FILE]),
                    case file:read_file(BuiltinSkill) of
                        {ok, Content} -> Content;
                        _ -> <<>>
                    end
            end
    end.

do_get_always_skills(State) ->
    AllSkills = do_list_skills(State, true),
    lists:filter(fun(Skill) ->
        case skill_metadata(Skill) of
            #{always := true} -> true;
            #{always := <<"true">>} -> true;
            #{always := "true"} -> true;
            _ -> false
        end
    end, AllSkills).

do_build_skills_summary(State) ->
    AllSkills = do_list_skills(State, false),
    case AllSkills of
        [] -> <<>>;
        _ ->
            SkillLines = lists:map(fun(Skill) ->
                Name = maps:get(name, Skill),
                Path = maps:get(path, Skill),
                Desc = skill_description(Skill),
                Available = check_requirements(Skill),
                NameBin = escape_xml(iolist_to_binary(Name)),
                DescBin = escape_xml(iolist_to_binary(Desc)),
                PathBin = iolist_to_binary(Path),
                AvailBin = atom_to_binary(Available, utf8),
                case Available of
                    true ->
                        <<"  <skill available=\"", AvailBin/binary, "\">\n",
                        "    <name>", NameBin/binary, "</name>\n",
                        "    <description>", DescBin/binary, "</description>\n",
                        "    <location>", PathBin/binary, "</location>\n",
                        "  </skill>">>;
                    false ->
                        Missing = missing_requirements(Skill),
                        MissingBin = escape_xml(iolist_to_binary(Missing)),
                        <<"  <skill available=\"", AvailBin/binary, "\">\n",
                        "    <name>", NameBin/binary, "</name>\n",
                        "    <description>", DescBin/binary, "</description>\n",
                        "    <location>", PathBin/binary, "</location>\n",
                        "    <requires>", MissingBin/binary, "</requires>\n",
                        "  </skill>">>
                end
            end, AllSkills),
            Inner = iolist_to_binary(lists:join(<<"\n">>, SkillLines)),
            <<"<skills>\n", Inner/binary, "\n</skills>">>
    end.

skill_metadata(#{name := Name}) ->
    Content = do_load_skill(Name, #state{}),
    parse_frontmatter(Content).

skill_description(#{name := Name} = Skill) ->
    case skill_metadata(Skill) of
        #{description := Desc} -> Desc;
        _ -> iolist_to_binary(Name)
    end.

check_requirements(#{name := _Name} = Skill) ->
    Metadata = skill_metadata(Skill),
    Requires = maps:get(requires, Metadata, #{}),
    case Requires of
        #{bins := Bins} -> check_bins(Bins);
        _ -> true
    end.

check_bins(Bins) when is_list(Bins) ->
    lists:all(fun(Bin) ->
        os:find_executable(binary_to_list(Bin)) =/= false
    end, Bins);
check_bins(_) -> true.

missing_requirements(#{name := _Name} = Skill) ->
    Metadata = skill_metadata(Skill),
    Requires = maps:get(requires, Metadata, #{}),
    MissingBins = case maps:get(bins, Requires, []) of
        [] -> [];
        Bins -> [<<"CLI: ", (iolist_to_binary(B))/binary>> || B <- Bins, os:find_executable(binary_to_list(B)) =:= false]
    end,
    MissingEnv = case maps:get(env, Requires, []) of
        [] -> [];
        Envs -> [<<"ENV: ", (iolist_to_binary(E))/binary>> || E <- Envs, os:getenv(binary_to_list(E)) =:= false]
    end,
    iolist_to_binary(lists:join(<<", ">>, MissingBins ++ MissingEnv)).

do_activate_conditional_skills(FilePaths, State) ->
    AllSkills = do_list_skills(State, false),
    lists:filter(fun(Skill) ->
        case skill_metadata(Skill) of
            #{path_patterns := Patterns} when is_list(Patterns) ->
                lists:any(fun(Pattern) ->
                    matches_any_pattern(FilePaths, Pattern)
                end, Patterns);
            _ -> false
        end
    end, AllSkills).

do_search_skills(Query, State) ->
    QueryBin = if is_list(Query) -> list_to_binary(Query); is_binary(Query) -> Query end,
    AllSkills = do_list_skills(State, false),
    lists:filter(fun(Skill) ->
        Name = maps:get(name, Skill, <<"">>),
        Desc = skill_description(Skill),
        Tags = case skill_metadata(Skill) of
            #{tags := T} when is_list(T) -> T;
            _ -> []
        end,
        NameMatch = binary:match(Name, QueryBin) =/= nomatch,
        DescMatch = binary:match(Desc, QueryBin) =/= nomatch,
        TagMatch = lists:any(fun(T) ->
            binary:match(iolist_to_binary(T), QueryBin) =/= nomatch
        end, Tags),
        NameMatch orelse DescMatch orelse TagMatch
    end, AllSkills).

matches_any_pattern(FilePaths, Pattern) ->
    PatternBin = if is_list(Pattern) -> list_to_binary(Pattern); is_binary(Pattern) -> Pattern end,
    lists:any(fun(FP) ->
        FPBin = if is_list(FP) -> list_to_binary(FP); is_binary(FP) -> FP end,
        match_glob(PatternBin, FPBin)
    end, FilePaths).

match_glob(Pattern, Path) ->
    RePattern = glob_to_regex(Pattern),
    case re:run(Path, RePattern, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

glob_to_regex(Glob) ->
    Bin = if is_list(Glob) -> list_to_binary(Glob); is_binary(Glob) -> Glob end,
    Esc = binary:replace(Bin, <<".">>, <<"\\.">>, [global]),
    Esc2 = binary:replace(Esc, <<"*">>, <<".*">>, [global]),
    binary:replace(Esc2, <<"?">>, <<".">>, [global]).

parse_frontmatter(Content) when is_binary(Content) ->
    case binary:match(Content, <<"---">>) of
        {0, _} ->
            case binary:split(Content, <<"---">>, [global]) of
                [_, YamlPart, _] ->
                    parse_yaml_frontmatter(YamlPart);
                _ -> #{}
            end;
        _ -> #{}
    end;
parse_frontmatter(_) -> #{}.

parse_yaml_frontmatter(YamlBin) ->
    Lines = binary:split(YamlBin, <<"\n">>, [global]),
    lists:foldl(fun(Line, Acc) ->
        case binary:split(Line, <<":">>) of
            [Key, Value] ->
                KeyStr = binary:strip(Key),
                ValStr = case binary:strip(Value) of
                    <<"\"", Rest/binary>> -> binary:strip(Rest, trailing, $");
                    <<"''", Rest/binary>> -> binary:strip(Rest, trailing, $');
                    Other -> Other
                end,
                case KeyStr of
                    <<"requires">> -> Acc#{requires => parse_yaml_value(ValStr)};
                    <<"always">> -> Acc#{always => parse_bool(ValStr)};
                    <<"description">> -> Acc#{description => ValStr};
                    <<"metadata">> -> Acc#{metadata => ValStr};
                    <<"context">> -> Acc#{context => parse_atom(ValStr)};
                    <<"model">> -> Acc#{model => ValStr};
                    <<"path_patterns">> -> Acc#{path_patterns => parse_yaml_value(ValStr)};
                    <<"tags">> -> Acc#{tags => parse_yaml_value(ValStr)};
                    <<"on_activate">> -> Acc#{hooks => maps:put(on_activate, ValStr, maps:get(hooks, Acc, #{}))};
                    <<"on_deactivate">> -> Acc#{hooks => maps:put(on_deactivate, ValStr, maps:get(hooks, Acc, #{}))};
                    <<"max_tokens">> -> Acc#{max_tokens => parse_int(ValStr)};
                    _ -> Acc
                end;
            _ -> Acc
        end
    end, #{}, Lines).

parse_yaml_value(Val) when is_binary(Val) ->
    case binary:first(Val) of
        $[ -> parse_yaml_list(Val);
        _ -> Val
    end.

parse_yaml_list(Val) ->
    Inner = binary:replace(Val, <<"[">>, <<"">>, [global]),
    Inner2 = binary:replace(Inner, <<"]">>, <<"">>, [global]),
    Items = binary:split(Inner2, <<",">>, [global]),
    [binary:strip(Item) || Item <- Items, byte_size(binary:strip(Item)) > 0].

parse_bool(Val) ->
    case binary:strip(Val) of
        <<"true">> -> true;
        <<"false">> -> false;
        <<"yes">> -> true;
        <<"no">> -> false;
        _ -> Val
    end.

parse_atom(Val) ->
    case binary:strip(Val) of
        <<"inline">> -> inline;
        <<"fork">> -> fork;
        <<"background">> -> background;
        Other -> Other
    end.

parse_int(Val) ->
    case catch binary_to_integer(binary:strip(Val)) of
        Int when is_integer(Int) -> Int;
        _ -> 0
    end.

escape_xml(Bin) when is_binary(Bin) ->
    Bin1 = binary:replace(Bin, <<"&">>, <<"&amp;">>, [global]),
    Bin2 = binary:replace(Bin1, <<"<">>, <<"&lt;">>, [global]),
    binary:replace(Bin2, <<">">>, <<"&gt;">>, [global]).

ensure_string(B) when is_binary(B) -> binary_to_list(B);
ensure_string(L) when is_list(L) -> L.

