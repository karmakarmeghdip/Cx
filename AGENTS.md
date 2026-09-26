# AGENTS.md — Cx Compiler (LuaJIT)

> Read this file before touching any code. It is the source of truth for
> architecture, toolchain, and workflow. `samples/c-vs-cx.md` is the source
> of truth for language syntax.

## 1. What this project is

Cx is a thin syntactic layer over C23. `compiler/` (pure LuaJIT, no LPeg,
no native deps) parses `.cx` → AST → expands extension nodes → emits raw C.
Root `build.lua` is the **user-editable build script** (zig `build.zig`-like,
but simpler). Users instantiate the compiler, register extensions, compile
files, and optionally shell out to `gcc`/`clang`/`cl`.

Pipeline (do not reorder):

```
.cx source → lexer → parser-core + grammar-table → AST (Cx* + Ext*)
         → expand loop (Ext* → Cx*, target-aware) → codegen (target-aware) → .c
         → (optional) cc/link for that target
```

The compiler is **target-aware** (see §10): every phase after lexing receives
a `CxTarget` (`{triple, os, arch, abi, cc, std}`). Extensions must branch on
`target`, never on host globals (`jit.os` etc. live only inside `target.lua`).

## 2. Toolchain (mandatory)

- Runtime: **LuaJIT** (`luajit -v` must work). No PUC-Lua-only features.
  No `bitop` beyond what LuaJIT provides; prefer `string`, `table`, `io`.
- Static analysis: **lua-language-server** (`lua-language-server --version`).
  - Config lives in `.luarc.json` (`runtime.version = "LuaJIT"`, strict-ish).
  - All public modules must carry EmmyLua annotations:
    `---@class`, `---@param`, `---@return`, `---@alias`, `---@overload`.
  - Zero global leaks: every file is a module returning a table.
    Use `local M = {}` pattern. `luacheck`-clean if configured.
- Verify before finishing any task:
  1. `luajit build.lua --help` (or the closest smoke target for your phase)
  2. `luajit tests/run.lua` (golden + unit tests, no network)
  3. `lua-language-server --check .` (or opened-editor diagnostics clean)

## 3. Layout (do not restructure without discussion)

```
build.lua                 # user-modifiable script, ~20-60 lines, thin shim only
compiler/
  init.lua                # public API: CxCompiler class (new/file/extension/emit/cc/link)
  target.lua              # CxTarget: triple/os/arch/abi/cc/std, detect/normalize, cc flag maps
  lexer.lua               # tokens + trivia + directives + Loc
  parser_core.lua         # grammar-AGNOSTIC recursive-descent combinators + Pratt
  grammar_cx.lua          # CORE language declared as a Lua table (the only grammar spec)
  ast.lua                 # node constructors, kinds, visitor/replace utils
  expand.lua              # fixpoint Ext* → Cx* expansion loop
  codegen.lua             # public emit entry + section wiring (stable require API)
  codegen/                # section printers sharing one table: core/types/exprs/stmts/decls
    core.lua              # ctx, guards, attributes, line emitter (no printer deps)
    types.lua             # declarators, bounds, params
    exprs.lua             # expressions + initializers
    stmts.lua             # statements + block lists
    decls.lua             # bindings, functions, records/enums/aliases
  extension.lua           # extension registry + hook contracts
  modules.lua             # import/export driver pass (graph, exports, prototypes)
  buildkit.lua            # helpers for build scripts (glob, emit, cc, link, flags)
  extensions/
    gnu.lua               # FIRST real extension: GNU/K&R dialect (sample 07)
    modules.lua           # ESM-style import/export (sample 08; driver in modules.lua)
tests/
  run.lua                 # single entry point, runs all *_test.lua under tests/
  goldens/                # .cx → .c snapshots derived from samples/programs/
samples/
  c-vs-cx.md              # language spec — do not contradict it
  programs/01..06*.cx/.c  # strict C23 goldens; 07*.cx/.c is GNU-only
  programs/08_*.cx/.c     # modules sample (multi-file program, tested in modules_test)
```

Rules:

- All compiler logic stays in `compiler/`. Root `build.lua` only wires
  `compiler.init` together (see §7).
- `compiler/parser.lua` is currently an empty placeholder: new code goes in
  `parser_core.lua` + `grammar_cx.lua`, not by growing a monolith.
- `compiler/extensions/` holds only dialect/extension modules (gnu, modules).
- Never parse headers (`#include` targets) as Cx. Never macro-expand.

## 4. Lexer contract (`compiler/lexer.lua`)

- Handles line-splicing (`\` + newline) BEFORE tokenizing.
- Tokenizes C23 literals: ints (hex/oct/bin, `'` separators, `wb/uwb`),
  floats, chars, strings (`u8`, `char8_t`, prefixes), operators, attributes
  `[[...]]`, punctuation.
- Trivia: whitespace, `//` + `/* */` (non-nesting) comments, and **directives**:
  a logical line starting with `#` (after splicing) is ONE opaque token,
  preserved verbatim (covers `#embed`, `#line`, `#define`, `#if`…).
- Cx keywords (`let function type as cinit`) match as whole tokens only
  (`letter`, `type_name` stay identifiers). Raw escape `@ident` lexes as ONE
  identifier token with `raw=true`; the `@` is dropped at codegen.
- Every token/node carries `Loc = {file, line, col, end_line, end_col, offset}`.
  Errors always report `file:line:col` + snippet. No silent `nil` drops.

## 5. AST contract (`compiler/ast.lua`)

Two — and only two — families, distinguished by `kind` prefix:

- Native: `kind = "Cx:..."` (e.g. `Cx:Binding`, `Cx:FunctionDef`,
  `Cx:RecordLit`, `Cx:Cinit`, `Cx:Directive`). Codegen knows these exhaustively.
- Extension: `kind = "Ext:<Name>:..."` (e.g. `Ext:Gnu:StmtExpr`).
  Codegen MUST assert-fail on these (they must be expanded first).

Constructor + utility rules:

- Build nodes only via `ast.node(kind, loc, fields)` so `kind`/`loc` are
  always present. Document each kind's fields with `---@class` in `ast.lua`.
- Provide `ast.walk(root, fn)`, `ast.collect_ext(root)`,
  `ast.replace(ctx, node, replacements)` — extensions must use these,
  never hand-splice parent arrays.
- AST is a plain Lua table tree (no metatables on hot paths — LuaJIT likes this).

## 6. Parser contract

### 6a. `parser_core.lua` — grammar-agnostic, no Cx knowledge

- Exposes combinators: `seq, choice, many, many1, sepBy, opt, expect, token,
  keyword, delimited, balanced, lookahead, commit/rollback`.
- Exposes a **Pratt/expression** driver driven by tables:
  `prefix_parsers`, `infix_specs = {prec, assoc, parse}` — precedence values
  live in the grammar table, NOT in core.
- Thread a `ParseEnv` through every rule: `{typedefs, tags, scopes, dialect,
  target, errors}`. Typedef-vs-expression tests (`sizeof(T)` vs `sizeof(expr)`,
  declaration-in-`for`) consult `env:is_typename(name)` — this is semantic,
  never pure-CFG. Headers contribute a prelude typedef set
  (`size_t`, `ptrdiff_t`, `va_list`, …), not parsed content. `env.target` is
  read-only: grammar may enable/disable rules per target (e.g. GNU forms only
  when `target.cc ~= "msvc"`), but must never mutate it.
- Ordered type-suffix loop lives in core as a reusable helper
  (`parse_suffixes`), configured by grammar: `*` qualifiers then
  `[quals static? expr?]` / `[*]`. Suffix ORDER is significant.
- Context-specific colon rules: binding-colon, field-colon, bitfield-colon,
  record-literal-colon, `_Generic`-assoc-colon, label-colon are SEPARATE
  functions. One generic colon rule is a bug.
- `cinit { ... }` is parsed as an **opaque balanced region** (braces nest,
  directives preserved, no Cx interpretation inside). Same for
  `(Type)[...]` vs `(Type){...}` compound literals (distinct from `as` casts).
- No left recursion. No backtracking explosions: prefer `choice` with
  1-token lookahead + committed `expect` after a keyword is consumed.

### 6b. `grammar_cx.lua` — core language as a Lua table

- The ONLY place Cx syntax is defined. Shape:

  ```lua
  ---@class CxGrammar
  M.keywords = { "let", "function", "type", "as", "cinit", ... }
  M.prefix = { ["sizeof"]=..., ["alignof"]=..., ... }
  M.infix  = { ["as"]={prec=..., assoc="right"}, ["*"]={...}, ... }
  M.rules  = { parseExternalDecl=..., parseStatement=..., parseType=..., ... }
  ```

- Extensions may ADD keys/rules or wrap existing rule functions, but may NOT
  replace the lexer and may NOT silently change C23 semantics of core rules
  (GNU forms stay behind `dialect.gnu` flag).
- After `struct/union/enum Name` header is parsed, register the tag BEFORE
  parsing the body (recursion works), but NEVER promote a tag to a bare
  type name — `struct Point` ≠ `Point` unless a `type` alias exists.

## 7. Extension + expansion contract

- Extension module shape (`compiler/extension.lua` validates this):

  ```lua
  ---@class CxExtension
  ---@field name string                    # e.g. "Gnu", used in Ext:<Name>:* kinds
  ---@field extend_grammar fun(G:CxGrammar, env:table)  # add syntax only
  ---@field expanders table<string, fun(ctx:ExpandCtx, node:CxNode): CxNode|CxNode[]|nil>
  ---@field graph_api CxGraphApi|nil       # optional driver-extension frontend
  ```

  Two flavors: **desugar extensions** (grammar + per-node expanders, e.g.
  gnu) and **driver extensions** (grammar + `graph_api` classifiers over
  whole TUs, linked by `compiler/modules.lua` via `CxCompiler:program`,
  e.g. modules). A driver frontend only classifies markers —
  `imports_of(root)` edges and `exports_of(root, path)` entries — while
  the driver owns graph DFS, cycles, prototype synthesis, and splicing.
  A new module syntax (say Rust-style `mod`/`use`/`pub`) reuses the driver
  with its own marker kinds and classifiers; `init.lua` never names a
  frontend (exactly one graph extension per program).

- `extend_grammar(G, env)`: `env = {target:CxTarget, dialect:table}`.
  Use `env.target.cc/os/arch` to conditionally add rules (e.g. skip
  statement-expressions when `target.cc == "msvc"` unless explicitly forced).
  Never read `jit.os`/`jit.arch` here — only `env.target`.
- Expander signature: `expanders["Ext:Gnu:StmtExpr"](ctx, node) → replacement
  node(s) | nil`. `ctx` exposes `{root, env, target:CxTarget, replace(node, repl), api}` —
  whole-AST reads allowed, whole-AST writes ONLY via `ctx.replace` + provided
  helpers (keeps codegen invariants intact). Branch on `ctx.target`
  (e.g. `if ctx.target.os == "windows"` emit `__declspec(...)` else
  `__attribute__((...))` via `Cx:*` nodes or `cinit` payload). Expansion must
  be deterministic for a fixed `(target, AST)` pair.
- `expand.lua` runs a **bounded fixpoint**: bottom-up post-order collection,
  dispatch, repeat until zero `Ext:*` nodes or `budget` (default 1024)
  exhausted. Non-termination → hard error with node loc + extension name.
  Deterministic order; expansion must be idempotent where possible.
- Codegen asserts `collect_ext(root)` is empty. An unexpanded node is a
  compiler bug, never silently emitted.

## 8. Codegen contract (`compiler/codegen.lua`)

- Input: fully expanded `Cx:*`-only AST + original trivia/directives.
- Output: raw C23 (or GNU C if `dialect.gnu`) text. Lowerings:
  `[a,b]` → `{a,b}`, `{x:1}` → `{.x=1}`, `expr as T` → `((T)(expr))`,
  `let x:T` → `T x`, `function f():T` → `T f(void)` iff zero params, etc.
- Codegen is target-aware: signature is `codegen.emit(root, ctx)` with
  `ctx = {target:CxTarget, ...}`. It must reject (with loc) constructs the
  selected `cc/std` cannot compile (e.g. `_BitInt`, `char8_t`, `typeof`,
  `[[attr]]`, `#embed` on old MSVC) instead of silently emitting broken C.
  Target-specific spellings (`__attribute__` vs `__declspec`, `asm` vs
  `__asm`) come from `Ext:*` expansion, not from `if msvc` hacks inside
  every emitter — core emitters stay portable.
- Preserve directives verbatim, one per logical line; never reflow `#embed`
  / `#line`. Preserve `cinit` payload as C initializer body.
- No pretty-print cleverness that changes line directives; keep output
  `gcc -fsyntax-only`-clean on goldens.

## 9. Build-script contract (`build.lua` + `compiler/init.lua` + `buildkit.lua`)

- `build.lua` stays SIMPLE and user-owned. Canonical shape (~30 lines):

  ```lua
  local Cx = require("compiler.init")
  local b = Cx.new({ std = "c23", cc = "gcc" })
  b:extension("gnu", require("compiler.extensions.gnu"))
  b:file("samples/programs/01_hello_args.cx"):emit("out/01.c")
  b:cc({ flags = { "-Wall", "-Wextra" } }):link({ out = "out/app" })
  ```

- Heavy lifting lives in `compiler/init.lua` (`CxCompiler` class:
  `new/file/files/extension/emit/emit_all/cc/link/run`) and
  `compiler/buildkit.lua` (glob, mkdir-p, incremental mtime skip, arg parsing,
  `exec` wrapper). Build scripts compose these; they never reimplement parsing.
- CLI convention: `luajit build.lua <task> [--flag ...]` with `--help`.
  Default task compiles the sample program(s). `cc`/`link` steps are OPTIONAL
  and must degrade gracefully if no C toolchain is present (emit `.c` anyway).

## 10. Target contract (`compiler/target.lua`)

- `CxTarget` shape (EmmyLua-annotated, plain table, no metatables):

  ```lua
  ---@class CxTarget
  ---@field triple string  # "x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-pc-windows-msvc"
  ---@field os string      # "linux"|"windows"|"macos"|...
  ---@field arch string    # "x86_64"|"aarch64"|...
  ---@field abi string     # "gnu"|"musl"|"msvc"|"darwin"|...
  ---@field cc string      # "gcc"|"clang"|"msvc"|"tcc" (the C toolchain, not the host)
  ---@field std string     # "c23"|"gnu23"|"c17" (passed as -std= / /std:)
  ```

- `target.lua` owns ALL host introspection. Only this file may read
  `jit.os`/`jit.arch` or probe `cc --version`. Everything else receives an
  already-built `target` and branches on `target.os/arch/cc/std`.
  API: `target.detect(opts?)`, `target.normalize(triple)`,
  `target.cc_args(target, kind)` where `kind = "compile"|"link"`.
- Threading: `Cx.new({target?, triple?, cc?, std?})` builds it once.
  Then `ParseEnv.target` (read-only), `ExpandCtx.target`,
  `codegen.emit(root, {target,...})`, `buildkit.cc/link` map it to real
  command lines:
  - gcc/clang: `cc -std=<std> [--target=<triple>] -c in.c -o out.o`
  - msvc (`cl.exe`): `cl /std:clatest /c in.c /Fo:out.obj` (+ `link` for link).
  - Unknown `cc` → hard error listing supported values, never silent fallback.
- Golden tests run at least `host-gcc` (strict C23) and, when available,
  `x86_64-pc-windows-msvc` (parse-only or `cl /Zs`) to prove GNU forms are
  gated and `__attribute__` vs `__declspec` lower per target. Same `.cx`
  may emit different `.c` per target — snapshots are stored per
  `(sample, triple, cc)`.

## 11. Tests

- `tests/run.lua` is the ONLY test entry. Each `tests/*_test.lua` returns
  `function run(ctx) ... end` and uses plain `assert` + `ctx.check(name, fn)`.
  No luarocks test framework (LuaJIT-friendly, zero deps).
- Golden tests: `samples/programs/0[1-6]*.cx` must round-trip to equivalent
  `.c` (normalize whitespace for comparison, then `gcc -fsyntax-only`
  when available). `07_gnu_*` runs ONLY with `dialect.gnu` enabled and is
  the acceptance test for the extension system.
- Unit tests per phase: lexer tokens/locs, combinators, Pratt table,
  type-suffix order, `as` vs compound-literal, `cinit` opacity, expansion
  fixpoint + budget, codegen lowerings.

## 12. Implementation phases (work in this order, don't skip)

- [ ] **P0 scaffold**: `.luarc.json`, `tests/run.lua`, `compiler/init.lua`
      stub, `build.lua --help` smoke. Goldens harness (failing, empty impl ok).
- [ ] **P1 lexer + ast**: tokens, trivia, directives, `Loc`, `@ident`,
      `ast.node/walk/collect_ext`. Unit tests on `samples/example.cx` prefix.
- [ ] **P2 parser-core**: combinators + Pratt driver + `ParseEnv`/typedef
      env + error with loc. No Cx rules yet; test with toy grammar.
- [ ] **P3 core grammar**: decls, types+suffix loop, funcs, records/unions/
      enums/bitfields, inits (`[]/{}/cinit`/compound), stmts, full C-expr
      chain, `sizeof/alignof/_Generic/typeof`. Parse 01–06 without expansion.
- [ ] **P4 codegen**: Cx*→C lowerings, directive preservation. 01–06 goldens
      green + `gcc -fsyntax-only` clean.
- [ ] **P5 extensions**: `extension.lua` + `expand.lua` fixpoint/budget +
      `extensions/gnu.lua` proving `07_gnu_*`. Unowned `Ext:*` → hard error.
- [ ] **P6 buildkit**: `CxCompiler` (`file/extension/emit/cc/link`),
      incremental skip, flags passthrough. `build.lua` becomes the demo.
- [ ] **P7 hardening**: error recovery/snippets, fuzz + differential tests,
      docs, strict `lua-language-server --check .` clean.

## 13. Style do / don't

- DO keep functions small, annotate every export, thread `loc` everywhere.
- DO add a golden or unit test with every grammar/codegen change.
- DON'T add dependencies (no LPeg, no luarocks) without explicit approval.
- DON'T emit code for `Ext:*` nodes; DON'T parse `.h` contents as Cx.
- DON'T edit `samples/*.c` expected outputs to make tests pass — fix the
  compiler. (`samples/*.cx` are inputs; `tests/goldens/` snapshots are
  regenerated only via `luajit tests/run.lua --bless` with review.)
