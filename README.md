# Interpreter
Lua 5.2 interpreter embedded in ERTS

## Design

The interpreter compiles a Lua 5.2 chunk into one Erlang Fun: statements
become a chain of Funs, each capturing its successor; expressions become
nested Funs in direct style. Variables live in the host, which answers
every read and write through `exec/3` and `exec/4`; the interpreter holds
no state between those calls. Background, in reading order:

- Cartwright, Felleisen. *Extensible Denotational Language
  Specifications.* TACS 1994. A computation is a value or a request to an
  administrator that owns the resources: the host-owned storage model.
- Plotkin, Pretnar. *Handlers of Algebraic Effects.* ESOP 2009. The
  requests as an operation signature, the host as its handler.
- Reynolds. *Definitional Interpreters for Higher-Order Programming
  Languages.* ACM 1972. Continuation passing; see `reynolds-1972.md`.
- Bell. *Threaded Code.* CACM 16(6), 1973. One jump per step, dispatch in
  the tail of every routine; see `bell-1973.md`.
- Danvy, Nielsen. *Defunctionalization at Work.* PPDP 2001. The
  serializable form of a continuation; see `danvy-nielsen-2001.md`.
- Feeley, Lapalme. *Using Closures for Code Generation.* Computer
  Languages 12(1), 1987. Tree to nested closures.
- Burckhardt et al. *Durable Functions: Semantics for Stateful
  Serverless.* OOPSLA 2021. Replay against a log of committed effects:
  the recovery model.

`Memory.md` describes how the compiled Funs are laid out and used in BEAM
memory. The full list of references is the READ block at the top of
`src/interpreter.erl`.

## Test suite

`priv/` holds the official Lua 5.2.2 test suite from Lua.org,
unmodified: the 26 `.lua` files of `lua-5.2.2-tests`
(https://www.lua.org/tests/), mirrored at https://github.com/lua/tests,
tag `v5-2-2`. They are distributed under Lua's licence, kept beside them
as `priv/LICENSE`.

`interpreter_tests` scans and parses every file of the suite as part of
`make tests`.
