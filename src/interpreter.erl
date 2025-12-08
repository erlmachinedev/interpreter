-module(interpreter).

%% Lua 5.2 interpreter embedded in ERTS
 
%% Embed API
-callback eval(runtime(), line(), command()) -> any().

-callback eval(runtime(), line(), integer(), name(), lua()) -> any().
-callback eval(runtime(), line(), integer(), name()) -> lua().

-optional_callbacks([eval/3]).

%% TODO Return from eval can be inspected on max size (table, string, etc.)
%% TODO Unlimited variables store based on AWS backend
%% TODO GC implemented on a host level (release previous cells, nil variables, etc.)
%% TODO Rate can be applied on eval/3 API (variable resolution is immediate)

-export([compile/2, compile/3]).

-type program() :: fun(([lua()]) -> lua()).

-type command() :: fun(() -> lua()).

-type runtime() :: term().

-type code() :: string().

-type name() :: [key()].

-type key() :: boolean() | function() | binary() | number() | map().

-type lua() :: key() | nil().

-type line() :: non_neg_integer().

-type iterator() :: function().

%% Interpreter API

%% TODO Lang specification: https://www.lua.org/manual/5.1/manual.html
%% 
%% TODO Library API to show VM internals (Erlang version, processes, etc.)
%% TODO Library API to configure ERTS (application:set_env/3, application:get_env/2)
%% 
%% TODO interrupt(Class, Reason, Stacktrace) via erlang:raise/3, try .. catch
%% TODO Lua Base Library API ipars/1, pairs/1, next/1, pcall/1
%% 
%% TODO Control structures - https://www.lua.org/pil/4.3.html 
%% 
%% TODO Break, Label and Goto can be implemented via Tree enclosure
%% TODO Fix Grammar rule (reduce conflicts)
%% 
%% TODO Implement lexical scoping - https://www.lua.org/pil/4.2.html
%% TODO Implement lexical scoping on chunk, control structures and function (have block), block
%% 
%% TODO Scopes are resolved at compile time (e.g., transformed into cells)
%% TODO Variables are resolved at compile time (transformed into host API calls)
%% TODO Function call and scope entrance does increment the next cell

%% API

ipars(_) ->
    ok.

pairs(_) ->
    ok.

pcall(_) ->
    ok.

-spec next(iterator()) -> {key(), lua(), iterator()} | none.
next(_I) ->
    none.

-spec compile(module(), code()) -> program().
compile(Module, Code) ->
    compile(Module, Code, fun (Pid, Cell, Name, Lua) -> Pid end).

-spec compile(module(), code(), fun((pid()) -> runtime())) -> program().
compile(Module, Code, Fun) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),
    Exec = chunk(Module, Tree),

    fun () ->
        %% TODO Side effects are produced independetly

        Exec(_Runtime = Fun(self()))
    end.

assert(If, Frame) ->
    Bool = If(Frame),

    if ((Bool == false) orelse (Bool == 'nil')) ->
        false;
    true ->
        true
    end.

assert(If, IfBody, Frame) ->
    Bool = assert(If, Frame),

    if Bool ->
        IfBody(Frame);
    true ->
        false
    end.

assert(If, IfBody, ElseBody, Frame) ->
    Bool = assert(If, Frame),

    if Bool ->
        IfBody(Frame);
    true ->
        ElseBody(Frame)
    end.

assert(If, IfBody, Else, ElseBody, Frame) ->
    Bool = assert(If, IfBody, Frame),

    if Bool ->
        true;
    true ->
        assert(Else, ElseBody, Frame)
    end.

repeat(Condition, Body, Frame) ->
    Bool = assert(Condition, Body, Frame),

    if Bool ->
        repeat(Condition, Body, Frame);
    true ->
        false 
    end.


assign([Var], [Val]) ->
    Var(Val);

assign([Var], []) ->
    Var('nil');

assign([Var|T], Acc = []) ->
    Var('nil'),

    assign(T, Acc);

assign([Var|T], [Val|Acc]) ->
    Var(Val),

    assign(T, Acc).

%% TODO Var acces in a frame is defined on compilation level (local, function args (), global)
assign(_Op1, _Op2, _Frame) ->
    %% TODO Implement assign in order to make test passed
    ok.

%% TODO Inspect supported operators list
binop('~=', L, R, _Frame) ->
    erlang:'/='(L, R);

binop(Op, L, R, _Frame) ->
    erlang:Op(L, R).

%% TODO Inspect supported operators list
unop(Op, R, _Frame) ->
    erlang:Op(R).

function(_Name, _Args, _Body, _Frame) ->
    %% TODO Inline arguments in a frame
    ok.

chunk(Module, Tree) ->
    _Local = [],

    fun (Frame) ->
        %% TODO Variable names are uniquely resolved at compile time (e.g., associated with slots)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Frame = (block(Module, Tree))(Frame) 
    end.

 %% TODO Handle ;
block(Module, Tree) ->
    Code = stats(Module, Tree),

    fun (Frame) -> 
        %% TODO Side effects are evaluated 
        %% TODO Dedicated call with side effects 
        %% TODO Side effects applied during the state transition
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Frame = Code(Frame),
        Eval = compute(Module, Tree) 
    end.

stats(_Module, []) ->
    fun () -> 
        _Res = 'nil' 
    end;

stats(Module, [Node]) ->
    retstat(Module, Node);

stats(Module, [Node|Tree]) ->
    Code = stats(Module, Tree),

    Exec = stat(Module, Node),
    fun (Frame0) ->
        %% TODO Function declaration, Var and Var assignment
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        %% TODO Elaborate enclosure overhead (GC) 
        Frame1 = Exec(Frame0),

        %% TODO Compute Frame based on variables
        Code(Frame1) 
    end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Body = fun (Frame) ->
        Vars = (explist(Module, Node1))(),
        Vals = (explist(Module, Node2))(),

        assign(Vars, Vals) end,

    command(Module, Body, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2}) ->
    Body = fun (Frame) ->
        If = exp(Module, Node1),
        assert(If, _IfBody = block(Module, Node2)) end,

    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Body = fun (Frame) ->
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _Else = stat(Module, Node3)) end,

    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3}) ->
    Body = fun (Frame) -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _ElseBody = block(Module, Node3)) end,

    command(Module, Body, ['if'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Body = fun (Frame) -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        Else = stat(Module, Node3),
        assert(If, IfBody, Else, _ElseBody = stat(Module, Node4)) end,

    eval(Module, _Command = command(Body), ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Body = fun (Frame) -> 
        (block(Module, Node1))() end,

    command(Module, Body, ['else'], Line);

stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Body = fun (Frame) -> 
        Condition = exp(Module, Node1),
        repeat(Condition, _Body = block(Module, Node2), Frame) end,

    command(Module, Body, ['while', 'do', 'end'], Line).

retstat(Module, {return, Line, Node}) ->
    Body = fun (Frame) -> 
        (explist(Module, Node))() end,

    command(Module, Body, ['return'], Line);

retstat(Module, Node) ->
    stat(Module, Node).

explist(Module, [Node]) ->
    Exec = exp(Module, Node),

    fun (Frame) -> 
        [Exec(Frame)]
    end;

explist(Module, [Node|Tree]) ->
    Exec = exp(Module, Node),
    Code = explist(Module, Tree),

    fun (Frame0) -> 
        Frame1 = Exec(Frame0),
        
        Code(Frame1)
    end.

exp(Module, {_Tag = op, Line, Op, Node1, Node2}) ->
    Op1 = (exp(Module, Node1))(),
    Op2 = (exp(Module, Node2))(),

    Body = fun (Frame) -> 
        binop(Op, Op1, Op2, Frame) end,

    command(Module, Body, [Op], Line);

exp(Module, {_Tag ='NAME', Line, Name}) ->
    Body = fun () -> 
        io:format(user, "var: ~p ~p", [Name, _Scope = []]), 
        %% TODO Debug
        _Res = 1 end,

    command(Module, Body, ['var', Name], Line);

exp(_Module, {_Tag = 'LITERALSTRING', _Line, Lit}) ->
    %% TODO Format encode and normalization
    fun () -> 
        Lit 
    end;

exp(_Module, {_Tag = 'NUMERAL', _Line, Lit}) ->
    %% TODO Format encode and normalization
    fun () -> 
        Lit 
    end;

exp(_Module, {_Tag = nil, _Line}) ->
    fun () -> 
        'nil' 
    end;

%% TODO Fix Lit expression (check the clause for Boolean)
exp(_Module, Lit) ->
    fun () -> 
        io:format(user, "Lit is ~p~n", [Lit]),
        Lit
    end.

%% Debug API
eval(Module, Command, Meta, Line) ->
    %% TODO Frame is pre-computed (function args are pre-processed)
    %% TODO Frame is contained as enclosure
    fun (Runtime) ->
        Module:eval(Runtime, Command, Line, Meta)
    end.

eval(Module, Command) ->
    fun (Runtime) ->
        Module:eval(Runtime, Command)
    end.

%% Embed API
exec(Module, Command) ->
    fun (Runtime) ->
        Module:exec(Runtime, Command)
    end.