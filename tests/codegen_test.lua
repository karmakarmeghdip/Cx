-- P4 codegen unit tests: exact-string lowerings (declarators, casts,
-- initializers, statements, directives). Sample-level fidelity belongs to
-- the golden + differential harness.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")
    local ast = require("compiler.ast")
    local G = require("compiler.grammar_cx")
    local codegen = require("compiler.codegen")

    --- Compile src (a full translation unit) to C text.
    --- @param src string
    --- @param opts table|nil {cc, std, line_markers}
    --- @return string
    local function emit_src(src, opts)
        opts = opts or {}
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local root = core.parse_unit(p, G.rules.parseTranslationUnit, "test")
        return codegen.emit(root, {
            cc = opts.cc or "clang",
            std = opts.std or "c23",
            src = src,
            line_markers = opts.line_markers,
        })
    end

    ctx.check("codegen: pointer/array declarators go inside-out", function()
        assert(emit_src("let r: int[4]*;") == "int (*r)[4];\n", "ptr-to-array wrong")
        assert(emit_src("let r: int*[4];") == "int *r[4];\n", "array-of-ptr wrong")
        assert(emit_src("let p: int**;") == "int **p;\n", "ptr-ptr wrong")
        assert(emit_src("let q: const char* const;") == "const char *const q;\n",
            "quals wrong")
        assert(emit_src("let v: int* restrict;") == "int *restrict v;\n", "restrict wrong")
    end)

    ctx.check("codegen: function declarators (incl. nested)", function()
        assert(emit_src("let f: ((int, char*) => int)*;")
            == "int (*f)(int, char *);\n", "fn ptr wrong")
        assert(emit_src("let a: ((int) => int)*[3];")
            == "int (*a[3])(int);\n", "array of fn ptr wrong")
        assert(emit_src("function f(): int;") == "int f(void);\n", "void params wrong")
        assert(emit_src("function f(a: int[static 4]): void;")
            == "void f(int a[static 4]);\n", "static bound wrong")
        assert(emit_src("function f(cb: ((int) => void)*): void;")
            == "void f(void (*cb)(int));\n", "nested fn param wrong")
        assert(emit_src("function f(...): void;") == "void f(...);\n", "... wrong")
    end)

    ctx.check("codegen: exotic types print C23", function()
        assert(emit_src("let v: unsigned _BitInt(37);")
            == "unsigned _BitInt(37) v;\n", "bitint wrong")
        assert(emit_src("let a: _Atomic(int);") == "_Atomic(int) a;\n", "atomic wrong")
        assert(emit_src("let t: typeof(x);") == "typeof(x) t;\n", "typeof expr wrong")
        assert(emit_src("let t: typeof_unqual(const int);")
            == "typeof_unqual(const int) t;\n", "typeof type wrong")
        assert(emit_src("let z: double _Complex;") == "double _Complex z;\n",
            "complex wrong")
        assert(emit_src("let d: _Decimal64;") == "_Decimal64 d;\n", "decimal wrong")
        assert(emit_src("static alignas(16) let a: int;")
            == "alignas(16) static int a;\n", "alignas wrong")
        assert(emit_src("static _Alignas(double) let a: char;")
            == "_Alignas(double) static char a;\n", "_Alignas spelling lost")
    end)

    ctx.check("codegen: bindings (multi, inference, const, auto)", function()
        assert(emit_src("let a: int = 1, b: int = 2;") == "int a = 1, b = 2;\n",
            "shared type wrong")
        assert(emit_src("let x = 5;") == "auto x = 5;\n", "inference wrong")
        assert(emit_src("const x: const int = 1;") == "const int x = 1;\n",
            "const doubling wrong")
        assert(emit_src("const x: int = 1;") == "const int x = 1;\n", "const lost")
        assert(emit_src("constexpr let n: int = 2;") == "constexpr int n = 2;\n",
            "constexpr wrong")
        do
            local ok = pcall(emit_src, "register let s: int = 1;")
            assert(not ok, "register must be rejected (spec)")
        end
        assert(emit_src("thread_local let t: int;") == "thread_local int t;\n",
            "thread_local spelling wrong")
        assert(emit_src("let v: int = [];") == "int v = {};\n", "[] wrong")
    end)

    ctx.check("codegen: casts print C-style with minimal parens", function()
        local out = emit_src("function f(): void { value as void; }")
        assert(out:find("(void)value;", 1, true) ~= nil, "as void wrong:\n" .. out)
        local out2 = emit_src("function f(): void { (a + b) as int; }")
        assert(out2:find("(int)(a + b);", 1, true) ~= nil, "low-prec target wrong:\n" .. out2)
        local out3 = emit_src("let x: int = y as int as float;")
        assert(out3:find("(float)(int)y;", 1, true) ~= nil, "as chain wrong:\n" .. out3)
    end)

    ctx.check("codegen: precedence re-derives needed parens only", function()
        local out = emit_src("function f(): void { a + b * c; a * (b + c); -(a + b); }")
        assert(out:find("a + b * c;", 1, true) ~= nil, "bare chain wrong")
        assert(out:find("a * (b + c);", 1, true) ~= nil, "needed parens lost")
        assert(out:find("-(a + b);", 1, true) ~= nil, "unary parens lost")
        local out2 = emit_src("function f(): void { (*p)++; *p++; }")
        assert(out2:find("(*p)++;", 1, true) ~= nil, "deref-inc wrong")
        assert(out2:find("*p++;", 1, true) ~= nil, "post-inc wrong")
    end)

    ctx.check("codegen: initializers lower structurally", function()
        local out = emit_src("let m: int[2][2] = [[1, 2], [3, 4]];")
        assert(out:find("int m[2][2] = {{1, 2}, {3, 4}};", 1, true) ~= nil,
            "matrix wrong:\n" .. out)
        local out2 = emit_src("let p: struct P = {x: 1, y: 2};")
        assert(out2:find("struct P p = {.x = 1, .y = 2};", 1, true) ~= nil,
            "record wrong:\n" .. out2)
        local out3 = emit_src("let c: int* = (int[])[1, 2];")
        assert(out3:find("(int[]){1, 2};", 1, true) ~= nil, "compound wrong:\n" .. out3)
        local out4 = emit_src('let s: char[] = "a" "b";')
        assert(out4:find('char s[] = "a" "b";', 1, true) ~= nil, "concat wrong:\n" .. out4)
    end)

    ctx.check("codegen: aggregates, aliases, asserts print C", function()
        local out = emit_src("struct P { x: int; y: int; };")
        assert(out == "struct P {\n    int x;\n    int y;\n};\n", "struct wrong:\n" .. out)
        local out2 = emit_src("struct B { low: unsigned int: 3; : 0; };")
        assert(out2:find("unsigned int low : 3;", 1, true) ~= nil, "bitfield wrong")
        assert(out2:find("unsigned : 0;", 1, true) ~= nil, "bare : 0 wrong")
        local out3 = emit_src("type Fn = ((int) => int)*;")
        assert(out3 == "typedef int (*Fn)(int);\n", "alias wrong:\n" .. out3)
        local out4 = emit_src("enum E : unsigned char { A, B = 3, };")
        assert(out4:find("enum E : unsigned char {", 1, true) ~= nil, "enum wrong")
        local out5 = emit_src('static_assert(1); static_assert(1, "m");')
        assert(out5:find('static_assert(1, "m");', 1, true) ~= nil, "assert wrong")
        local out6 = emit_src("type Vec = struct { len: int; items: int*; };")
        assert(out6 == "typedef struct {\n    int len;\n    int *items;\n} Vec;\n",
            "anon alias wrong:\n" .. out6)
    end)

    ctx.check("codegen: statements (for, switch, labels, attrs)", function()
        local out = emit_src("function f(): void { for (;;) { break; } }")
        assert(out:find("for (;;) {", 1, true) ~= nil, "for(;;) wrong:\n" .. out)
        local out2 = emit_src("function f(): void { [[fallthrough]]; }")
        assert(out2:find("[[fallthrough]];", 1, true) ~= nil, "attr stmt wrong")
        local out3 = emit_src("function f(): void { goto d; d: ; }")
        assert(out3:find("goto d;", 1, true) ~= nil, "goto wrong")
        assert(out3:find("d:\n", 1, true) ~= nil, "label wrong")
        local out4 = emit_src("function f(x: int): int { switch (x) { case 0: return 1; default: return 0; } }")
        assert(out4:find("case 0:", 1, true) ~= nil, "case wrong")
        assert(out4:find("default:", 1, true) ~= nil, "default wrong")
        local out5 = emit_src("function f(): void { do { x(); } while (ok); }")
        assert(out5:find("} while (ok);", 1, true) ~= nil, "do-while wrong")
    end)

    ctx.check("codegen: statement attributes are emitted, never dropped", function()
        -- Spec: statement = attributes? (...). Dropping them is a silent
        -- miscompile (reliability), so every branch must preserve them.
        local cases = {
            { src = "function f(): void { [[likely]] if (a) { b(); } }", want = "[[likely]] if (a)" },
            { src = "function f(): void { [[unroll]] for (;;) { break; } }", want = "[[unroll]] for (;;)" },
            { src = "function f(): void { [[likely]] while (a) { b(); } }", want = "[[likely]] while (a)" },
            { src = "function f(): void { [[a]] switch (x) { default: break; } }", want = "[[a]] switch (x)" },
            { src = "function f(): void { [[a]] return 1; }", want = "[[a]] return 1;" },
            { src = "function f(): void { [[a]] break; }", want = "[[a]] break;" },
            { src = "function f(): void { [[a]] continue; }", want = "[[a]] continue;" },
            { src = "function f(): void { [[a]] goto d; d: ; }", want = "[[a]] goto d;" },
        }
        for _, c in ipairs(cases) do
            local got = emit_src(c.src)
            assert(got:find(c.want, 1, true) ~= nil,
                "attr lost for " .. c.src .. ":\n" .. got)
        end
    end)

    ctx.check("codegen: sizeof/Generic keep source shapes", function()
        local out = emit_src("function f(): int { return sizeof(x) + sizeof(int); }")
        assert(out:find("sizeof(x) + sizeof(int);", 1, true) ~= nil, "sizeof wrong")
        local out2 = emit_src("function f(v: int): int { return _Generic(v, int: 1, default: 0); }")
        assert(out2:find("_Generic(v, int: 1, default: 0);", 1, true) ~= nil,
            "generic wrong")
    end)

    ctx.check("codegen: directives stay verbatim (incl. splices)", function()
        local out = emit_src("#define X 1 \\\n+ 2\nlet a: int = X;")
        assert(out:find("#define X 1 \\\n+ 2\n", 1, true) ~= nil, "directive reflowed:\n" .. out)
        assert(out:find("int a = X;", 1, true) ~= nil, "decl wrong")
    end)

    ctx.check("codegen: msvc hook rejects unsupported constructs", function()
        local function rejects(src, what)
            local ok, err = pcall(emit_src, src, { cc = "msvc" })
            assert(not ok and tostring(err):find(what, 1, true) ~= nil,
                what .. " must be rejected on msvc: " .. tostring(err))
        end
        rejects("let t: typeof(x);", "typeof")
        rejects("let v: unsigned _BitInt(8);", "_BitInt")
        rejects("let d: _Decimal32;", "_Decimal32")
        rejects("function f(): void { let a: size_t = alignof(int); }", "alignof")
        rejects("let w: int = 42wb;", "42wb")
        local ok = pcall(emit_src, "let x: int = 1;", { cc = "msvc" })
        assert(ok, "plain decl must pass on msvc")
    end)

    ctx.check("codegen: #line markers are opt-in", function()
        local plain = emit_src("let a: int = 1;\nlet b: int = 2;\n")
        assert(plain:find("#line", 1, true) == nil, "markers must default off")
        local marked = emit_src("let a: int = 1;\nlet b: int = 2;\n", { line_markers = true })
        assert(marked:find('#line 1 "t.cx"', 1, true) ~= nil, "first marker missing")
        assert(marked:find('#line 2 "t.cx"', 1, true) ~= nil, "second marker missing")
    end)

    ctx.check("codegen: unexpanded Ext nodes are hard errors", function()
        local loc = { file = "t.cx", line = 1, col = 1, end_line = 1, end_col = 2, offset = 1 }
        local bad = ast.translation_unit(loc, {
            ast.node("Ext:Gnu:StmtExpr", loc, {}),
        })
        local ok, err = pcall(codegen.emit, bad, { cc = "clang", std = "c23", src = "" })
        assert(not ok and tostring(err):find("unexpanded", 1, true) ~= nil,
            "Ext must fail loudly: " .. tostring(err))
    end)
end
