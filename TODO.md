# TODO — Bootstrapping Cx in Cx

Goal: freeze the **fixed core** (lexer → parser-core + grammar table →
`Cx:*` AST → codegen, plus target/buildkit), then reimplement that core
*in Cx itself*, using a small set of extensions for the parts plain Cx
cannot express. Strategy is **strangler fig, Lua stays host**: the
self-hosted `cxc` binary embeds LuaJIT and runs the Lua compiler
unchanged on day one; pipeline pieces move Lua → Cx incrementally over
an FFI boundary, driven by interface cleanliness, not file order. The
end state keeps the *extension runtime* in LuaJIT (extenders write Lua —
that API is a feature, not debt) while all *pipeline* code is Cx.

Non-goals: changing `samples/c-vs-cx.md` core syntax, replacing the Lua
extension API, supporting MSVC for GNU-lowered features.

## 0. Ground truths (verified, do not re-litigate)

- **Toolchain has no `defer`.** Checked GCC 16.2.1 and Clang 22.1.8 on
  this machine: `defer` (C2y proposal, no `stddefer.h` anywhere) does not
  compile. Any `defer`/destructor support must **lower** to something the
  toolchain already has — in practice `__attribute__((cleanup))` on
  gcc/clang, gated off MSVC — not forward to a keyword.
- **Extensions are single-file today.** `compile_source`, `ParseEnv`, and
  `ExpandCtx.root` are all per translation unit (`compiler/init.lua`,
  `compiler/expand.lua`). Cross-file features (modules, whole-program
  monomorphization) need a **new driver-level pass**, not just another
  `extend_grammar` + expander pair. The `gnu.lua` pattern is insufficient
  for items 1 and 3 below.
- **New keywords are free.** `import`, `export`, `defer`, `match`, etc.
  lex as plain `ident`s today (core keywords are only `let function type
  as cinit const constexpr sizeof alignof _Generic`). Extensions can claim
  them exactly like `gnu.lua` claims `__asm__`/`case`, without touching
  the lexer — per the extension contract.
- **Lowering budget per feature is known:** tagged unions ≈ pure desugar
  (no runtime); defer ≈ `cleanup`-attribute desugar (no runtime);
  modules ≈ driver pass + prototype injection (no runtime); generics ≈
  whole-program instantiation (build-system problem, the hard one).
- **LuaJIT FFI works and embed headers are installed** (verified:
  `ffi.os`/`ffi.arch` report correctly, `luajit-2.1/lua.h` +
  `libluajit-5.1.so` present). Both bootstrap directions below are
  buildable on this machine today.
- **Binding constraint: Lua tables do not cross FFI.** Tokens, AST nodes,
  export tables, and argv lists are all plain Lua tables — none of them
  can be passed to a Cx-compiled `.so` directly. This single fact dictates
  the port order in §4: C→Lua direction (embedded host driving Lua code)
  is always clean; Lua→C direction is only clean for C-representable
  signatures (strings, numbers, flat buffers, out-params). Anything else
  needs a marshaling layer or a redesigned flat interface first.
- **Typechecking payoff is modest until Cx gains its own checks.**
  Lowered Cx gets C-compiler diagnostics, which is real but not a
  soundness story. The safety net that matters is tests + differential
  runs + the fixed-point check (§4). Port for dogfooding, distribution
  (single binary), and measured hot loops — not on a blanket "static
  types fix bugs" claim. (LuaJIT is already fast; claim no speedups
  without numbers.)

## 1. Recommended order (dependencies, not preferences)

```
modules (A) ──┬──> generics (D)   [needs cross-TU symbol table]
              └──> self-host (E)  [needs multi-file compiler sources]
tagged unions (B) ──> self-host (E)  [AST-in-Cx is a tagged union]
defer/destructors (C) ──> user ergonomics + optional Rc library
GC decision ──> self-host (E)  [how the stage-2 binary manages memory]
```

**Work on A first.** Everything else either depends on it (D, E) or is
independent and smaller (B, C). Do not start generics before modules —
monomorphization without a module symbol table forces per-TU codegen
hacks (`static` + link dedup) that the module pass will obsolete anyway.

## 2. Extension designs (open questions listed, not resolved)

### A. `modules` — ESM-style import/export (do first)

Sketch (to be ironed out):

```cx
// vec.cx
export function push(v: Vec*, x: int): void { ... }
export type Vec = struct { len: size_t; cap: size_t; items: int*; };

// main.cx
import { push, Vec } from "vec";
```

Design constraints (locked in `compiler/extensions/modules.lua` +
`compiler/modules.lua`, sample `08_modules_*`):

- Exportable surface: functions, `type` aliases, `let`/`const` bindings
  (as `extern` prototypes), and full named record/enum definitions
  (cloned whole — they are self-contained). `struct` tags are otherwise
  file-local. `static_assert`/directives/`;` cannot be exported;
  `static` bindings cannot be exported.
- Resolution: path relative to the importing file's directory, `.cx`
  appended when missing, `.`/`..` collapsed lexically. Absolute paths
  allowed. Unreadable target → located error.
- Cycles rejected with the chain (`a -> b -> a`). Diamond imports parse
  once (visited set). Basenames must be unique per program in v1.
- Mechanism (formalized, not hardcoded): `CxCompiler:program(entry)`
  works with **any registered graph extension** (exactly one per
  program). The contract has two flavors — desugar (`extend_grammar` +
  per-node `expanders`, e.g. gnu) and driver (`extend_grammar` +
  `graph_api` classifiers, e.g. modules). The driver
  (`compiler/modules.lua`) owns graph DFS, cycles, prototype synthesis,
  and splicing; a frontend only classifies markers (`imports_of` edges,
  `exports_of` entries). A Rust-style `mod`/`use`/`pub` frontend reuses
  the driver with its own marker kinds — proven by a test linking a
  second marker family through the same driver. `init.lua` never names a
  frontend. Bodies still compile once from their home TU; link step
  unchanged (`cc`/`link` already handle many objects). One TU = one `.c`
  = one `.o`, same as today. `cc()`/`link()` work unchanged via queued
  sources; `emit_all` re-emits linked ASTs.
- Selectiveness: `import { a, b }` injects only those prototypes (the
  "smarter headers" idea); unknown name → error listing available
  exports. `import *` and `export { … }` are v1 rejections with a clear
  message, as are block-level import/export (top level only).
- Acceptance (all in `tests/modules_test.lua`): parse/shape checks,
  strict-mode rejection, prototype injection, types-first ordering,
  differential run vs hand-written `08_modules_*.c` pair, and located
  errors for unknown/cycle/duplicate/static/missing/collision cases.

### B. `tagged` — Rust-style enum / tagged union + `match` (do second)

Why second: the self-hosted compiler's AST-in-Cx is naturally a tagged
union (`CxNode = IntLit | Binary | Call | …`). Writing the compiler
without this means `void*` + manual tags — the exact pain being removed.

- [ ] Syntax sketch: `tagged Result = Ok(value: int) | Err(code: int);`
  plus `match (r) { Ok(v) => ..., Err(e) => ... }`. Exact keywords open.
- [ ] Lowering (pure desugar, no runtime): `struct { int tag; union {…}; }`
  + `match` → `switch` on the tag with bindings unpacked per arm.
  Exhaustiveness check at expansion time (warn or error — decide).
- [ ] Target note: plain C23 output, no gating needed. MSVC-safe.
- [ ] Acceptance: `samples/programs/09_tagged.*`, exhaustiveness error
  carries a loc, `gcc -fsyntax-only -std=c23` clean.

### C. `scope` — `defer` + destructors (do third)

- [ ] `defer <stmt>;` lowers to a `cleanup`-attribute temporary wrapping a
  generated function containing `<stmt>` (LIFO order at scope exit).
  Gate: reject on `cc == "msvc"` with a loc (same pattern as `gnu.lua`).
- [ ] Destructors: `destructor(T) <fn>` registers `<fn>` as the cleanup
  for `T`-typed bindings at scope exit. Open: explicit annotation vs.
  structural (any `fn(T*)` named `drop`?). Keep explicit in v1.
- [ ] **Rc is a library, not a feature.** On top of generics (D) +
  destructors: `Rc<T> = struct { count: size_t*; ptr: T*; }` with
  clone/drop functions. Do not special-case refcounting in the compiler.
- [ ] Acceptance: `samples/programs/10_defer.*` incl. LIFO order test,
  loop-scope behavior test, msvc rejection test.

### D. `generics` — monomorphize on use (do last, only on trigger)

Trigger: start D when compiler-in-Cx (E) needs a second instantiation of
a container (e.g. `Vec<int>` and `Vec<Node>`), not before.

- [ ] Syntax sketch: `function push<T>(v: Vec<T>*, x: T): void`.
- [ ] Lowering: at expansion time, collect used instantiations from the
  **module export table (A)** and emit one C copy per instantiation with
  a mangled name (`push__int`), typed via the existing declarator
  printer. Requires the whole-program view from A — this is why D waits.
- [ ] Open: constraint syntax (none in v1 — duck-typed, C-style);
  code-bloat guard (budget cap like `expand.lua`'s, error past it);
  incremental builds (instantiation set is part of the rebuild key).
- [ ] Acceptance: `samples/programs/11_generics.*` with ≥2 instantiations,
  no duplicate-symbol link errors, mangle scheme documented.

## 3. Memory management decision (recommendation)

Your "or" is actually two different questions for two different programs:

| Program | Recommendation | Rationale |
|---|---|---|
| stage-2 compiler binary (batch tool) | **Link BDWGC** (`-lgc`) | Throughput-only workload, pauses irrelevant, zero annotation burden on compiler sources, no destructor bugs in the highest-value binary |
| User code written in Cx | **`defer` + destructors (C)**, `Rc<T>` as a library | Ergonomics without a runtime tax on every user binary; GC stays opt-in per program, not imposed by the language |

So: do C now (it serves users regardless), link BDWGC only in the
self-host link step (E3 below), and build `Rc<T>` as a sample/library
once C and D both exist. Do not make the transpiler itself depend on GC.

## 4. Bootstrap stages (E) — strangler fig

Prerequisite for all stages: **freeze the core.** No `Cx:*` grammar or
lowering changes while porting; only additive extensions (A–D). Any core
bug found mid-port gets fixed in Lua first, then ported.

The rule for what moves Lua → Cx, in order of increasing friction:

1. **Greenfield, FFI-clean by design** (no legacy tables to marshal).
2. **Leaf pure helpers** over strings/numbers/buffers (precedence lookup,
   mangling, span arithmetic, golden normalizer — see E1).
3. **Phases only with redesigned flat interfaces** — never by pushing AST
   tables through FFI. AST phases may stay Lua indefinitely; that is a
   stable intermediate, not a failure (end state keeps the Lua extension
  runtime regardless).

- [ ] **E0 — Embed + CLI.** C `main` embeds LuaJIT (`luaL_dofile` the
  existing `compiler/` tree, zero porting) → single `cxc` binary.
  Embedding risk is retired here, not in E3: headers/lib verified
  present (§0). Move CLI/task dispatch out of `build.lua` into `cxc
  build|emit|run|test` (see §6); keep `build.lua` as a compat shim.
- [ ] **E1 — ABI discipline + first Cx units.** Short doc:
  `cxc_` prefix, strings in as `const char*` (Lua-owned, call duration
  only), strings out via caller buffer or callee-allocates + named free,
  errors as integer codes (Lua caller attaches `file:line:col` — Lua
  errors never cross FFI), no callback-heavy APIs (LuaJIT callbacks run
  uninterpretted and must stay referenced). First units: the E0
  fixed-point comparator/normalizer (new code, buffer-oriented, tested by
  construction) + one leaf helper behind `ffi.load` with differential
  tests against the Lua original.
- [ ] **E2 — Phase ports, interface-cleanliness order.** Each ported unit
  ships as a `.so` loaded by the Lua host with dual-run diffs (Lua vs Cx
  on the full sample corpus). Suggested order: golden comparator →
  mangle/normalize helpers → lexer-adjacent scanners (flat buffers) →
  declarator/span logic. AST-table phases (parse, expand, emit
  orchestration) move last, only with flat interfaces — or not at all.
- [ ] **E3 — Stage binaries.** LuaJIT-hosted flow emits the ported units'
  C (`gcc -fsyntax-only -std=c23` clean); link with embedded LuaJIT
  **+ BDWGC** (§3) → `out/selfhost/cxc`.
- [ ] **E4 — Fixed point.** `cxc` recompiles its own Cx sources;
  output byte-identical to the Lua-hosted build. CI gate: any commit
  breaking the fixed point fails `build.lua selfhost --check`.
- [ ] **E5 — Dogfood.** New extensions/samples authored in Cx and built
  with `cxc`; Lua implementation remains the reference.

Known risks: msvc stays parse-only for `scope`/`gnu` lowerings;
monomorphization (D) arriving late must not change already-ported code
(it only adds new syntax, so the freeze holds); FFI callback and string
ownership bugs are the main new bug class — the ABI doc + differential
tests exist to contain it.

## 5. Suggested milestones

1. [ ] M1: `modules` (A) designed, implemented, sampled (`08`), goldened.
2. [ ] M2: `tagged` (B) + `scope` (C) implemented, sampled (`09`, `10`).
3. [ ] M3: E0 embedded `cxc` + CLI (build.lua thinned to shim) + E1 ABI
   doc + first Cx units (comparator + one leaf helper, dual-run green).
4. [ ] M4: E2–E4 → `cxc` fixed point green in CI.
5. [ ] M5: `generics` (D) only if ported code demands it; else `Rc<T>`
   library + docs, and declare victory.

## 6. Build system evolution (deferred — modules first)

Corrected model (earlier draft had this backwards): like `build.zig`,
the **binary owns the CLI** and **calls the project script**. `cxc`
embeds LuaJIT; `build.lua` is the project description the binary
executes — it calls into the compiler API to perform the whole
compilation flow. There is no `build.cx`; the script stays Lua because
the host is Lua.

- [ ] **Later (after E0):** move flag parsing + task dispatch
  (`build|emit|run|test|clean`) into the `cxc` binary. `cxc` loads and
  runs the user's `build.lua` for the project-specific flow (which
  sources, which extensions, which flags). Keep the current
  `luajit build.lua …` path working as a compat shim during transition.
- [ ] Non-goal: a package manager. Relative-path imports (§2.A) plus the
  existing zero-dependency rule stay.
