# TODO — Cx Roadmap: General Language Extensions & Ecosystem Goals

**Vision:** Make Cx a modern, general-purpose systems programming language over C23
with exceptional developer ergonomics. Cx provides **first-class declarative UI syntax (JSX),
automated resource management (RAII/destructors), closures, and async/await**, while remaining
**100% library-agnostic at the language core**.

**Application Targets:** While Cx language extensions are completely decoupled from any single
library, our primary flagship application goals are **native Linux desktop applications
(GTK4 + Libadwaita)** and **high-performance async system services (GIO / libsoup / epoll)**.

**Pivot Context:** Bootstrapping the Cx compiler in Cx itself is intentionally
retired as a priority. LuaJIT is sub-millisecond fast, has zero native dependencies,
and provides a rock-solid, extensible compiler host. Keeping the compiler host in
LuaJIT frees 100% of our engineering bandwidth to focus on user-facing features and libraries.

---

## 0. Architecture: Decoupling Extensions from Libraries

A core principle of Cx is **clean separation between language extensions and library bindings**:

1. **Extensions are General Language Primitives:**
   - `compiler/extensions/jsx.lua`: A generic AST transform for `<Tag prop={val}>children</Tag>`.
     Works with *any* C factory convention (GTK, Raylib, Clay, DOM, custom tree builders).
   - `compiler/extensions/clean.lua`: A general RAII destructor convention `{Type}_clean(&x)`
     and `take(x)` desugared to `defer`. Works with `FILE*`, `malloc`, POSIX sockets, or GObject.
   - `compiler/extensions/closure.lua`: First-class closures with environment structs, static
     thunks, and defunctionalization optimizations. Works with any C callback API `(fn, user_data, free_user_data)`.
   - `compiler/extensions/async.lua`: Lightweight CPS (Continuation-Passing Style) desugaring
     into `Ext:Closure`, with closure-level defunctionalization yielding stackless state machines.
2. **Library Conventions Live in Userland / Adapters:**
   - Specific GObject/GTK4/GIO integrations (e.g. `gclass`, Libadwaita container protocols,
     GIO `_async`/`_finish` wrappers) live as opt-in dialect modules or standard header libraries.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Core Language Extensions                        │
│    JSX (Tree Builder) │ Clean / RAII │ Closures │ Async (via CPS)      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
           ┌────────────────────────┴────────────────────────┐
           ▼                                                 ▼
┌─────────────────────────────────────┐   ┌──────────────────────────────────────┐
│       GTK4 / Libadwaita Domain      │   │    Other Domains (Clay, Raylib,      │
│  - GObject ref counting via Clean   │   │     Embedded, POSIX HTTP, Win32)     │
│  - GTK4 widget trees via JSX        │   │  - Tree building for Clay/Raylib     │
│  - GIO async runtime adapter        │   │  - POSIX file/socket RAII cleanups   │
│  - gclass OOP boilerplate           │   │  - Zero runtime dependencies         │
└─────────────────────────────────────┘   └──────────────────────────────────────┘
```

---

## 1. Deep Dive: CPS + Defunctionalization (The Best of Both Worlds)

The classic tension in language design is:
- **CPS (Continuation-Passing Style):** Elegant, simple frontend desugaring (`async`/`await` simply slices statements into lambdas), but naive implementations suffer from multiple heap allocations and indirect function pointer overhead.
- **Stackless State Machine:** Fast (single allocation, `switch(state)` resumption), but complex compiler frontend (spilling locals, manually tracking state points across loops and branches).

### The Solution: CPS Frontend + Defunctionalized Closures

By applying **defunctionalization** (Reynolds, 1972) inside the closure pipeline, we get **both**:
the frontend simplicity of CPS and the runtime efficiency of a stackless state machine.

```
[Developer Code]
   async function foo() { await step1(); await step2(); }
         │
         ▼ (Round 1: Ext:Async CPS slice — simple AST rewrite)
[CPS Closures]
   step1((res1) => { step2((res2) => { ... }) })
         │
         ▼ (Round 2: Closure Defunctionalization Pass)
[Single Unified Frame + Tagged Dispatch]
   - Coalesces the continuation chain of the function into ONE state enum (STEP1, STEP2)
   - Unifies captured locals into ONE shared frame struct
   - Turns indirect closure calls into a local `switch (frame->state)` state machine
         │
         ▼ (Round 3: Codegen)
[Zero-Cost C23 Code]
   - Exactly ONE allocation (or stack frame)
   - Compiles down to standard C23 switch/goto with full GCC/Clang inlining!
```

### Why This Is Architecturally Superior for Cx

1. **Frontend Simplicity:**
   - The `async` extension doesn't need to know anything about C control flow, register spilling, or state tables. It just performs a straightforward CPS lambda wrap.
2. **Unified Optimization Engine in `closure.lua`:**
   - Instead of building a specialized coroutine engine *and* a separate closure engine, we put the optimization into the closure pipeline.
   - Any local closure pattern (e.g. chaining, immediate invocation, continuation pipelines) benefits from defunctionalization and frame coalescence, not just `async`.
3. **Graceful Fallback:**
   - Escaping closures that are passed to third-party C APIs (like GTK button signals) fall back naturally to dynamic environment structs + static thunks with `GDestroyNotify`.
   - Internal continuation chains are detected and collapsed into a static state machine.

---

## 2. Feature Extension Specifications

### Phase 1: Buildkit & Toolchain Helpers (`compiler/buildkit.lua`)

Keep build scripts user-friendly while supporting system package detection.

- [ ] **`buildkit.pkg_config(...)`:**
  - General helper: `pkg-config --cflags --libs <packages...>`.
  - Not tied to GTK: works with `sdl2`, `sqlite3`, `libuv`, `gtk4`, `libsoup-3.0`, etc.
  - Injects include paths and link flags into `b:cc()` and `b:link()`.
- [ ] **Asset / Resource compilation:**
  - Helpers for C23 `#embed` and optional external tools (`glib-compile-resources`, `windres`).

---

### Phase 2: Destructor / Drop System (RAII desugared to `defer`)

A completely library-agnostic resource cleanup convention.

- [x] **`defer` extension (`compiler/extensions/defer.lua`):**
  - Portable LIFO scope-exit cleanup lowering across GCC, Clang, MSVC, and TCC.
- [ ] **Clean Function Convention (`compiler/extensions/clean.lua`):**
  - Any type `T` with a matching `{T}_clean(self: T*)` or attribute `[[clean(fn)]]`
    automatically synthesizes a scope-exit `defer`:
    ```cx
    type FileHandle = struct { fd: int; };
    function FileHandle_clean(h: FileHandle*): void {
        if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    }

    function test(): void {
        let f: FileHandle = open_file("foo.txt");
        // Compiler auto-inserts: defer FileHandle_clean(&f);
    }
    ```
- [ ] **Ownership Transfer (`take(x)` / `move(x)`):**
  - Built-in expression `take(x)`: reads `x`, zeroes/nulls `x` in the local scope,
    and returns the value. Prevents premature cleanup on return or container insertion.
- [ ] **Library Bindings (Userland Header):**
  - In a standard header (e.g. `cx_glib.h`):
    ```cx
    type GObjectPtr = GObject*;
    function GObjectPtr_clean(p: GObjectPtr*): void {
        if (*p) { g_object_unref(*p); *p = NULL; }
    }
    ```
  - Core compiler stays 100% free of GObject knowledge.

---

### Phase 3: Closures & Defunctionalization (`compiler/extensions/closure.lua`)

First-class closures with optimization for continuation and callback patterns.

- [ ] **Syntax:**
  ```cx
  let mul = (x: int) => x * factor;
  ```
- [ ] **Lowering (Pure C AST expansion):**
  1. Capture analysis (detect referenced outer variables).
  2. **Escaping Closures (Fallback Path):**
     - Synthesize `struct __cx_env_N { ... }` and `static Ret __cx_thunk_N(Args..., void* user_data)`.
     - Yields a `(fn_ptr, user_data, free_fn)` tuple (compatible with `GDestroyNotify`).
  3. **Continuation / Local Chains (Defunctionalization Path):**
     - Detect closures passed as continuations within the same translation unit.
     - Coalesce captured variables into a single shared frame struct.
     - Replace indirect calls with an enum tag and direct dispatch function (`switch (tag)`).
- [ ] **Acceptance:**
  - Tests covering variable capture, `GDestroyNotify` cleanup, and defunctionalized continuation chains.

---

### Phase 4: Generic Declarative UI Syntax (`compiler/extensions/jsx.lua`)

A generic, library-agnostic JSX extension for hierarchical tree construction in C.

- [ ] **Syntax:**
  ```cx
  let root = <Container spacing={10}>
      <Item title="First" />
      <Item title="Second" />
  </Container>;
  ```
- [ ] **Generic Factory Protocol:**
  - Desugars based on configurable naming rules or functional components:
    - `<Foo a={b} />` lowers to `Foo_new()` or `foo_new()` followed by property assignments.
    - Child elements invoke container attachment protocol:
      `Container_append(parent, child)` or custom slot handlers (`slot="header"`).
  - Can be configured for:
    - **GTK4 / Libadwaita** (`gtk_*_new`, `gtk_box_append`, `adw_window_set_content`)
    - **Clay / Raylib UI** (immediate-mode UI layout trees)
    - **Custom DOM / Node trees**
- [ ] **Functional Components:**
  - Any function returning a widget/element pointer can be used as a tag name:
    ```cx
    function Header(props: HeaderProps): GtkWidget* { ... }
    <Header title="App" />
    ```

---

### Phase 5: Async / Await via CPS (`compiler/extensions/async.lua`)

Simple frontend desugaring that leverages the closure optimization pipeline.

- [ ] **Syntax sketch:**
  ```cx
  async function fetch_avatar(user_id: int): GdkTexture* {
      let path: char* = await fetch_avatar_path(user_id);
      let bytes: GBytes* = await read_file_async(path);
      return gdk_texture_new_from_bytes(bytes);
  }
  ```
- [ ] **CPS Transformation Rules:**
  1. Add completion continuation parameter `__cb` and `__user_data`.
  2. Rewrite `return expr` to `__cb(expr, __user_data); return;`.
  3. Slice `await` points into continuation closures passed to the async function.
- [ ] **Defunctionalization Hand-off:**
  - Sliced continuation closures are tagged with `Ext:Closure:Continuation`.
  - Phase 3 closure pipeline defunctionalizes the continuation chain into a unified frame + `switch(state)`,
    yielding stackless state machine performance without any coroutine complexity in `async.lua`.
- [ ] **Acceptance:**
  - Async non-blocking I/O sample compiling to single-allocation state machine C code.

---

### Phase 6: Domain-Specific Extensions & Showcases

With the core language primitives complete, build domain-specific modules:

- [ ] **GObject Helper (`compiler/extensions/gobject.lua` or dialect):**
  - `gclass` syntactic sugar to eliminate GLib boilerplate for custom widgets.
- [ ] **GTK4 + Libadwaita Showcase:**
  - Modern desktop app showcasing JSX, RAII destructors, and signal closures.
- [ ] **High-Performance Async Backend Showcase:**
  - Async HTTP service using `libsoup-3.0` or `libuv` driven by Cx async functions.

---

## 3. Milestones & Work Order

| Milestone | Deliverables | Acceptance Criteria |
|---|---|---|
| **M1: Buildkit `pkg_config`** | `buildkit.pkg_config()` | Configures arbitrary C libraries (`gtk4`, `sqlite3`, etc.) |
| **M2: RAII Cleanups & `take()`**| `compiler/extensions/clean.lua` | Automated `{T}_clean(&x)` lowering to `defer`; `take(x)` transfer |
| **M3: Closures & Defunctionalization** | `compiler/extensions/closure.lua` | Variable capture, static thunks, continuation defunctionalization |
| **M4: Library-Agnostic JSX** | `compiler/extensions/jsx.lua` | Hierarchical tree builder desugaring to factory + child appends |
| **M5: CPS Async / Await** | `compiler/extensions/async.lua` | CPS rewrite into defunctionalized continuation closures |
| **M6: GTK4 & Libadwaita App Demo** | Desktop sample (`samples/programs/gtk_app.cx`) | Complete desktop application with JSX UI, destructors, and closures |
| **M7: Async Server Demo** | HTTP service sample (`samples/programs/http_server.cx`) | Non-blocking async server showing coroutine performance |

---

## 4. What We Are NOT Doing (Explicit Non-Goals)

1. **No Hardcoded Library Dependencies in Compiler Core:**
   - The compiler will **never** link against GTK, GLib, or any C library. All library
     interactions happen purely in generated C code via standard headers.
2. **No JavaScript / Web Runtime Engine:**
   - JSX is strictly a compile-time tree construction transform. Zero JS engines, zero VDOM.
3. **No Garbage Collection Runtime:**
   - Memory management is deterministic via `defer` and RAII cleanups (`{T}_clean`).
4. **No Dynamic Header Parsing:**
   - Cx does not parse `.h` headers into compiler internal types. Type annotations remain
     straightforward C types, keeping compilation instant.
