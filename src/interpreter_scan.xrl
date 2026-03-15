%% Copyright (c) 2013-2023 Robert Virding
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

%% File    : interpreter_scan.xrl
%% Author  : Robert Virding
%% Purpose : Token definitions for LUA.

Definitions.

D = [0-9]
H = [0-9A-Fa-f]
U = [A-Z]
L = [a-z]

Rules.

%% Names/identifiers. Pass Line, Column as separate params (TokenLine,
%% TokenCol from leex).
({U}|{L}|_)({U}|{L}|_|{D})* :
	name_token(TokenChars, TokenLine, TokenCol).
%% Numbers.
{D}+ : 
	case catch {ok,list_to_integer(TokenChars)} of
	    {ok,I} -> {token,{'NUMERAL',TokenLine,TokenCol,I}};
	    _ -> {error,"illegal number"}
	end.
0[xX]{H}+ :
        Int = list_to_integer(string:substr(TokenChars, 3), 16),
        {token,{'NUMERAL',TokenLine,TokenCol,Int}}.

%% Floats, we have separate rules to make them easier to handle.
{D}+\.{D}+([eE][-+]?{D}+)? :
	case catch {ok,list_to_float(TokenChars)} of
	    {ok,F} -> {token,{'NUMERAL',TokenLine,TokenCol,F}};
	    _ -> {error,"illegal number"}
	end.
{D}+[eE][-+]?{D}+ :
	[M,E] = string:tokens(TokenChars, "eE"),
	case catch {ok,list_to_float(M ++ ".0e" ++ E)} of
	    {ok,F} -> {token,{'NUMERAL',TokenLine,TokenCol,F}};
	    _ -> {error,"illegal number"}
	end.
{D}+\.([eE][-+]?{D}+)? :
	[M|E] = string:tokens(TokenChars, "."),
	case catch {ok,list_to_float(lists:append([M,".0"|E]))} of
	    {ok,F} -> {token,{'NUMERAL',TokenLine,TokenCol,F}};
	    _ -> {error,"illegal number"}
	end.
\.{D}+([eE][-+]?{D}+)? :
	case catch {ok,list_to_float("0" ++ TokenChars)} of
	    {ok,F} -> {token,{'NUMERAL',TokenLine,TokenCol,F}};
	    _ -> {error,"illegal number"}
	end.

%% Hexadecimal floats, we have one complex rule to handle bad formats
%% more like the Lua parser.

0[xX]{H}*\.?{H}*([pP][+-]?{D}+)? :
	hex_float_token(TokenChars, TokenLine, TokenCol).

%% Strings. 
%% Handle the illegal newlines in string_token.
\"(\\.|\\\n|[^"\\])*\" :
	string_token(TokenChars, TokenLen, TokenLine, TokenCol).
\'(\\.|\\\n|[^'\\])*\' :
	string_token(TokenChars, TokenLen, TokenLine, TokenCol).
\[\[([^]]|\][^]])*\]\] :
	long_string_token(TokenChars, TokenLen, 2, TokenLine, TokenCol).
\[=\[([^]]|\](=[^]]|[^=]))*\]=\] :
	long_string_token(TokenChars, TokenLen, 3, TokenLine, TokenCol).
\[==\[([^]]|\](==[^]]|=[^=]|[^=]))*\]==\] :
	long_string_token(TokenChars, TokenLen, 4, TokenLine, TokenCol).
\[===\[([^]]|\](===[^]]|==[^=]|=[^=]|[^=]))*\]===\] :
	long_string_token(TokenChars, TokenLen, 5, TokenLine, TokenCol).

%% \[==\[([^]]|\]==[^]]|\]=[^=]|\][^=])*\]==\] :

%% Other known tokens.
\+  : {token,{'+',TokenLine,TokenCol}}.
\-  : {token,{'-',TokenLine,TokenCol}}.
\*  : {token,{'*',TokenLine,TokenCol}}.
\/  : {token,{'/',TokenLine,TokenCol}}.
\// : {token,{'//',TokenLine,TokenCol}}.
\%  : {token,{'%',TokenLine,TokenCol}}.
\^  : {token,{'^',TokenLine,TokenCol}}.
\&  : {token,{'&',TokenLine,TokenCol}}.
\|  : {token,{'|',TokenLine,TokenCol}}.
\~  : {token,{'~',TokenLine,TokenCol}}.
\>> : {token,{'>>',TokenLine,TokenCol}}.
\<< : {token,{'<<',TokenLine,TokenCol}}.
\#  : {token,{'#',TokenLine,TokenCol}}.
==  : {token,{'==',TokenLine,TokenCol}}.
~=  : {token,{'~=',TokenLine,TokenCol}}.
<=  : {token,{'<=',TokenLine,TokenCol}}.
>=  : {token,{'>=',TokenLine,TokenCol}}.
<  :  {token,{'<',TokenLine,TokenCol}}.
>  :  {token,{'>',TokenLine,TokenCol}}.
=  :  {token,{'=',TokenLine,TokenCol}}.
\( : {token,{'(',TokenLine,TokenCol}}.
\) : {token,{')',TokenLine,TokenCol}}.
\{ : {token,{'{',TokenLine,TokenCol}}.
\} : {token,{'}',TokenLine,TokenCol}}.
\[ : {token,{'[',TokenLine,TokenCol}}.
\] : {token,{']',TokenLine,TokenCol}}.
:: : {token,{'::',TokenLine,TokenCol}}.
;  : {token,{';',TokenLine,TokenCol}}.
:  : {token,{':',TokenLine,TokenCol}}.
,  : {token,{',',TokenLine,TokenCol}}.
\. : {token,{'.',TokenLine,TokenCol}}.
\.\. : {token,{'..',TokenLine,TokenCol}}.
\.\.\. : {token,{'...',TokenLine,TokenCol}}.

[\011-\015\s\240]+ : skip_token.		%Mirror Lua here

%% Comments, either -- or --[[ ]].
%%--(\[([^[\n].*|\[\n|[^[\n].*|\n) : skip_token.
--\n :		skip_token.
--[^[\n].* :	skip_token.
--\[\n :	skip_token.
--\[[^[\n].* :	skip_token.

%% comment --ab ... yz  --ab([^y]|y[^z])*yz
--\[\[([^]]|\][^]])*\]\] : skip_token.
--\[\[([^]]|\][^]])* : {error,"unfinished long comment"}.

Erlang code.
%% Leex predefined variables in rules: TokenChars, TokenLen, TokenLine,
%% TokenCol.
%% We pass Line and Column as separate parameters (TokenLine, TokenCol)
%% to helpers.
%% https://www.erlang.org/doc/apps/parsetools/leex.html

-export([process/1, is_keyword/1, string_chars/1, chars/1]).

-include_lib("eunit/include/eunit.hrl").

process_test() -> ok.

%% string/1 (leex-generated) returns {ok, Tokens, EndLine} | {error, ...}.
-spec process(string()) -> [term()].
process(Code) ->
    case string(Code) of
        {ok, Tokens, _EndLine} ->
            Tokens;
        {error, {_Loc, _Mod, Desc}, _} ->
            error(format_error(Desc))
    end.

%% name_token(Chars, Line, Column) -> {token,{...}} | {error,E}.
%%  Line, Column as separate parameters. Build a name from list of legal
%%  characters.

name_token(Cs, Line, Column) ->
    case catch {ok,list_to_binary(Cs)} of
	{ok,Name} ->
	    case is_keyword(Name) of
		true -> {token,{name_string(Name),Line,Column}};
		false -> {token,{'NAME',Line,Column,Name}}
	    end;
	_ -> {error,"illegal name"}
    end.

name_string(Name) ->
    binary_to_atom(Name, latin1).		%Only latin1 in Lua

%% hex_float_token(TokenChars, Line, Column) -> {token,{...}} | {error,E}.

hex_float_token(TokenChars, Line, Column) ->
    Tcs = string:substr(TokenChars, 3),
    case lists:splitwith(fun (C) -> (C =/= $p) and (C =/= $P) end, Tcs) of
	{Mcs,[]} when Mcs /= [] ->
	    hex_float(Mcs, [], Line, Column);
	{Mcs,[_P|Ecs]} when Ecs /= [] ->
	    hex_float(Mcs, Ecs, Line, Column);
	_Other -> {error,"malformed number"}
    end.

%% hex_float(Mantissa, Exponent) -> {token,{'NUMERAL',Line,Float}} | {error,E}.
%% hex_mantissa(Chars) -> {float,Float} | error.
%% hex_fraction(Chars, Pow, SoFar) -> Fraction.

hex_float(Mcs, [], Line, Column) ->
    case hex_mantissa(Mcs) of
	{float,M} -> {token,{'NUMERAL',Line,Column,M}};
	error -> {error,"malformed number"}
    end;
hex_float(Mcs, Ecs, Line, Column) ->
    case hex_mantissa(Mcs) of
	{float,M} ->
	    case catch list_to_integer(Ecs, 10) of
		{'EXIT',_} -> {error,"malformed number"};
		E -> {token,{'NUMERAL',Line,Column,M * math:pow(2, E)}}
	    end;
	error -> {error,"malformed number"}
    end.

hex_mantissa(Mcs) ->
    case lists:splitwith(fun (C) -> C =/= $. end, Mcs) of
	{[],[]} -> error;			%Nothing at all
	{[],[$.]} -> error;			%Only a '.'
	{[],[$.|Fcs]} -> {float,hex_fraction(Fcs, 16.0, 0.0)};
	{Hcs,[]} -> {float,float(list_to_integer(Hcs, 16))};
	{Hcs,[$.|Fcs]} ->
	    H = float(list_to_integer(Hcs, 16)),
	    {float,hex_fraction(Fcs, 16.0, H)}
    end.

hex_fraction([C|Cs], Pow, SoFar) when C >= $0, C =< $9 ->
    hex_fraction(Cs, Pow*16, SoFar + (C - $0)/Pow);
hex_fraction([C|Cs], Pow, SoFar) when C >= $a, C =< $f ->
    hex_fraction(Cs, Pow*16, SoFar + (C - $a + 10)/Pow);
hex_fraction([C|Cs], Pow, SoFar) when C >= $A, C =< $F ->
    hex_fraction(Cs, Pow*16, SoFar + (C - $A + 10)/Pow);
hex_fraction([], _Pow, SoFar) -> SoFar.

%% string_token(InputChars, Length, Line, Column) -> {token,{...}} | {error,E}.

string_token(Cs0, Len, Line, Column) ->
    Cs1 = string:substr(Cs0, 2, Len - 2),
    try
        Bytes = string_chars(Cs1),
        String = unicode:characters_to_binary(Bytes, utf8, utf8),
        {token,{'LITERALSTRING',Line,Column,String}}
    catch
        _:_ ->
            {error,"illegal string"}
    end.

%% string_chars(Chars)
%% chars(Chars)
%%  Return a list of UTF-8 encoded binaries and one byte unencoded
%%  characters. chars/1 is for external backwards compatibilty.

chars(Cs) ->
    string_chars(Cs).

string_chars(Cs) ->
    string_chars(Cs, []).

string_chars([$\\ | Cs], []) ->                 %Nothing here to worry about
    bq_chars(Cs);
string_chars([$\\ | Cs], Acc) ->
    [lists:reverse(Acc) | bq_chars(Cs)];
string_chars([$\n | _], _Acc) -> throw(string_error);
string_chars([C | Cs], Acc) -> string_chars(Cs, [C|Acc]);
string_chars([], []) -> [];
string_chars([], Acc) ->
    [lists:reverse(Acc)].

%% long_string_token(InputChars, Length, BracketLength, Line, Column) ->
%%     {token,{'LITERALSTRING',Line,Column,String}} | {error,E}.

long_string_token(Cs0, Len, BrLen, Line, Column) ->
    Cs2 = case string:substr(Cs0, BrLen+1, Len - 2*BrLen) of
	      [$\n | Cs1] -> Cs1;
	      Cs1 -> Cs1
	  end,
    try
	String = unicode:characters_to_binary(Cs2, utf8, utf8),
	{token,{'LITERALSTRING',Line,Column,String}}
    catch
	_:_ ->
	    {error,"illegal string"}
    end.

%% bq_chars(Chars)
%%  Handle the backquotes characters. These always fit directly into
%%  one byte and are never UTF-8 encoded.

bq_chars([C1|Cs0]) when C1 >= $0, C1 =< $9 ->   %1-3 decimal digits
    I1 = C1 - $0,
    case Cs0 of
        [C2|Cs1] when C2 >= $0, C2 =< $9 ->
            I2 = C2 - $0,
            case Cs1 of
                [C3|Cs2] when C3 >= $0, C3 =< $9 ->
                    I3 = C3 - $0,
                    Byte = 100*I1 + 10*I2 + I3,
                    %% Must fit into one byte!
                    (Byte =< 255) orelse throw(string_error),
                    [Byte | string_chars(Cs2, [])];
                _ ->
                    Byte = 10*I1 + I2,
                    [Byte | string_chars(Cs1, [])]
            end;
        _ -> [I1 | string_chars(Cs0, [])]
    end;
bq_chars([$x,C1,C2|Cs]) ->                      %2 hex digits
    case hex_char(C1) and hex_char(C2) of
        true ->
            Byte = hex_val(C1)*16 + hex_val(C2),
            [Byte | string_chars(Cs, [])];
        false -> throw(string_error)
    end;
bq_chars([$z|Cs]) ->                            %Skip blanks
    string_chars(skip_space(Cs), []);
bq_chars([C|Cs]) -> [escape_char(C)|string_chars(Cs, [])];
bq_chars([]) ->
    [].

skip_space([C|Cs]) when C >= 0, C =< $\s -> skip_space(Cs);
skip_space(Cs) -> Cs.

hex_char(C) when C >= $0, C =< $9 -> true;
hex_char(C) when C >= $a, C =< $f -> true;
hex_char(C) when C >= $A, C =< $F -> true;
hex_char(_) -> false.

hex_val(C) when C >= $0, C =< $9 -> C - $0;
hex_val(C) when C >= $a, C =< $f -> C - $a + 10;
hex_val(C) when C >= $A, C =< $F -> C - $A + 10.

escape_char($n) -> $\n;				%\n = LF
escape_char($r) -> $\r;				%\r = CR
escape_char($t) -> $\t;				%\t = TAB
escape_char($v) -> $\v;				%\v = VT
escape_char($b) -> $\b;				%\b = BS
escape_char($f) -> $\f;				%\f = FF
escape_char($e) -> $\e;				%\e = ESC
escape_char($s) -> $\s;				%\s = SPC
escape_char($d) -> $\d;				%\d = DEL
escape_char(C) -> C.

%% is_keyword(Name) -> boolean().
%%  Test if the name is a keyword.

is_keyword(<<"and">>) -> true;
is_keyword(<<"break">>) -> true;
is_keyword(<<"do">>) -> true;
is_keyword(<<"else">>) -> true;
is_keyword(<<"elseif">>) -> true;
is_keyword(<<"end">>) -> true;
is_keyword(<<"false">>) -> true;
is_keyword(<<"for">>) -> true;
is_keyword(<<"function">>) -> true;
is_keyword(<<"goto">>) -> true;
is_keyword(<<"if">>) -> true;
is_keyword(<<"in">>) -> true;
is_keyword(<<"local">>) -> true;
is_keyword(<<"nil">>) -> true;
is_keyword(<<"not">>) -> true;
is_keyword(<<"or">>) -> true;
is_keyword(<<"repeat">>) -> true;
is_keyword(<<"return">>) -> true;
is_keyword(<<"then">>) -> true;
is_keyword(<<"true">>) -> true;
is_keyword(<<"until">>) -> true;
is_keyword(<<"while">>) -> true;
is_keyword(_) -> false.
