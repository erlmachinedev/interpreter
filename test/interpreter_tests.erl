-module(interpreter_tests).

-import(interpreter, [compile/2, compute/1]).

-export([]).

-include_lib("eunit/include/eunit.hrl").

%% meck API (exported from meck.erl, v1.1.0). Two lines per function: spec then
%% description. Reference for test development. Lines fit 80 columns.
%% new/1
%%   -spec new(Mods) -> ok when Mods :: Mod | [Mod], Mod :: atom().
%%   Create mock(s); equivalent to new(Mods, []).
%% new/2
%%   -spec new(Mods, Options) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(),
%%            Options :: [proplists:property()].
%%   Create mock(s) with options (non_strict, passthrough, unstick, etc.).
%% unload/0
%%   -spec unload() -> Unloaded when Unloaded :: [Mod], Mod :: atom().
%%   Unload all mocked modules; returns list of unloaded.
%% unload/1
%%   -spec unload(Mods) -> ok when Mods :: Mod | [Mod], Mod :: atom().
%%   Unload mocked module(s); restore original.
%% mocked/0
%%   -spec mocked() -> [atom()].
%%   Return list of currently mocked modules.
%% reset/1
%%   -spec reset(Mods) -> ok when Mods :: Mod | [Mod], Mod :: atom().
%%   Erase call history for mocked module(s).
%% expect/3
%%   -spec expect(Mods, Func, Expectation) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(),
%%            Expectation :: function() | [func_clause_spec()].
%%   Add expectation (fun or clause list).
%% expect/4
%%   -spec expect(Mods, Func, ArgsSpec, RetSpec) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(),
%%            ArgsSpec :: args_spec(), RetSpec :: ret_spec().
%%   Add expectation ArgsSpec -> RetSpec.
%% expects/1
%%   -spec expects(Mods) -> [{Mod, Func, Ari}]
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(), Ari :: byte().
%%   Return list of expectations (MFAs).
%% expects/2
%%   -spec expects(Mods, ExcludePassthrough) -> [{Mod, Func, Ari}]
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(), Ari :: byte(),
%%            ExcludePassthrough :: boolean().
%%   Return list of expectations; ExcludePassthrough excludes passthroughs.
%% delete/3
%%   -spec delete(Mods, Func, Ari) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(), Ari :: byte().
%%   Delete expectation for Func with arity Ari.
%% delete/4
%%   -spec delete(Mods, Func, Ari, Force) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(),
%%            Ari :: byte(), Force :: boolean().
%%   Delete expectation; Force to delete even if passthrough.
%% val/1
%%   -spec val(Value) -> ret_spec() when Value :: any().
%%   ret_spec: single return value.
%% seq/1
%%   -spec seq(Sequence) -> ret_spec() when Sequence :: [ret_spec()].
%%   ret_spec: sequence of return values (exhaust in order).
%% loop/1
%%   -spec loop(Loop) -> ret_spec() when Loop :: [ret_spec()].
%%   ret_spec: loop of return values (cycle).
%% exec/1
%%   -spec exec(fun()) -> ret_spec().
%%   ret_spec: forward calls to given function.
%% passthrough/0
%%   -spec passthrough() -> ret_spec().
%%   ret_spec: call original module function.
%% passthrough/1
%%   -spec passthrough(Args) -> Result when Args :: [any()], Result :: any().
%%   Call original with given args (use only inside expect fun).
%% raise/2
%%   -spec raise(Class, Reason) -> ret_spec()
%%       when Class :: throw | error | exit, Reason :: term().
%%   ret_spec: raise exception (Class, Reason).
%% exception/2
%%   -spec exception(Class, Reason) -> no_return()
%%       when Class :: throw | error | exit, Reason :: any().
%%   Throw exception inside expect fun (does not invalidate mock).
%% history/1
%%   -spec history(Mod) -> history() when Mod :: atom().
%%   Return call history for module (all callers).
%% history/2
%%   -spec history(Mod, OptCallerPid) -> history()
%%       when Mod :: atom(), OptCallerPid :: '_' | pid().
%%   Return call history for module and optional caller pid.
%% called/3
%%   -spec called(Mod, OptFun, OptArgsSpec) -> boolean()
%%       when Mod :: atom(), OptFun :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec().
%%   True if Mod:Fun was called with Args.
%% called/4
%%   -spec called(Mod, OptFun, OptArgsSpec, OptCallerPid) -> boolean()
%%       when Mod :: atom(), OptFun :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec(), OptCallerPid :: '_' | pid().
%%   Same with optional caller pid.
%% num_calls/3
%%   -spec num_calls(Mod, OptFun, OptArgsSpec) -> non_neg_integer()
%%       when Mod :: atom(), OptFun :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec().
%%   Number of times Mod:Fun was called with Args.
%% num_calls/4
%%   -spec num_calls(Mod, OptFun, OptArgsSpec, OptCallerPid) ->
%%       non_neg_integer()
%%       when Mod :: atom(), OptFun :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec(), OptCallerPid :: '_' | pid().
%%   Same with optional caller pid.
%% capture/5
%%   -spec capture(Occur, Mod, Func, OptArgsSpec, ArgNum) -> ArgValue
%%       when Occur :: first | last | pos_integer(), Mod :: atom(),
%%            Func :: atom(), OptArgsSpec :: args_spec(),
%%            ArgNum :: pos_integer(), ArgValue :: any().
%%   Return argument ArgNum at occurrence (first/last/N) for Mod:Fun, ArgsSpec.
%% capture/6
%%   -spec capture(Occur, Mod, Func, OptArgsSpec, ArgNum, OptCallerPid) ->
%%       ArgValue
%%       when Occur :: first | last | pos_integer(), Mod :: atom(),
%%            Func :: atom(), OptArgsSpec :: '_' | args_spec(),
%%            ArgNum :: pos_integer(), OptCallerPid :: '_' | pid(),
%%            ArgValue :: any().
%%   Same with optional caller pid.
%% validate/1
%%   -spec validate(Mods) -> boolean() when Mods :: Mod | [Mod], Mod :: atom().
%%   True if mock was used according to expectations.
%% wait/4
%%   -spec wait(Mod, OptFunc, OptArgsSpec, Timeout) -> ok
%%       when Mod :: atom(), OptFunc :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec(), Timeout :: non_neg_integer().
%%   Block until Mod:Fun called once with ArgsSpec or Timeout.
%% wait/5
%%   -spec wait(Times, Mod, OptFunc, OptArgsSpec, Timeout) -> ok
%%       when Times :: pos_integer(), Mod :: atom(), OptFunc :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec(), Timeout :: non_neg_integer().
%%   Block until called Times or Timeout.
%% wait/6
%%   -spec wait(Times, Mod, OptFunc, OptArgsSpec, OptCallerPid, Timeout) -> ok
%%       when Times :: pos_integer(), Mod :: atom(), OptFunc :: '_' | atom(),
%%            OptArgsSpec :: '_' | args_spec(), OptCallerPid :: '_' | pid(),
%%            Timeout :: non_neg_integer().
%%   Block until Mod:Fun called Times with ArgsSpec by Pid or Timeout.
%% is/1
%%   -spec is(MatcherImpl) -> matcher()
%%       when MatcherImpl :: Predicate | HamcrestMatcher,
%%            Predicate :: fun((any()) -> any()),
%%            HamcrestMatcher :: meck_matcher:hamcrest_matchspec().
%%   Create matcher from predicate fun or Hamcrest matcher.
%% loop/4
%%   -spec loop(Mods, Func, Ari, Loop) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(),
%%            Ari :: byte(), Loop :: [any()].
%%   Deprecated. Use expect/3 or expect/4 with loop/1.
%% sequence/4
%%   -spec sequence(Mods, Func, Ari, Sequence) -> ok
%%       when Mods :: Mod | [Mod], Mod :: atom(), Func :: atom(),
%%            Ari :: byte(), Sequence :: [any()].
%%   Deprecated. Use expect/3 or expect/4 with seq/1.

%% Current status: this test module is a development sketch from an older API
%% contract. Several assertions below document intended behavior rather than
%% matching the current compile/2 + eval/2 surface exactly. Keep it as a map of
%% desired coverage until the smallest compile/eval vertical slice is fixed.
%%
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
    %% TODO Mock exec API (predefined variables). This still follows the older
    %% "compile returns runnable fun" shape; current compile/2 returns
    %% {ok, Forms} | {error, Err}.
    Module = test,
    
    meck:new(Module, [non_strict]),

    meck:expect(Module, exec, fun exec/4),
    meck:expect(Module, exec, fun exec/3),

    meck:expect(Module, eval, fun eval/4),

    Code0 = <<"1a = 1 -- error line (scan)">>,
    Code1 = <<"1 = a1 -- error line (parse)">>,
    
    Code2 = <<"a1 / 0 -- error line (runtime)">>,

    ?assertMatch({error, _}, process(Code0)),
    ?assertMatch({error, _}, process(Code1)),

    ?assertMatch({error, _}, (compile(Module, Code2))(self())),

    %% TODO Introduce data type construction helpers (test API)
    %% TODO Introduce host functions (code.lua)
    %% TODO Introduce arguments compaction (list) and substitution (nil)
    %% TODO Test the presence of Arg

    Code3 = read_file(),

    %% TODO Real computed hash assertion. Current production API is md5/1;
    %% the older test sketch still says compute/1 in code.
    ?assertEqual(<<"md5">>, compute(Code3)),

    ?debugVal(process(Code3), _Depth = 1000),

    %% TODO _G or _ENV variable (compatibility)
    %% TODO arg variable 
    %% TODO Default function and variables (Libraries API)
    %% TODO Default should be controlled on the host side (exec/4, exec/3)
    %% TODO Developer can introduce custom exception handling

    %% TODO Return value
    %% TODO Return cells (environment)
    ?assertEqual({ok, 'nil'}, (compile(Module, Code3))(self())).

filename() ->
    Dir = code:priv_dir(_Name = interpreter),

    [Filename|_] = filelib:wildcard("*.lua", Dir),

    filename:join(Dir, Filename).

read_file() ->    
    {ok, Code} = erl_prim_loader:read_file(_Filename = filename()),

    Res = binary_to_list(Code),
    Res.

%% TODO Current interpreter_parse:process/1 expects tokens, not the full
%% scanner reply. Keep this helper comment here until the test is realigned
%% with interpreter:compile/2 or split into scan and parse tests.
process(File) ->
    Scan = interpreter_scan:process(File),
    interpreter_parse:process(Scan).

%% Debug API
eval(Name, Line, Column, Command) ->
    ?debugVal(Name),

    ?debugVal(Line),
    ?debugVal(Column),

    ?debugVal(Command),

    Command(). %% TODO Assert Command result

%% TODO Embed API (completetly encoded)
%% TODO Mock based sequence (meck)
%% Embed API
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

%% =============================================================================
%% TODO: AST produced code vs Erlang code equivalence tests
%% =============================================================================
%%
%% For each function (assign, op, retstat, block, while, for, etc.):
%%   1. Build the AST form (as produced by interpreter:process/1)
%%   2. Write the equivalent Erlang function directly
%%   3. Assert they produce identical results for the same inputs
%%
%% Example (assign):
%%   - AST version:  compile and call the inlined assign/3 from process/1
%%   - Erlang version: call the exported assign/3 from interpreter.erl
%%   - ?assertEqual(interpreter:assign(Module, Vars, Exps),
%%                  CompiledModule:assign(Module, Vars, Exps))
%%
%% This ensures the inline AST forms are faithful to the reference
%% implementation in interpreter.erl.
%% =================================================================================================================================================
