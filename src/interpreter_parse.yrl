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
%%
%% Lua tree
%% --------
%% Semantic actions build neutral Lua tuples: `{Prim, Line, Column, Args}`.
%% The parser does not embed a host module, Erlang abstract syntax, or
%% evaluation workaround. Later compiler passes decide whether a tuple becomes
%% a closure, a direct runtime primitive call, or a validation error.
%%
%% API: `process/1` — scan tokens -> Lua tree only.
%%
%% Summary — this fork vs Virding’s `luerl_parse` (Luerl, rvirding/luerl)
%% -----------------------------------------------------------------
%% BNF matches the Lua 5.2 manual + Weimer `stat` fix; semantic actions
%% differ (see Luerl `develop` for the reference tuple IR):
%%   • IR: Luerl emits tagged tuples and token passthrough; here grammar
%%     actions emit `{Prim, Line, Column, Args}` with column included.
%%   • Position: we thread `line/1` and `column/1`; dot chains use
%%     `{'.', L, C, H, T}` and `dot_append/4` (Luerl’s `'.'` is line-only).
%%   • Stats: Lua 5.2-style `function` / `local` on `stat`; we omit Luerl’s
%%     `func_stat` / `local_stat` / `attnamelist` (5.3+ attribute locals).
%%   • if: `condition/6` and Lua tuples for `if` / `elseif` / `else`, not
%%     Luerl’s one `{'if', Line, [test/block pairs], else}` tuple.
%%   • var: `NAME` -> `{var, Line, Column, [Name]}`, not raw `$1`.
%%   • check_functioncall / tag: tuple tree and `'.'`; Luerl matches
%%     tuple `{functioncall,…}` / `{'.',…}`.
%%   • Entry: `process/1` here; Luerl `chunk/1` wraps the body (see their
%%     Erlang block).
%%
%% Detailed comparison with Luerl `luerl_parse.yrl`
%% ------------------------------------------------
%% Reference checked against `rvirding/luerl`, branch `develop`, file
%% `src/luerl_parse.yrl`. That parser is the baseline for the grammar and
%% grammar helper names used here, but the tree contract is deliberately
%% different.
%%
%% Entry point:
%%   - Luerl exports `chunk/1` and returns a callable nameless function:
%%       `{functiondef, 1, [{'...', 1}], Body}`.
%%   - This parser exports `process/1` and returns the chunk body directly:
%%       `[Stat, ...]`.
%%     The later interpreter/compiler stage decides whether to wrap the chunk
%%     as a function, closure, or host-specific program object.
%%
%% Position data:
%%   - Luerl tree tuples carry line only.
%%   - Luerl's synthetic chunk wrapper uses line `1` because it creates a
%%     parser-entry function wrapper that has no source token of its own.
%%   - This parser carries `{Line, Column}` in every constructed primitive
%%     tuple: `{Primitive, Line, Column, Args}`.
%%   - This parser does not synthesize wrapper positions. Every emitted
%%     primitive position must come from `line(Token)` / `column(Token)` or
%%     from helper arguments that were themselves derived from a source token.
%%     Do not hardcode or guess line/column values in grammar actions.
%%     Tokens still keep their scanner shape where grammar rules pass tokens
%%     through unchanged.
%%
%% Primitive tuple shape:
%%   - Luerl uses per-primitive tuple arities, for example:
%%       `{assign, Line, Vars, Exps}`
%%       `{while, Line, Cond, Block}`
%%       `{op, Line, Op, Left, Right}`
%%       `{functiondef, Line, Name, Pars, Body}`
%%   - This parser uses one uniform primitive shape:
%%       `{assign, Line, Column, [Vars, Exps]}`
%%       `{while, Line, Column, [Cond, Block]}`
%%       `{op, Line, Column, [Op, Left, Right]}`
%%       `{functiondef, Line, Column, [Name, Pars, Body]}`
%%     The uniform `Args` list makes the following closure-lowering pass
%%     simple: each primitive compiles from one tuple shape.
%%
%% Raw token passthrough:
%%   - Luerl leaves many leaves as scanner tokens: NAME, NUMERAL,
%%     LITERALSTRING, `nil`, `false`, `true`, and `...`.
%%   - This parser constructs explicit tuples for most expression leaves:
%%       `{var, Line, Column, [Name]}`
%%       `{numeral, Line, Column, [Value]}`
%%       `{literalstring, Line, Column, [Value]}`
%%       `{'nil' | 'false' | 'true' | vararg, Line, Column, []}`
%%     NAME tokens are still preserved where the grammar needs declaration
%%     syntax first, for example namelists and function parameter lists.
%%
%% Function and local statements:
%%   - Luerl uses separate nonterminals `func_stat` and `local_stat`.
%%     Its current grammar also includes `attnamelist`, `attname`, and
%%     `attrib`, matching newer Lua local-attribute syntax.
%%   - This parser keeps Lua 5.2-oriented statement rules directly under
%%     `stat`: `function funcname funcbody` and `local local_decl`.
%%     Local attributes are intentionally absent.
%%
%% If/elseif/else:
%%   - Luerl lowers an if-chain to one tuple:
%%       `{'if', Line, [{Cond, Block}, ...], ElseBlock}`.
%%     Elseif branches are accumulated as a list of `{Cond, Block}` pairs.
%%   - This parser keeps branch markers as primitive tuples:
%%       `{'if', Line, Column, [Cond, IfBody, ElseBody]}`
%%       `{'if', Line, Column, [Cond, IfBody, ElseIf, ElseBody]}`
%%       `{elseif, Line, Column, [Cond, Body | Rest]}`
%%       `{'else', Line, Column, [Body]}`
%%     The closure compiler can either keep that shape or normalize it to
%%     Luerl's pair-list shape before lowering.
%%
%% Dot chains and calls:
%%   - Luerl's `dot_append/3` produces `{'.', Line, Head, Tail}` and leaves
%%     that dotted chain as the parser result.
%%   - This parser tracks columns while building the temporary chain:
%%       `{'.', Line, Column, Head, Tail}`
%%     Grammar rules that expose the chain call `dot_to_tree/1`, producing
%%     the uniform primitive tuple:
%%       `{'.', Line, Column, [Head, Tail]}`.
%%   - Both parsers use `check_functioncall/1` to reject invalid statement
%%     prefix expressions after the Florian Weimer reduce-conflict fix.
%%   - Luerl implements that check with explicit success clauses:
%%       `{functioncall, _, _}`
%%       `{methodcall, _, _, _}`
%%       `{'.', Line, Head, Tail}`
%%     followed by `Other -> return_error(line(Other), "illegal call")`.
%%     That final clause is an error path, not a default value. Here we keep
%%     the same intent but avoid a broad `Other` fallback: accepted call
%%     shapes and token error shapes are separate clauses.
%%
%% Loops, tables, fields, and operators:
%%   - Grammar and precedence remain close to Luerl, including the existing
%%     operator set (`//`, bitwise, shifts) even though strict Lua 5.2 does
%%     not include those operators.
%%   - Tree construction differs only by shape:
%%       Luerl: primitive-specific arity, line only.
%%       Here: `{Primitive, Line, Column, Args}`.
%%
%% This file should stay a parser. It must not rebuild the removed Erlang
%% abstract-form path, host-module injection, or evaluation workaround. The
%% next stage owns lexical resolution and closure construction.

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

retstat -> return semi : {return, line('$1'), column('$1'), []} .
retstat -> return explist semi :
    {return, line('$1'), column('$1'), '$2'} .

semi -> ';' .					%semi is never returned
semi -> '$empty' .

stats -> '$empty' : [] .
stats -> stats stat : '$1' ++ ['$2'] .

stat -> ';' : '$1' .
stat -> varlist '=' explist :
    {assign, line('$2'), column('$2'), ['$1', '$3']} .
%% Following functioncall rule removed to stop reduce-reduce conflict.
%% Replaced with a prefixexp which should give the same. We hope!
%%stat -> functioncall : '$1' .
stat -> prefixexp : check_functioncall('$1') .
stat -> label_stat : '$1' .
stat -> 'break' : {break, line('$1'), column('$1'), []} .
stat -> 'goto' NAME : {goto, line('$1'), column('$1'), ['$2']} .
stat -> 'do' block 'end' : {block, line('$1'), column('$1'), ['$2']} .
stat -> while_stat : '$1' .
stat -> repeat_stat : '$1' .
stat -> if_stat : '$1' .
stat -> for_stat : '$1' .
stat -> function funcname funcbody :
    functiondef(line('$1'), column('$1'), '$2', '$3') .
stat -> local local_decl : {local, line('$1'), column('$1'), ['$2']} .

label_stat -> '::' NAME '::' : {label, line('$1'), column('$1'), ['$2']} .

while_stat -> 'while' exp 'do' block 'end' :
    {while, line('$1'), column('$1'), ['$2', '$4']} .

repeat_stat -> 'repeat' block 'until' exp :
    {repeat, line('$1'), column('$1'), ['$2', '$4']} .

if_stat -> 'if' exp 'then' block if_elseif if_else 'end' :
    condition('if', line('$1'), column('$1'), '$2', '$4', '$5', '$6') .

if_elseif -> 'elseif' exp 'then' block if_elseif:
    condition('elseif', line('$1'), column('$1'), '$2', '$4', '$5') .
if_elseif -> '$empty' :
    [] .

if_else -> 'else' block :
    {'else', line('$1'), column('$1'), ['$2']} .
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
    dot_to_tree(dot_append(line('$2'), column('$2'), '$1',
        {method, line('$2'), column('$2'), ['$3']})) .
funcname -> dottedname : '$1' .

local_decl -> function NAME funcbody :
          functiondef(line('$1'),column('$1'),'$2','$3') .
local_decl -> namelist :
    {assign, line(hd('$1')), column(hd('$1')), ['$1', nil]} .
local_decl -> namelist '=' explist :
    {assign, line('$2'), column('$2'), ['$1', '$3']} .

dottedname -> NAME : '$1'.
dottedname -> dottedname '.' NAME :
    dot_to_tree(dot_append(line('$2'), column('$2'), '$1', '$3')) .

varlist -> var : ['$1'] .
varlist -> varlist ',' var : '$1' ++ ['$3'] .

var -> NAME :
    {var, line('$1'), column('$1'), [element(4, '$1')]} .
var -> prefixexp '[' exp ']' :
    dot_to_tree(dot_append(line('$2'), column('$2'), '$1',
        {key_field, line('$2'), column('$2'), ['$3']})) .
var -> prefixexp '.' NAME :
    dot_to_tree(dot_append(line('$2'), column('$2'), '$1', '$3')) .

namelist -> NAME : ['$1'] .
namelist -> namelist ',' NAME : '$1' ++ ['$3'] .

explist -> exp : ['$1'] .
explist -> explist ',' exp : '$1' ++ ['$3'] .

exp -> 'nil'         : {'nil', line('$1'), column('$1'), []} .
exp -> 'false'       : {'false', line('$1'), column('$1'), []} .
exp -> 'true'        : {'true', line('$1'), column('$1'), []} .
exp -> NUMERAL       :
    {numeral, line('$1'), column('$1'), [element(4, '$1')]} .
exp -> LITERALSTRING :
    {literalstring, line('$1'), column('$1'), [element(4, '$1')]} .
exp -> '...'         : {vararg, line('$1'), column('$1'), []} .
exp -> functiondef   : '$1' .
exp -> prefixexp     : '$1' .
exp -> tableconstructor : '$1' .
exp -> binop         : '$1' .
exp -> unop          : '$1' .

prefixexp -> var : '$1' .
prefixexp -> functioncall : '$1' .
prefixexp -> '(' exp ')' : {single, line('$1'), column('$1'), ['$2']} .

functioncall -> prefixexp args :
    dot_to_tree(dot_append(line('$1'), column('$1'), '$1',
        {functioncall, line('$1'), column('$1'), ['$2']})) .
functioncall -> prefixexp ':' NAME args :
    dot_to_tree(dot_append(line('$2'), column('$2'), '$1',
        {methodcall, line('$2'), column('$2'), ['$3', '$4']})) .

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

%% Table constructor {...}: semantic rules and tuple shape are in place.
%% Runtime: `tableconstructor(Module, nil | FieldList)`.
%%   Field tuples use key_field, name_field, exp_field. Implement in exp.
tableconstructor -> '{' '}' :
    {table, line('$1'), column('$1'), [nil]} .
tableconstructor -> '{' fieldlist '}' :
    {table, line('$1'), column('$1'), ['$2']} .

%% TODO array and map constructors

fieldlist -> fields : '$1' .
fieldlist -> fields fieldsep : '$1' .

fields -> field : ['$1'] .
fields -> fields fieldsep field : '$1' ++ ['$3'] .

field -> '[' exp ']' '=' exp :
    {key_field, line('$1'), column('$1'), ['$2', '$5']} .
field -> NAME '=' exp :
    {name_field, line('$1'), column('$1'), ['$1', '$3']} .
%% TODO array elements
field -> exp :
    {exp_field, line('$1'), column('$1'), ['$1']} .

fieldsep -> ',' .
fieldsep -> ';' .

%% exp ::= exp binop exp
%% exp ::= unop exp
%% We have to write them these way for the priorities to work.

binop -> exp '+'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '-'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '*'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '/'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '//' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '%'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '^'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '&'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '|'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '~'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '>>' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '<<' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '==' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '~=' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '<=' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '>=' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '<'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '>'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp '..' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp 'and' exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.
binop -> exp 'or'  exp :
    {op, line('$2'), column('$2'), [cat('$2'), '$1', '$3']}.

unop -> 'not' exp :
    {op, line('$1'), column('$1'), [cat('$1'), '$2']} .
unop -> '#'   exp :
    {op, line('$1'), column('$1'), [cat('$1'), '$2']} .
unop -> '~'   exp :
    {op, line('$1'), column('$1'), [cat('$1'), '$2']} .
unop -> uminus : '$1' .

uminus -> '-' exp :
    {op, line('$1'), column('$1'), ['-', '$2']} .

Erlang code.

-include_lib("eunit/include/eunit.hrl").

%% Grammar (above) and tree construction (below) in one module; compact.
%% This module only: functions follow two-line style (head -> ; body on next).
%% Primitives: interpreter.erl. Grammar actions build neutral Lua tuples.

-export([process/1]).

process_test() ->
    ok.

%% Returns parsed AST body. Parse errors return {error, {Line, Column, Desc}};
%% success {ok, Body}.
%% (Ours; R.Virding Luerl has chunk/1 instead.)
-type parse_reply() ::
    {ok, term()} | {error, {integer(), integer(), string()}}.

-spec process([term()]) -> parse_reply().
process(Tokens) ->
    case parse(Tokens) of
        {ok, Body} -> {ok, Body};
        {error, {{Line, Column}, _Mod, Desc}} ->
            {error, {Line, Column, format_error(Desc)}}
    end.

%% -----------------------------------------------------------------------------
%% Exact terms returned under Descriptor:
%%
%% Origin          | Type     | Example / Format
%% ----------------|----------|-------------------------------------------------
%% Yecc engine     | string   | "syntax error before: 'end'"
%% Rule (For loop) | string   | "illegal for"
%% Rule (Calls)    | string   | "illegal call"
%% -----------------------------------------------------------------------------

%% Primitives: interpreter.erl. Grammar helpers below are parser-internal.

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
    {for, Line, Column, [Var, Init, Limit, Block]};
numeric_for(Line, Column, Var, [Init,Limit,Step], Block) ->
    {for, Line, Column, [Var, Init, Limit, Step, Block]};
numeric_for(Line, Column, Var, Exps, Block) when is_list(Exps) ->
    _ = {Column, Var, Block},
    return_error({Line, Column}, "illegal for").

%% generic_for(Line, Column, Names, ExpList, Block). R.Virding.

generic_for(Line, Column, Names, Exps, Block) ->
    {for, Line, Column, [Names, Exps, Block]}.

%% functiondef(Line, Column, Name, {Parameters,Body}). R.Virding.
%% functiondef(Line, Column, {Parameters,Body}).

functiondef(Line, Column, Name, {Pars,Body}) ->
    {functiondef, Line, Column, [Name, Pars, Body]}.

functiondef(Line, Column, {Pars,Body}) ->
    {functiondef, Line, Column, [Pars, Body]}.

%% dot_append(Line, Column, DotList, Last) -> DotList. R.Virding.
%%  Append Last to the end of a dotlist. Builds {'.', ...} internally;
%%  grammar rules that expose the chain as output wrap with dot_to_tree/1.
%%  dot_to_tree: ours (dot chain -> tree); R.Virding Luerl has no equivalent.

dot_append(Line, Column, {'.', L, C, H, T}, Last) ->
    {'.', L, C, H, dot_append(Line, Column, T, Last)};
dot_append(Line, Column, H, Last) ->
    {'.', Line, Column, H, Last}.

dot_to_tree({'.', L, C, H, T}) ->
    {'.', L, C, [dot_to_tree(H), dot_to_tree(T)]};
dot_to_tree(Other) ->
    Other.

%% check_functioncall(PrefixExp) -> PrefixExp. R.Virding.
%%  Check that the PrefixExp is a proper function call/method.

check_functioncall({functioncall, _L, _C, _Args} = Call) ->
    Call;
check_functioncall({methodcall, _L, _C, _Args} = Call) ->
    Call;
check_functioncall({'.', L, C, [H, T0]}) ->
    T = check_functioncall(T0),
    {'.', L, C, [H, T]};
check_functioncall({'.', L, C, H, T}) ->
    dot_to_tree({'.', L, C, H, check_functioncall(T)});
check_functioncall({_Type, L, C}) ->
    return_error({L, C}, "illegal call");
check_functioncall({_Type, L, C, _Value}) ->
    return_error({L, C}, "illegal call").

%% condition: ours; no direct R.Virding equivalent.
condition('if', Line, Column, If, IfBody, _ElseIf = [], ElseBody) ->
    {'if', Line, Column, [If, IfBody, ElseBody]};
condition('if', Line, Column, If, IfBody, ElseIf, ElseBody) ->
    {'if', Line, Column, [If, IfBody, ElseIf, ElseBody]}.

condition('elseif', Line, Column, If, IfBody, []) ->
    {elseif, Line, Column, [If, IfBody]};
condition('elseif', Line, Column, If, IfBody, ElseIf) ->
    {elseif, Line, Column, [If, IfBody, ElseIf]}.
