-module(interpreter).

%% Lua 5.2 interpreter to embed in ERTS 
-callback eval(command(), line(), meta(), graph()) -> lua().

-export([compile/2]).

-type command() :: function().

-type table() :: function().

-type lua() :: 'nil' | boolean() | function() | binary() | number() | table().

-type graph() :: term().

-type code() :: string().
-type line() :: non_neg_integer().

-type meta() :: [term()].

-type program() :: fun((graph()) -> lua()).

%% Interpreter API

%% TODO Lang specification: https://www.lua.org/manual/5.1/manual.html
%% 
%% TODO API to show VM internals (Erlang version, processes, etc.)
%% TODO API to configure ERTS (application:set_env/3, application:get_env/2)
%% TODO API to expose table (lazy evaluated functional object)
%% TODO module:interrupt(Class, Reason, Stacktrace) via erlang:raise/3, try .. catch
%% TODO module:ipars/1, module:pairs/1, module:next/1
%% 
%% TODO Control structures - https://www.lua.org/pil/4.3.html 
%% 
%% TODO Graph is made via init API which creates _G table 
%% 
%% TODO Break, Label and Goto can be implemented with the help of Tree enclosure
%% TODO local variables can be implemented as Labels on a Graph
%% TODO Fix Grammar rule (reduce conflicts)
-spec compile(module(), code()) -> program().
compile(Module, Code) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),

    _Program = chunk(Module, Tree).

assert(If, Graph) ->
    Bool = If(Graph),

    if ((Bool == false) orelse (Bool == 'nil')) ->
        false;
    true ->
        true
    end.

assert(If, IfBody, Graph) ->
    Bool = assert(If, Graph),

    if Bool ->
        IfBody(Graph);
    true ->
        false
    end.

assert(If, IfBody, Else, Graph) ->
    Bool = assert(If, Graph),

    if Bool ->
        IfBody(Graph);
    true ->
        assert(Else, Graph)
    end.

assert(If, IfBody, Else, ElseBody, Graph) ->
    Bool = assert(If, IfBody, Graph),

    if Bool ->
        true;
    true ->
        assert(Else, ElseBody, Graph)
    end.

repeat(Condition, Body, Graph) ->
    Bool = assert(Condition, Body, Graph),

    if Bool ->
        repeat(Condition, Body, Graph);
    true ->
        false 
    end.

assign(_Op1, _Op2, _Graph) ->
    %% TODO Implement assign in order to make test passed
    %% TODO Implement list
    ok.

%% TODO Inspect supported operators list
binop(Op, L, R, _Graph) ->
    erlang:Op(L, R).

%% TODO Inspect supported operators list
unop(Op, R, _Graph) ->
    erlang:Op(R).

chunk(Module, Tree) ->
    %% TODO System wide commands to embed into the program (non-local API)
    fun (Graph) -> 
        (_Program = block(Module, Tree))(Graph)
    end.

 %% TODO Handle ;
block(Module, Tree) ->
    fun (Graph) -> 
        (_Program = stats(Module, Tree))(Graph) 
    end.

stats(_Module, []) ->
    fun (Graph) -> 
        (_Command = fun (_) -> 'nil' end)(Graph)
    end;

stats(Module, [Node]) ->
    fun (Graph) -> 
        (_Command = retstat(Module, Node))(Graph)
    end;

stats(Module, [Node|Tree]) ->
    fun (Graph) -> 
        (_Command = stat(Module, Node))(Graph),
        (_Program = stats(Module, Tree))(Graph) 
    end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Command = fun (Graph) -> 
        Vars = (explist(Module, Node1))(Graph),
        Vals = (explist(Module, Node2))(Graph),

        io:format(user, "~p = ~p", [Vars, Vals]) end,

    eval(Module, Command, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2}) ->
    Command = fun (Graph) -> 
        io:format(user, "elseif Node1: ~p~n", [Node1]),
        io:format(user, "elseif Node2: ~p~n", [Node2]),

        If = exp(Module, Node1),

        assert(If, _IfBody = block(Module, Node2), Graph) end,

    eval(Module, Command, ['elseif'], Line);

%% TODO Rewrite onto single line assert
stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Command = fun (Graph) -> 
        io:format(user, "elseif Node1: ~p~n", [Node1]),
        io:format(user, "elseif Node2: ~p~n", [Node2]),
        io:format(user, "elseif Node3: ~p~n", [Node3]),

        If = exp(Module, Node1),
        IfBody = block(Module, Node2),

        assert(If, IfBody, _Else = stat(Module, Node3), Graph) end,

    eval(Module, Command, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3}) ->
    Command = fun (Graph) -> 
        io:format(user, "if Node1: ~p~n", [Node1]),
        io:format(user, "if Node2: ~p~n", [Node2]),
        io:format(user, "if Node3: ~p~n", [Node3]),

        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
                             
        assert(If, IfBody, _ElseBody = block(Module, Node3), Graph) end,

    eval(Module, Command, ['if'], Line);

%% TODO Rewrite onto single line assert
stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Command = fun (Graph) -> 
        io:format(user, "if Node1: ~p~n", [Node1]),
        io:format(user, "if Node2: ~p~n", [Node2]),
        io:format(user, "if Node3: ~p~n", [Node3]),
        io:format(user, "if Node4: ~p~n", [Node4]),

        If = exp(Module, Node1),
        IfBody = block(Module, Node2),

        Else = stat(Module, Node3),
                             
        assert(If, IfBody, Else, _ElseBody = stat(Module, Node4), Graph) end,

    eval(Module, Command, ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Command = fun (Graph) -> 
        io:format(user, "else Node1: ~p~n", [Node1]),

        (_Body = block(Module, Node1))(Graph) end,

    eval(Module, Command, ['else'], Line);

%% TODO Rewrite onto single line assert
stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Command = fun (Graph) -> 

        Condition = exp(Module, Node1),
        
        repeat(Condition, _Body = block(Module, Node2), Graph) end,
                             
    eval(Module, Command, ['while', 'do', 'end'], Line).

retstat(Module, {return, Line, Node1}) ->
    Command = fun (Graph) -> 
        (explist(Module, Node1))(Graph) end,
    
    eval(Module, Command, ['return'], Line);

retstat(Module, Node1) ->
    stat(Module, Node1).

explist(Module, [Node]) ->
    fun (Graph) -> 
        Val = (_Command = exp(Module, Node))(Graph),

        Res = [Val],
        Res 
    end;

explist(Module, [Node|Tree]) ->
    fun (Graph) -> 
        Val = (_Command = exp(Module, Node))(Graph), 
    
        Res = [Val|(_Program = explist(Module, Tree))(Graph)],
        Res 
    end.

exp(Module, {_Tag = op, Line, Op, Node1, Node2}) ->
    Command = fun (Graph) -> 
        Op1 = (exp(Module, Node1))(Graph),
        Op2 = (exp(Module, Node2))(Graph),
                             
        binop(Op, Op1, Op2, Graph) end,

    eval(Module, Command, [Op], Line);

exp(Module, {_Tag ='NAME', Line, Name}) ->
    %% TODO Format encode and normalization
    %% TODO Extract the NAME from Graph
    Command = fun (_Graph) -> 
        io:format(user, "var: ~p", [Name]), 
        %% TODO Debug
        Res = 1,
        Res end,

    eval(Module, Command, ['var', Name], Line);

exp(_Module, {_Tag = 'LITERALSTRING', _Line, Lit}) ->
    %% TODO Format encode and normalization
    fun (_Graph) -> 
        Lit 
    end;

exp(_Module, {_Tag = 'NUMERAL', _Line, Lit}) ->
    %% TODO Format encode and normalization
    fun (_Graph) -> 
        Lit 
    end;

exp(_Module, {_Tag = nil, _Line}) ->
    fun (_Graph) -> 
        'nil' 
    end;

%% TODO Fix Lit expression (check the clause for Boolean)
exp(_Module, Lit) ->
    fun (_Graph) -> 
        io:format(user, "Lit is ~p~n", [Lit]),
    
        Res = Lit,
        Res 
    end.

%% API
eval(Module, Command, Meta, Line) ->
    fun (Graph) -> 
        Module:eval(Command, Line, Meta, Graph) 
    end.