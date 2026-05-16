# Repository Guidelines

## AI agent behavior
- Do not edit repository files, run write tools, or apply patches until the
  user explicitly approves that change (e.g. implement, apply, or change named
  files).
- Do not run `make`, `erlc`, `rebar`, `eunit`, or other build/test/shell
  tooling unless the user explicitly asks to run that command in the session.
- Parser output: treat `interpreter_parse.erl` as **generated** from
  `interpreter_parse.yrl` — do **not** hand-edit the `.erl` (and never
  bulk-replace inside the yecc automaton). Change the **`.yrl` only**; a human
  or `make` regenerates the `.erl` when the user allows builds.
- Do not run destructive Git commands (`git restore`, `reset`, `checkout`,
  `clean`, and similar) without explicit approval for that command.
- Treat questions and design discussion as answer-only unless the user asks
  for code or repository edits.
- If the user asks to revert agent changes, undo those edits in the working
  tree (e.g. patch), not reset to last commit, unless they explicitly ask for
  Git.

## Project Structure & Module Organization
- `src/`: Erlang implementation of the Lua interpreter; includes the lexer/parser sources (`interpreter_scan.xrl`, `interpreter_parse.yrl`) and compiled modules such as `interpreter.erl`.
- `priv/`: Embedded Lua fixtures (e.g., `code.lua`) used during compilation/testing.
- `test/`: EUnit suites (`interpreter_tests.erl`) with `meck`-backed mocks; `.beam` artifacts may appear after running tests.
- `deps/` and `ebin/`: Third-party dependencies and compiled beams managed by `erlang.mk`; do not edit manually.
- Generated files (from `.xrl`/`.yrl`) are refreshed by the build; edit the sources, not the generated `.erl`.

## Build, Test, and Development Commands
- `make`: Fetches dependencies and compiles the project using `erlang.mk`.
- `make clean` / `make distclean`: Remove compiled artifacts / dependencies before a fresh build.
- `make eunit`: Run the EUnit suite; preferred quick-test command.
- `make shell`: Start an Erlang shell with the project code on the path for interactive debugging.
- When editing lexer/parser definitions, re-run `make` to regenerate
  scanner/parser modules (human / CI; not an agent default).

## Coding Style & Naming Conventions
- Keep lines within 80 columns (80 symbols; canonical line limit). All project
  modules (src, test) must follow. Wrap comments and long expressions; for API
  reference comments use two lines per item (spec on first line, description on
  second) so each line fits.
- Follow existing Erlang style: 4-space indents, snake_case for modules/functions/variables, and guard clauses where they aid clarity.
- Use `-spec` and type aliases where possible to document public functions (`compile/2`, `compile/3`, etc.).
- Prefer pattern matching and small, pure helper functions; keep side-effects inside clearly named functions (`exec`, `assign`, etc.).
- Place repository-specific constants or fixtures under `priv/`; keep test-only helpers inside `test/`.

### Naming scope (single-word rule)
- **Do not change:** OTP conventions (e.g. `process_test`); names by Robert Virding in `interpreter_parse.yrl` (grammar, generated code, and his Erlang helpers: `numeric_for`, `generic_for`, `functiondef`, `check_functioncall`, `dot_append`, `dot_to_icall`, etc.); Leex conventions in `interpreter_scan.xrl` (`TokenLine`, `TokenCol`, etc.).
- **In scope:** Only names we introduced in our Erlang code. Prefer a single word per function or variable; no camelCase or snake_case compound names. IfBody, ElseBody, ElseIf are kept as-is (control-flow parameters).
- **Single-word renames applied:** `build_module`→`build`, `ModAttr`→`mod`,
  `icall_tag`→`tag`. (Virding names and `dot_to_icall` unchanged;
  `dot_to_icall` is this project's dot-chain→icall step, not in Luerl.)

## Testing Guidelines
- When asked to show or list an API, provide the complete surface (every export, each with a comment); use selective or summarized description only when the user asks to assess or describe selectively.
- Tests use EUnit with `meck` for mocking (`meck:new/2`, `meck:expect/3`); keep test functions suffixed with `_test`.
- Add new suites to `test/` as `<module>_tests.erl`; ensure `-include_lib("eunit/include/eunit.hrl").` is present.
- Use `?assertEqual`, `?assertError`, and `?debugVal` consistently; avoid side effects that leak process state across tests.
- Before submitting changes, run `make eunit`; include any new fixtures under `priv/` if the test relies on Lua samples.

## Commit & Pull Request Guidelines
- Commit messages should be short, imperative, and focused (e.g., `Improve assert API`, `Add exec guard`), matching existing history.
- In pull requests, include: a concise summary, the problem being solved, key changes, and test evidence (`make eunit` output or rationale if unrun).
- Link related issues/tickets and describe any API or behavior changes affecting embed callers.
- If adding generated files, explain why they must be committed; otherwise, prefer keeping build outputs out of diffs.

## Security & Configuration Tips
- Do not commit secrets or machine-specific configs; rely on `erlang.mk` to resolve dependencies.
- Keep dependencies pinned via the `Makefile` definitions; update them deliberately and document version bumps.
