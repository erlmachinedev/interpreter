-module(interpreter).

%% Lua 5.2 interpreter to embed in ERTS 
-callback eval(command(), line(), meta(), graph()) -> lua().

-export([compile/2]).

-type command() :: function().

-type graph() :: term().

-type lua() :: 'nil' | boolean() | function() | binary() | number() | graph().

-type code() :: string().
-type line() :: non_neg_integer().

-type meta() :: [term()].

-type program() :: fun((graph()) -> lua()).

%% Interpreter API

%% TODO demo API to show VM internals (Erlang version, processes, etc.)
%% TODO Introduce Backend API (application:set_env/3, application:get_env/2)
%% TODO module:interrupt(Class, Reason, Stacktrace) via erlang:raise/3, try .. catch
%% TODO module:ipars/1, module:pairs/1, module:next/1
%% 
%% TODO Control structures - https://www.lua.org/pil/4.3.html 
%% 
%% TODO Graph is made via init API which creates _G table 
%% 
%% TODO Break, Label and Goto can be implemented with the help of Tree argument
%% TODO local variables can be implemented as Labels on a Graph
%% TODO Fix Grammar rule (reduce conflicts)
-spec compile(module(), code()) -> program().
compile(Module, Code) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),

    _Program = chunk(Module, Tree).

assert(Exp, Graph) ->
    Bool = Exp(Graph),

    if ((Bool == false) orelse (Bool == 'nil')) ->
        false;
    true ->
        true
    end.

assert(Exp, Body, Graph) ->
    Bool = assert(Exp, Graph),

    if Bool ->
        Body(Graph);
    true ->
        false
    end.

assert(Value, Exp, Body, Graph) ->
    Bool = assert(Exp, Graph),

    if Bool == Value ->
        true;
    true ->
        Body(Graph)
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

%% TODO Lang specification: https://www.lua.org/manual/5.1/manual.html
%% 
%% TODO eval(Command, Line, Meta) -> Command(Graph)

chunk(Module, Tree) ->
    %% TODO System wide procedures to embed (non-local API)
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
        (_Program = stats(Module, Tree))(Graph) end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Command = fun (Graph) -> 
        Vars = (explist(Module, Node1))(Graph),
        Vals = (explist(Module, Node2))(Graph),

        io:format(user, "= (E1 ~p E2 ~p)", [Vars, Vals]) end,

    eval(Module, Command, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Command = fun (Graph) -> 
        io:format(user, "elseif Node1: ~p~n", [Node1]),
        io:format(user, "elseif Node2: ~p~n", [Node2]),
        io:format(user, "elseif Node3: ~p~n", [Node3]),

        IfBody = block(Module, Node2),

        Bool = assert(_If = exp(Module, Node1), IfBody, Graph),

        if Bool ->
                true;
           true ->
                assert(_Else = stat(Module, Node3), Graph)
        end end,

    eval(Module, Command, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Command = fun (Graph) -> 

        io:format(user, "if Node1: ~p~n", [Node1]),
        io:format(user, "if Node2: ~p~n", [Node2]),
        io:format(user, "if Node3: ~p~n", [Node3]),
        io:format(user, "if Node4: ~p~n", [Node4]),

        IfBody = block(Module, Node2),
                             
        Bool = assert(_If = exp(Module, Node1), IfBody, Graph),

        if Bool ->
                true;
           true ->
                ElseBody = block(Module, Node4),

                assert(false, _Else = stat(Module, Node3), ElseBody, Graph)
        end end,

    eval(Module, Command, ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Command = fun (Graph) -> 
        io:format(user, "else Node1: ~p~n", [Node1]),

        (_Body = block(Module, Node1))(Graph) end,

    eval(Module, Command, ['else'], Line);

stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Command = fun (Graph) -> 

        Body = block(Module, Node2),

        (fun F() -> 
            Res = assert(_Cond = exp(Module, Node1), Graph),
                             
            if Res -> 
                Body(Graph),
                F();
                true -> 
                    'nil' 
            end 
        end)(Graph) end,

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
    io:format(user, "Lit is ~p~n", [Lit]),
    Lit.

%% API
eval(Module, Command, Meta, Line) ->
    fun (Graph) -> 
        Module:eval(Command, Line, Meta, Graph) 
    end.