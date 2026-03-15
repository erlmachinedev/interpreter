-module(interpreter).

%% Lua 5.2 interpreter embedded in ERTS
%%
%% This module serves three roles:
%%   1. Behaviour definition — host implements exec/3, exec/4 callbacks.
%%   2. Runtime primitives (assert, assign, exec, etc.) — called via LFH,
%%      not exported. gen_statem controls evaluation via eval/4 callback.
%%   3. Public API: run/2, compile/2, handler/0, iterator/1, next/1.
%%
%% Pipeline: tokenization → parse (+ Merl inject) → erl_eval + LFH + EFH.
%%   - run/2(Module, Code) → lua(). Module cannot be undefined.
%%   - process/2(Tokens, Module) → Body with Module injected.
%%   - erl_eval:exprs(Body, [], {value, LFH}, {value, EFH}).
%%   - LFH (route/2): local calls → primitives (assign, block, …).
%%   - EFH (guard/2): Module:exec/eval → callback module (security
%%     gated; only exec and eval allowed; other calls rejected).
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

-optional_callbacks([eval/4]).

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
%%       function defs)
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
%% END READ
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
%%   - getmetatable(object), setmetatable(table, metatable).
%%   - select(index, ...), load(chunk [, chunkname [, mode [, env]]]). select is
%%     supplied as part of the standard library (§6.1); use with ... for vararg.
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
%%   - Lexical scoping: chunk, block, control bodies, function body (see
%%     NOTES re. cell increment).
%%   - Scopes resolved at compile time (transformed into cells); variables
%%     into host API calls.
%%   - Function call and scope entrance increment the next cell.
%%   - Grammar: fix reduce conflicts if any; ref. Lua 5.2 manual §3.
%%   - Evaluators for statements, expressions, literals: lowered closure
%%     conversion.
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

%% Public API:
%%   Run:       run/2       Lua source → lua() (scan → parse → eval)
%%   Setup:     iterator/1  create iterator over §6.1 bindings
%%              next/1       pull next {Keys, Value, Iterator} | none
%%   Transform: compute/1   Lua source → content hash (MD5 hex)
%%   LFH:      handler/0   LocalFunctionHandler for erl_eval
%%   EFH:      guard/2     ExternalFunctionHandler (security gate)
%%
%% Host implements exec/3 (read) and exec/4 (write) as behaviour callbacks.
%% Setup (iterator/next) and runtime (exec) use separate mechanisms:
%% the interpreter stays stateless; the host owns storage and _ENV.
-export([run/2, handler/0, iterator/1, next/1, compile/2, compute/1]).

-type code() :: string().

-type name() :: erl().

-type cell() :: non_neg_integer().

-type key() :: boolean() | function() | binary() | number() | map().

-type lua() :: key() | nil().

-type erl() :: any().

-type offset() :: pos_integer().

-type line() :: offset().

-type column() :: offset().

-type command() :: fun(() -> erl()).

-type iterator() :: erl().

%% API

%% Create an iterator over semantics-relevant §6.1 bindings; host pulls via
%% next/1.
-spec iterator(map()) -> iterator().
iterator(_Opts) ->
    throw(not_implemented).

%% Return the next {Keys, Value, Iterator} or none.
-spec next(iterator()) -> {[key()], lua(), iterator()} | none.
next(_Iterator) ->
    throw(not_implemented).

-spec compute(code()) -> <<_:_*16>>.
compute(Code) ->
    binary:encode_hex(_Md5 = erlang:md5(Code)).


%% Scan → parse (with Module injection) → eval via erl_eval + LFH + EFH.
-spec run(module(), code()) -> {value, lua(), erl()}.
run(Module, Code) ->
    Tokens = interpreter_scan:process(Code),
    Body = interpreter_parse:process(Tokens, Module),
    {value, LFH} = handler(),
    erl_eval:exprs(Body, [], {value, LFH}, {value, fun guard/2}).

-spec compile(module(), code()) -> {ok, module(), binary()} | {error, term()}.
compile(Module, Code) ->
    Tokens = interpreter_scan:process(Code),
    Forms = interpreter_parse:process(Tokens, Module),
    compile:forms(Forms, [binary]).

%% LocalFunctionHandler (LFH) for erl_eval. AST emits local calls:
%%   assign(Module, ...), block(Module, ...), etc. — primitives.
%% gen_statem controls evaluation; all primitives go through route/2.
-spec handler() ->
    {value, fun((atom(), [erl()]) -> erl())}.
handler() ->
    {value, fun route/2}.

%% ExternalFunctionHandler (EFH) for erl_eval. AST emits qualified
%% calls: Module:exec(...) — cell read/write via callback module.
%% Security: only exec is allowed; any other call is rejected.
%% Debug: client receives both exec (cell access) and eval (commands)
%% through the callback module.
guard({Mod, exec}, Args) ->
    apply(Mod, exec, Args);
guard({Mod, eval}, Args) ->
    apply(Mod, eval, Args);
guard({Mod, Fun}, _Args) ->
    error({forbidden, Mod, Fun}).

%% Explicit clauses so the compiler verifies all targets.
route(assert, [A, B]) -> assert(A, B);
route(assert, [A, B, C]) -> assert(A, B, C);
route(assert, [A, B, C, D]) -> assert(A, B, C, D);
route(assert, [A, B, C, D, E]) -> assert(A, B, C, D, E);
route(repeat, [A, B, C]) -> repeat(A, B, C);
route(assign, [A, B]) -> assign(A, B);
route(assign, [A, B, C]) -> assign(A, B, C);
route(binop, [A, B, C, D]) -> binop(A, B, C, D);
route(unop, [A, B, C]) -> unop(A, B, C);
route(fnew, [A, B, C, D]) -> fnew(A, B, C, D);
route(fset, [A, B, C, D, E]) -> fset(A, B, C, D, E);
route(fcall, [A, B, C, D]) -> fcall(A, B, C, D);
route(argv, [A, B]) -> argv(A, B);
route(chunk, [A, B]) -> chunk(A, B);
route(block, [A, B]) -> block(A, B);
route(stats, [A, B]) -> stats(A, B);
route(stat, [A, B]) -> stat(A, B);
route(retstat, [A, B]) -> retstat(A, B);
route(command, [A]) -> command(A);
route(command, [A, B, C, D, E]) -> command(A, B, C, D, E);
route(explist, [A, B]) -> explist(A, B);
route(exp, [A, B]) -> exp(A, B);
route(eval, [A, B]) -> eval(A, B);
route(eval, [A, B, C, D]) -> eval(A, B, C, D);
route(Name, Args) ->
    error({not_implemented, Name, length(Args)}).

%% -------------------------------------------------------------
%% Primitives — called via LFH (not exported). AST emits
%% local calls Fun(Module, ...); route/2 dispatches here.
%% -------------------------------------------------------------

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

%% ---------------------------------------------------------
%% Embeddable erl_syntax example (assert/2). Same pattern
%% applies to other primitives.
%% ---------------------------------------------------------
%% Assert2Clause = erl_syntax:clause(
%%     [erl_syntax:variable('If'),
%%      erl_syntax:variable('Frame')],
%%     none,
%%     [erl_syntax:case_expr(
%%         erl_syntax:application(
%%             erl_syntax:variable('If'),
%%             [erl_syntax:variable('Frame')]),
%%         [erl_syntax:clause(
%%             [erl_syntax:variable('V')],
%%             erl_syntax:disjunction([
%%                 erl_syntax:infix_expr(
%%                     erl_syntax:variable('V'),
%%                     erl_syntax:atom('=='),
%%                     erl_syntax:atom(false)),
%%                 erl_syntax:infix_expr(
%%                     erl_syntax:variable('V'),
%%                     erl_syntax:atom('=='),
%%                     erl_syntax:atom('nil'))]),
%%             [erl_syntax:atom(false)]),
%%          erl_syntax:clause(
%%             [erl_syntax:underscore()], none,
%%             [erl_syntax:atom(true)])])]),
%% Assert2Form = erl_syntax:revert(
%%     erl_syntax:function(
%%         erl_syntax:atom(assert), [Assert2Clause])),
%% Forms = [..., Assert2Form, ...].
%% ---------------------------------------------------------

repeat(Condition, Body, Frame) ->
    case assert(Condition, Body, Frame) of
        true -> repeat(Condition, Body, Frame);
        _ -> false
    end.

assign([Var], [Val]) ->
    Var(Val);
assign([Var], []) ->
    Var('nil');
assign([Var|T], []) ->
    Var('nil'), assign(T, []);
assign([Var|T], [Val|Acc]) ->
    Var(Val), assign(T, Acc).
assign(_, _, _) ->
    ok.

binop('~=', L, R, _) ->
    erlang:'/='(L, R);
binop(Op, L, R, _) ->
    erlang:Op(L, R).

unop(Op, R, _) ->
    erlang:Op(R).

%% exec/3,4 (cell access) is now a grammar-level construct:
%% access helper in interpreter_parse.yrl emits Module:exec(...)
%% as a qualified call. erl_eval resolves it directly via apply/3.
%% No primitive wrapper; no LFH interception for cell access.

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
%%  ScopeSpec = static recipe for scope-construction.
fnew(_Module, _Pars, _Body, _ScopeSpec) ->
    error(todo).

%% fset(Module, Name, Cell, Keys, Fun) -> ok.
%%  Assign named function in scope.
fset(_Module, _Name, _Cell, _Keys, _Fun) ->
    error(todo).

%% fcall(Module, Frame, Fun, Args) -> Result.
%%  Invoke function; arity/vararg via argv.
fcall(_Module, _Frame, _Fun, _Args) ->
    error(todo).

%% argv(Pars, Args) -> {BoundParams, Vararg} | {BoundParams}.
%%  Normalize Args to Pars.
argv(_Pars, _Args) ->
    error(todo).

%% ---------------------------------------------------------
%% Scope construction: static (pre-compiled), no traversal.
%% Each function's scope is built by fixed code emitted at
%% compile time. On entry: bind params (argv), copy upvalues
%% from known sources (compiler-determined). O(upvalues) per
%% call. Parent frame/cell available in Frame.
%% ---------------------------------------------------------

%% Semantic / tree layer stubs. Module is first arg (injected
%% by icall); gen_statem controls via eval/4.
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
command(_Body) ->
    error(todo).
command(_Module, _Body, _Meta, _Line, _Column) ->
    error(todo).
explist(_Module, [_Node]) ->
    error(todo);
explist(_Module, [_Node|_Tree]) ->
    error(todo).
exp(_Module, _Node) ->
    error(todo).
eval(_Module, _Command) ->
    error(todo).
eval(_Module, _Command, _Line, _Column) ->
    error(todo).

%% =============================================================================
%% NOTES — Design and implementation notes; add or update below; keep markers.
%% =============================================================================
%%
%% Scope (cell) incrementing rule
%% ------------------------------
%% Frame carries the current cell (scope index). The host uses (Name, Cell,
%% Keys) for variable resolution (exec/3, exec/4). Cell must be incremented when
%% execution *enters* a nested block so that locals and variable lookups use
%% the correct scope.
%%
%% Increment cell when entering:
%%   - Chunk:        no (chunk is top-level block; use initial cell).
%%   - If/elseif/else then- or else-blocks:  yes (each block is a scope).
%%   - While/repeat/for loop body:          yes (loop body is a block).
%%   - Explicit do ... end block:           yes (block stat).
%%   - Function body (on call):             yes (callee runs in new scope).
%%
%% Implementation: wherever we run a nested block, call it with
%%   (block(Module, SubTree))(inc_cell(Frame)), not
%%   (block(Module, SubTree))(Frame).
%% The chunk is the only block that runs with the unmodified initial Frame.
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
%% The callback Module is pre-compiled (fixed at codegen); no ENV/key resolution.
%% Advantages:
%%   - Storage backend is pluggable: in-memory map, ETS, DB, or remote
%%     (e.g. AWS). Same Lua code can run against different backends by
%%     swapping the host module.
%%   - Persistence and durability: host can persist cells/keys; interpreter
%%     stays stateless. Enables "resumable" or distributed execution.
%%   - Observability and control: host can log, rate-limit, or audit every
%%     variable access without changing the interpreter.
%%   - Resource limits: host can enforce quotas, eviction, or size limits per
%%     Name/Cell (e.g. "unlimited variables store based on AWS backend").
%%   - Multi-tenant or multi-context: Name (e.g. process/session id) isolates
%%     environments; one interpreter process can serve many logical Lua runs.
%%   - GC and lifecycle: host can release or compact storage when a cell/scope
%%     is no longer reachable, without interpreter-side GC.
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
%% Execution (AST + erl_eval + LFH + EFH)
%% ---------------------------------------
%%   Parser (interpreter_parse.yrl) builds erl_syntax nodes:
%%     icall  → local calls: assign(Module, ...), block(Module, ...)
%%     access → qualified calls: Module:exec(Keys) (cell read/write)
%%   process/2 injects Module via Merl (variable → atom). run/2
%%   evaluates Body via erl_eval:exprs/4 with LFH + EFH.
%%   LFH (route/2): local calls → primitives (not exported).
%%   EFH (guard/2): Module:exec/eval → callback (security gated;
%%     only exec and eval allowed; other qualified calls rejected).
%%   gen_statem controls evaluation via eval/4.
%%   No BEAM module created or loaded.
%%
%% =============================================================================
%% END NOTES
%% =============================================================================
