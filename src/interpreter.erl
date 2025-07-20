-module(interpreter).

%% Lua 5.2 interpreter to embed in ERTS 

%% Debug API
-callback eval(command(), line(), meta(), frame()) -> lua().
%% TODO API (maps compatible) to resolve reference (map/3, fold/4, filter/3, next/2) 

%% TODO Interpreter crates dedicated frames (scopes) via eval/2
%% TODO Consider recursive map creation API (maps compatible)

-export([is_key/2, get/2, put/3, iterator/1, next/1]).

-export([new/0, new/1, delete/1, info/1]).

-export([compile/3]).

-type program() :: fun(([lua()]) -> lua()).

-type graph() :: digraph:graph().

-type frame() :: map().

-type command() :: function().

-type key() :: binary().
%% TODO reference() does make lua datatype resursive
-type lua() :: 'nil' | boolean() | function() | binary() | number() | reference().

-type code() :: string().
-type line() :: non_neg_integer().

-type meta() :: [term()].

-type iterator() :: function().

%% Interpreter API

%% TODO Lang specification: https://www.lua.org/manual/5.1/manual.html
%% 
%% TODO API to show VM internals (Erlang version, processes, etc.)
%% TODO API to configure ERTS (application:set_env/3, application:get_env/2)
%% 
%% TODO API (maps compatible) to expose table (lazy evaluated functional object)
%% TODO API (maps compatible) to expose table (map/3, fold/4, filter/3, next/2) 
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
%% TODO Variable names are uniquely resolved at compile time (e.g., transformed into unique IDs or slots)

%% API
-spec is_key(key(), reference()) -> boolean().
is_key(_Key, _Ref) ->
    true.

-spec get(key(), reference()) -> lua().
get(_Key, _Ref) ->
    ok.

-spec put(key(), lua(), reference()) -> reference().
put(_Key, _Val, _Ref) ->
    ok.

%% TODO iterator API creates a Fun with enclosure
-spec iterator(reference()) -> iterator().
iterator(Ref) ->
    fun () -> 
        Ref
    end.

-spec next(iterator()) -> {key(), lua(), iterator()} | none.
next(_I) ->
    none.

-spec new(protected | private) -> graph().
new(Type) when Type == protected;
               Type == private ->
    %% TODO Setup environment ("G", etc.) 
    Res = digraph:new(Type),
    Res.

-spec new() -> graph().
new() ->
    new(_Type = protected).

-spec delete(graph()) -> term().
delete(Graph) ->
    digraph:delete(Graph).

-spec info(graph()) -> [{memory, non_neg_integer()}].
info(Graph) ->
    digraph:info(Graph).

-spec compile(module(), code(), graph()) -> program().
compile(Module, Code, _Graph) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),
    fun (Args) ->
        _Global = setup(Module, Args), 
        chunk(Module, Tree)
    end.

setup(Global, _Args) ->
    Global.

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

%% TODO Var acces is defined on compilation level (local, function args, global)
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
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        %% TODO Declared vars are merged inside block
        %% TODO Changed vars are preserved outside block
        %% TODO Variable names are uniquely resolved at compile time (e.g., transformed into unique IDs or slots)
        Frame = (block(Module, Tree))(Frame)
        %% TODO Variable names are merged (in consecutive calls) or released on return
        %% TODO Inplement frame GC (released variables)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
    end.

 %% TODO Handle ;
block(Module, Tree) ->
    _Scope = [],
    fun (Frame) -> 
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Frame = (stats(Module, Tree))(Frame)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
    end.

stats(_Module, []) ->
    fun () -> 
        _Res = 'nil'
    end;

stats(Module, [Node]) ->
    retstat(Module, Node);

stats(Module, [Node|Tree]) ->
    %% TODO Scope is computed in GC
    %% TODO Global is implemented via behaviour
    %% TODO Variable is made dynamically (created inside frame)
    %% TODO Scope can be implemented as sliding frame (map) 
    Execute = stats(Module, Tree),
    Command = stat(Module, Node),
    fun (Frame) ->
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Command(Frame), Execute(Frame)
    end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Command = fun () ->
        Vars = (explist(Module, Node1))(),
        Vals = (explist(Module, Node2))(),
        io:format(user, "~p = ~p", [Vars, Vals]) end,
    eval(Module, Command, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2}) ->
    Command = fun () ->
        If = exp(Module, Node1),
        assert(If, _IfBody = block(Module, Node2)) end,
    eval(Module, Command, ['elseif'], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Command = fun () ->
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _Else = stat(Module, Node3)) end,
    eval(Module, Command, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3}) ->
    Command = fun () -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _ElseBody = block(Module, Node3)) end,
    eval(Module, Command, ['if'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Command = fun () -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        Else = stat(Module, Node3),
        assert(If, IfBody, Else, _ElseBody = stat(Module, Node4)) end,
    eval(Module, Command, ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Command = fun () -> 
        (block(Module, Node1))() end,
    eval(Module, Command, ['else'], Line);

stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Command = fun (Frame) -> 
        Condition = exp(Module, Node1),
        repeat(Condition, _Body = block(Module, Node2), Frame) end,
    eval(Module, Command, ['while', 'do', 'end'], Line).

retstat(Module, {return, Line, Node1}) ->
    Command = fun () -> 
        (explist(Module, Node1))() end,
    eval(Module, Command, ['return'], Line);

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
    Command = fun (Frame) -> 
        Op1 = (exp(Module, Node1))(),
        Op2 = (exp(Module, Node2))(),
        binop(Op, Op1, Op2, Frame) end,
    eval(Module, Command, [Op], Line);

exp(Module, {_Tag ='NAME', Line, Name}) ->
    Command = fun () -> 
        io:format(user, "var: ~p ~p", [Name, _Scope = []]), 
        %% TODO Debug
        _Res = 1 end,
    eval(Module, Command, ['var', Name], Line);

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
    fun (Frame) ->
        Module:eval(Command, Line, Meta, Frame)
    end.