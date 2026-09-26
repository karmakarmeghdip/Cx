# Cx — a thin syntactic layer over C23

Cx keeps C's expressions, control flow, pointer operations, aggregate
layout, and preprocessor model, while adding a TypeScript-like surface for
declarations (`let x: int`), functions (`function f(a: int): int`), type
aliases (`type T = ...`), casts (`x as T`), and callback types
(`((int) => int)*`). The compiler parses `.cx` and emits plain C, then
optionally drives a C toolchain. The language spec lives in
[`samples/c-vs-cx.md`](samples/c-vs-cx.md); `AGENTS.md` is the
architecture/workflow source of truth for contributors.

## Setup

- **Runtime:** LuaJIT (`luajit -v` must work). Zero dependencies — no LPeg,
  no luarocks, no native modules.
- **Static analysis:** lua-language-server (`lua-language-server --version`),
  configured by `.luarc.json` (`runtime.version = "LuaJIT"`).
- **C toolchain (optional, degrades gracefully):** `gcc` or `clang` with C23
  support for the `cc`/`link`/`run` steps and the differential golden tests.

## Quickstart

```sh
luajit build.lua --help        # tasks and flags
luajit tests/run.lua           # full suite (goldens + units, no network)
luajit build.lua build         # emit+compile+link samples 01-06 -> out/<stem>
luajit build.lua run 01        # build (if needed) and execute a sample
luajit build.lua emit          # emit 01_hello_args.cx -> out/01.c
luajit build.lua clean         # remove out/
lua-language-server --check .  # diagnostics must stay clean
```

Useful flags: `build [--cc gcc] [--std c23] [--force]`,
`test -- --bless` (regenerate golden snapshots — review the diff),
`test -- --filter <substr>`, `test -- --fuzz-seed <n>`.

A minimal build script (see `build.lua`, which is user-editable):

```lua
local Cx = require("compiler.init")
local b = Cx.new({ std = "c23", cc = "gcc" })
b:extension("gnu", require("compiler.extensions.gnu"))
b:file("samples/programs/01_hello_args.cx"):emit("out/01.c")
b:cc({ flags = { "-Wall", "-Wextra" } }):link({ out = "out/app" })
print(b:run({ out = "out/app", args = { "you" } }))
```

## Architecture

```
.cx source -> lexer -> parser-core + grammar-table -> AST (Cx* + Ext*)
         -> expand loop (Ext* -> Cx*, target-aware) -> codegen -> .c
         -> (optional) cc/link for that target
```

| Module | Role |
|---|---|
| `compiler/lexer.lua` | Splicing, C23 literals, trivia, opaque directives, `Loc` |
| `compiler/parser_core.lua` | Grammar-agnostic combinators + Pratt driver + `ParseEnv` + recovery |
| `compiler/grammar_cx.lua` + `compiler/grammar/` | Core language as a Lua table (the only syntax spec) |
| `compiler/ast.lua` | `Cx:*`/`Ext:*` nodes, walk/replace, s-expr dump |
| `compiler/extension.lua` | Extension validation + per-parse grammar assembly |
| `compiler/expand.lua` | Bounded fixpoint expansion (budgeted, deterministic) |
| `compiler/extensions/gnu.lua` | GNU/K&R dialect (statement-exprs, K&R, asm, …) |
| `compiler/codegen.lua` + `compiler/codegen/` | `Cx*` → C text (core/emitter, types, exprs, stmts, decls) |
| `compiler/target.lua` | Triples, host detection, cc flag maps (only host-aware module) |
| `compiler/buildkit.lua` | glob, mkdir-p, mtime skip, exec (build-script helpers) |
| `compiler/init.lua` | `CxCompiler`: `new/file/extension/parse_file/emit/emit_all/cc/link/run` |

Two node families: `Cx:*` (native, codegen knows them exhaustively) and
`Ext:*` (extension markers, expanded before codegen — leftovers are hard
errors). Errors are `ParseError` tables rendering as `file:line:col` plus a
snippet; declaration/statement loops recover (panic-mode) and report an
aggregate of up to 10.

## Testing

`tests/run.lua` is the only entry point; each `tests/*_test.lua` returns
`function run(ctx)` and uses plain `assert` + `ctx.check`. Coverage:

- **Goldens** (`tests/goldens/`): 01–06 strict snapshots (round-trip +
  `gcc -fsyntax-only` + differential stdout/exit vs `samples/*.c` under
  gcc *and* clang), 07 GNU snapshot (`-std=gnu23` + differential).
- **Units per phase**: lexer/AST, parser-core (toy grammar), full grammar
  (constructs + 01–06 shapes + strict negatives), codegen lowerings,
  extension/expansion machinery, GNU per-construct round-trips, target
  matrix, buildkit, recovery (multi-error aggregates, partial trees, cap).
- **Fuzz** (`tests/fuzz_test.lua`, seeded): token soup + byte-mutated
  samples through lex+parse under both grammars. Oracle: success, or a
  located `file:line:col:` failure — never a bare Lua crash or hang.

## Writing an extension

```lua
local M = { name = "Mine" }
function M.extend_grammar(G, env)
    -- env = { target = {cc, std, ...}, dialect = { mine = true } }
    -- add G.prefix/G.infix entries or wrap G.rules.* functions here;
    -- parse new forms into Ext:Mine:* nodes (never touch the lexer).
end
M.expanders = {
    ["Ext:Mine:Thing"] = function(ctx, node)
        -- ctx = { root, target, dialect, replace }
        -- branch on ctx.target (never jit.os); return Cx:* node(s).
    end,
}
return M
```

Register with `b:extension("mine", require("..."))`. Strict inputs must keep
parsing identically with the extension registered (assembly copies the base
grammar — covered by test).

## Phase status (AGENTS.md §12)

P0 scaffold · P1 lexer+AST · P2 parser-core · P3 core grammar ·
P4 codegen · P5 extensions+GNU · P6 buildkit+target — all green.
P7 (this phase): recovery, fuzz, docs, type-safety sweep.
