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
%%
%% Based on Robert Virding's file `src/luerl_scan.xrl`,
%% https://github.com/rvirding/luerl.
%%
%% Changes in comparison to the initial Luerl source:
%%   - Every token carries `Column` next to `Line`; every helper takes it.
%%   - Entry `process/1` runs `string(Code, {1, 1})` and normalises errors
%%     to `{error, {Line, Column, String}}` through `format_error/1`.
%%   - No catch-all `.` rule; Leex's `{illegal, Char}` is reformatted in
%%     `format_error/1`.

Definitions.

D = [0-9]
H = [0-9A-Fa-f]
U = [A-Z]
L = [a-z]
NAME = ({U}|{L}|_|{D})

Rules.

%% Names/identifiers. Pass Line, Column as separate params (TokenLine,
%% TokenCol from leex).
({U}|{L}|_)({U}|{L}|_|{D})* :
	name_token(TokenChars, TokenLine, TokenCol).
%% Hexadecimal numbers, we have separate rule to ensure we don't have
%% just a '.'. NOTE THESE MUST COME FIRST TO CATCH 0[xX]!!!!
0[xX]{H}*\.?{H}*([pP][-+]?{D}*)?{NAME}* :
	hex_number_token(TokenChars, TokenLine, TokenCol).

%% Decimal numbers, we separate rules to ensure we don't have just a '.'.
%% Both integers and floats are handled here.
\.{D}+([eE][-+]?{D}+)?{NAME}* :
	decimal_number_token(TokenChars, TokenLine, TokenCol).
{D}+\.?{D}*([eE][-+]?{D}+)?{NAME}* :
	decimal_number_token(TokenChars, TokenLine, TokenCol).

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

-define(DIGIT(C), (C >= $0 andalso C =< $9)).
-define(HEX(C), (C >= $A andalso C =< $F orelse
                 C >= $a andalso C =< $f orelse
                 ?DIGIT(C))).

%% Leex predefined variables in rules: TokenChars, TokenLen, TokenLine,
%% TokenCol.
%% We pass Line and Column as separate parameters (TokenLine, TokenCol)
%% to helpers.
%% https://www.erlang.org/doc/apps/parsetools/leex.html

-export([process/1, is_keyword/1, string_chars/1, chars/1]).

-include_lib("eunit/include/eunit.hrl").

process_test() -> ok.

%% string/2 (leex-generated) returns {ok, Tokens, EndLoc} | {error, ...}.
-spec process([byte()]) ->
    {ok, [term()]} | {error, {integer(), integer(), string()}}.
process(Code) ->
    case string(Code, {1, 1}) of
        {ok, Tokens, _EndLoc} ->
            {ok, Tokens};
        {error, {{Line, Column}, _Mod, Desc}, _EndLoc} ->
            {error, {Line, Column, format_error(Desc)}}
    end.

%% -----------------------------------------------------------------------------
%% Exact terms returned under Descriptor (normalized to string):
%%
%% Origin          | Engine Descriptor    | Normalized Descriptor (string)
%% ----------------|----------------------|-------------------------------------
%% Leex engine     | {illegal, Character} | "unexpected characters \"...\""
%% Rule (Numbers)  | "malformed number…"  | "malformed number near '...'"
%% Rule (Strings)  | "illegal string"     | "illegal string"
%% Rule (Names)    | "illegal name"       | "illegal name"
%% Rule (Comments) | "unfinished ..."     | "unfinished long comment"
%% -----------------------------------------------------------------------------

format_error({illegal, S}) ->
    Args = [io_lib:write_string(S)],
    lists:flatten(io_lib:format("unexpected characters ~s", Args));
format_error(S) when is_list(S) ->
    S;
format_error(S) ->
    lists:flatten(io_lib:write(S)).

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

%% decimal_number_token(TokenChars, Line, Column) -> {token,{...}} | {error,E}.
%% hex_number_token(TokenChars, Line, Column) -> {token,{...}} | {error,E}.
%%  Line, Column as separate parameters.

decimal_number_token(TokenChars, Line, Column) ->
    Result = case dec_number_split(TokenChars) of
                 {_,_,_,Rest} when Rest =/= [] -> error;
                 {[],[],[],_Rest} -> error;
                 {[],[],_Ecs,_Rest} -> error;
                 {[],".",_Ecs,_Rest} -> error;
                 {_,_,[_E],_Rest} -> error;
                 {Hcs,Fcs,Ecs,_Rest} ->
                     DW = list_to_integer("0" ++ Hcs),
                     DF = dec_number_fraction(Fcs, DW),
                     Dnum = dec_number_exponent(Ecs, DF),
                     {ok,Dnum}
             end,
    case Result of
        {ok,Number} ->
            {token,{'NUMERAL',Line,Column,Number}};
        error ->
            number_token_error(TokenChars)
    end.

number_token_error(Tcs) ->
    {error,"malformed number near '" ++ Tcs ++ "'"}.

dec_number_split(Tcs0) ->
    Digit = fun (C) -> ?DIGIT(C) end,
    {Hcs,Tcs1} = lists:splitwith(Digit, Tcs0),
    {Fcs,Tcs2} = dec_number_split_fraction(Tcs1),
    {Ecs,Rest} = dec_number_split_exponent(Tcs2),
    {Hcs,Fcs,Ecs,Rest}.

dec_number_split_fraction([$. | Fcs0]) ->
    {Fcs1,Frest} = lists:splitwith(fun (C) -> ?DIGIT(C) end, Fcs0),
    {[$.|Fcs1],Frest};
dec_number_split_fraction(Tcs) ->
    {[],Tcs}.

dec_number_split_exponent([P | Pcs0]) when P =:= $e ; P =:= $E ->
    Digit = fun (C) -> ?DIGIT(C) end,
    case Pcs0 of
        [S | Pcs1] when S =:= $+ ; S =:= $- ->
            {Pcs2,Rest} = lists:splitwith(Digit, Pcs1),
            {[P,S|Pcs2],Rest};
        Pcs1 ->
            {Pcs2,Rest} = lists:splitwith(Digit, Pcs1),
            {[P|Pcs2],Rest}
    end;
dec_number_split_exponent(Tcs) ->
    {[],Tcs}.

dec_number_fraction(".", DW) -> float(DW);
dec_number_fraction([$. | Fcs], DW) ->
    DW + list_to_float("0." ++ Fcs);
dec_number_fraction([], DW) -> DW.

dec_number_exponent([_E | Ecs], DF) ->
    DF * math:pow(10, list_to_integer(Ecs));
dec_number_exponent([], DF) -> DF.

hex_number_token([$0,X|TokenChars], Line, Column) ->
    Result = case hex_number_split(TokenChars) of
                 {_,_,_,Rest} when Rest =/= [] -> error;
                 {[],[],[],_Rest} -> error;
                 {[],[],_Ecs,_Rest} -> error;
                 {[],".",_Ecs,_Rest} -> error;
                 {_,_,[_P],_Rest} -> error;
                 {Hcs,Fcs,Ecs,_Rest} ->
                     HW = list_to_integer("0" ++ Hcs, 16),
                     HF = hex_number_fraction(Fcs, HW),
                     Hnum = hex_number_exponent(Ecs, HF),
                     {ok,Hnum}
             end,
    case Result of
        {ok,Number} ->
            {token,{'NUMERAL',Line,Column,Number}};
        error ->
            number_token_error([$0,X|TokenChars])
    end.

hex_number_split(Tcs0) ->
    Hex = fun (C) -> ?HEX(C) end,
    {Hcs,Tcs1} = lists:splitwith(Hex, Tcs0),
    {Fcs,Tcs2} = hex_number_split_fraction(Tcs1),
    {Ecs,Rest} = hex_number_split_exponent(Tcs2),
    {Hcs,Fcs,Ecs,Rest}.

hex_number_split_fraction([$. | Fcs0]) ->
    {Fcs1,Frest} = lists:splitwith(fun (C) -> ?HEX(C) end, Fcs0),
    {[$.|Fcs1],Frest};
hex_number_split_fraction(Tcs) ->
    {[],Tcs}.

hex_number_split_exponent([P | Pcs0]) when P =:= $p ; P =:= $P ->
    Digit = fun (C) -> ?DIGIT(C) end,
    case Pcs0 of
        [S | Pcs1] when S =:= $+ ; S =:= $- ->
            {Pcs2,Rest} = lists:splitwith(Digit, Pcs1),
            {[P,S|Pcs2],Rest};
        Pcs1 ->
            {Pcs2,Rest} = lists:splitwith(Digit, Pcs1),
            {[P|Pcs2],Rest}
    end;
hex_number_split_exponent(Tcs) ->
    {[],Tcs}.

hex_number_fraction([$. | Fcs], HW) ->
    {HF,_} = hex_number_fraction(Fcs, 16.0, HW + 0.0),
    HF;
hex_number_fraction([], HW) -> HW.

hex_number_fraction([C|Cs], Pow, SoFar) when C >= $0, C =< $9 ->
    hex_number_fraction(Cs, Pow*16.0, SoFar + (C - $0)/Pow);
hex_number_fraction([C|Cs], Pow, SoFar) when C >= $a, C =< $f ->
    hex_number_fraction(Cs, Pow*16.0, SoFar + (C - $a + 10)/Pow);
hex_number_fraction([C|Cs], Pow, SoFar) when C >= $A, C =< $F ->
    hex_number_fraction(Cs, Pow*16.0, SoFar + (C - $A + 10)/Pow);
hex_number_fraction(Cs, _Pow, SoFar) ->
    {SoFar,Cs}.

hex_number_exponent([_P | Ecs], HF) ->
    HF * math:pow(2, list_to_integer(Ecs));
hex_number_exponent([], HF) -> HF.

%% string_token(InputChars, Length, Line, Column) -> {token,{...}} | {error,E}.

string_token(Cs0, Len, Line, Column) ->
    Cs1 = string:substr(Cs0, 2, Len - 2),
    try
        Bytes = string_chars(Cs1),
        String = iolist_to_binary(Bytes),
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
	String = iolist_to_binary(Cs2),
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
