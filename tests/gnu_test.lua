-- P5 GNU dialect tests: each form parses (gnu) to Ext, expands to Cx:Gnu,
-- and emits exact GNU C; the same snippet must FAIL in strict mode.
-- 07_gnu_* acceptance itself lives in the golden harness.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")
    local ast = require("compiler.ast")
    local base_G = require("compiler.grammar_cx")
    local extension = require("compiler.extension")
    local expand = require("compiler.expand")
    local codegen = require("compiler.codegen")
    local gnu = require("compiler.extensions.gnu")

    --- Assembled GNU grammar for target cc.
    --- @param cc string|nil
    --- @return table G
    local function gnu_G(cc)
        return extension.assemble(base_G, { { name = "gnu", mod = gnu } },
            { target = { cc = cc or "clang", std = "gnu23" }, dialect = { gnu = true } })
    end

    --- Parse src with a grammar (no expansion): returns root + Ext kinds.
    --- @param src string
    --- @param G CxGrammar
    --- @param file string|nil
    --- @return table root
    local function parse_with(src, G, file)
        local toks = lexer.lex(src, file or "t.cx")
        local env = core.new_env({ file = file or "t.cx", src = src,
            target = { cc = "clang", std = "gnu23" },
            dialect = { gnu = G ~= base_G }, grammar = G })
        local p = core.new(toks, env)
        return core.parse_unit(p, G.rules.parseTranslationUnit, "test")
    end

    --- Full GNU pipeline for target cc: parse, expand, emit.
    --- @param src string
    --- @param cc string|nil
    --- @return string C text
    local function gnu_emit(src, cc)
        cc = cc or "clang"
        local G = gnu_G(cc)
        local root = parse_with(src, G)
        local out = expand.expand(root, gnu.expanders,
            { target = { cc = cc, std = "gnu23" }, dialect = { gnu = true } })
        assert(#ast.collect_ext(out) == 0, "Ext must be gone after expand")
        return codegen.emit(out, { cc = cc, std = "gnu23", src = src })
    end

    --- Assert strict (base grammar) rejects src.
    --- @param src string
    local function strict_rejects(src)
        local ok, err = pcall(parse_with, src, base_G)
        assert(not ok, "strict must reject: " .. src)
        assert(tostring(err):find("t.cx:", 1, true) ~= nil, "error needs a loc")
    end

    ctx.check("gnu: case ranges round-trip", function()
        local out = gnu_emit("function f(v: int): int { switch (v) { case 1 ... 5: return 1; default: return 0; } }")
        assert(out:find("case 1 ... 5:", 1, true) ~= nil, "range lost:\n" .. out)
        strict_rejects("function f(v: int): int { switch (v) { case 1 ... 5: return 1; } }")
    end)

    ctx.check("gnu: omitted-middle ternary round-trips", function()
        local out = gnu_emit("function f(v: int): int { return v ?: 9; }")
        assert(out:find("return v ?: 9;", 1, true) ~= nil, "?: lost:\n" .. out)
        strict_rejects("function f(v: int): int { return v ?: 9; }")
    end)

    ctx.check("gnu: statement expressions (init and return positions)", function()
        local out = gnu_emit("function f(v: int): int { let e: int = ({ v + 1; }); return ({ e; }); }")
        assert(out:find("int e = ({ v + 1; });", 1, true) ~= nil, "init stmt-expr wrong:\n" .. out)
        assert(out:find("return ({ e; });", 1, true) ~= nil, "return stmt-expr wrong")
        strict_rejects("function f(v: int): int { return ({ v; }); }")
    end)

    ctx.check("gnu: computed goto and label addresses", function()
        local out = gnu_emit("function f(v: int): int { static let t: void*[] = [&&a, &&b]; goto *t[v]; a: return 0; b: return 1; }")
        assert(out:find("goto *t[v];", 1, true) ~= nil, "computed goto wrong:\n" .. out)
        assert(out:find("{&&a, &&b};", 1, true) ~= nil, "label addrs wrong")
        strict_rejects("function f(v: int): int { goto *t; }")
        strict_rejects("function f(v: int): int { let t: int = &&a; }")
    end)

    ctx.check("gnu: K&R definitions keep decl lines verbatim", function()
        local src = "static int add(a, b)\nint a;\nint b;\n{\nreturn a + b;\n}\n"
        local out = gnu_emit(src)
        assert(out:find("static int add(a, b)", 1, true) ~= nil, "K&R header wrong:\n" .. out)
        assert(out:find("int a;\nint b;", 1, true) ~= nil, "K&R lines wrong")
        strict_rejects(src)
    end)

    ctx.check("gnu: nested functions and __label__ decls", function()
        local out = gnu_emit("function f(v: int): int { __label__ done; function h(x: int): int { return x; } goto done; done: return h(v); }")
        assert(out:find("__label__ done;", 1, true) ~= nil, "label decl wrong:\n" .. out)
        assert(out:find("int h(int x)", 1, true) ~= nil, "nested fn wrong")
        strict_rejects("function f(v: int): int { __label__ done; goto done; done: return v; }")
        strict_rejects("function f(v: int): int { function h(x: int): int { return x; } return h(v); }")
    end)

    ctx.check("gnu: inline assembly keeps payload verbatim", function()
        local out = gnu_emit('function f(v: int): void { __asm__ volatile ("" : "+r"(v) : : "memory"); }')
        assert(out:find('__asm__ volatile ("" : "+r"(v) : : "memory");', 1, true) ~= nil,
            "asm wrong:\n" .. out)
        strict_rejects('function f(v: int): void { __asm__ volatile (""); }')
    end)

    ctx.check("gnu: trailing attributes stay trailing", function()
        local out = gnu_emit("struct S { x: int; } __attribute__((packed));")
        assert(out:find("} __attribute__((packed));", 1, true) ~= nil, "record trailing wrong:\n" .. out)
        local out2 = gnu_emit("type V = int __attribute__((vector_size(16)));")
        assert(out2:find("typedef int V __attribute__((vector_size(16)));", 1, true) ~= nil,
            "alias trailing wrong:\n" .. out2)
        strict_rejects("struct S { x: int; } __attribute__((packed));")
    end)

    ctx.check("gnu: leading __attribute__/__extension__ pass through", function()
        local out = gnu_emit("__attribute__((noinline)) function f(): void {}")
        assert(out:find("__attribute__((noinline)) void f(void)", 1, true) ~= nil,
            "leading attr wrong:\n" .. out)
        local out2 = gnu_emit("__extension__ let x: int = 1;")
        assert(out2:find("__extension__ int x = 1;", 1, true) ~= nil, "__extension__ wrong")
        strict_rejects("__extension__ let x: int = 1;")
    end)

    ctx.check("gnu: __alignof__ keeps its spelling", function()
        local out = gnu_emit("function f(): int { return __alignof__(double) > 0; }")
        assert(out:find("__alignof__(double) > 0;", 1, true) ~= nil, "alignof spelling wrong")
        strict_rejects("function f(): int { return __alignof__(double); }")
    end)

    ctx.check("gnu: lenient core paths need no extension", function()
        -- __auto_type/__int128 ride unchecked NamedTypes; union casts are core.
        local out = gnu_emit("function f(v: float): int { __auto_type c = v; let w: __int128 = v as __int128; let u: union U = v as union U; return c as int; }")
        assert(out:find("__auto_type c = v;", 1, true) ~= nil, "auto passthrough wrong")
        assert(out:find("(__int128)v", 1, true) ~= nil, "int128 cast wrong")
        assert(out:find("(union U)v", 1, true) ~= nil, "union cast wrong")
    end)

    ctx.check("gnu: msvc target rejects (expand and codegen)", function()
        local G = gnu_G("clang")
        local toks = lexer.lex("function f(v: int): int { return v ?: 1; }", "t.cx")
        local env = core.new_env({ file = "t.cx", src = "x", target = { cc = "clang" },
            dialect = { gnu = true }, grammar = G })
        local p = core.new(toks, env)
        local root = core.parse_unit(p, G.rules.parseTranslationUnit, "test")
        local ok, err = pcall(expand.expand, root, gnu.expanders,
            { target = { cc = "msvc", std = "c++" }, dialect = { gnu = true } })
        assert(not ok and tostring(err):find("msvc", 1, true) ~= nil,
            "expand must reject msvc: " .. tostring(err))
        -- Codegen backstop: GNU tree expanded for clang, emitted for msvc.
        local G2 = gnu_G("clang")
        local toks2 = lexer.lex("function f(v: int): int { return v ?: 1; }", "t.cx")
        local env2 = core.new_env({ file = "t.cx", src = "x", target = { cc = "clang" },
            dialect = { gnu = true }, grammar = G2 })
        local p2 = core.new(toks2, env2)
        local root2 = core.parse_unit(p2, G2.rules.parseTranslationUnit, "test")
        local out2 = expand.expand(root2, gnu.expanders,
            { target = { cc = "clang", std = "gnu23" }, dialect = { gnu = true } })
        local ok2, err2 = pcall(codegen.emit, out2, { cc = "msvc", std = "c++", src = "x" })
        assert(not ok2 and tostring(err2):find("msvc", 1, true) ~= nil,
            "codegen must reject msvc: " .. tostring(err2))
    end)
end
