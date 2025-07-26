-module(interpreter).

%% Lua 5.2 interpreter embedded in ERTS
 
%% TODO Command(_Frame = frame(Ref))
%% TODO frame(Ref, _Frame = Command())
%% TODO Consider side effect to be created by scoping
%% TODO eval can access higher level frame via reference
-callback eval(command(), reference(), line(), meta()) -> lua().
%% TODO Ensure the right order eval -> return -> exec (side effects) -> eval
-callback exec(command(), reference()) -> lua().
%% TODO Frame commit is to be merged

%% TODO Function call is adopted to return the result enclosure (without side effects)
%% TODO Consider GC API implemented by embedding app

-export([compile/2, compile/3]).

-type chunk() :: fun(([lua()]) -> lua()).

-type command() :: function().

-type key() :: boolean() | function() | binary() | number().

-type lua() :: key() | reference() | nil().

-type code() :: string().
-type line() :: non_neg_integer().

-type meta() :: [term()].

-type iterator() :: function().


%% Interpreter API

%% TODO Lang specification: https://www.lua.org/manual/5.1/manual.html
%% 
%% TODO Stream based processing
%% TODO Library API to show VM internals (Erlang version, processes, etc.)
%% TODO Library API to configure ERTS (application:set_env/3, application:get_env/2)
%% 
%% TODO interrupt(Class, Reason, Stacktrace) via erlang:raise/3, try .. catch
%% TODO Lua API ipars/1, pairs/1, next/1
%% 
%% TODO Control structures - https://www.lua.org/pil/4.3.html 
%% 
%% TODO Global does instantiate _G table 
%% 
%% TODO Break, Label and Goto can be implemented with the help of Tree enclosure
%% TODO Fix Grammar rule (reduce conflicts)
%% 
%% TODO Implement lexical scoping - https://www.lua.org/pil/4.2.html
%% TODO Implement lexical scoping on chunk, control structures and function (have block), block
%% TODO Implement lexical scoping via variable Name resolver on a compilation stage
%% TODO Implement lexical scoping as transient context (Symbol table)
%% 
%% TODO Variable names are resolved at compile time (e.g., transformed into reference())

%% API

-spec iterator(reference()) -> iterator().
iterator(Ref) ->
    fun () -> 
        Ref
    end.

-spec next(iterator()) -> {key(), lua(), iterator()} | none.
next(_I) ->
    none.

-spec compile(module(), code()) -> chunk().
compile(Module, Code) ->
    compile(Module, Code, _Global = global()).

-spec compile(module(), code(), map()) -> chunk().
compile(Module, Code, Global) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),
    fun (Args) -> 
        chunk(Module, Tree, _Frame = setup(Global, Args))
    end.

global() ->
    _Global = maps:new().

setup(Global, Args) ->
    maps:put(_Key = <<"arg">>, Args, Global).

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
    %% TODO make function API as a part of compilation step
    %% TODO Inline arguments in a frame
    ok.

chunk(Module, Tree) ->
    _Local = [],
    fun (Frame) ->
        %% TODO Variable names are uniquely resolved at compile time (e.g., transformed into unique IDs or slots)
        Frame = (block(Module, Tree))(Frame)
        %% TODO Inplement frame GC (released variables)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
    end.

 %% TODO Handle ;
block(Module, Tree) ->
    Code = stats(Module, Tree),
    fun (Frame) -> 
        %% TODO Side effects are evaluated 
        %% TODO Dedicated node with side effects 
        %% TODO Side effects applied during the state transition
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        %% TODO Consider deterministic and repeatable evaluation via Frames (reference by id)
        Frame = Code(Frame),
        Eval = compute(Module, Tree)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
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
    fun (Frame) ->
        %% TODO Function declaration, Var and Var assignment
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Exec(_Frame = Body(Frame)),
        Eval = compute(Module, Node)
    end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Body = fun () ->
        Vars = (explist(Module, Node1))(),
        Vals = (explist(Module, Node2))(),
        io:format(user, "~p = ~p", [Vars, Vals]) end,
    command(Module, Body, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2}) ->
    Body = fun () ->
        If = exp(Module, Node1),
        assert(If, _IfBody = block(Module, Node2)) end,
    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Body = fun () ->
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _Else = stat(Module, Node3)) end,
    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3}) ->
    Body = fun () -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _ElseBody = block(Module, Node3)) end,
    command(Module, Body, ['if'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Body = fun () -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        Else = stat(Module, Node3),
        assert(If, IfBody, Else, _ElseBody = stat(Module, Node4)) end,
    command(Module, Body, ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Body = fun () -> 
        (block(Module, Node1))() end,
    command(Module, Body, ['else'], Line);

stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Body = fun (Frame) -> 
        Condition = exp(Module, Node1),
        repeat(Condition, _Body = block(Module, Node2), Frame) end,
    command(Module, Body, ['while', 'do', 'end'], Line).

retstat(Module, {return, Line, Node1}) ->
    Body = fun () -> 
        (explist(Module, Node1))() end,
    command(Module, Body, ['return'], Line);

retstat(Module, Node1) ->
    stat(Module, Node1).

explist(Module, [Node]) ->
    Command = exp(Module, Node),
    fun (_) -> 
        [Command()]
    end;

explist(Module, [Node|Tree]) ->
    Command = exp(Module, Node),
    Program = explist(Module, Tree),
    fun (_) -> 
        Program(Command())
    end.

exp(Module, {_Tag = op, Line, Op, Node1, Node2}) ->
    Body = fun (Frame) -> 
        Op1 = (exp(Module, Node1))(),
        Op2 = (exp(Module, Node2))(),
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
command(Module, Command, Meta, Line) ->
    %% TODO Frame is pre-computed (function args are pre-processed)
    %% TODO Command is executed without Module
    fun ( ) ->
        Module:exec(Command, Line, Meta, Frame)
    end.

%% Frame API