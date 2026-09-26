-- Modules tests: import/export grammar, driver linking, program() API,
-- and end-to-end equivalence with hand-written reference C (08 samples).
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local Cx = require("compiler.init")
    local modules = require("compiler.modules")
    local modext = require("compiler.extensions.modules")

    --- New compiler with the modules extension registered.
    --- @return table CxCompiler
    local function new_mod()
        local b = Cx.new()
        b:extension("modules", modext)
        return b
    end

    --- Write `content` to `path`, creating parent dirs.
    --- @param path string
    --- @param content string
    local function write_file(path, content)
        local dir = path:match("^(.*)/[^/]*$")
        if dir ~= nil then
            os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
        end
        local f = assert(io.open(path, "w"), "cannot write " .. path)
        f:write(content)
        f:close()
    end

    --- Read a whole file or return nil.
    --- @param path string
    --- @return string|nil
    local function read_file(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local body = f:read("*a")
        f:close()
        return body
    end

    --- True when an executable exists on PATH.
    --- @param name string
    --- @return boolean
    local function have_tool(name)
        local ok = os.execute("command -v " .. name .. " >/dev/null 2>&1")
        return ok == true or ok == 0
    end

    --- Compile sources to bin; returns true iff the binary appeared.
    --- @param srcs string[]
    --- @param bin string
    --- @return boolean
    --- @return string log
    local function try_compile(srcs, bin)
        os.remove(bin)
        local h = io.popen("gcc -std=c23 -o " .. bin .. " "
            .. table.concat(srcs, " ") .. " 2>&1")
        local log = ""
        if h ~= nil then
            log = h:read("*a") or ""
            h:close()
        end
        local t = io.open(bin, "r")
        local ok = t ~= nil
        if t ~= nil then
            t:close()
        end
        return ok, log
    end

    --- Run bin with stdin closed; returns stdout and exit code.
    --- @param bin string
    --- @return string|nil
    --- @return integer|nil
    local function run_capture(bin)
        local h = io.popen(bin .. " </dev/null 2>&1; echo \"CX_DIFF_EXIT:$?\"")
        if h == nil then
            return nil, nil
        end
        local out = h:read("*a") or ""
        h:close()
        local code = out:match("CX_DIFF_EXIT:(%d+)%s*$")
        local body = out:gsub("CX_DIFF_EXIT:%d+%s*$", "")
        return body, tonumber(code)
    end

    ctx.check("modules: import/export parse to Ext nodes", function()
        local root = new_mod():parse_file("samples/programs/08_modules_main.cx")
        assert(root.body[2].kind == "Ext:Modules:Import", "import node lost")
        assert(root.body[2].names[1] == "Vec", "import names wrong")
        assert(root.body[2].path == "./08_modules_vec.cx", "import path wrong")
        local vroot = new_mod():parse_file("samples/programs/08_modules_vec.cx")
        assert(vroot.body[1].kind == "Ext:Modules:Export", "export node lost")
        assert(vroot.body[1].decl.kind == "Cx:TypeAlias", "export decl wrong")
    end)

    ctx.check("modules: strict mode rejects import/export", function()
        local ok, err = pcall(function()
            Cx.new():parse_file("samples/programs/08_modules_main.cx")
        end)
        assert(not ok, "strict must fail on import")
        local ok2 = pcall(function()
            Cx.new():parse_file("samples/programs/08_modules_vec.cx")
        end)
        assert(not ok2, "strict must fail on export: " .. tostring(err))
    end)

    ctx.check("modules: block-level import/export fail loudly", function()
        local core = require("compiler.parser_core")
        local lexer = require("compiler.lexer")
        local G = require("compiler.grammar_cx")
        local extension = require("compiler.extension")
        local GA = extension.assemble(G, { { name = "modules", mod = modext } },
            { target = {}, dialect = { modules = true } })
        local function must_fail(src, want)
            local toks = lexer.lex(src, "t.cx")
            local env = core.new_env({ file = "t.cx", src = src, grammar = GA })
            local p = core.new(toks, env)
            local ok, err = pcall(core.parse_unit, p,
                GA.rules.parseTranslationUnit, "test")
            assert(not ok, "must fail: " .. src)
            assert(tostring(err):find(want, 1, true) ~= nil,
                "error missing '" .. want .. "': " .. tostring(err))
        end
        must_fail('function f(): void { import { a } from "m"; }',
            "top-level only")
        must_fail('function f(): void { export let a: int = 1; }',
            "top-level only")
        must_fail('import * from "m";', "not supported in v1")
        must_fail('export { a };', "not supported in v1")
    end)

    ctx.check("modules: resolve appends .cx and collapses dots", function()
        assert(modules.resolve("a/b/main.cx", "./vec") == "a/b/vec.cx",
            "suffix wrong")
        assert(modules.resolve("a/b/main.cx", "./vec.cx") == "a/b/vec.cx",
            "plain wrong")
        assert(modules.resolve("a/b/main.cx", "../lib/x.cx") == "a/lib/x.cx",
            "dots wrong")
        assert(modules.resolve("main.cx", "./vec.cx") == "vec.cx",
            "bare dir wrong")
    end)

    ctx.check("modules: program() injects prototypes, drops markers", function()
        os.execute('rm -rf out/.tmp_mods_prog 2>/dev/null')
        local b = new_mod()
        b:program("samples/programs/08_modules_main.cx", "out/.tmp_mods_prog")
        assert(#b.sources == 2, "two modules queued, got " .. #b.sources)
        local main_c = assert(read_file("out/.tmp_mods_prog/08_modules_main.c"),
            "main.c missing")
        assert(main_c:find("int vec_sum(Vec *v);", 1, true) ~= nil,
            "prototype lost:\n" .. main_c)
        assert(main_c:find("extern const int MOD;", 1, true) ~= nil,
            "extern binding lost:\n" .. main_c)
        assert(main_c:find("typedef struct", 1, true) ~= nil,
            "typedef lost:\n" .. main_c)
        assert(main_c:find("Ext:", 1, true) == nil, "markers must go")
        assert(main_c:find("import", 1, true) == nil, "import must go")
        local vec_c = assert(read_file("out/.tmp_mods_prog/08_modules_vec.c"),
            "vec.c missing")
        assert(vec_c:find("const int MOD = 1000;", 1, true) ~= nil,
            "definition lost:\n" .. vec_c)
        assert(vec_c:find("export", 1, true) == nil, "export must go")
    end)

    ctx.check("modules: types precede uses whatever the import order", function()
        os.execute('rm -rf out/.tmp_mods_ord 2>/dev/null')
        write_file("out/.tmp_mods_ord/lib.cx", table.concat({
            "export type T = int;",
            "export function f(x: T): T { return x; }",
            "",
        }, "\n"))
        write_file("out/.tmp_mods_ord/main.cx", table.concat({
            'import { f, T } from "./lib.cx";',
            "function main(): int { let x: T = f(1); return x; }",
            "",
        }, "\n"))
        new_mod():program("out/.tmp_mods_ord/main.cx", "out/.tmp_mods_ord/out")
        local main_c = assert(read_file("out/.tmp_mods_ord/out/main.c"),
            "main.c missing")
        local ty = main_c:find("typedef int T;", 1, true)
        local fn = main_c:find("T f(T x);", 1, true)
        assert(ty ~= nil and fn ~= nil and ty < fn,
            "typedef must precede prototype:\n" .. main_c)
    end)

    ctx.check("modules: differential execution matches reference C", function()
        if not have_tool("gcc") then
            io.stdout:write("  SKIP no gcc on PATH\n")
            return
        end
        os.execute('rm -rf out/.tmp_mods_diff 2>/dev/null')
        new_mod():program("samples/programs/08_modules_main.cx",
            "out/.tmp_mods_diff")
        local got_srcs = {
            "out/.tmp_mods_diff/08_modules_main.c",
            "out/.tmp_mods_diff/08_modules_vec.c",
        }
        local ref_srcs = {
            "samples/programs/08_modules_main.c",
            "samples/programs/08_modules_vec.c",
        }
        local ok, log = try_compile(ref_srcs, "out/.tmp_mods_diff_ref")
        assert(ok, "reference must build:\n" .. log)
        local ok2, log2 = try_compile(got_srcs, "out/.tmp_mods_diff_got")
        assert(ok2, "emitted must build:\n" .. log2)
        local ref_out, ref_code = run_capture("out/.tmp_mods_diff_ref")
        local got_out, got_code = run_capture("out/.tmp_mods_diff_got")
        os.remove("out/.tmp_mods_diff_ref")
        os.remove("out/.tmp_mods_diff_got")
        assert(ref_code == got_code, "exit codes differ")
        assert(ref_out == got_out, "stdout differs: "
            .. tostring(ref_out) .. " vs " .. tostring(got_out))
        assert(got_out == "sum=9 mod=1000\nsum=90\n", "output wrong: "
            .. tostring(got_out))
    end)

    ctx.check("modules: program() queues sources for cc()/link()", function()
        if not have_tool("gcc") then
            io.stdout:write("  SKIP no gcc on PATH\n")
            return
        end
        os.execute('rm -rf out/.tmp_mods_cc 2>/dev/null')
        os.execute('mkdir -p out/.tmp_mods_cc 2>/dev/null')
        write_file("out/.tmp_mods_cc/two.cx", table.concat({
            "export function two(): int { return 2; }",
            "",
        }, "\n"))
        write_file("out/.tmp_mods_cc/one.cx", table.concat({
            'import { two } from "./two.cx";',
            "function main(): int { return two() - 2; }",
            "",
        }, "\n"))
        local b = Cx.new({ cc = "gcc" })
        b:extension("modules", modext)
        b:program("out/.tmp_mods_cc/one.cx", "out/.tmp_mods_cc/c")
        assert(#b.sources == 2, "both modules queued for cc/link")
        assert(b.program_units ~= nil, "linked units retained for emit_all")
        -- cc()/link() always target out/; here we compile the emitted
        -- pair directly to prove it links and runs (scaffold covers cc).
        local ok, log = try_compile(
            { "out/.tmp_mods_cc/c/one.c", "out/.tmp_mods_cc/c/two.c" },
            "out/.tmp_mods_cc/pair")
        assert(ok, "pair must link:\n" .. log)
        local _, code = run_capture("out/.tmp_mods_cc/pair")
        os.remove("out/.tmp_mods_cc/pair")
        assert(code == 0, "pair must exit 0, got " .. tostring(code))
    end)

    ctx.check("modules: unknown export names available alternatives", function()
        os.execute('rm -rf out/.tmp_mods_err1 2>/dev/null')
        write_file("out/.tmp_mods_err1/lib.cx",
            "export function push(): void {}\n")
        write_file("out/.tmp_mods_err1/main.cx",
            'import { pop } from "./lib.cx";\nfunction main(): int { return 0; }\n')
        local ok, err = pcall(function()
            new_mod():program("out/.tmp_mods_err1/main.cx",
                "out/.tmp_mods_err1/out")
        end)
        assert(not ok, "unknown export must fail")
        assert(tostring(err):find("no export 'pop'", 1, true) ~= nil,
            "must name it: " .. tostring(err))
        assert(tostring(err):find("available: push", 1, true) ~= nil,
            "must list alternatives: " .. tostring(err))
    end)

    ctx.check("modules: cycles, duplicates, statics, missing files fail", function()
        os.execute('rm -rf out/.tmp_mods_err2 2>/dev/null')
        write_file("out/.tmp_mods_err2/a.cx",
            'import { b } from "./b.cx";\nexport function a(): int { return 0; }\n')
        write_file("out/.tmp_mods_err2/b.cx",
            'import { a } from "./a.cx";\nexport function b(): int { return 0; }\n')
        local ok, err = pcall(function()
            new_mod():program("out/.tmp_mods_err2/a.cx", "out/.tmp_mods_err2/o")
        end)
        assert(not ok, "cycle must fail")
        assert(tostring(err):find("import cycle", 1, true) ~= nil,
            "must say cycle: " .. tostring(err))

        write_file("out/.tmp_mods_err2/dup.cx", table.concat({
            "export function d(): int { return 1; }",
            "export function d(): int { return 2; }",
            "",
        }, "\n"))
        write_file("out/.tmp_mods_err2/dupm.cx", table.concat({
            'import { d } from "./dup.cx";',
            "function main(): int { return d(); }",
            "",
        }, "\n"))
        local ok2, err2 = pcall(function()
            new_mod():program("out/.tmp_mods_err2/dupm.cx",
                "out/.tmp_mods_err2/o2")
        end)
        assert(not ok2, "duplicate export must fail")
        assert(tostring(err2):find("duplicate export 'd'", 1, true) ~= nil,
            "must say duplicate: " .. tostring(err2))

        write_file("out/.tmp_mods_err2/st.cx",
            "export static let s: int = 1;\n")
        write_file("out/.tmp_mods_err2/stm.cx", table.concat({
            'import { s } from "./st.cx";',
            "function main(): int { return s; }",
            "",
        }, "\n"))
        local ok3, err3 = pcall(function()
            new_mod():program("out/.tmp_mods_err2/stm.cx",
                "out/.tmp_mods_err2/o3")
        end)
        assert(not ok3, "static export must fail")
        assert(tostring(err3):find("static", 1, true) ~= nil,
            "must say static: " .. tostring(err3))

        write_file("out/.tmp_mods_err2/ghost.cx",
            'import { x } from "./nope.cx";\nfunction main(): int { return 0; }\n')
        local ok4, err4 = pcall(function()
            new_mod():program("out/.tmp_mods_err2/ghost.cx",
                "out/.tmp_mods_err2/o4")
        end)
        assert(not ok4, "missing file must fail")
        assert(tostring(err4):find("cannot open", 1, true) ~= nil,
            "must say cannot open: " .. tostring(err4))
    end)

    ctx.check("modules: program() needs a graph extension registered", function()
        local ok, err = pcall(function()
            Cx.new():program("samples/programs/08_modules_main.cx",
                "out/.tmp_mods_noext")
        end)
        assert(not ok, "must fail without extension")
        assert(tostring(err):find("graph extension", 1, true) ~= nil,
            "must say so: " .. tostring(err))
    end)

    ctx.check("modules: basename collisions are rejected", function()
        os.execute('rm -rf out/.tmp_mods_col 2>/dev/null')
        write_file("out/.tmp_mods_col/d1/same.cx",
            "export function f(): int { return 1; }\n")
        write_file("out/.tmp_mods_col/d2/same.cx",
            "export function g(): int { return 2; }\n")
        write_file("out/.tmp_mods_col/main.cx", table.concat({
            'import { f } from "./d1/same.cx";',
            'import { g } from "./d2/same.cx";',
            "function main(): int { return f() + g(); }",
            "",
        }, "\n"))
        local ok, err = pcall(function()
            new_mod():program("out/.tmp_mods_col/main.cx",
                "out/.tmp_mods_col/out")
        end)
        assert(not ok, "collision must fail")
        assert(tostring(err):find("collision", 1, true) ~= nil,
            "must say collision: " .. tostring(err))
    end)

    ctx.check("modules: driver links a different frontend's markers", function()
        -- A Rust-style syntax would parse different marker kinds; the
        -- driver must not care. Hand-built TUs + stub parser exercise
        -- build_graph/link_graph with zero ESM involvement.
        local ast = require("compiler.ast")
        local core = require("compiler.parser_core")
        local lexer = require("compiler.lexer")
        local G = require("compiler.grammar_cx")
        local function tloc()
            return { file = "t.cx", line = 1, col = 1,
                end_line = 1, end_col = 2, offset = 1 }
        end
        local function parse_decl(src)
            local toks = lexer.lex(src, "t.cx")
            local env = core.new_env({ file = "t.cx", src = src, grammar = G })
            local p = core.new(toks, env)
            local root = core.parse_unit(p, G.rules.parseTranslationUnit,
                "test")
            assert(#root.body == 1, "one decl expected: " .. src)
            return root.body[1]
        end
        local fake = {
            imports_of = function(root)
                local out = {}
                for _, node in ipairs(root.body) do
                    if node.kind == "Ext:T:Imp" then
                        out[#out + 1] = { node = node, names = node.names,
                            path = node.path, loc = node.loc }
                    end
                end
                return out
            end,
            exports_of = function(root, path)
                local out = {}
                for _, node in ipairs(root.body) do
                    if node.kind == "Ext:T:Exp" then
                        assert(out[node.decl.name] == nil, "dup in fixture")
                        out[node.decl.name] = { node = node,
                            decl = node.decl, loc = node.loc }
                    end
                end
                assert(path ~= nil, "path required")
                return out
            end,
        }
        local fn = parse_decl("function f(x: int): int { return x; }")
        local ty = parse_decl("type T = int;")
        local files = {
            ["m.cx"] = ast.translation_unit(tloc(), {
                ast.node("Ext:T:Imp", tloc(),
                    { names = { "f", "T" }, path = "l.cx" }),
            }),
            ["l.cx"] = ast.translation_unit(tloc(), {
                ast.node("Ext:T:Exp", tloc(), { decl = fn }),
                ast.node("Ext:T:Exp", tloc(), { decl = ty }),
            }),
        }
        os.execute('mkdir -p out/.tmp_mods_fe 2>/dev/null')
        write_file("out/.tmp_mods_fe/m.cx", "// probe\n")
        write_file("out/.tmp_mods_fe/l.cx", "// probe\n")
        local function stub(path)
            local short = path:match("([^/]*)$")
            assert(files[short] ~= nil, "unexpected " .. path)
            return files[short], ""
        end
        local graph = modules.build_graph("out/.tmp_mods_fe/m.cx", stub,
            fake)
        assert(#graph.order == 2, "both files discovered")
        modules.link_graph(graph, fake)
        local main = graph.units["out/.tmp_mods_fe/m.cx"].root
        assert(#main.body == 2, "import spliced two prototypes")
        assert(main.body[1].kind == "Cx:TypeAlias", "types first")
        assert(main.body[2].kind == "Cx:FunctionDecl"
            and main.body[2].body == nil, "bodiless prototype")
        local lib = graph.units["out/.tmp_mods_fe/l.cx"].root
        assert(lib.body[1].kind == "Cx:FunctionDecl"
            and lib.body[1].body ~= nil, "definition kept")
        for _, u in pairs(graph.units) do
            assert(#ast.collect_ext(u.root) == 0, "markers consumed")
        end
    end)

    ctx.check("modules: multiple graph extensions are rejected", function()
        local b = Cx.new()
        b:extension("modules", modext)
        b:extension("other", { name = "Other",
            extend_grammar = function() end,
            expanders = {},
            graph_api = modext.graph_api })
        local ok, err = pcall(function()
            b:program("samples/programs/08_modules_main.cx",
                "out/.tmp_mods_multi")
        end)
        assert(not ok, "two drivers must fail")
        assert(tostring(err):find("multiple graph extensions", 1, true) ~= nil,
            "must say so: " .. tostring(err))
    end)
end
