-module(interpreter).

%% TEST(devcontainer): edit this line + save to see workspace bind-mount
%% sync (instant) vs. Rebuild Container (full image rebuild). Bump: 0

%% Lua 5.2 interpreter embedded in ERTS
%%
%% This module serves three roles:
%%   1. Behaviour definition — host implements exec/3, exec/4 callbacks.
%%   2. Runtime primitives (assert, assign, exec, etc.) used by the closure
%%      compiler/runtime path.
%%   3. Public API: compile/2, md5/1, iterator/1, next/1.
%%      Planned/convenience API under discussion: run/2.
%%
%% Pipeline: tokenization -> parse -> process/2 -> inspect.
%%   - compile/2(Module, Code) -> {ok, Tree}; Module is reserved for the
%%     closure lowering/runtime stage.
%%   - The parser returns neutral Lua tree tuples, not Erlang abstract forms.
%%
%% Grammar and AST construction live in interpreter_parse.yrl.
%% Libraries and extensions belong in this module.
%%
%% Erlang module structure is flat (no nested modules). We choose a small,
%% fixed set of modules (interpreter, interpreter_parse, interpreter_scan) to
%% avoid messy project navigation at the cost of a few larger modules.

%% Embed API
-callback exec(name(), cell(), [key()], lua()) -> erl().
-callback exec(name(), cell(), [key()]) -> lua().

%% Debug API
-callback eval(name(), line(), column(), command()) -> erl().

%% =============================================================================
%% READ — Reference implementation (Lua 5.2 manual, reading order)
%% =============================================================================
%%
%% Syntax (lexer and parser)
%% -------------------------
%%   1. §3.1 Lexical Conventions (tokens, comments, literals, names)
%%      https://www.lua.org/manual/5.2/manual.html#3.1
%%   2. §9 The Complete Syntax of Lua (BNF)
%%      https://www.lua.org/manual/5.2/manual.html#9
%%
%% Values and execution model
%% --------------------------
%%   3. §2.1 Values and Types
%%      https://www.lua.org/manual/5.2/manual.html#2.1
%%   4. §2.2 Environments and the Global Environment (_ENV, _G)
%%      https://www.lua.org/manual/5.2/manual.html#2.2
%%   5. §2.3 Error Handling (error, pcall, xpcall)
%%      https://www.lua.org/manual/5.2/manual.html#2.3
%%   6. §2.4 Metatables and Metamethods (getmetatable, setmetatable,
%%      rawget, ...)
%%      https://www.lua.org/manual/5.2/manual.html#2.4
%%   7. §2.5 Garbage Collection (optional for minimal; §2.5.1 for __gc)
%%      https://www.lua.org/manual/5.2/manual.html#2.5
%%   8. §2.6 Coroutines (optional for minimal)
%%      https://www.lua.org/manual/5.2/manual.html#2.6
%%
%% Language (statements, expressions, visibility)
%% ----------------------------------------------
%%   9.  §3.2 Chunks (compilation unit, _ENV)
%%       https://www.lua.org/manual/5.2/manual.html#3.2
%%   10. §3.3.1 Blocks
%%       https://www.lua.org/manual/5.2/manual.html#3.3.1
%%   11. §3.3.2 Chunks (as statement)
%%       https://www.lua.org/manual/5.2/manual.html#3.3.2
%%   12. §3.3.7 Local Declarations
%%       https://www.lua.org/manual/5.2/manual.html#3.3.7
%%   13. §3.3.3 Assignment
%%       https://www.lua.org/manual/5.2/manual.html#3.3.3
%%   14. §3.4 Expressions (literals, operators, precedence, calls, table,
%%       function defs, vararg ...)
%%       https://www.lua.org/manual/5.2/manual.html#3.4
%%   15. §3.3.6 Function Calls as Statements
%%       https://www.lua.org/manual/5.2/manual.html#3.3.6
%%   16. §3.3.4 Control Structures (if, while, repeat, for)
%%       https://www.lua.org/manual/5.2/manual.html#3.3.4
%%   17. §3.3.5 For Statement (numeric and generic)
%%       https://www.lua.org/manual/5.2/manual.html#3.3.5
%%   18. §3.5 Visibility Rules (scoping; aligns with cell/scope design)
%%       https://www.lua.org/manual/5.2/manual.html#3.5
%%
%% Basic library
%% -------------
%%   19. §6.1 Basic Functions (type, rawget, rawset, pcall, load, ...)
%%       https://www.lua.org/manual/5.2/manual.html#6.1
%%
%% Optional (scoping and control)
%% ------------------------------
%%   PIL 4.2 Lexical Scoping   https://www.lua.org/pil/4.2.html
%%   PIL 4.3 Control Structures https://www.lua.org/pil/4.3.html
%%
%% =============================================================================
%% END READ — Lua 5.2
%% =============================================================================
%%
%% =============================================================================
%% READ — Erlang/OTP (this module; read after Lua block above)
%% =============================================================================
%%
%%   1. Modules, attributes, behaviours (-module, -export, -behaviour,
%%      -callback, -optional_callbacks):
%%      https://www.erlang.org/doc/system/modules.html
%%   2. maybe … end, ?= (conditional match), else — Expressions:
%%      https://www.erlang.org/doc/system/expressions.html#maybe
%%      Feature maybe_expr: OTP 25+; on by default from OTP 27+. Older OTP:
%%      https://www.erlang.org/doc/system/features.html
%%   3. Types and function specifications (-spec, -type):
%%      https://www.erlang.org/doc/system/typespec.html
%%   4. gen_statem (possible evaluation driver): optional
%%      https://www.erlang.org/doc/man/gen_statem.html
%%
%% =============================================================================
%% END READ — Erlang/OTP
%% =============================================================================
%%
%% =============================================================================
%% TODO — Minimal viable default for Lua 5.2 (see www.lua.org/manual/5.2)
%% =============================================================================
%%
%% Variables and storage
%% ---------------------
%%   - All eight types: nil, boolean, number, string, function, userdata,
%%     thread, table.
%%   - Local and global variables; globals via _ENV (chunk compiles with
%%     external _ENV).
%%   - Assignment, multi-assignment, and variable resolution (host exec/3,
%%     exec/4).
%%   - _G and _ENV in global environment; host provides initial _ENV.
%%
%% Basic library (§6.1) — minimal set
%% ----------------------------------
%%   All are "standard library" per the manual; the standard does not define
%%   "implementation default" separately. For minimal implementation we
%%   distinguish:
%%   - Semantics-relevant: referenced in the manual's semantic description
%%     (§2, §3 meaning of operations), not in lexical/grammar: type,
%%     getmetatable,
%%     setmetatable, rawget, rawset, rawlen, tonumber, tostring, rawequal.
%%   - Pure library: only in §6, not used to define meaning: print, dofile,
%%     loadfile, collectgarbage. Omit for minimal.
%%   - type(v), tonumber, tostring, rawequal, rawget, rawset, rawlen.
%%   - next(t [, index]), pairs(t), ipairs(t).
%%   - pcall(f, ...), xpcall(f, msgh [, ...]), error(message [, level]),
%%     assert(v [, message]).
%%     TBD: Protected-call helpers define the Lua error boundary. Unprotected
%%     language errors may use Erlang exceptions internally, but pcall/xpcall
%%     must catch interpreter-owned Lua errors and convert them into Lua return
%%     values. Do not accidentally swallow unrelated host/BEAM failures unless
%%     the host contract explicitly maps them to Lua errors.
%%   - getmetatable(object), setmetatable(table, metatable).
%%   - select(index, ...), load(chunk [, chunkname [, mode [, env]]]). select is
%%     supplied as part of the standard library (§6.1); use with ... for
%%     vararg.
%%   - Optional for minimal: print(...), _VERSION (string "Lua 5.2").
%%
%% Embedded (host-provided) functions
%% ----------------------------------
%%   - Host registers C (here: Erlang) functions into _ENV (e.g. io.print,
%%     os.clock).
%%   - No built-in I/O or OS in core; host supplies io, os, etc. as needed.
%%   - For minimal: host can provide empty _ENV or a table with type, pairs,
%%     ipairs, pcall, next.
%%
%% Constructor for host setup (_ENV + language constructs)
%% -------------------------------------------------------
%%   - Provide iterator/1 (constructor) that returns an iterator over §6.1
%%     bindings.
%%     Host pulls bindings via next/1; no callback Fun needed.
%%     This separates setup scope (iterator/1 + next/1) from runtime
%%     (exec/3, exec/4).
%%   - iterator/1 does NOT call exec/4: setup and runtime use different
%%     mechanisms.
%%   - Signature: iterator(Opts) -> iterator()
%%       next(Iterator) -> {[key()], lua(), iterator()} | none
%%       Opts = map with optional keys below
%%     Host calls next/1 repeatedly to pull each standard binding (type,
%%     pairs, ...).
%%   - Pre-compile: bindings are native Erlang funs; no Lua source compiled.
%%   - Naming: iterator/1 is a constructor (cf. maps:iterator/1); next/1 steps.
%%   - Suggested Opts:
%%       include => [print | dofile | loadfile | ...]  optional standard names
%%       exclude => [load | ...]  names to omit (e.g. sandbox)
%%       extra   => [{Keys, Value} | ...] or map of host bindings (e.g. io, os)
%%     Examples:
%%       iterator(#{})                                 minimal default
%%       iterator(#{include => [print]})               default + print
%%       iterator(#{extra => [{[<<"io">>], IOTable}]}) add host bindings
%%       iterator(#{exclude => [load]})                sandbox
%%
%% Language (syntax, scoping, control)
%% ----------------------------------
%%   - Control structures: if/elseif/else, while, repeat, for (numeric and
%%     generic), do block.
%%   - Break, label, goto (e.g. via tree enclosure).
%%   - Vararg (...), select, and call lowering (manual §3.4; §6.1 for select).
%%   - Lexical scoping: chunk, block, control bodies, function body (see
%%     NOTES re. cell resolution).
%%   - Scopes resolved during process/2 lowering: variable occurrences become
%%     host API calls with Keys plus a Cell expression.
%%   - Scope entrance allocates a lexical Cell in the compiled model; runtime
%%     primitives do not mutate a threaded Cell/Frame.
%%   - Grammar: fix reduce conflicts if any; ref. Lua 5.2 manual §3.
%%   - Evaluators for statements, expressions, literals: lowered closure
%%     conversion.
%%   - Cell access in closure lowering:
%%       A resolved Lua variable carries {Cell, Keys}. Generated Erlang
%%       closures capture Cell/Keys as ordinary Erlang closure environment.
%%       Function calls pass Lua values only; hidden cells are installed by
%%       the callee runtime setup.
%%
%%   Sources (docs):
%%     https://www.lua.org/manual/5.2/manual.html (Lua 5.2 Reference Manual)
%%     https://www.lua.org/manual/5.2/manual.html#2  (§2 Basic concepts)
%%     https://www.lua.org/manual/5.2/manual.html#3  (§3 Syntax and semantics)
%%     https://www.lua.org/pil/4.2.html (PIL 4.2 Lexical scoping)
%%     https://www.lua.org/pil/4.3.html (PIL 4.3 Control structures)
%%
%% =============================================================================
%% END TODO
%% =============================================================================

%% Public API (current exports):
%%   Setup:     iterator/1  planned constructor for §6.1 bindings
%%              next/1      planned pull step:
%%                            {Keys, Value, Iterator} | none
%%   Compile:   compile/2   Lua source → {ok, program()} | {error, Err}
%%   Eval:      eval/4      Line/Column continuation entry point
%%   Transform: md5/1       Lua source → content hash (MD5 hex)
%%
%% Planned/convenience API kept in design notes, not exported today:
%%   run/2       Lua source → lua() (scan → parse → closure runtime)
%%
%% Host implements exec/3 (read) and exec/4 (write) as behaviour callbacks.
%% Setup (iterator/next) and runtime (exec) use separate mechanisms:
%% the interpreter stays stateless; the host owns storage and _ENV.
%%
%% =============================================================================
%% Runtime work categories
%% =============================================================================
%%
%% Controlled execution is wider than host storage access. A Lua command can do
%% real work before it reaches exec/4, and that work must still be visible to
%% the interpreter's budget, interruption, and resume machinery. Keep the
%% following categories distinct when lowering parser tuples to runtime code.
%%
%% Language primitive invocation
%% -----------------------------
%% Interpreter-owned Lua semantics. These operations are part of the language,
%% not host callbacks: assignment sequencing, control flow, operators, function
%% calls, vararg adjustment, return/break/goto handling, lexical block entry,
%% closure creation, and table construction. They may call into expression
%% evaluation and may allocate or perform many small ordered steps.
%%
%% Host environment access
%% -----------------------
%% Reads and writes of resolved storage go through the host callbacks:
%%
%%   exec(Name, Cell, Keys)       %% read
%%   exec(Name, Cell, Keys, Lua)  %% write
%%
%% This is the boundary for storage ownership. It is not the boundary for all
%% execution cost. For example, the right-hand side of an assignment must be
%% evaluated completely before any left-hand write is performed.
%%
%% Host primitive invocation
%% -------------------------
%% Host-provided functions are ordinary Lua values stored in the environment.
%% The interpreter first resolves the callee using normal Lua rules, evaluates
%% arguments in Lua order, then invokes the host primitive only if the resolved
%% callee is such a value. The host call is therefore after language-level
%% callee and argument evaluation, not a shortcut around it.
%%
%% Compile-time literal creation
%% -----------------------------
%% Immutable scalar constants may be created or normalized during compile or
%% lowering: nil, booleans, numbers, and string values once the representation
%% is chosen. These values do not allocate fresh Lua identity each time the
%% expression executes, so it is safe for lowered code to carry them directly.
%%
%% Runtime constructor literals
%% ----------------------------
%% Constructors that look literal in source are not necessarily compile-time
%% values. Tables and functions are executable construction recipes. Each
%% evaluation creates fresh identity and can contain nested expressions with
%% side effects, suspension points, or host calls:
%%
%%   f1 = {a = 1, b = 2}
%%   t = {[f()] = g(), h()}
%%   x = function() return y end
%%
%% The parser/lowerer may keep a compact term such as:
%%
%%   {table, Line, Column, Fields}
%%
%% but runtime must build the value under controlled evaluation. A table
%% constructor should allocate the table, evaluate fields in Lua order, insert
%% each field with the correct array/key semantics, and only then allow the
%% enclosing assignment to call exec/4. If construction is large, budget or
%% interruption checks belong inside those allocation and field steps, because
%% exec/4 sees only the final value and is too late to account for the work.
%%
%% Table constructor positioning rules:
%%   - Assignment is not what gives a constructor dynamic shape. Evaluation is.
%%   - The syntactic field list count is known after parsing.
%%   - Name fields, such as a = 1, have compile-time literal keys.
%%   - Array fields, such as "x", "y", receive planned integer positions from
%%     constructor order.
%%   - Explicit key fields, such as [k] = v, evaluate the key expression at
%%     runtime.
%%   - The final table may still differ from the plan because later fields can
%%     overwrite earlier keys, computed keys can collide with planned keys, and
%%     evaluation may suspend or fail before all fields are inserted.
%%   - Lua multi-result adjustment can also affect trailing array fields when
%%     the last field expression returns more than one value.
%%
%% Therefore lowering may precompute the constructor field schedule and any
%% literal keys, but it must not prebuild the table value. Allocation, dynamic
%% key evaluation, value evaluation, multi-result expansion, collision effects,
%% and insertion remain runtime work under eval/4-controlled execution.
%%
%% A large constructor also has compile-time cost: the source must first become
%% tokens and parser terms. Runtime eval/4 protects execution after lowering;
%% separate compile/inspect limits may still be needed for maximum source size,
%% AST size, or constructor field count.
%%
%% =============================================================================
%% END Runtime work categories
%% =============================================================================
-export([iterator/1, next/1, compile/2, eval/4, md5/1]).

-type code() :: string().

-type offset() :: pos_integer().

-type line() :: offset().

-type column() :: offset().

%% TODO: opaque until host identity contract is settled; refine to a concrete
%% type once the callback module convention is decided.
-type name() :: erl().

-type cell() :: non_neg_integer().

%% TODO: function() covers any Erlang fun; narrow to a dedicated Lua closure
%% type once closure lowering defines the representation. map() represents a
%% Lua table used as a key via reference identity; may need its own type alias.
-type key() :: boolean() | function() | binary() | number() | map().

-type lua() :: key() | 'nil'.

-type erl() :: any().

-type command() :: fun(() -> erl()).

-type program() :: fun(([lua()]) -> [lua()]).

%% TODO: placeholder; refine when iterator/1 and next/1 are implemented.
-type iterator() :: erl().

%% API

%% Planned: create an iterator over semantics-relevant §6.1 bindings; host
%% pulls via next/1. Current implementation deliberately raises until the
%% library-binding contract is finalized.
-spec iterator(map()) -> iterator().
iterator(_Opts) ->
    throw(not_implemented).

%% Planned: return the next {Keys, Value, Iterator} or none.
-spec next(iterator()) -> {[key()], lua(), iterator()} | none.
next(_Iterator) ->
    throw(not_implemented).

%% =============================================================================
%% TODO — Interrupted execution through continuation lowering
%% =============================================================================
%%
%% Goal
%% ----
%% The only planned interrupted-execution use case is:
%%
%%   eval(Line, Column, Program, Runtime)
%%
%% Meaning:
%%
%%   Start from the command located at Line:Column and continue from there.
%%   Runtime is supplied by the host and is assumed to already contain all
%%   cells, globals, upvalues, parameters, tables, and other values that the
%%   skipped commands would have produced during a previous run.
%%
%% This is not a suspended BEAM process and not a Lua VM resume point. It is a
%% partial entry into a compiled continuation chain.
%%
%% Lowering model
%% --------------
%% Statements are lowered from the end of each block to the beginning. Each
%% statement receives the continuation compiled for the statement that follows
%% it.
%%
%% This is the core ordering rule:
%%
%%   Build wrappers right-to-left.
%%   Execute wrapped code left-to-right.
%%
%% Construction order and runtime order are intentionally different. During
%% compilation the next command is already known, so the previous command can
%% capture it as an ordinary Erlang closure value. At runtime the current
%% command executes first and invokes its captured continuation only after its
%% own side effects are complete.
%%
%% Statement lowering
%% ------------------
%% A statement continuation has this intended shape:
%%
%%   StmtK :: fun((Runtime0) -> Runtime1)
%%
%% For a normal statement:
%%
%%   KStat = fun(Rt0) ->
%%               Rt1 = execute_statement(Rt0),
%%               KNext(Rt1)
%%           end
%%
%% A block is lowered with fold-right semantics:
%%
%%   lower_block([S1, S2, S3], ExitK)
%%     -> K3 = lower_stat(S3, ExitK)
%%     -> K2 = lower_stat(S2, K3)
%%     -> K1 = lower_stat(S1, K2)
%%
%% Runtime order is still:
%%
%%   S1 -> S2 -> S3 -> ExitK
%%
%% Program.conts stores the KStat produced for each command location. Therefore
%% eval(Line, Column, Program, Runtime) can jump directly into an existing
%% continuation without reconstructing the chain.
%%
%% Expression lowering
%% -------------------
%% Expressions are wrapped as value-producing Funs. Prefer threading Runtime
%% through expressions because Lua expression evaluation can call functions and
%% therefore can have host-visible side effects.
%%
%%   ExpK :: fun((Runtime0) -> {Value, Runtime1})
%%
%% Expression lists, call arguments, table fields, and similar ordered groups
%% follow the same construction rule: build the wrapper from the end so each
%% expression can call the continuation that collects the remaining values.
%%
%% Example:
%%
%%   f(), g(), h()
%%
%% The compiler may build H first, then G, then F; runtime evaluation is:
%%
%%   f -> g -> h
%%
%% Binary and unary expressions use explicit sequencing:
%%
%%   fun(Rt0) ->
%%       {Left, Rt1} = LeftFun(Rt0),
%%       {Right, Rt2} = RightFun(Rt1),
%%       eval_binop(Op, Left, Right, Rt2)
%%   end
%%
%% Assignment rule
%% ---------------
%% Assignment must not interleave right-hand expression evaluation with
%% left-hand writes. Lowering must preserve this shape:
%%
%%   AssignK = fun(Rt0) ->
%%                 {Vals, Rt1} = EvalRhs(Rt0),
%%                 Rt2 = assign_values(Vars, Vals, Rt1),
%%                 KNext(Rt2)
%%             end
%%
%% This handles Lua multi-assignment correctly:
%%
%%   a, b = b, a
%%
%% The old values are read before any write happens.
%%
%% Control statements
%% ------------------
%% if/elseif/else nodes choose one branch continuation. Each branch is lowered
%% with the same KNext, so both paths rejoin naturally after the conditional.
%%
%% while/repeat/for nodes should use a loop primitive or recursive driver that
%% receives BodyK and KNext. BodyK eventually returns to the loop driver, while
%% loop exit calls KNext.
%%
%% return, break, and goto are control-transfer statements. They may ignore
%% KNext and return a control result to an enclosing driver instead of calling
%% the next sequential continuation.
%%
%% Representative lowering cases
%% -----------------------------
%% Statement: assignment.
%%
%% Lua:
%%
%%   x = 1
%%
%% Comment:
%%   The statement continuation writes x and then calls KNext. Program.conts
%%   indexes the continuation for the source location of this assignment.
%%
%% Statement: function call.
%%
%% Lua:
%%
%%   emit(a(), b())
%%
%% Comment:
%%   The callee and arguments are expression Funs. They are evaluated in the
%%   chosen source order, the call side effects happen, returned values are
%%   discarded because this is a statement, and then KNext is called.
%%
%% Expression: arithmetic.
%%
%% Lua:
%%
%%   a + b * c
%%
%% Comment:
%%   The parser has already fixed precedence in the tree. Lower each operand
%%   as a value Fun and sequence evaluation explicitly. The final expression
%%   Fun returns {Value, Runtime1}; it does not call the statement KNext.
%%
%% Expression list: call arguments.
%%
%% Lua:
%%
%%   f(g(), h(), i())
%%
%% Comment:
%%   Build the argument wrappers from right to left so runtime evaluation is
%%   g(), then h(), then i(). The call primitive receives the collected values
%%   after all argument effects are complete.
%%
%% Assignment: read before write.
%%
%% Lua:
%%
%%   a, b = b, a
%%
%% Comment:
%%   Evaluate the whole right-hand side first, adjust values to the left-hand
%%   side count, then write variables. This is mandatory for swap semantics.
%%
%% Conditional statement.
%%
%% Lua:
%%
%%   if ready() then
%%     send()
%%   else
%%     drop()
%%   end
%%
%% Comment:
%%   The condition expression runs first. The selected branch continuation
%%   executes and then rejoins through the same KNext captured by both branch
%%   blocks.
%%
%% Loop statement.
%%
%% Lua:
%%
%%   while more() do
%%     consume()
%%   end
%%
%% Comment:
%%   The loop driver evaluates the condition before each iteration. BodyK runs
%%   the body and returns to the driver. Loop exit calls KNext.
%%
%% Control transfer.
%%
%% Lua:
%%
%%   return f(), g()
%%
%% Comment:
%%   return evaluates its expression list and produces a return-control result
%%   for the enclosing function driver. It does not call KNext.
%%
%% Example Lua:
%%
%%   a = 1
%%   b = a + 1
%%   print(b)
%%
%% Intended closure shape:
%%
%%   K3 = fun(Rt0) ->
%%            Rt1 = call_print(Rt0),
%%            Rt1
%%        end.
%%
%%   K2 = fun(Rt0) ->
%%            Rt1 = assign_b(Rt0),
%%            K3(Rt1)
%%        end.
%%
%%   K1 = fun(Rt0) ->
%%            Rt1 = assign_a(Rt0),
%%            K2(Rt1)
%%        end.
%%
%% Program stores the normal entry and a line/column vocabulary:
%%
%%   #{entry => K1,
%%     conts => #{{1, 1} => K1,
%%                {2, 1} => K2,
%%                {3, 1} => K3}}
%%
%% Then:
%%
%%   eval(2, 1, Program, Rt0)
%%
%% executes "b = a + 1" and then "print(b)". The value of "a" must already be
%% present in Runtime through the host storage/cell model.
%%
%% Why this fits the Fun-based design
%% ----------------------------------
%% Closure overhead buys something useful: every statement closure is both
%% executable code and a restart point. The continuation table stores references
%% to existing closures; it does not duplicate program bodies.
%%
%% We do not need digraph/CFG metadata for the current use case. Control flow is
%% already encoded by closure captures:
%%
%%   statement closure -> captures Next continuation
%%   if closure        -> chooses branch closure, both exit to same Next
%%   loop closure      -> delegates to loop primitive or recursive driver
%%
%% Function identity is not used. BEAM fun identity and fun table indexes
%% identify Erlang closure sites, not Lua commands. The interpreter-level
%% identity is the source location used to find a continuation in Program.
%%
%% Scope and storage contract
%% --------------------------
%% The compiler still resolves variables to cells/keys. Runtime data remains
%% owned by the host behind exec/3 and exec/4. A continuation may therefore
%% start in the middle of a source chunk only when the host already has the
%% needed cells and values.
%%
%% Index only commands/statements at first. Expression-level probing can be
%% added later, but it is not needed for interrupted execution.
%%
%% Ambiguous source positions should be rejected during compilation or resolved
%% by an explicit statement-position rule. Do not use the Fun term itself as a
%% stable key.
%%
%% =============================================================================
%% END TODO
%% =============================================================================

%% TODO: look up {Line, Column} in Program.conts and invoke the continuation.
%% The current implementation is a contract stub until closure lowering builds
%% the continuation vocabulary.
eval(_Line, _Column, _Program, _Runtime) ->
    throw(not_implemented).

%% TODO In order to reduce invocation cost:
%%   Exec = program(Line, Column, Interpreter)

%% -----------------------------------------------------------------------------
%% Compile pipeline — error Descriptor (aggregated from scan + parse)
%% -----------------------------------------------------------------------------
%% compile/2 runs: interpreter_scan:process/1 →
%% interpreter_parse:process/1 → interpreter:process/2 → inspect/1. On
%% failure, {error, {Line, Column, String}} (same tuple shape as scan/parse
%% steps) carries a normalized descriptor string (see tables in
%% interpreter_scan.xrl, interpreter_parse.yrl).
%%
%% Scan — Leex (interpreter_scan:process/1); Desc via format_error/1
%%
%% Origin          | Engine Descriptor    | Normalized Descriptor (string)
%% ----------------|----------------------|-------------------------------------
%% Leex engine     | {illegal, Character} | "unexpected characters \"...\""
%% Rule (Numbers)  | "illegal number"     | "illegal number"
%% Rule (Floats)   | "malformed number"   | "malformed number"
%% Rule (Strings)  | "illegal string"     | "illegal string"
%% Rule (Names)    | "illegal name"       | "illegal name"
%% Rule (Comments) | "unfinished ..."     | "unfinished long comment"
%%
%% Parse (interpreter_parse:process/1) — Yecc; Desc is string as returned
%%
%% Origin          | Type     | Example / Format
%% ----------------|----------|-------------------------------------------------
%% Yecc engine     | string   | "syntax error before: 'end'"
%% Rule (For loop) | string   | "illegal for"
%% Rule (Calls)    | string   | "illegal call"
%% -----------------------------------------------------------------------------

%% TODO compile/1
%% TODO Implement comments parsing and extraction from the tree.
%% TODO Implement Graph construction and navigation.
%% TODO Elaborate digraph usage if continuation lowering is not enough.
%% 
-spec compile(module(), code()) ->
    {ok, program()} | {error, {line(), column(), string()}}.
compile(Module, Code) ->
    maybe
        {ok, Scan} ?= interpreter_scan:process(Code),
        {ok, Tree} ?= interpreter_parse:process(Scan),
        
        _Program = process(Tree, Module)
    end.

%% TODO Lexical scope evaluation 
-spec process(program(), module()) -> program().
process([], _Module) ->
    {ok, _Program = fun () -> [] end};
process([_|_] = Tree, _Module) ->
    {ok, _Program = fun () -> Tree end}.

%% inspect/1 — optional compile pass after parse.
%% Today: identity. Intended hook for semantic checks before eval or embed.
%%
%% Contract for compile/2: inspect/1 must return {ok, Tree} | {error, Err}
%% so each ?= in the maybe … end block matches scan/parse (Err = {error, _}
%% for the else arm). Breaking that tuple shape breaks the pipeline without
%% touching the maybe expression itself.
%%
%% Established practice (Erlang compiler and similar pipelines):
%%   - Sequential passes: each step is fun(Forms) -> {ok, Forms} | {error, …}.
%%   - Lint-style: warnings vs errors; OTP uses return tuples and
%%     format_error/1 on the owning module.
%%   - Structural tree checks over tuples and lists.
%%   - Optional: Dialyzer, xref, or gradual typing are separate tools, not
%%     usually inlined here; same for eunit — tests are outside compile.
%%
%% Possible implementations (pick one or combine):
%%   - Structural: every parser tuple has a known primitive atom.
%%   - Semantic stubs: detect chunk/block shapes that still error(todo).
%%   - Policy: sandbox flags (forbid goto, forbid io) as data-driven rules.
%%   - Transform: desugar or annotate before closure lowering.
%%   - Metrics: depth/count of tuples for resource limits in embedders.

%% 
%% Parser primitive catalogue from interpreter_parse.yrl.
%%
%% The parser emits neutral Lua tuples `{Primitive, Line, Column, Args}`.
%% Closure lowering will turn these tuples into runtime Funs.
%%
%% =============================================================================
%% Parser primitive catalogue from interpreter_parse.yrl
%% =============================================================================
%%
%% Each item below names a parser primitive, gives a Lua 5.2 source shape that
%% reaches it, and records the lowering/runtime note. Parser helpers such as
%% functiondef/3, numeric_for/5, and dot_to_tree/1 also lower to these
%% primitive names.
%%
%% -----------------------------------------------------------------------------
%% Variables and assignment
%% -----------------------------------------------------------------------------
%%
%% Primitive: var
%% Lua:
%%   x
%% Comment:
%%   Raw NAME use. During process/2 lexical lowering, resolve x to
%%   {Cell, Keys}. Closure lowering captures Cell and Keys in the accessor
%%   Fun and calls Module:exec(Name, Cell, Keys) at runtime.
%%
%% Primitive: assign
%% Lua:
%%   x = 1
%%   a, b = b, a
%%   local x
%%   local x, y = 1, 2
%% Comment:
%%   Implements Lua assignment adjustment: evaluate RHS first, adjust result
%%   count to LHS count, then write each LHS. For locals, lowering must create
%%   the local binding before later statements, but initializer expressions
%%   resolve against the previous scope.
%%
%% Primitive: .
%% Lua:
%%   t.x
%%   t.x.y()
%% Comment:
%%   Parser uses dot_to_tree/1 to encode chained prefix access as nested
%%   '.' tuples. This is not lexical lookup; first resolve/evaluate the
%%   table expression, then apply Lua gettable/settable semantics.
%%
%% Primitive: key_field
%% Lua:
%%   t[k]
%%   { [k] = v }
%% Comment:
%%   In prefix access, key_field supplies the computed table key. In table
%%   constructors, it represents an explicit key-value field.
%%
%% -----------------------------------------------------------------------------
%% Literals and expression wrappers
%% -----------------------------------------------------------------------------
%%
%% Primitive: nil
%% Lua:
%%   nil
%% Comment:
%%   Produces Lua nil.
%%
%% Primitive: false
%% Lua:
%%   false
%% Comment:
%%   Produces Lua false.
%%
%% Primitive: true
%% Lua:
%%   true
%% Comment:
%%   Produces Lua true.
%%
%% Primitive: numeral
%% Lua:
%%   123
%%   1.5
%% Comment:
%%   Produces the scanner-normalized Lua number.
%%
%% Primitive: literalstring
%% Lua:
%%   "abc"
%%   'abc'
%% Comment:
%%   Produces a Lua string value. Decide binary vs list representation before
%%   host/library work expands.
%%
%% Primitive: single
%% Lua:
%%   (exp)
%% Comment:
%%   Parenthesized expression. Important because Lua adjusts multiple return
%%   values differently in parenthesized vs tail positions.
%%
%% Primitive: vararg
%% Lua:
%%   ...
%% Comment:
%%   Valid only in the immediately enclosing vararg function. Not an upvalue.
%%   Implement as callee-local runtime binding, not host exec/3 storage.
%%
%% -----------------------------------------------------------------------------
%% Operators
%% -----------------------------------------------------------------------------
%%
%% Primitive: op
%% Lua:
%%   a + b
%%   a == b
%%   a and b
%%   not a
%%   #a
%%   -a
%% Comment:
%%   Covers binary and unary operators. Must implement Lua 5.2 coercion,
%%   metamethods, truthiness, and short-circuit semantics. Note: parser also
%%   has //, &, |, ~, <<, >> rules; those are not Lua 5.2 language operators
%%   and should be treated as extension or removed for strict Lua 5.2.
%%
%% -----------------------------------------------------------------------------
%% Tables
%% -----------------------------------------------------------------------------
%%
%% Primitive: table
%% Lua:
%%   {}
%%   { a = 1, [k] = v, "x" }
%% Comment:
%%   Builds a table from field primitives. Must preserve Lua constructor
%%   order and array-field insertion index.
%%
%% Primitive: name_field
%% Lua:
%%   { a = 1 }
%% Comment:
%%   Syntactic sugar for string key "a".
%%
%% Primitive: exp_field
%% Lua:
%%   { "x", "y" }
%% Comment:
%%   Array-style field. Assigns to successive integer keys starting at 1.
%%
%% Primitive: key_field
%% Lua:
%%   { [k] = v }
%% Comment:
%%   Explicit table constructor key.
%%
%% -----------------------------------------------------------------------------
%% Blocks and control flow
%% -----------------------------------------------------------------------------
%%
%% Primitive: block
%% Lua:
%%   do
%%     local x = 1
%%   end
%% Comment:
%%   Evaluates a lexical block with its block cell installed in the activation.
%%
%% Primitive: local
%% Lua:
%%   local x = 1
%%   local function f() end
%% Comment:
%%   Parser wraps local_decl in local. Lowering must enforce declaration
%%   visibility and create local bindings/cells.
%%
%% Primitive: return
%% Lua:
%%   return
%%   return a, b
%% Comment:
%%   Stops the current function/chunk and returns adjusted values to caller.
%%   It is control flow, not just an expression value.
%%
%% Primitive: break
%% Lua:
%%   break
%% Comment:
%%   Exits nearest loop. Needs non-local control representation across block
%%   primitives.
%%
%% Primitive: while
%% Lua:
%%   while c do body end
%% Comment:
%%   Repeatedly evaluate condition in enclosing scope, body in loop block
%%   scope. Must handle break.
%%
%% Primitive: repeat
%% Lua:
%%   repeat body until c
%% Comment:
%%   Body runs before condition. In Lua, the until condition is inside the
%%   repeat block scope and can see locals declared in body.
%%
%% Primitive: if
%% Lua:
%%   if c then a() elseif d then b() else e() end
%% Comment:
%%   Evaluate conditions left-to-right. Each body is its own block scope.
%%
%% Primitive: elseif
%% Lua:
%%   elseif c then body
%% Comment:
%%   Parser helper for chained if. Could be lowered away during process/2.
%%
%% Primitive: else
%% Lua:
%%   else body
%% Comment:
%%   Parser helper for if fallback block. Could be lowered away.
%%
%% Primitive: for
%% Lua:
%%   for i = 1, 10, 2 do body end
%%   for k, v in pairs(t) do body end
%% Comment:
%%   numeric_for and generic_for both emit for with different arities.
%%   Numeric for owns hidden control state and visible loop variable.
%%   Generic for owns iterator state and visible name-list variables.
%%
%% Primitive: label
%% Lua:
%%   ::again::
%% Comment:
%%   Marks a goto target. No runtime variable cell, but lowering must validate
%%   goto rules and reject jumps into local-variable scope.
%%
%% Primitive: goto
%% Lua:
%%   goto again
%% Comment:
%%   Non-local jump inside a function. Needs validation plus runtime jump
%%   representation if implemented directly.
%%
%% -----------------------------------------------------------------------------
%% Functions and calls
%% -----------------------------------------------------------------------------
%%
%% Primitive: functiondef
%% Lua:
%%   function f(a) return a end
%%   local function g() return g end
%%   function(a) return a end
%% Comment:
%%   Creates a closure. Named function forms also assign the closure to the
%%   resolved target. Captures are copied from parent activation into the
%%   closure; parameters are installed when the closure is called.
%%
%% Primitive: functioncall
%% Lua:
%%   f(a, b)
%%   f "literal"
%%   f { x = 1 }
%% Comment:
%%   Calls a function value. Lua arguments are separate from hidden
%%   captured cells. Must implement argument/result adjustment.
%%
%% Primitive: methodcall
%% Lua:
%%   obj:m(a)
%% Comment:
%%   Syntactic sugar for obj.m(obj, a). Receiver is evaluated once and becomes
%%   implicit self argument.
%%
%% Primitive: method
%% Lua:
%%   function t:m(a) return self, a end
%% Comment:
%%   Parser marker in funcname for method definition. Lower to assignment of a
%%   closure whose parameter list starts with self.
%%
%% -----------------------------------------------------------------------------
%% Compatibility / scaffolding primitive clauses
%% -----------------------------------------------------------------------------
%%
%% Primitive: chunk
%% Lua:
%%   -- whole source file
%% Comment:
%%   Parser currently returns block content directly. A closure compiler may
%%   add an explicit chunk wrapper later.
%%
%% Primitive: stats, stat, explist, exp
%% Lua:
%%   -- internal grouping shapes
%% Comment:
%%   These are not direct parser tuple names in the current grammar. They are
%%   reserved for possible later lowering/evaluator layers.
%%
%% Runtime implementation checklist from current parser:
%%   var, assign, '.', key_field, nil, false, true, numeral, literalstring,
%%   single, vararg, op, table, name_field, exp_field, block, local, return,
%%   break, while, repeat, if, elseif, else, for, label, goto, functiondef,
%%   functioncall, methodcall, method.
%%
%% Existing helper/scaffold clauses not emitted directly by current parser:
%%   assert, fnew, fset, fcall, argv, chunk, stats, stat, explist, exp.
%%

%% wrap/1 is the closure-lowering entry point placeholder. Each clause below
%% mirrors one tuple primitive produced by interpreter_parse.yrl. Keep this
%% list explicit: adding or removing a parser primitive should change this
%% wrapper surface in the same patch.
wrap(Tree) when is_list(Tree) ->
    [wrap(Stat) || Stat <- Tree];
wrap({var, Line, Column, [Name]}) ->
    wrap(var, Line, Column, [Name]);
wrap({assign, Line, Column, [Vars, nil]}) ->
    wrap(assign, Line, Column, [Vars, nil]);
wrap({assign, Line, Column, [Vars, Exps]}) ->
    wrap(assign, Line, Column, [Vars, Exps]);
wrap({'.', Line, Column, [Head, {functioncall, FL, FC, [Args]}]}) ->
    wrap('.', Line, Column, [Head, {functioncall, FL, FC, [Args]}]);
wrap({'.', Line, Column, [Head, {methodcall, ML, MC, [Name, Args]}]}) ->
    wrap('.', Line, Column, [Head, {methodcall, ML, MC, [Name, Args]}]);
wrap({'.', Line, Column, [Head, {method, ML, MC, [Name]}]}) ->
    wrap('.', Line, Column, [Head, {method, ML, MC, [Name]}]);
wrap({'.', Line, Column, [Head, Tail]}) ->
    wrap('.', Line, Column, [Head, Tail]);
wrap({key_field, Line, Column, [Key]}) ->
    wrap(key_field, Line, Column, [Key]);
wrap({key_field, Line, Column, [Key, Value]}) ->
    wrap(key_field, Line, Column, [Key, Value]);
wrap({'nil', Line, Column, []}) ->
    wrap('nil', Line, Column, []);
wrap({'false', Line, Column, []}) ->
    wrap('false', Line, Column, []);
wrap({'true', Line, Column, []}) ->
    wrap('true', Line, Column, []);
wrap({numeral, Line, Column, [Value]}) ->
    wrap(numeral, Line, Column, [Value]);
wrap({literalstring, Line, Column, [Value]}) ->
    wrap(literalstring, Line, Column, [Value]);
wrap({single, Line, Column, [Exp]}) ->
    wrap(single, Line, Column, [Exp]);
wrap({vararg, Line, Column, []}) ->
    wrap(vararg, Line, Column, []);
wrap({op, Line, Column, [Op, Right]}) ->
    wrap(op, Line, Column, [Op, Right]);
wrap({op, Line, Column, [Op, Left, Right]}) ->
    wrap(op, Line, Column, [Op, Left, Right]);
wrap({table, Line, Column, [nil]}) ->
    wrap(table, Line, Column, [nil]);
wrap({table, Line, Column, [Fields]}) ->
    wrap(table, Line, Column, [Fields]);
wrap({name_field, Line, Column, [Name, Value]}) ->
    wrap(name_field, Line, Column, [Name, Value]);
wrap({exp_field, Line, Column, [Value]}) ->
    wrap(exp_field, Line, Column, [Value]);
wrap({block, Line, Column, [Body]}) ->
    wrap(block, Line, Column, [Body]);
wrap({local, Line, Column, [Decl]}) ->
    wrap(local, Line, Column, [Decl]);
wrap({return, Line, Column, Exps}) ->
    wrap(return, Line, Column, Exps);
wrap({break, Line, Column, []}) ->
    wrap(break, Line, Column, []);
wrap({while, Line, Column, [Cond, Body]}) ->
    wrap(while, Line, Column, [Cond, Body]);
wrap({repeat, Line, Column, [Body, Cond]}) ->
    wrap(repeat, Line, Column, [Body, Cond]);
wrap({'if', Line, Column, [Cond, Block, {'else', EL, EC, [Else]}]}) ->
    wrap('if', Line, Column, [Cond, Block, {'else', EL, EC, [Else]}]);
wrap({'if', Line, Column, [Cond, Block, []]}) ->
    wrap('if', Line, Column, [Cond, Block, []]);
wrap({'if', Line, Column,
      [Cond, Block, ElseIf, {'else', EL, EC, [Else]}]}) ->
    wrap('if', Line, Column,
         [Cond, Block, ElseIf, {'else', EL, EC, [Else]}]);
wrap({'if', Line, Column, [Cond, Block, ElseIf, []]}) ->
    wrap('if', Line, Column, [Cond, Block, ElseIf, []]);
wrap({elseif, Line, Column, [Cond, Body]}) ->
    wrap(elseif, Line, Column, [Cond, Body]);
wrap({elseif, Line, Column, [Cond, Body, ElseIf]}) ->
    wrap(elseif, Line, Column, [Cond, Body, ElseIf]);
wrap({for, Line, Column, [Var, Init, Limit, Body]}) ->
    wrap(for, Line, Column, [Var, Init, Limit, Body]);
wrap({for, Line, Column, [Var, Init, Limit, Step, Body]}) ->
    wrap(for, Line, Column, [Var, Init, Limit, Step, Body]);
wrap({for, Line, Column, [Names, Exps, Body]}) ->
    wrap(for, Line, Column, [Names, Exps, Body]);
wrap({label, Line, Column, [Name]}) ->
    wrap(label, Line, Column, [Name]);
wrap({goto, Line, Column, [Name]}) ->
    wrap(goto, Line, Column, [Name]);
wrap({functiondef, Line, Column, [Pars, Body]}) ->
    wrap(functiondef, Line, Column, [Pars, Body]);
wrap({functiondef, Line, Column, [Name, Pars, Body]}) ->
    wrap(functiondef, Line, Column, [Name, Pars, Body]);
wrap({';', _Line, _Column}) ->
    [].

wrap(Primitive, Line, Column, Args) ->
    {Primitive, Line, Column, Args}.

%% -------------------------------------------------------------
%% Runtime primitives.
%%
%% Thunks (below) are fun(() -> ...) /0: lexical reads and writes use
%% Module:exec(Name, Cell, Keys) or Module:exec(Name, Cell, Keys, Lua) with
%% Cell fixed at compile time.
%% No interpreter-level Frame is threaded through these primitives; any
%% host correlation stack or session record is entirely inside exec/3 and
%% exec/4.
%% -------------------------------------------------------------

assert(If) ->
    not falsy(If()).

assert(If, IfBody) ->
    case falsy(If()) of
        true ->
            false;
        false ->
            IfBody()
    end.

assert(If, IfBody, ElseBody) ->
    case falsy(If()) of
        false ->
            IfBody();
        true ->
            ElseBody()
    end.

assert(If, IfBody, Else, ElseBody) ->
    case falsy(assert(If, IfBody)) of
        false ->
            true;
        true ->
            assert(Else, ElseBody)
    end.

repeat(Body, Until) ->
    Body(),
    case falsy(Until()) of
        true ->
            repeat(Body, Until);
        false ->
            false
    end.

falsy(V) ->
    (V == false) orelse (V == 'nil').

%% TODO Assign does invocation of exec/4

assign([Var], [Val]) ->
    Var(Val);
assign([Var], []) ->
    Var('nil');
assign([Var|T], []) ->
    Var('nil'), assign(T, []);
assign([Var|T], [Val|Acc]) ->
    Var(Val), assign(T, Acc).
assign(Module, Vars, Vals)
        when is_atom(Module), is_list(Vars), is_list(Vals) ->
    assign(Vars, Vals).

binop('~=', L, R, _) ->
    erlang:'/='(L, R);
binop(Op, L, R, _) ->
    erlang:Op(L, R).

unop(Op, R, _) ->
    erlang:Op(R).

%% Placeholders (parse shapes `tableconstructor/2`, `(` /1).
tablecons(_M, _T) ->
    error(todo).

paren(_M, _E) ->
    error(todo).

%% Planned: `var('Module', NameString)` resolves an identifier via the host
%% storage callback / runtime binding contract. The parser already emits this
%% shape; runtime resolution is not implemented yet.
var(_M, _Name) ->
    error({not_implemented, var, resolver}).

%% ---------------------------------------------------------
%% Vararg + arity normalization.
%% All function/method invocations use list-based Lua
%% semantics: too few args → 'nil'; too many → dropped
%% unless vararg (...). argv/2 normalizes (Pars, Args).
%% ---------------------------------------------------------
%%
%% Variadic expression ... : compile-time construct.
%%   In Lua 5.2, ... is valid only in a function whose
%%   parlist includes '...'. No cell slot; codegen defers
%%   to caller-initiated values.
%%
%%   Last vs non-last position semantics:
%%     return ...         → last: full Vararg.
%%     return 1, ...      → last: [1 | Vararg].
%%     return 1, ..., 2   → non-last: [1, hd(Vararg), 2].
%%     local x, y = ...   → last: destructure from Vararg.
%%     print(...)         → last: pass Vararg as args.
%%     print(..., 1)      → non-last: [hd(Vararg), 1].
%%     {...}              → last: table from Vararg.
%%   Codegen checks "is ... last?" and emits accordingly.
%%
%%   §3.4.11: ... valid only in immediately enclosing
%%   function; no upvalue capture for vararg. Compile-time
%%   resolution is self-contained.
%% ---------------------------------------------------------

%% fnew(Module, Pars, Body, ScopeSpec) -> closure.
%%  ScopeSpec = compile-time closure recipe: call-time bindings plus
%%  creation-time captures of enclosing cells.
fnew(_Module, _Pars, _Body, _ScopeSpec) ->
    error(todo).

%% fset(Module, Name, Cell, Keys, Fun) -> ok.
%%  Assign named function in scope.
fset(_Module, _Name, _Cell, _Keys, _Fun) ->
    error(todo).

%% fcall(Module, Fun, Args) -> Result.
%%  Invoke function; arity/vararg via argv.
fcall(_Module, _Fun, _Args) ->
    error(todo).

%% argv(Pars, Args) -> {BoundParams, Vararg} | {BoundParams}.
%%  Normalize Args to Pars.
argv(_Pars, _Args) ->
    error(todo).

%% ---------------------------------------------------------
%% Scope construction: fixed code, no runtime tree traversal.
%% Compile time assigns lexical cells, classifies each variable
%% reference as relative or captured, and emits a ScopeSpec for
%% each function. Runtime closure creation evaluates enclosing
%% captures once and stores captured cells in the closure.
%% On function call, bind params/vararg in the callee cell and
%% copy captured upvalue cells from ScopeSpec. Cell is only the
%% value passed to exec/3 and exec/4; runtime primitives do not maintain
%% a separate Cell stack.
%% ---------------------------------------------------------

%% Semantic / tree layer stubs. Module is first arg (injected
%% by parser tuples; closure lowering is not implemented yet.
chunk(_Module, _Tree) ->
    error(todo).
block(_Module, _Tree) ->
    error(todo).
stats(_Module, []) ->
    error(todo);
stats(_Module, [_Node]) ->
    error(todo);
stats(_Module, [_Node|_Tree]) ->
    error(todo).
stat(_Module, _Node) ->
    error(todo).
retstat(_Module, _Node) ->
    error(todo).
explist(_Module, [_Node]) ->
    error(todo);
explist(_Module, [_Node|_Tree]) ->
    error(todo).
exp(_Module, _Node) ->
    error(todo).

%% =============================================================================
%% NOTES — Design and implementation notes; add or update below; keep markers.
%% =============================================================================
%%
%% Cell resolution rule
%% --------------------
%% A Cell names a lexical scope in host storage. Codegen resolves every
%% variable occurrence to Keys plus a Cell expression during closure lowering.
%% Runtime primitives receive thunks and call Module:exec(Name, Cell, Keys)
%% or Module:exec(Name, Cell, Keys, Lua) with the Cell expression already
%% embedded.
%%
%% There are two Cell access classes:
%%
%%   relative
%%     The declaration is in the current function activation: current block,
%%     a parent block, the chunk cell, or the global _ENV cell. The target is
%%     selected from the activation's cell arguments by generated code. It
%%     can be a direct argument, tuple/list index, or map lookup. Resolution
%%     and distance are compile-time facts; only applying the selector to the
%%     concrete cell arguments happens at runtime. No numeric relationship
%%     between Cell ids is required.
%%
%%   captured
%%     The declaration belongs to an enclosing function activation. The cell
%%     is selected from the parent activation's cell arguments when the
%%     function value is created, then stored in the closure ScopeSpec. Calls
%%     to that closure reuse the captured cell; they do not recompute it from
%%     the callee's current cell.
%%
%% Lookup rule:
%%   1. Search the current block, then parent blocks in the same function.
%%      Matches here are relative.
%%   2. If lookup crosses a function boundary, the match is an upvalue.
%%      Capture its cell when the closure is created.
%%   3. If no local/upvalue matches, lower Name to _ENV.Name. Resolve _ENV by
%%      this same rule. It is usually relative chunk/global state, but can be a
%%      captured upvalue when _ENV itself is captured.
%%
%% The interpreter never increments Cell at runtime. Nested Lua blocks
%% (if body, loop body, do ... end, function body, ...) receive distinct
%% Cell ids during lowering. Optional host-side frames, stacks, tenancy, ETS
%% keys, or GC are entirely inside the callback module and are orthogonal to
%% the Cell resolution rule.
%%
%% =============================================================================
%% Lua 5.2 lexical scope examples
%% =============================================================================
%%
%% Notation used below:
%%
%%   Activation
%%     Runtime call environment for a chunk or function invocation. It carries
%%     host/session identity and the cells available to compiled closures.
%%
%%   Lua variable binding
%%     {Cell, Keys}. Cell is captured by the generated closure. Keys names
%%     the Lua variable inside host storage for that cell.
%%
%%   Relative cell
%%     Cell is available in the current function activation.
%%
%%   Captured cell
%%     Cell is installed from a closure capture into the callee
%%     activation, for example 'Cap0'.
%%
%% -----------------------------------------------------------------------------
%% 1. Chunk global through _ENV
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   x = 1
%%   return x
%%
%% Scope:
%%   x is not declared local, so Lua 5.2 lowers it to _ENV.x.
%%   _ENV is an implicit local of the chunk.
%%
%% Binding:
%%   _ENV -> {Cell0, ["_ENV"]}
%%   x    -> {Cell0, ["_ENV", "x"]}
%%
%% Use:
%%   Cell0 is bound in the initial activation for the chunk.
%%
%% -----------------------------------------------------------------------------
%% 2. Local variable in a block
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   do
%%     local x = 1
%%     return x
%%   end
%%
%% Scope:
%%   x is local to the do-block. It is relative because the access happens in
%%   the same function activation.
%%
%% Binding:
%%   x -> {Cell1, ["x"]}
%%
%% Use:
%%   Entering the block evaluates its body with activation extended by
%%   Cell1. Cell1 is a cell number allocated by the host/runtime strategy;
%%   it is not derived by subtracting from Cell0.
%%
%% -----------------------------------------------------------------------------
%% 3. Local declaration visibility
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local x = x
%%   return x
%%
%% Scope:
%%   The new local x is visible only after the declaration statement. The
%%   right-hand x resolves to an outer x, usually _ENV.x. The returned x
%%   resolves to the new local.
%%
%% Binding:
%%   rhs x -> outer binding, often {Cell0, ["_ENV", "x"]}
%%   ret x -> local binding, for example {Cell0, ["x"]}
%%
%% -----------------------------------------------------------------------------
%% 4. Shadowing
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local x = 1
%%   do
%%     local x = 2
%%     return x
%%   end
%%
%% Scope:
%%   Inner x shadows outer x. Both are relative cells in the same function
%%   activation, but they use different Cells and/or Keys.
%%
%% Binding:
%%   outer x -> {Cell0, ["x"]}
%%   inner x -> {Cell1, ["x"]}
%%
%% -----------------------------------------------------------------------------
%% 5. Function parameters
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local function f(a, b)
%%     return a + b
%%   end
%%
%% Scope:
%%   Parameters are locals in the function body. A call passes Lua argument
%%   values; it does not pass hidden cell values through the Lua arg list.
%%
%% Binding:
%%   a -> {Cell0, ["a"]}
%%   b -> {Cell0, ["b"]}
%%
%% Use:
%%   fcall creates the callee cell, stores a and b there, then evaluates the
%%   body with activation containing the callee 'Cell0'.
%%
%% -----------------------------------------------------------------------------
%% 6. Vararg
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local function f(...)
%%     return ...
%%   end
%%
%% Scope:
%%   ... is valid only in the immediately enclosing vararg function. It is
%%   not an upvalue and is not captured by nested functions.
%%
%% Binding:
%%   ... should be represented by a callee-local activation variable or
%%   runtime slot, not by host exec/3 storage.
%%
%% -----------------------------------------------------------------------------
%% 7. Captured upvalue
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local x = 0
%%   local function inc()
%%     x = x + 1
%%     return x
%%   end
%%
%% Scope:
%%   x is declared in the enclosing function/chunk activation and used inside
%%   inc. The inner function captures the cell identity, not x's current Lua
%%   value.
%%
%% Parent binding:
%%   x -> {Cell0, ["x"]}
%%
%% Closure capture:
%%   Cap0 = Cell0
%%
%% Callee binding:
%%   x -> {Cap0, ["x"]}
%%
%% Use:
%%   Reads and writes in inc share the same host location as the outer x.
%%
%% -----------------------------------------------------------------------------
%% 8. Captured global through captured _ENV
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local function f()
%%     return print
%%   end
%%
%% Scope:
%%   print is _ENV.print. If f is created in a chunk where _ENV is available
%%   as Cell0, f captures the _ENV cell when needed.
%%
%% Parent binding:
%%   _ENV  -> {Cell0, ["_ENV"]}
%%   print -> {Cell0, ["_ENV", "print"]}
%%
%% Callee binding:
%%   print -> {Cap0, ["_ENV", "print"]}  where Cap0 is the captured _ENV cell.
%%
%% -----------------------------------------------------------------------------
%% 9. Numeric for
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   for i = 1, 3 do
%%     print(i)
%%   end
%%
%% Scope:
%%   i is local to the for body. The control variable is not visible after the
%%   loop. It is relative inside the loop activation/body.
%%
%% Binding:
%%   i -> {Cell1, ["i"]}
%%
%% -----------------------------------------------------------------------------
%% 10. Generic for
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   for k, v in pairs(t) do
%%     print(k, v)
%%   end
%%
%% Scope:
%%   k and v are locals in the loop body. Iterator state is runtime loop
%%   state; k and v are the visible Lua locals.
%%
%% Binding:
%%   k -> {Cell1, ["k"]}
%%   v -> {Cell1, ["v"]}
%%
%% -----------------------------------------------------------------------------
%% 11. Repeat condition sees block locals
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   repeat
%%     local x = next()
%%   until x == nil
%%
%% Scope:
%%   In Lua, the repeat condition is inside the loop block scope. x is visible
%%   to the until expression.
%%
%% Binding:
%%   x in body      -> {Cell1, ["x"]}
%%   x in condition -> {Cell1, ["x"]}
%%
%% -----------------------------------------------------------------------------
%% 12. Method definition and self
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   function t:m(a)
%%     return self, a
%%   end
%%
%% Scope:
%%   The colon form adds an implicit first parameter named self. self and a are
%%   function-body locals.
%%
%% Binding:
%%   self -> {Cell0, ["self"]}
%%   a    -> {Cell0, ["a"]}
%%
%% -----------------------------------------------------------------------------
%% 13. If and while bodies
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   if c then
%%     local x = 1
%%     return x
%%   end
%%
%%   while c do
%%     local y = 2
%%   end
%%
%% Scope:
%%   Each body block has its own lexical scope. Locals declared inside the body
%%   are not visible after the body. The condition expression is evaluated in
%%   the enclosing scope, not in the body scope.
%%
%% Binding:
%%   c -> enclosing binding
%%   x -> {Cell1, ["x"]}
%%   y -> {Cell1, ["y"]}
%%
%% -----------------------------------------------------------------------------
%% 14. Function statement and local function
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   function f()
%%     return 1
%%   end
%%
%%   local function g()
%%     return g()
%%   end
%%
%% Scope:
%%   function f() is assignment to f, so f follows normal variable lookup
%%   rules; at chunk level this is _ENV.f. local function g() creates a local
%%   g visible inside its own body, so recursion resolves to that local.
%%
%% Binding:
%%   f -> {Cell0, ["_ENV", "f"]} at chunk level
%%   g -> {Cell0, ["g"]}
%%
%% Use:
%%   The function value for g captures the cell containing g so recursive
%%   calls read the local g, not _ENV.g.
%%
%% -----------------------------------------------------------------------------
%% 15. Function expression assigned to local
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local f
%%   f = function()
%%     return f
%%   end
%%
%% Scope:
%%   The anonymous function captures the existing local f. This differs from
%%   local f = function() return f end only in the local-declaration
%%   visibility rule for the initializer expression.
%%
%% Binding:
%%   f outside body -> {Cell0, ["f"]}
%%   f inside body  -> {Cap0, ["f"]}
%%
%% -----------------------------------------------------------------------------
%% 16. Local _ENV
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local _ENV = env
%%   return x
%%
%% Scope:
%%   _ENV is just a lexical local with a special desugaring rule. Free name x
%%   resolves to _ENV.x, and this _ENV shadows the chunk _ENV.
%%
%% Binding:
%%   _ENV -> {Cell0, ["_ENV"]}
%%   x    -> {Cell0, ["_ENV", "x"]}
%%
%% Captured use:
%%   A nested function that reads x captures this local _ENV cell, then reads
%%   {Cap0, ["_ENV", "x"]}.
%%
%% -----------------------------------------------------------------------------
%% 17. Table fields are not lexical variables
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   local t = {}
%%   t.x = 1
%%   return t.x
%%
%% Scope:
%%   t is a lexical local. x is a table key, not a lexical binding and not a
%%   Cell. Field access is table semantics after t is resolved.
%%
%% Binding:
%%   t -> {Cell0, ["t"]}
%%
%% -----------------------------------------------------------------------------
%% 18. Labels and goto
%% -----------------------------------------------------------------------------
%%
%% Lua:
%%   goto label
%%   local x = 1
%%   ::label::
%%
%% Scope:
%%   goto has scope rules but no variable cell. Lua 5.2 forbids jumps into the
%%   scope of a local variable. This is a semantic validation rule during
%%   lowering/inspection, not a host exec/3 binding.
%%
%% Minimal Lua 5.2 interpreter (per standard)
%% ------------------------------------------
%% The standard (www.lua.org/manual/5.2) defines:
%%   (1) The language: §2 Basic concepts, §3 Syntax and semantics. That is the
%%       minimal interpreter: values and types, _ENV, expressions, statements,
%%       control flow, functions, tables, metatables. No library required by the
%%       language for correctness.
%%   (2) Standard libraries (§6): the manual describes their behavior so the
%%       reference implementation and embedders can provide compatible
%%       behavior. The reference host loads them into the global environment;
%%       an embedder may provide a subset.
%%
%% Basic library: implement or host-provide?
%% ----------------------------------------
%% The basic library (§6.1) can be implemented inside the interpreter or
%% supplied by the host (Erlang functions registered into _ENV). The manual
%% specifies behavior; either way is standard. Some functions are referenced
%% by the language semantics (e.g. type, getmetatable, rawget, tonumber in
%% §2.4), so a minimal runnable interpreter needs at least those, as
%% built-ins or host-provided. Recommendation: provide §6.1 (or a minimal
%% subset) as host-registered functions so the interpreter stays small and the
%% host controls what is available.
%%
%% Host-provided functions: part of the standard?
%% ----------------------------------------------
%% Yes. The manual §1: "The host program can ... register C functions to be
%% called by Lua code. Through the use of C functions, Lua can be augmented to
%% cope with a wide range of different domains." So registering host
%% (C/Erlang) functions is the standard extension mechanism. The *standard
%% library* is the set of functions the manual describes and that the
%% reference host puts in the global environment; a minimal interpreter can
%% supply a subset via the host and still be Lua 5.2 compliant for that
%% subset.
%%
%% Standard library: semantics-relevant vs pure library
%% ----------------------------------------------------
%% Strict "language spec" = lexical rules + formal grammar (syntax only). The
%% formal grammar is given in extended BNF in the manual's "Complete Syntax"
%% section: Lua 5.1 §8, Lua 5.2 §9.
%%   https://www.lua.org/manual/5.1/manual.html#8
%%   https://www.lua.org/manual/5.2/manual.html#9
%% The Lua Reference Manual also contains a semantic description (§2,
%% semantic parts of §3) that defines the meaning of operations in terms of
%% certain functions. We call those semantics-relevant: they are referenced in
%% that semantic description, not in the lexical/grammar spec. Ours: type,
%% getmetatable, setmetatable, rawget, rawset, rawlen, tonumber, tostring,
%% rawequal, error, pcall, xpcall. Pure library (only in §6, not used to
%% define meaning): print, dofile, loadfile, collectgarbage. Both groups are
%% standard library; use this split for minimal implementation scope.
%%
%% Where the manual's semantic description references them (Lua 5.2):
%%   §2.1 Values and Types: "The library function type returns a string
%%     describing the type of a given value (see §6.1)."
%%   §2.3 Error Handling: "Lua code can explicitly generate an error by
%%     calling the error function. If you need to catch errors in Lua, you
%%     can use pcall or xpcall to call a given function in protected mode."
%%   §2.4 Metatables and Metamethods: "You can query the metatable of any
%%     value using the getmetatable function." / "You can replace the
%%     metatable of tables using the setmetatable function."
%%   §2.4: "All functions used in these descriptions (rawget, tonumber, etc.)
%%     are described in §6.1. In particular, to retrieve the metamethod ...
%%     rawget(getmetatable(obj) or {}, event)". The illustrative code for
%%     add_event, unm_event, concat_event, len_event, gettable_event,
%%     settable_event, function_event uses type, getmetatable, tonumber,
%%     rawget, rawset, error.
%%   See:  https://www.lua.org/manual/5.2/manual.html#2.1
%%         https://www.lua.org/manual/5.2/manual.html#2.3
%%         https://www.lua.org/manual/5.2/manual.html#2.4
%%
%% Host-based variable storage (exec/3, exec/4)
%% --------------------------------------------
%% Variables live in the host, not in the interpreter. The interpreter only
%% issues read/write via exec(Name, Cell, Keys) and exec(Name, Cell, Keys, Lua).
%% The callback Module is pre-compiled (fixed at codegen); no ENV/key
%% resolution.
%% Advantages:
%%   - Storage backend is pluggable: in-memory map, ETS, DB, or remote
%%     (e.g. AWS). Same Lua code can run against different backends by
%%     swapping the host module.
%%   - Persistence and durability: host can persist cells/keys; interpreter
%%     stays stateless. Enables "resumable" or distributed execution.
%%   - Observability and control: host can log, rate-limit, or audit every
%%     variable read/write without changing the interpreter.
%%   - Resource limits: host can enforce quotas, eviction, or size limits per
%%     Name/Cell (e.g. "unlimited variables store based on AWS backend").
%%   - Multi-tenant or multi-context: Name (e.g. process/session id) isolates
%%     environments; one interpreter process can serve many logical Lua runs.
%%   - GC and lifecycle: host can release or compact storage when a cell/scope
%%     is no longer reachable, without interpreter-side GC.
%%   - Ra (Raft): exec/3 and exec/4 map to ra state-machine commands and
%%     queries. Name selects the ra cluster or log group; exec/4 (write)
%%     submits a command to the leader; exec/3 (read) may query a local
%%     replica at the consistency level the host chooses. Since the
%%     interpreter holds no mutable state between callbacks, a node that
%%     crashes and rejoins can resume Lua execution via eval/4 from any
%%     line/column once ra has restored the committed cells.
%%
%% Ra (Raft) leader-only Lua execution
%% ------------------------------------
%% The design guarantees that eval/4 (Lua code execution) runs only on
%% the ra cluster leader. Followers act as state replicas only.
%%
%% Effect guarantee
%%   ra apply/3 runs on every cluster node. Effects returned by apply/3
%%   execute only on the leader; followers discard them. The {mod_call,
%%   Mod, Fun, Args} effect is leader-only. Mapping:
%%     exec/4 (write)   -> ra command : replicated to all nodes
%%     exec/3 (read)    -> ra query   : any node (host chooses level)
%%     eval/4 (execute) -> ra effect  : leader only, never on followers
%%
%% Failover gap
%%   If the leader commits {run, RunId, Name, Code} and then crashes,
%%   the new leader has the log entry but will not re-fire its effect.
%%   Fix:
%%     1. State machine records RunId in its pending map on submission.
%%     2. Implement state_enter(leader, State) -> Effects in ra_machine.
%%        ra calls it when this node becomes leader. Return
%%        {mod_call, my_host, execute, [RunId, Name, Code]} for each
%%        RunId still in pending. The new leader re-fires unfinished
%%        scripts automatically.
%%
%% Completion
%%   After eval/4 finishes, submit {done, RunId} as a ra command. The
%%   state machine removes it from pending so state_enter does not
%%   re-fire it after the next leader election.
%%
%% Idempotency
%%   Narrow window: eval/4 completes but {done, RunId} is not committed
%%   before the leader crashes. The new leader re-fires execute/2 for
%%   that RunId. Since exec/4 writes cells incrementally and those
%%   writes are in the ra log, execute/2 can check the last committed
%%   {Line, Column} for RunId and call eval/4 from that point instead
%%   of re-running from the top.
%%
%% Agentic Lua 5.2 workflow
%% ------------------------
%% Lua 5.2 scripts in this interpreter are generated by a large language
%% model (LLM). The LLM acts as the agent; Lua is its action language.
%%
%% LLM as script generator
%%   The LLM receives a prompt describing a task and the host-available
%%   functions. It responds with a Lua 5.2 source string. The host
%%   submits that string to compile/2, then eval/4. The interpreter
%%   executes it on the ra leader; state mutations persist via exec/4.
%%
%% Tool-use as _ENV bindings
%%   Host functions registered in _ENV are the LLM's tools. The LLM
%%   calls them by writing Lua function calls. The host controls _ENV
%%   exactly: the LLM can only call what the host explicitly provides.
%%   No shell access, file I/O, or network unless the host registers
%%   those functions. This is a hard sandbox boundary.
%%
%% Auditability
%%   Every variable read and write by LLM-generated code goes through
%%   exec/3 and exec/4. The host can log, rate-limit, or reject any
%%   state mutation without modifying the interpreter. The ra log also
%%   records every committed write command, giving a full audit trail.
%%
%% Agent session identity
%%   Name in exec/3 and exec/4 identifies the LLM agent session. Each
%%   invocation gets a unique Name; cells are isolated per Name. Multiple
%%   concurrent LLM agents can share one ra cluster without interference.
%%
%% Multi-step agentic loop
%%   The host can run the LLM in a loop:
%%     1. LLM generates Lua code given task + current state summary.
%%     2. Host submits {run, RunId, Name, Code} to ra.
%%     3. eval/4 executes on leader; results land in cells via exec/4.
%%     4. Host reads result cells via exec/3 (ra local query).
%%     5. Host feeds results back to LLM as next prompt context.
%%     6. Repeat until task done or budget exhausted.
%%   Each loop iteration is a distinct RunId; the ra pending map tracks
%%   completion. Leader failover between steps is handled transparently.
%%
%% Resume after partial execution
%%   If LLM-generated code fails at {Line, Column}, the host can:
%%     a. Query the LLM to generate a repair script starting from the
%%        known-good state (cells already committed via exec/4).
%%     b. Or restart from {Line, Column} via eval/4 once the failure
%%        cause is resolved, without re-running preceding statements.
%%   This enables fine-grained recovery without re-executing side effects
%%   that already completed.
%%
%% Determinism and reproducibility
%%   Given the same ra cell state, the same Lua script always produces
%%   the same exec/4 writes. LLM-generated scripts are therefore
%%   testable in isolation: replay the ra log to restore cells, re-run
%%   the script, compare exec/4 call sequences.
%%
%% Setup via iterator/1 + next/1
%% ------------------------------
%%   iterator(Opts) -> iterator().  Constructor; cf. maps:iterator/1.
%%   next(Iterator) -> {[key()], lua(), iterator()} | none.
%%   Host pulls standard bindings (type, pairs, ipairs, pcall, next, rawget,
%%   rawset, getmetatable, setmetatable, ...) one at a time via next/1.
%%   iterator/1 does NOT call exec/4 — different mechanism for different
%%   phase:
%%     setup:   iterator/1 + next/1 (pull-based, host drives, no scoping)
%%     runtime: exec/3, exec/4 (scoped by Name/Cell/Keys, called repeatedly)
%%   Naming: iterator/1 is a constructor, next/1 is the step function.
%%   Implementations are pre-built Erlang funs; no Lua source compiled.
%%
%% Execution (tree + closures)
%% ---------------------------
%%   Parser (interpreter_parse.yrl) builds neutral Lua tuples:
%%     {Primitive, Line, Column, Args}.
%%   compile/2 currently returns that tree after process/2 and inspect/1.
%%   The next runtime step is closure lowering: tuples become Erlang Funs that
%%   capture resolved Cell/Keys and call runtime primitives explicitly.
%%
%% -----------------------------------------------------------------------------
%% Literal Pool
%% -----------------------------------------------------------------------------
%%
%% Problem: closure captures carry literals
%% ----------------------------------------
%% Closure lowering embeds every Lua literal — numbers, strings, pre-known
%% table field keys — directly into fun object captures. A fun that returns
%% the string "hello" carries that binary on the process heap. A program with
%% N statement closures each referencing the same literal produces N separate
%% references (potentially N copies if the binary is small enough to be inlined
%% rather than reference-counted). When the program is sent to a Ra leader via
%% message passing it is deep-copied, dragging every captured literal with it.
%% During GC, every minor collection scans all live closure captures including
%% those literals. For LLM-generated scripts where literals dominate (the LLM
%% writes concrete values; the dynamic parts are only variable reads and writes)
%% this overhead is disproportionate to the actual runtime work.
%%
%% HAMT churn
%% ----------
%% Erlang maps are persistent (immutable, structurally shared). An update
%% path-copies only the nodes from root to the changed leaf and shares all other
%% subtrees with the previous version. The discarded path nodes immediately
%% become garbage. Updating a map key on every statement evaluation — for
%% example storing a loop counter or vararg in Runtime — produces a steady
%% stream of short-lived allocation even though the logical map does not grow.
%% The GC must collect it. Because the continuation chain is a long-lived root,
%% every minor collection scans and copies the whole chain; if the chain is
%% large, minor GC becomes expensive relative to the per-statement work.
%% For maps with 32 or fewer keys Erlang uses a flat tuple pair (not a trie),
%% so the per-update cost is lower but still non-zero allocation. Keeping
%% Runtime thin — session identity only, no mutable slots — avoids this class
%% of allocation entirely for the statement-level hot path.
%%
%% Optimization tier 1 — scalar literal pool in persistent_term
%% -------------------------------------------------------------
%% During process/2, extract every scalar literal (numbers, strings, booleans)
%% from the AST and assign each a slot index in a flat tuple. Store the tuple
%% once in persistent_term keyed by the program's MD5 hash. Closure lowering
%% captures the integer index instead of the value itself.
%%
%%   Before: fun(_Rt) -> {<<"configuration">>, _Rt} end
%%           %% binary is in fun captures on process heap; copied with the fun
%%
%%   After:  fun(_Rt) -> {element(7, persistent_term:get(Key)), _Rt} end
%%           %% fun captures only integer 7; pool lives in persistent_term
%%
%% Benefits:
%%   - Message passing to Ra leader copies only integers. The pool is already
%%     in persistent_term and requires zero copying regardless of cluster
%%     topology or how many times the script is submitted.
%%   - The same literal appearing N times in one script is stored once. All N
%%     closures reference the same pool slot by index.
%%   - MD5-keyed pools deduplicate across sessions: the same Lua source
%%     compiled twice by different LLM sessions shares one pool entry.
%%   - persistent_term reads are pointer dereferences — no allocation, no GC
%%     write barrier, no HAMT traversal.
%%
%% Optimization tier 2 — table constructor literal base
%% -----------------------------------------------------
%% A table constructor mixes literal and dynamic fields:
%%
%%   { a = 1, b = "key", c = t.x }
%%
%% Fields a and b are fully known at compile time. Field c requires a runtime
%% lookup. The two kinds can be separated during process/2:
%%
%%   compile time : literal_base = #{<<"a">> => 1, <<"b">> => <<"key">>}
%%                  stored in the literal pool (tier 1 above)
%%
%%   eval time    : evaluate only c = t.x, then merge into a copy of
%%                  literal_base
%%
%% The runtime constructor fun evaluates only the dynamic fields and calls a
%% single merge step. For LLM-generated configuration tables — common in
%% agentic scripts where the LLM emits complete data structures — nearly all
%% fields are literal. The constructor fun becomes nearly free.
%%
%% Optimization tier 3 — host as table factory (prepared statement pattern)
%% -------------------------------------------------------------------------
%% Extending the principle that the host owns storage: the interpreter can
%% describe the table schema to the host at compile time and let the host
%% allocate the base structure. At eval time the interpreter only submits the
%% dynamic field bindings.
%%
%%   compile: describe schema to host → host returns opaque handle H
%%   eval:    exec(Name, H, [dynamic_keys], [dynamic_values])
%%            → host builds the table from the pre-allocated base + bindings
%%
%% This maps directly onto the database prepared statement pattern: the plan
%% is fixed at compile time; the bind variables are runtime. The host controls
%% the table representation entirely — it may use an ETS record, a C struct
%% via NIF, or any backend appropriate for the deployment. The interpreter
%% never constructs a Lua table as an Erlang term at all.
%%
%% This is the natural extension of the existing design principle: host owns
%% storage, interpreter drives logic. Extending that boundary to cover table
%% construction means table value identity and layout also belong to the host.
%%
%% Responsibility boundary with literal pool active
%% -------------------------------------------------
%%
%%   Scalar literals            process heap → literal pool (persistent_term)
%%   Literal table fields       process heap → literal base in pool (tier 2)
%%   Dynamic field evaluation   runtime funs, thin captures (indices only)
%%   Table value identity       host factory handle (tier 3, optional)
%%   Variable reads/writes      host exec/3 and exec/4 (existing contract)
%%   Control flow sequencing    closure chain (unchanged)
%%
%% After applying tiers 1 and 2, closure captures shrink to small integers.
%% Minor GC scans them in constant time. Message passing copies them cheaply.
%% The program as a whole can live in persistent_term and is shared across all
%% Ra leader evaluations without any per-eval allocation for the compiled plan.
%%
%% -----------------------------------------------------------------------------
%% Command — cursor, executable, and capability token
%% -----------------------------------------------------------------------------
%%
%% command() is defined as fun(() -> erl()). It is the unit of execution passed
%% between the interpreter and the host. Each command() is three things at once:
%%
%%   Executable
%%     Calling the fun runs the compiled program from the point it represents.
%%     Closure lowering produces one command() per statement; each captures its
%%     successor as an ordinary Erlang closure value. The chain is built right-
%%     to-left; execution runs left-to-right.
%%
%%   Cursor
%%     The host holds the command() reference between interpreter calls. It is
%%     the execution pointer: after eval/4 returns, the host owns the current
%%     position in the program. On resume the host passes the command() directly.
%%     No lookup or position resolution is needed — the interpreter receives the
%%     callable and invokes it. The interpreter is stateless; the cursor lives in
%%     the host.
%%
%%   Capability token
%%     The identity of the command() tells the host which effect is about to be
%%     requested through exec/3 or exec/4. The host can use the paired
%%     {Line, Column} — kept alongside the command() in the host's own state —
%%     to make per-cursor decisions before or during execution.
%%
%% Host options when holding a command()
%% --------------------------------------
%% The host has four distinct options for any command() it holds:
%%
%%   Execute
%%     Call the fun directly to run the program from this point. The normal
%%     path for eval/4.
%%
%%   Gate exec/4 by cursor identity
%%     exec/3 is a read; exec/4 is a write. Reads are unconditionally safe to
%%     re-execute. Writes should be gated: the host tracks which cursor positions
%%     have already produced committed writes. If the cursor's write is already
%%     in the committed record, the host exec/4 implementation returns without
%%     applying the effect again. The command() identity — recorded by
%%     {Line, Column} in the host's own log — is the idempotency key for exec/4.
%%     This is the host's responsibility; the interpreter always calls exec/4
%%     when lowered code reaches a write; the host implementation absorbs the
%%     idempotency check.
%%
%%   Defer
%%     The host may hold the command() and decide when to invoke it: budget
%%     control, scheduling, or ordering relative to other sessions. The fun is
%%     an ordinary Erlang term; it can be stored in process state, ETS, or
%%     passed in a message. Nothing in the interpreter needs to be notified.
%%
%%   Discard
%%     If execution should not continue — budget exhausted, policy violation,
%%     session cancelled — the host simply does not call the command(). No
%%     interpreter state requires cleanup.
%%
%% Cursor monotonicity
%% -------------------
%% The cursor moves forward only. A command() represents "everything before this
%% point is committed; this is the next unit of work." The host enforces
%% monotonicity: it never submits a command() for a position whose effects are
%% already in the committed record. This makes interrupted-execution recovery
%% safe — resuming at a cursor cannot re-apply effects that already completed.
%%
%% Compilation per cluster member and recovery on leader loss
%% ----------------------------------------------------------
%% Each Ra state machine member compiles the Lua source independently.
%% The natural place is the apply/3 callback: when a {run, RunId, Source}
%% command is applied, every member compiles Source and stores the resulting
%% program in state. Every member is then ready to become leader without a
%% separate compilation step on election. Compilation is deterministic — the
%% same source produces structurally identical continuation chains — so the
%% program shape is consistent across the cluster even though each member
%% holds distinct Fun heap objects.
%%
%% On leader loss the new leader already holds a compiled program. The
%% challenge is locating the resume point given that Fun references differ
%% per node:
%%
%%   Re-execute with idempotent exec/4
%%     The new leader re-runs the program from the beginning. exec/4 is
%%     implemented to be idempotent: if the Ra log already contains a
%%     committed write for a given statement, the host returns without
%%     applying the effect again. Read-only exec/3 calls are always safe
%%     to re-execute. This approach requires no resume-point mechanism;
%%     the idempotency check in exec/4 is sufficient.
%%
%%   Statement ordinal in Ra log
%%     Each apply/3 records the ordinal of the last completed statement.
%%     The new leader counts N steps into its own compiled chain to reach
%%     the resume Fun. Works for linear programs; requires additional design
%%     for branching control flow.
%%
%% Both ideas share the same constraint: the Ra log must not store Fun
%% references. Funs are session-local; only serializable values (ordinals,
%% RunId, committed write markers) belong in the log.
%%
%% -----------------------------------------------------------------------------
%% Gemini Architectural Analysis & Detailed Library Classification
%% -----------------------------------------------------------------------------
%%
%% Core Identity & Design Philosophy
%% ---------------------------------
%%   This project is a highly integrated Lua 5.2 interpreter built for 
%%   embedding in ERTS. It prioritizes safety, isolation, and flexibility 
%%   by using a "tree-based" traversal rather than BEAM bytecode 
%%   compilation.
%%
%% Pros/Cons of Traversal (Tree-Based)
%% --------------------------------------------
%%   Pros:
%%     - Zero-Latency: Immediate execution without code-loading overhead.
%%     - Sandboxing: function gating via local and non-local handlers.
%%     - State Isolation: Execution state is just Erlang data on the heap.
%%     - Atom Safety: No atom table exhaustion from dynamic module loading.
%%   Cons:
%%     - Performance: Significantly slower than native BEAM bytecode.
%%     - Memory: AST storage is heavier than compact bytecode modules.
%%     - Optimization: Bypasses BEAM's native compiler optimizations.
%%
%% Lua 5.2 Standard Library Classification (Complete)
%% --------------------------------------------------
%%   Legend: C=Core Primitive, H=High Priority, M=Medium, L=Low (Sandboxed)
%%
%%   Object   | Method          | Cat | Description
%%   ---------|-----------------|-----|-----------------------------------------
%%   _G       | _G              | C   | Reference to global environment table
%%   _G       | _VERSION        | H   | Current interpreter version string
%%   _G       | assert          | H   | Check condition; error if false/nil
%%   _G       | collectgarbage  | L   | Interface to garbage collector
%%   _G       | dofile          | L   | Opens and executes a Lua file
%%   _G       | error           | C   | Terminates last protected function
%%   _G       | getmetatable    | C   | Returns metatable of an object
%%   _G       | ipairs          | H   | Returns iterator for arrays (1..n)
%%   _G       | load            | L   | Loads chunk from string or function
%%   _G       | loadfile        | L   | Loads chunk from a file
%%   _G       | next            | H   | Traverses all fields of a table
%%   _G       | pairs           | H   | Returns iterator for all table fields
%%   _G       | pcall           | C   | Calls function in protected mode
%%   _G       | print           | H   | Receives args and prints them
%%   _G       | rawequal        | C   | Checks equality without metamethods
%%   _G       | rawget          | C   | Gets value without metamethods
%%   _G       | rawlen          | C   | Returns length without metamethods
%%   _G       | rawset          | C   | Sets value without metamethods
%%   _G       | select          | H   | Returns args after index or total count
%%   _G       | setmetatable    | C   | Sets metatable for a table
%%   _G       | tonumber        | H   | Converts argument to a number
%%   _G       | tostring        | H   | Converts argument to a string
%%   _G       | type            | C   | Returns type of argument as string
%%   _G       | xpcall          | C   | Calls function with custom error handler
%%   ---------|-----------------|-----|-----------------------------------------
%%   coroutine| create          | M   | Creates new coroutine from function
%%   coroutine| resume          | M   | Starts/continues coroutine execution
%%   coroutine| running         | M   | Returns running coroutine or nil
%%   coroutine| status          | M   | Returns status of coroutine as string
%%   coroutine| wrap            | M   | Creates function that resumes coroutine
%%   coroutine| yield           | M   | Suspends execution of calling coroutine
%%   ---------|-----------------|-----|-----------------------------------------
%%   table    | concat          | H   | Concatenates table elements to string
%%   table    | insert          | H   | Inserts element at given position
%%   table    | pack            | H   | Returns new table with all arguments
%%   table    | remove          | H   | Removes element from given position
%%   table    | sort            | H   | Sorts table elements in given order
%%   table    | unpack          | H   | Returns elements from given table
%%   ---------|-----------------|-----|-----------------------------------------
%%   string   | byte            | H   | Returns numerical codes of characters
%%   string   | char            | H   | Returns string from numerical codes
%%   string   | dump            | M   | Returns binary representation of fun
%%   string   | find            | H   | Looks for first match of a pattern
%%   string   | format          | H   | Returns formatted version of args
%%   string   | gmatch          | H   | Returns iterator for pattern matching
%%   string   | gsub            | H   | Returns copy with substitutions
%%   string   | len             | H   | Returns length of the string
%%   string   | lower           | H   | Returns copy of string in lowercase
%%   string   | match           | H   | Searches for first match of a pattern
%%   string   | rep             | H   | Returns string concatenated n times
%%   string   | reverse         | H   | Returns string with characters reversed
%%   string   | sub             | H   | Returns substring from index i to j
%%   string   | upper           | H   | Returns copy of string in uppercase
%%   ---------|-----------------|-----|-----------------------------------------
%%   math     | abs             | M   | Returns absolute value of x
%%   math     | acos            | M   | Returns arc cosine of x
%%   math     | asin            | M   | Returns arc sine of x
%%   math     | atan            | M   | Returns arc tangent of x
%%   math     | atan2           | M   | Returns arc tangent of y/x
%%   math     | ceil            | M   | Returns smallest integer >= x
%%   math     | cos             | M   | Returns cosine of x
%%   math     | cosh            | M   | Returns hyperbolic cosine of x
%%   math     | deg             | M   | Converts radians to degrees
%%   math     | exp             | M   | Returns value e^x
%%   math     | floor           | M   | Returns largest integer <= x
%%   math     | fmod            | M   | Returns remainder of x/y
%%   math     | frexp           | M   | Decomposes number into mantissa/exp
%%   math     | huge            | M   | Value larger than any other number
%%   math     | ldexp           | M   | Returns m*2^e
%%   math     | log             | M   | Returns logarithm of x
%%   math     | max             | M   | Returns maximum value among args
%%   math     | min             | M   | Returns minimum value among args
%%   math     | modf            | M   | Returns integer and fractional parts
%%   math     | pi              | M   | The value of Pi
%%   math     | pow             | M   | Returns x^y
%%   math     | rad             | M   | Converts degrees to radians
%%   math     | random          | M   | Returns pseudo-random number
%%   math     | randomseed      | M   | Sets seed for pseudo-random generator
%%   math     | sin             | M   | Returns sine of x
%%   math     | sinh            | M   | Returns hyperbolic sine of x
%%   math     | sqrt            | M   | Returns square root of x
%%   math     | tan             | M   | Returns tangent of x
%%   math     | tanh            | M   | Returns hyperbolic tangent of x
%%   ---------|-----------------|-----|-----------------------------------------
%%   bit32    | arshift         | M   | Arithmetic right shift of x by disp
%%   bit32    | band            | M   | Bitwise logical AND of arguments
%%   bit32    | bnot            | M   | Bitwise logical NOT of x
%%   bit32    | bor             | M   | Bitwise logical OR of arguments
%%   bit32    | btest           | M   | Returns boolean; (AND) is not zero
%%   bit32    | bxor            | M   | Bitwise logical XOR of arguments
%%   bit32    | extract         | M   | Returns unsigned field from x
%%   bit32    | replace         | M   | Returns copy of x with field replaced
%%   bit32    | lrotate         | M   | Logical left rotation of x by disp
%%   bit32    | lshift          | M   | Logical left shift of x by disp
%%   bit32    | rrotate         | M   | Logical right rotation of x by disp
%%   bit32    | rshift          | M   | Logical right shift of x by disp
%%   ---------|-----------------|-----|-----------------------------------------
%%   package  | config          | L   | String describing compile configs
%%   package  | cpath           | L   | Path used to search for C loader
%%   package  | loaded          | L   | Table used to control modules
%%   package  | loadlib         | L   | Dynamically links host with library
%%   package  | path            | L   | Path used to search for Lua loader
%%   package  | preload         | L   | Table to store loaders for modules
%%   package  | require         | L   | Loads the given module
%%   package  | searchers       | L   | Table used to control how to find
%%   package  | searchpath      | L   | Searches for file in a given path
%%   ---------|-----------------|-----|-----------------------------------------
%%   io       | close           | L   | Closes default output file
%%   io       | flush           | L   | Saves data to default output file
%%   io       | input           | L   | Sets or gets default input file
%%   io       | lines           | L   | Iterator function over file lines
%%   io       | open            | L   | Opens file in specified mode
%%   io       | output          | L   | Sets or gets default output file
%%   io       | popen           | L   | Starts program in separated process
%%   io       | read            | L   | Reads from default input file
%%   io       | tmpfile         | L   | Returns handle for temporary file
%%   io       | type            | L   | Checks if object is valid file handle
%%   io       | write           | L   | Writes to default output file
%%   (file)   | close           | L   | Closes the file
%%   (file)   | flush           | L   | Saves written data to the file
%%   (file)   | lines           | L   | Returns iterator over file lines
%%   (file)   | read            | L   | Reads from the file
%%   (file)   | seek            | L   | Sets and gets file position
%%   (file)   | setvbuf         | L   | Sets buffering mode for output file
%%   (file)   | write           | L   | Writes to the file
%%   ---------|-----------------|-----|-----------------------------------------
%%   os       | clock           | M   | Returns approximation of CPU time
%%   os       | date            | M   | Returns string or table with date/time
%%   os       | difftime        | M   | Returns difference in secs (t1 - t2)
%%   os       | execute         | L   | Calls OS shell to execute command
%%   os       | exit            | L   | Terminates the host program
%%   os       | getenv          | L   | Returns value of environment variable
%%   os       | remove          | L   | Deletes file with the given name
%%   os       | rename          | L   | Renames a file or directory
%%   os       | setlocale       | L   | Sets current locale of the program
%%   os       | time            | M   | Returns the current time
%%   os       | tmpname         | L   | Returns filename for a temp file
%%   ---------|-----------------|-----|-----------------------------------------
%%   debug    | debug           | L   | Enters interactive mode with user
%%   debug    | getuservalue    | L   | Returns Lua value with userdata
%%   debug    | gethook         | L   | Returns current hook settings
%%   debug    | getinfo         | L   | Returns info about a function
%%   debug    | getlocal        | L   | Returns name/value of local variable
%%   debug    | getmetatable    | L   | Returns metatable of given object
%%   debug    | getregistry     | L   | Returns the registry table
%%   debug    | getupvalue      | L   | Returns name/value of an upvalue
%%   debug    | setuservalue    | L   | Sets Lua value with userdata
%%   debug    | sethook         | L   | Sets a debug hook
%%   debug    | setlocal        | L   | Sets value of a local variable
%%   debug    | setmetatable    | L   | Sets metatable for given object
%%   debug    | setupvalue      | L   | Sets the value of an upvalue
%%   debug    | upvalueid       | L   | Returns unique ID for an upvalue
%%   debug    | upvaluejoin     | L   | Joins two upvalues from closures
%%
%% =============================================================================
%% END NOTES
%% =============================================================================

-spec md5(code()) -> <<_:_*16>>.
md5(Code) ->
    binary:encode_hex(_Md5 = erlang:md5(Code)).
