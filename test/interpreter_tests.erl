-module(interpreter_tests).

-import(interpreter, [compile/2]).

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
    Module = test,
    
    meck:new(Module, [non_strict]),

    meck:expect(Module, eval, fun eval/4),

    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(read_file())),

    ?debugVal(Tree, _Depth = 1000),

    Program = compile(Module, _Code = read_file()),

    Program(_Graph = digraph:new()).


filename() ->
    Dir = code:priv_dir(_Name = interpreter),

    [Filename|_] = filelib:wildcard("*.lua", Dir),

    filename:join(Dir, Filename).

read_file() ->    
    {ok, Code} = erl_prim_loader:read_file(_Filename = filename()),

    Res = binary_to_list(Code),
    Res.

eval(Command, Line, Meta, Graph) ->
    ?debugVal(Command),
    ?debugVal(Line),
    ?debugVal(Meta),
    ?debugVal(Graph),

    _Res = Command(Graph).