-module(interpreter).

%% Lua 5.2 interpreter embedded in ERTS (lowered to an Erlang function)
 
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
%%   6. §2.4 Metatables and Metamethods (getmetatable, setmetatable, rawget, ...)
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
%%   14. §3.4 Expressions (literals, operators, precedence, calls, table, function defs)
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
%%   - All eight types: nil, boolean, number, string, function, userdata, thread, table.
%%   - Local and global variables; globals via _ENV (chunk compiles with external _ENV).
%%   - Assignment, multi-assignment, and variable resolution (host exec/3, exec/4).
%%   - _G and _ENV in global environment; host provides initial _ENV.
%%
%% Basic library (§6.1) — minimal set
%% ----------------------------------
%%   All are "standard library" per the manual; the standard does not define
%%   "implementation default" separately. For minimal implementation we distinguish:
%%   - Semantics-relevant: referenced in the manual's semantic description
%%     (§2, §3 meaning of operations), not in lexical/grammar: type, getmetatable,
%%     setmetatable, rawget, rawset, rawlen, tonumber, tostring, rawequal.
%%   - Pure library: only in §6, not used to define meaning: print, dofile,
%%     loadfile, collectgarbage. Omit for minimal.
%%   - type(v), tonumber, tostring, rawequal, rawget, rawset, rawlen.
%%   - next(t [, index]), pairs(t), ipairs(t).
%%   - pcall(f, ...), xpcall(f, msgh [, ...]), error(message [, level]), assert(v [, message]).
%%   - getmetatable(object), setmetatable(table, metatable).
%%   - select(index, ...), load(chunk [, chunkname [, mode [, env]]]).
%%   - Optional for minimal: print(...), _VERSION (string "Lua 5.2").
%%
%% Embedded (host-provided) functions
%% ----------------------------------
%%   - Host registers C (here: Erlang) functions into _ENV (e.g. io.print, os.clock).
%%   - No built-in I/O or OS in core; host supplies io, os, etc. as needed.
%%   - For minimal: host can provide empty _ENV or a table with type, pairs, ipairs, pcall, next.
%%
%% Constructor for host setup (_ENV + language constructs)
%% -------------------------------------------------------
%%   - Provide iterator/1 (constructor) that returns an iterator over §6.1 bindings.
%%     Host pulls bindings via next/1; no callback Fun needed.
%%     This separates setup scope (iterator/1 + next/1) from runtime (exec/3, exec/4).
%%   - iterator/1 does NOT call exec/4: setup and runtime use different mechanisms.
%%   - Signature: iterator(Opts) -> iterator()
%%       next(Iterator) -> {[key()], lua(), iterator()} | none
%%       Opts = map with optional keys below
%%     Host calls next/1 repeatedly to pull each standard binding (type, pairs, ...).
%%   - Pre-compile: bindings are native Erlang funs; no Lua source compiled.
%%   - Naming: iterator/1 is a constructor (cf. maps:iterator/1); next/1 steps.
%%   - Suggested Opts:
%%       include => [print | dofile | loadfile | ...]  optional standard names to add
%%       exclude => [load | ...]  names to omit (e.g. sandbox)
%%       extra   => [{Keys, Value} | ...] or map of host-provided bindings (e.g. io, os)
%%     Examples:
%%       iterator(#{})                                 minimal default
%%       iterator(#{include => [print]})               default + print
%%       iterator(#{extra => [{[<<"io">>], IOTable}]}) add host bindings
%%       iterator(#{exclude => [load]})                sandbox
%%
%% Language (syntax, scoping, control)
%% ----------------------------------
%%   - Control structures: if/elseif/else, while, repeat, for (numeric and generic), do block.
%%   - Break, label, goto (e.g. via tree enclosure).
%%   - Lexical scoping: chunk, block, control bodies, function body (see NOTES re. cell increment).
%%   - Scopes resolved at compile time (transformed into cells); variables into host API calls.
%%   - Function call and scope entrance increment the next cell.
%%   - Grammar: fix reduce conflicts if any; ref. Lua 5.2 manual §3.
%%   - Evaluators for statements, expressions, literals: lowered closure conversion.
%%
%%   Sources (docs):
%%     https://www.lua.org/manual/5.2/manual.html          (Lua 5.2 Reference Manual)
%%     https://www.lua.org/manual/5.2/manual.html#2       (§2 Basic concepts: types, env, errors, metatables)
%%     https://www.lua.org/manual/5.2/manual.html#3       (§3 Syntax and semantics)
%%     https://www.lua.org/pil/4.2.html                   (PIL 4.2 Lexical scoping)
%%     https://www.lua.org/pil/4.3.html                   (PIL 4.3 Control structures)
%%
%% =============================================================================
%% END TODO
%% =============================================================================

%% Public API — four functions, two pairs:
%%   Setup:     iterator/1  create iterator over §6.1 bindings
%%              next/1       pull next {Keys, Value, Iterator} | none
%%   Transform: compile/2   Lua source → program (closure tree)
%%              compute/1   Lua source → content hash (MD5 hex)
%%
%% Host implements exec/3 (read) and exec/4 (write) as behaviour callbacks.
%% Setup (iterator/next) and runtime (exec) use separate mechanisms:
%% the interpreter stays stateless; the host owns storage and _ENV.
-export([iterator/1, next/1, compile/2, compute/1]).

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

-type program() :: fun(([lua()]) -> lua()).

-type iterator() :: erl().

%% API

%% Create an iterator over semantics-relevant §6.1 bindings; host pulls via next/1.
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

-spec compile(module(), code()) -> program().
compile(Module, Code) ->
    Tree = interpreter_parse:process(_Scan = interpreter_scan:process(Code)),
    Exec = chunk(Module, Tree),

    fun (Name) ->
        %% TODO Side effects are produced independetly

        Exec(Name)
    end.

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


assign([Var], [Val]) ->
    Var(Val);

assign([Var], []) ->
    Var('nil');

assign([Var|T], Acc = []) ->
    Var('nil'),

    assign(T, Acc);

assign([Var|T], [Val|Acc]) ->
    Var(Val),

    assign(T, Acc).

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
    %% TODO Inline arguments in a frame
    ok.

chunk(Module, Tree) ->
    _Local = [],

    fun (Frame) ->
        %% TODO Variable names are uniquely resolved at compile time (e.g., associated with slots)
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Frame = (block(Module, Tree))(Frame) 
    end.

 %% TODO Handle ;
block(Module, Tree) ->
    Code = stats(Module, Tree),

    fun (Frame) -> 
        %% TODO Side effects are evaluated 
        %% TODO Dedicated call with side effects 
        %% TODO Side effects applied during the state transition
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        Frame = Code(Frame),
        Eval = compute(Module, Tree) 
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
    fun (Frame0) ->
        %% TODO Function declaration, Var and Var assignment
        %% TODO Frame check expression (maps:with/2, maps:merge/2)
        %% TODO Elaborate enclosure overhead (GC) 
        Frame1 = Exec(Frame0),

        %% TODO Compute Frame based on variables
        Code(Frame1) 
    end.

stat(Module, {_Tag = 'assign', Line, Node1, Node2}) ->
    Body = fun (Frame) ->
        Vars = (explist(Module, Node1))(),
        Vals = (explist(Module, Node2))(),

        assign(Vars, Vals) end,

    command(Module, Body, ['='], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2}) ->
    Body = fun (Frame) ->
        If = exp(Module, Node1),
        assert(If, _IfBody = block(Module, Node2)) end,

    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'elseif', Line, Node1, Node2, Node3}) ->
    Body = fun (Frame) ->
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _Else = stat(Module, Node3)) end,

    command(Module, Body, ['elseif'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3}) ->
    Body = fun (Frame) -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        assert(If, IfBody, _ElseBody = block(Module, Node3)) end,

    command(Module, Body, ['if'], Line);

stat(Module, {_Tag = 'if', Line, Node1, Node2, Node3, Node4}) ->
    Body = fun (Frame) -> 
        If = exp(Module, Node1),
        IfBody = block(Module, Node2),
        Else = stat(Module, Node3),
        assert(If, IfBody, Else, _ElseBody = stat(Module, Node4)) end,

    eval(Module, _Command = command(Body), ['if'], Line);

stat(Module, {_Tag = 'else', Line, Node1}) ->
    Body = fun (Frame) -> 
        (block(Module, Node1))() end,

    command(Module, Body, ['else'], Line);

stat(Module, {_Tag = 'while', Line, Node1, Node2}) ->
    Body = fun (Frame) -> 
        Condition = exp(Module, Node1),
        repeat(Condition, _Body = block(Module, Node2), Frame) end,

    command(Module, Body, ['while', 'do', 'end'], Line).

retstat(Module, {return, Line, Node}) ->
    Body = fun (Frame) -> 
        (explist(Module, Node))() end,

    command(Module, Body, ['return'], Line);

retstat(Module, Node) ->
    stat(Module, Node).

explist(Module, [Node]) ->
    Exec = exp(Module, Node),

    fun (Frame) -> 
        [Exec(Frame)]
    end;

explist(Module, [Node|Tree]) ->
    Exec = exp(Module, Node),
    Code = explist(Module, Tree),

    fun (Frame0) -> 
        Frame1 = Exec(Frame0),
        
        Code(Frame1)
    end.

exp(Module, {_Tag = op, Line, Op, Node1, Node2}) ->
    Op1 = (exp(Module, Node1))(),
    Op2 = (exp(Module, Node2))(),

    Body = fun (Frame) -> 
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
eval(Module, Command, Meta, Line) ->
    %% TODO Frame is pre-computed (function args are pre-processed)
    %% TODO Frame is contained as enclosure
    fun (Runtime) ->
        Module:eval(Runtime, Command, Line, Meta)
    end.

eval(Module, Command) ->
    fun (Runtime) ->
        Module:eval(Runtime, Command)
    end.

%% Embed API
exec(Module, Command) ->
    fun (Runtime) ->
        Module:exec(Runtime, Command)
    end.

%% =============================================================================
%% NOTES — Design and implementation notes; add or update below; keep markers.
%% =============================================================================
%%
%% Scope (cell) incrementing rule
%% ------------------------------
%% Frame carries the current cell (scope index). The host uses (Name, Cell, Keys)
%% for variable resolution (exec/3, exec/4). Cell must be incremented when
%% execution *enters* a nested block so that locals and variable lookups use
%% the correct scope.
%%
%% Increment cell when entering:
%%   - Chunk:        no (chunk is the top-level block; use initial cell from Frame).
%%   - If/elseif/else then- or else-blocks:  yes (each block is a scope).
%%   - While/repeat/for loop body:          yes (loop body is a block).
%%   - Explicit do ... end block:           yes (block stat).
%%   - Function body (on call):             yes (callee runs in a new scope).
%%
%% Implementation: wherever we run a nested block, call it with
%%   (block(Module, SubTree))(inc_cell(Frame)), not (block(Module, SubTree))(Frame).
%% The chunk is the only block that runs with the unmodified initial Frame.
%%
%% Minimal Lua 5.2 interpreter (per standard)
%% ------------------------------------------
%% The standard (www.lua.org/manual/5.2) defines:
%%   (1) The language: §2 Basic concepts, §3 Syntax and semantics. That is the
%%       minimal interpreter: values and types, _ENV, expressions, statements,
%%       control flow, functions, tables, metatables. No library is required
%%       by the language for correctness.
%%   (2) Standard libraries (§6): the manual describes their behavior so the
%%       reference implementation and embedders can provide compatible behavior.
%%       The reference host loads them into the global environment; an embedder
%%       may provide a subset.
%%
%% Basic library: implement or host-provide?
%% ----------------------------------------
%% The basic library (§6.1) can be implemented inside the interpreter or
%% supplied by the host (Erlang functions registered into _ENV). The manual
%% specifies behavior; either way is standard. Some functions are referenced
%% by the language semantics (e.g. type, getmetatable, rawget, tonumber in §2.4),
%% so a minimal runnable interpreter needs at least those, as built-ins or
%% host-provided. Recommendation: provide §6.1 (or a minimal subset) as
%% host-registered functions so the interpreter stays small and the host
%% controls what is available.
%%
%% Host-provided functions: part of the standard?
%% ----------------------------------------------
%% Yes. The manual §1: "The host program can ... register C functions to be
%% called by Lua code. Through the use of C functions, Lua can be augmented
%% to cope with a wide range of different domains." So registering host (C/Erlang)
%% functions is the standard extension mechanism. The *standard library* is the
%% set of functions the manual describes and that the reference host puts in
%% the global environment; a minimal interpreter can supply a subset via the
%% host and still be Lua 5.2 compliant for that subset.
%%
%% Standard library: semantics-relevant vs pure library
%% ----------------------------------------------------
%% Strict "language spec" = lexical rules + formal grammar (syntax only). The
%% formal grammar is given in extended BNF in the manual's "Complete Syntax"
%% section: Lua 5.1 §8, Lua 5.2 §9.
%%   https://www.lua.org/manual/5.1/manual.html#8
%%   https://www.lua.org/manual/5.2/manual.html#9
%% The Lua Reference Manual also contains a semantic description (§2, semantic
%% parts of §3) that defines the meaning of operations in terms of certain
%% functions. We call those semantics-relevant: they are referenced in that
%% semantic description, not in the lexical/grammar spec. Ours: type,
%% getmetatable, setmetatable, rawget, rawset, rawlen, tonumber, tostring,
%% rawequal, error, pcall, xpcall. Pure library (only in §6, not used to define
%% meaning): print, dofile, loadfile, collectgarbage. Both groups are standard
%% library; use this split for minimal implementation scope.
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
%% Advantages:
%%   - Storage backend is pluggable: in-memory map, ETS, DB, or remote (e.g. AWS).
%%     Same Lua code can run against different backends by swapping the host module.
%%   - Persistence and durability: host can persist cells/keys; interpreter stays
%%     stateless. Enables "resumable" or distributed execution.
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
%%   iterator/1 does NOT call exec/4 — different mechanism for different phase:
%%     setup:   iterator/1 + next/1 (pull-based, host drives, no scoping)
%%     runtime: exec/3, exec/4      (scoped by Name/Cell/Keys, called repeatedly)
%%   Naming: iterator/1 is a constructor, next/1 is the step function.
%%   Implementations are pre-built Erlang funs; no Lua source compiled.
%%
%% Portable compiled programs via Horus
%% -------------------------------------
%%   compile/2 returns an Erlang fun (closure tree). This fun references
%%   internal interpreter functions (chunk, block, stat, exp, etc.) by module.
%%   Sending it to another BEAM node requires the same interpreter module
%%   version — otherwise results differ or the call crashes.
%%
%%   Horus (https://github.com/rabbitmq/horus) solves this:
%%     1. horus:to_standalone_fun/1 disassembles the fun's BEAM bytecode
%%     2. Recursively extracts all called functions (interpreter internals)
%%     3. Creates a standalone module with everything inlined
%%     4. Returns a #horus_fun{} — portable binary, no module dependency
%%     5. horus:exec/2 loads and runs it on any node
%%
%%   Usage with this interpreter:
%%     Program    = interpreter:compile(Host, LuaSource),
%%     Standalone = horus:to_standalone_fun(Program),
%%     %% Send to another node or store as binary:
%%     erpc:call(NodeB, horus, exec, [Standalone, [Name]]).
%%
%%   What the execution node needs:
%%     - Host module (for exec/3, exec/4 callbacks)
%%     - Horus runtime
%%   What it does NOT need:
%%     - interpreter, interpreter_scan, interpreter_parse
%%
%%   Caveats:
%%     - Host module must be present on the execution node (external call).
%%       Horus's should_process_function callback can extract it too if needed.
%%     - Both nodes should run the same (or compatible) OTP version — Horus
%%       works at BEAM assembly level; newer instructions break on older VMs.
%%     - Horus is Alpha (used by RabbitMQ/Khepri internally).
%%     - Extraction cost: do once per compiled program, cache the result.
%%       compute/1 hash can serve as cache key for standalone funs.
%%
%%   Aligns with the stateless design: stateless interpreter + portable
%%   compiled output (via Horus) + host-owned storage = fully distributed
%%   Lua execution. Compile on node A, run on node B, state on node C.
%%
%% =============================================================================
%% END NOTES
%% =============================================================================