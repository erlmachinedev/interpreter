%% Copyright (c) 2013-2019 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : interpreter_parse.yrl
%% Author  : Robert Virding
%% Purpose : Parser for LUA 5.2.

%% The Grammar rules here are taken directly from the LUA 5.2
%% manual. Unfortunately it is not an LALR(1) grammar but I have
%% included a fix by Florian Weimer <fw@deneb.enyo.de> which makes it
%% so, but it needs some after processing. Actually his fix was
%% unnecessarily complex and all that was needed was to change one
%% rule for statements.

Expect 2.					%Suppress shift/reduce warning

Nonterminals
chunk block stats stat semi retstat label_stat
while_stat repeat_stat if_stat if_elseif if_else for_stat local_decl
funcname dottedname varlist var namelist
explist exp prefixexp args
functioncall
functiondef funcbody parlist
tableconstructor fieldlist fields field fieldsep
binop unop uminus.

Terminals
NAME NUMERAL LITERALSTRING

'and' 'break' 'do' 'else' 'elseif' 'end' 'false' 'for' 'function' 'goto' 'if' 
'in' 'local' 'nil' 'not' 'or' 'repeat' 'return' 'then' 'true' 'until' 'while' 

'+' '-' '*' '/' '//' '%' '^' '&' '|' '~' '>>' '<<' '#'
'==' '~=' '<=' '>=' '<' '>' '='
'(' ')' '{' '}' '[' ']' '::' ';' ':' ',' '.' '..' '...' .


Rootsymbol chunk.

%% uminus needed for '-' as it has duplicate precedences.

Left 100 'or'.
Left 200 'and'.
Left 300 '<' '>' '<=' '>=' '~=' '=='.
Left 400 '|'.
Left 500 '~'.
Left 600 '&'.
Left 700 '<<' '>>'.
Right 800 '..'.
Left 900 '+' '-'.
Left 1000 '*' '/' '//' '%'.
Unary 1100 'not' '#' uminus.
Right 1200 '^'.

chunk -> block : '$1'  .

%% block ::= {stat} [retstat]

block -> stats : '$1' .
block -> stats retstat : '$1' ++ ['$2'] .

retstat -> return semi : icall(line('$1'), column('$1'), retstat, []) .
retstat -> return explist semi :
    icall(line('$1'), column('$1'), retstat, '$2') .

semi -> ';' .					%semi is never returned
semi -> '$empty' .

stats -> '$empty' : [] .
stats -> stats stat : '$1' ++ ['$2'] .

stat -> ';' : '$1' .
stat -> varlist '=' explist :
    icall(line('$2'), column('$2'), assign, ['$1','$3']) .
%% Following functioncall rule removed to stop reduce-reduce conflict.
%% Replaced with a prefixexp which should give the same. We hope!
%%stat -> functioncall : '$1' .
stat -> prefixexp : check_functioncall('$1') .
stat -> label_stat : '$1' .
stat -> 'break' : icall(line('$1'), column('$1'), break, []) .
stat -> 'goto' NAME : icall(line('$1'), column('$1'), goto, ['$2']) .
stat -> 'do' block 'end' : icall(line('$1'), column('$1'), block, ['$2']) .
stat -> while_stat : '$1' .
stat -> repeat_stat : '$1' .
stat -> if_stat : '$1' .
stat -> for_stat : '$1' .
stat -> function funcname funcbody :
    functiondef(line('$1'), column('$1'), '$2', '$3') .
stat -> local local_decl : icall(line('$1'), column('$1'), local, ['$2']) .

label_stat -> '::' NAME '::' : icall(line('$1'), column('$1'), label, ['$2']) .

while_stat -> 'while' exp 'do' block 'end' :
    icall(line('$1'), column('$1'), while, ['$2', '$4']) .

repeat_stat -> 'repeat' block 'until' exp :
    icall(line('$1'), column('$1'), repeat, ['$2', '$4']) .

if_stat -> 'if' exp 'then' block if_elseif if_else 'end' :
    condition('if', line('$1'), column('$1'), '$2', '$4', '$5', '$6') .

if_elseif -> 'elseif' exp 'then' block if_elseif:
    condition('elseif', line('$1'), column('$1'), '$2', '$4', '$5') .
if_elseif -> '$empty' :
    [] .

if_else -> 'else' block :
    icall(line('$1'), column('$1'), 'else', ['$2']) .
if_else -> '$empty' :
    [] .

%% stat ::= for Name '=' exp ',' exp [',' exp] do block end
%% stat ::= for namelist in explist do block end

for_stat -> 'for' NAME '=' explist do block end :
        numeric_for(line('$1'),column('$1'),'$2','$4','$6') .
for_stat -> 'for' namelist 'in' explist 'do' block 'end' :
        generic_for(line('$1'),column('$1'),'$2','$4','$6') .

%% funcname ::= Name {'.' Name} [':' Name]

funcname -> dottedname ':' NAME :
    dot_to_icall(dot_append(line('$2'), column('$2'), '$1',
        icall(line('$2'), column('$2'), method, ['$3']))) .
funcname -> dottedname : '$1' .

local_decl -> function NAME funcbody :
          functiondef(line('$1'),column('$1'),'$2','$3') .
local_decl -> namelist :
    icall(line(hd('$1')), column(hd('$1')), assign, ['$1', erl_syntax:nil()]) .
local_decl -> namelist '=' explist :
    icall(line('$2'), column('$2'), assign, ['$1', '$3']) .

dottedname -> NAME : '$1'.
dottedname -> dottedname '.' NAME :
    dot_to_icall(dot_append(line('$2'), column('$2'), '$1', '$3')) .

varlist -> var : ['$1'] .
varlist -> varlist ',' var : '$1' ++ ['$3'] .

var -> NAME :
    access(line('$1'), column('$1'),
        [erl_syntax:string(element(4, '$1'))]) .
var -> prefixexp '[' exp ']' :
    dot_to_icall(dot_append(line('$2'), column('$2'), '$1',
        icall(line('$2'), column('$2'), key_field, ['$3']))) .
var -> prefixexp '.' NAME :
    dot_to_icall(dot_append(line('$2'), column('$2'), '$1', '$3')) .

namelist -> NAME : ['$1'] .
namelist -> namelist ',' NAME : '$1' ++ ['$3'] .

explist -> exp : ['$1'] .
explist -> explist ',' exp : '$1' ++ ['$3'] .

exp -> 'nil'         : icall(line('$1'), column('$1'), 'nil', []) .
exp -> 'false'       : icall(line('$1'), column('$1'), 'false', []) .
exp -> 'true'        : icall(line('$1'), column('$1'), 'true', []) .
exp -> NUMERAL       :
    icall(line('$1'), column('$1'), numeral, [erl_syntax:abstract(element(4,'$1'))]) .
exp -> LITERALSTRING :
    icall(line('$1'), column('$1'), literalstring, [erl_syntax:string(element(4,'$1'))]) .
exp -> '...'         : icall(line('$1'), column('$1'), vararg, []) .
exp -> functiondef   : '$1' .
exp -> prefixexp     : '$1' .
exp -> tableconstructor : '$1' .
exp -> binop         : '$1' .
exp -> unop          : '$1' .

prefixexp -> var : '$1' .
prefixexp -> functioncall : '$1' .
prefixexp -> '(' exp ')' : icall(line('$1'), column('$1'), single, ['$2']) .

functioncall -> prefixexp args :
    dot_to_icall(dot_append(line('$1'), column('$1'), '$1',
        icall(line('$1'), column('$1'), functioncall, ['$2']))) .
functioncall -> prefixexp ':' NAME args :
    dot_to_icall(dot_append(line('$2'), column('$2'), '$1',
        icall(line('$2'), column('$2'), methodcall, ['$3', '$4']))) .

args -> '(' ')' : [] .
args -> '(' explist ')' : '$2' .
args -> tableconstructor : ['$1'] .		%Syntactic sugar
%% TODO Convert string to binary
args -> LITERALSTRING : ['$1'] .		%Syntactic sugar

functiondef -> 'function' funcbody :
    functiondef(line('$1'), column('$1'), '$2').

funcbody -> '(' ')' block 'end' : {[],'$3'} .
funcbody -> '(' parlist ')' block 'end' : {'$2','$4'} .

parlist -> namelist : '$1' .
parlist -> namelist ',' '...' : '$1' ++ ['$3'] .
parlist -> '...' : ['$1'] .

%% Table constructor {...}: semantic rules (grammar + icall shape) are in place.
%% Runtime: table(Module, []) or table(Module, [FieldList]) must be implemented
%% (e.g. primitive or in exp): evaluate field list (key_field, name_field,
%% exp_field) and build a Lua table value. Implement when adding table
%% semantics.
tableconstructor -> '{' '}' :
    icall(line('$1'), column('$1'), table, [erl_syntax:nil()]) .
tableconstructor -> '{' fieldlist '}' :
    icall(line('$1'), column('$1'), table, ['$2']) .

%% TODO array and map constructors

fieldlist -> fields : '$1' .
fieldlist -> fields fieldsep : '$1' .

fields -> field : ['$1'] .
fields -> fields fieldsep field : '$1' ++ ['$3'] .

field -> '[' exp ']' '=' exp :
    icall(line('$1'), column('$1'), key_field, ['$2', '$5']) .
field -> NAME '=' exp :
    icall(line('$1'), column('$1'), name_field, ['$1', '$3']) .
%% TODO array elements
field -> exp :
    icall(line('$1'), column('$1'), exp_field, ['$1']) .

fieldsep -> ',' .
fieldsep -> ';' .

%% exp ::= exp binop exp
%% exp ::= unop exp
%% We have to write them these way for the priorities to work.

binop -> exp '+'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '-'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '*'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '/'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '//' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '%'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '^'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '&'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '|'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '~'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '>>' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '<<' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '==' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '~=' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '<=' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '>=' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '<'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '>'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp '..' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp 'and' exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).
binop -> exp 'or'  exp :
    icall(line('$2'), column('$2'), op, [erl_syntax:atom(cat('$2')), '$1', '$3']).

unop -> 'not' exp :
    icall(line('$1'), column('$1'), op, [erl_syntax:atom(cat('$1')), '$2']) .
unop -> '#'   exp :
    icall(line('$1'), column('$1'), op, [erl_syntax:atom(cat('$1')), '$2']) .
unop -> '~'   exp :
    icall(line('$1'), column('$1'), op, [erl_syntax:atom(cat('$1')), '$2']) .
unop -> uminus : '$1' .

uminus -> '-' exp :
    icall(line('$1'), column('$1'), op, [erl_syntax:atom('-'), '$2']) .

Erlang code.

-include_lib("eunit/include/eunit.hrl").
-include_lib("syntax_tools/include/erl_syntax.hrl").

%% Grammar (above) and AST construction (below) in one module; compact.
%% This module only: functions follow two-line style (head -> ; body on next).
%% We use only erl_syntax here for AST construction; convenient and uniform.
%% Primitives moved to interpreter.erl; called via LFH (local calls).
%% Cell access (exec/3,4) emitted as Module:exec(...) via access helper.

-export([process/1, process/2, inject/2]).

process_test() ->
    ok.

%% -----------------------------------------------------------------------------
%% Module in the final tree (implementation record)
%% -----------------------------------------------------------------------------
%% Module is required. Parser emits variable('Module'). process/2 uses Merl
%% (inject/2) post-parse to replace it with atom(Module). No process dictionary.
%% Evaluation: erl_eval + LFH (route/2) dispatches local calls to
%% primitives. EFH (guard/2) gates Module:exec/eval (security).
%% -----------------------------------------------------------------------------

%% Returns parsed AST body. Parse errors raise; caller handles.
%% (Ours; R.Virding Luerl has chunk/1 instead.) Use process/2 for run pipeline.
process(Tokens) ->
    case parse(Tokens) of
        {error, {Line, _Mod, Desc}} ->
            error({parse_error, Line, format_error(Desc)});
        {ok, Body} -> Body
    end.

%% Like process/1; injects Module into tree via Merl (variable -> atom).
process(Tokens, Module) ->
    Body = process(Tokens),
    inject(Body, Module).

%% Merl-based: replace variable('Module') with atom(Module). Module required.
inject(Body, Module) when is_list(Body) ->
    T = merl:template(Body),
    merl:tree(merl:subst(T, [{'Module', merl:term(Module)}]));
inject(Tree, Module) ->
    T = merl:template(Tree),
    merl:tree(merl:subst(T, [{'Module', merl:term(Module)}])).

%% Primitives (assert, assign, etc.) and semantic stubs (chunk, block,
%% stats, etc.) moved to interpreter.erl; called via LFH (handler/0).
%% Cell access: access helper emits Module:exec(...) (qualified; EFH gates).
%% Grammar helpers below are parser-internal.

cat(T) ->  %% R.Virding.
    element(1, T).
%% Token format: {Type, Line, Column} or {Type, Line, Column, Value}.
%% Line, Column as separate elements.
line(T) ->  %% R.Virding.
    element(2, T).
column(T) ->  %% Ours (Column); Luerl has line only.
    element(3, T).

%% numeric_for(Line, Column, LoopVar, [Init,Test,Upd], Block). R.Virding.

numeric_for(Line, Column, Var, [Init,Limit], Block) ->
    icall(Line, Column, for, [Var, Init, Limit, Block]);
numeric_for(Line, Column, Var, [Init,Limit,Step], Block) ->
    icall(Line, Column, for, [Var, Init, Limit, Step, Block]);
numeric_for(Line, _Column, _, _, _) ->
    return_error(Line, "illegal for").

%% generic_for(Line, Column, Names, ExpList, Block). R.Virding.

generic_for(Line, Column, Names, Exps, Block) ->
    icall(Line, Column, for, [Names, Exps, Block]).

%% functiondef(Line, Column, Name, {Parameters,Body}). R.Virding.
%% functiondef(Line, Column, {Parameters,Body}).

functiondef(Line, Column, Name, {Pars,Body}) ->
    icall(Line, Column, functiondef, [Name, Pars, Body]).

functiondef(Line, Column, {Pars,Body}) ->
    icall(Line, Column, functiondef, [Pars, Body]).

%% dot_append(Line, Column, DotList, Last) -> DotList. R.Virding.
%%  Append Last to the end of a dotlist. Builds {'.', ...} internally;
%%  grammar rules that expose the chain as output wrap with dot_to_icall/1.
%%  dot_to_icall: ours (dot chain -> icall); R.Virding Luerl has no equivalent.

dot_append(Line, Column, {'.', L, C, H, T}, Last) ->
    {'.', L, C, H, dot_append(Line, Column, T, Last)};
dot_append(Line, Column, H, Last) ->
    {'.', Line, Column, H, Last}.

dot_to_icall({'.', L, C, H, T}) ->
    icall(L, C, '.', [dot_to_icall(H), dot_to_icall(T)]);
dot_to_icall(Other) ->
    Other.

%% check_functioncall(PrefixExp) -> PrefixExp. R.Virding.
%%  Check that the PrefixExp is a proper function call/method.

check_functioncall(Node) ->
    case tag(Node) of  %% tag: was icall_tag.
        functioncall -> Node;
        methodcall   -> Node;
        _ ->
            case Node of
                {'.', L, C, H, T} ->
                    dot_to_icall({'.', L, C, H, check_functioncall(T)});
                _ -> return_error(line(Node), "illegal call")
            end
    end.

%% tag(Node) -> atom() | undefined. Was icall_tag.
%%  Extracts the interpreter function name from an icall erl_syntax node.

tag(Node) ->
    try erl_syntax:atom_value(
            erl_syntax:module_qualifier_argument(
                erl_syntax:application_operator(Node)))
    catch _:_ -> undefined end.

%% condition, icall: ours (icall-based AST); no direct R.Virding equivalent.
condition('if', Line, Column, If, IfBody, _ElseIf = [], ElseBody) ->
    icall(Line, Column, 'if', [If, IfBody, ElseBody]);
condition('if', Line, Column, If, IfBody, ElseIf, ElseBody) ->
    icall(Line, Column, 'if', [If, IfBody, ElseIf, ElseBody]).

condition('elseif', Line, Column, If, IfBody, []) ->
    icall(Line, Column, elseif, [If, IfBody]);
condition('elseif', Line, Column, If, IfBody, ElseIf) ->
    icall(Line, Column, elseif, [If, IfBody, ElseIf]).

%% icall(Line, Column, Fun, Args) -> erl_syntax node for
%%   Fun(Module, Args...).
%% Local call; LFH (interpreter:handler/0) dispatches at eval time.
%% First arg is always variable('Module'); Merl injects atom(Module).

icall(Line, Column, Fun, Args) when is_list(Args) ->
    Node = erl_syntax:application(
        erl_syntax:atom(Fun),
        [erl_syntax:variable('Module') | Args]),
    erl_syntax:set_pos(Node, {Line, Column});
icall(Line, Column, Fun, Arg) ->
    icall(Line, Column, Fun, [Arg]).

%% access(Line, Column, Args) -> erl_syntax node for
%%   Module:exec(Args...).
%% Qualified call to callback module; cell read/write. EFH (guard/2)
%% gates for security; only exec and eval allowed.

access(Line, Column, Args) when is_list(Args) ->
    Node = erl_syntax:application(
        erl_syntax:module_qualifier(
            erl_syntax:variable('Module'),
            erl_syntax:atom(exec)),
        Args),
    erl_syntax:set_pos(Node, {Line, Column}).