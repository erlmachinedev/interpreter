-module(interpreter_tests).

-import(interpreter, [compile/2, compile/3]).

-export([]).

-include_lib("eunit/include/eunit.hrl").

%% TODO Hide warnings from the build
%% 
%% TODO debugTime(Text,Expr)
%% TODO debugVal(Expr, Depth)
%% TODO assertException(ClassPattern, TermPattern, Expr)
%% TODO assertMatch(GuardedPattern, Expr)
%% TODO assertEqual(Expect, Expr)
%% 
%% TODO Empty code test
interpreter_test() ->
    %% TODO Mock exec API (predfined variables)
    Module = test,
    
    meck:new(Module, [non_strict]),

    meck:expect(Module, eval, fun eval/4),
    meck:expect(Module, eval, fun eval/2),

    meck:expect(Module, exec, fun exec/4),
    meck:expect(Module, exec, fun exec/3),

    ?assertError({error, _}, process(<<"1a = 1 -- error line (scan)">>)),
    ?assertError({error, _}, process(<<"1 = a1 -- error line (parse)">>)),

    %% TODO Introduce data type construction helpers (test API)
    %% TODO Introduce host functions (code.lua)
    %% TODO Introduce arguments compaction (list) and substitution (nil)
    %% TODO Test the presence of Arg

    Env = #{ <<"io">> => #{ <<"print">> => fun print/1 } },

    install(Env, _Arg = [_Mode = <<"test">>, false]),

    Code = read_file(),

    ?debugVal(process(Code), _Depth = 1000),

    Program0 = compile(Module, <<"1/0 -- error line (runtime)">>),

    Program1 = compile(Module, Code, fun (Pid) -> Pid end),
    Program2 = compile(Module, Code),

    ?assertEqual(Program1, Program2),

    %% TODO Developer can introduce custom exception handling
    %% 
    ?assertError({error, _}, Program0),

    ?assertEqual('nil', Program1()).

install(Env, Arg) ->
    Map0 = maps:new(),
    Map1 = maps:put(<<"arg">>, Arg, Env),

    Map2 = maps:put(<<"_G">>, Map1, Map0),
    %% TODO Default function and variables (Libraries API)
    %% TODO Default should be declared on the host side (exec/4, exec/3)
    %% TODO Elaborate behaviour (Library setup)
    put(_Global = 0, Map2).

filename() ->
    Dir = code:priv_dir(_Name = interpreter),

    [Filename|_] = filelib:wildcard("*.lua", Dir),

    filename:join(Dir, Filename).

read_file() ->    
    {ok, Code} = erl_prim_loader:read_file(_Filename = filename()),

    Res = binary_to_list(Code),
    Res.

process(File) ->
    Scan = interpreter_scan:process(File),

    Tree = interpreter_parse:process(Scan),
    Tree.

%% Debug API
eval(_Runtime, Command, Line, Meta) ->
    ?debugVal(Command),
    
    ?debugVal(Line),
    ?debugVal(Meta),

    _Lua = Command().

eval(_Runtime, Command) ->
    %% TODO Assert Command result
    ?debugVal(Command),

    Command().

%% Embed API
exec(_Runtime, Integer, Name, Lua) ->    
    ?debugVal(Scope),
    
    ?debugVal(Name), 
    ?debugVal(Lua),

    get(Scope).

exec(_Runtime, Integer, Name) ->
    ?debugVal(Scope),
    ?debugVal(Name),

    get(Scope).

%% TODO Iterator (maps) creation and acess