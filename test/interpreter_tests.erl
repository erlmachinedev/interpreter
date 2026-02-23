-module(interpreter_tests).

-import(interpreter, [compile/2, compute/1]).

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

    meck:expect(Module, exec, fun exec/4),
    meck:expect(Module, exec, fun exec/3),

    meck:expect(Module, eval, fun eval/4),

    Code0 = <<"1a = 1 -- error line (scan)">>,
    Code1 = <<"1 = a1 -- error line (parse)">>,
    
    Code2 = <<"a1 / 0 -- error line (runtime)">>,

    ?assertError({error, _}, process(Code0)),
    ?assertError({error, _}, process(Code1)),

    ?assertError({error, _}, (compile(Module, Code2))(self())),

    %% TODO Introduce data type construction helpers (test API)
    %% TODO Introduce host functions (code.lua)
    %% TODO Introduce arguments compaction (list) and substitution (nil)
    %% TODO Test the presence of Arg

    Code3 = read_file(),

    %% TODO Real computed hash assertion
    ?assertEqual(<<"md5">>, compute(Code3)),

    ?debugVal(process(Code3), _Depth = 1000),

    %% TODO _G or _ENV variable (compatibility)
    %% TODO arg variable 
    %% TODO Default function and variables (Libraries API)
    %% TODO Default should be controlled on the host side (exec/4, exec/3)
    %% TODO Developer can introduce custom exception handling

    %% TODO Return value
    %% TODO Return cells (environment)
    ?assertEqual('nil', (compile(Module, Code3))(self())).

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
eval(Name, Line, Column, Command) ->
    ?debugVal(Name),

    ?debugVal(Line),
    ?debugVal(Column),

    ?debugVal(Command),

    Command(). %% TODO Assert Command result

%% TODO Embed API (completetly encoded)
%% TODO Mock based sequence (meck)
exec(Name, 0 = Cell, ["num"] = Var, 42 = Lua) ->
    ?debugVal(Name),
    ?debugVal(Cell),
    
    ?debugVal(Var),
    ?debugVal(Lua).

exec(Name, 0 = Cell, ["num"] = Var) ->
    ?debugVal(Name),
    ?debugVal(Cell),

    ?debugVal(Var),

    42;

exec(Name, 0 = Cell, ["_ENV", "io", "print"] = Var) ->
    ?debugVal(Name),
    ?debugVal(Cell),

    ?debugVal(Var),

    fun print/1.

%% Host API
print(Lua) ->
    ?debugVal(Lua).

%% TODO Iterator (maps) creation and acess