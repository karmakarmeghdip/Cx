-- Cross-file LSP tests: workspace graph index over import/export
-- programs, cross-file completion + definition, and graph diagnostics
-- (missing files, unknown exports, cycles). Fixtures live under
-- out/.tmp_lsp_graph/ (ignored by git and the Lua workspace).
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local docs = require("compiler.lsp.docs")
    local buildinfo = require("compiler.lsp.buildinfo")
    local graph = require("compiler.lsp.graph")
    local query = require("compiler.lsp.query")
    local server = require("compiler.lsp.server")
    local target_mod = require("compiler.target")
    local modext = require("compiler.extensions.modules")

    local DIR = "out/.tmp_lsp_graph"

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

    --- Config with the modules graph extension registered.
    --- @param file string
    --- @return table
    local function mod_config(file)
        return {
            file = file,
            target = target_mod.detect({ cc = "clang", std = "c23" }),
            std = "c23", cc = "clang",
            entries = { { name = "modules", mod = modext } },
            dialect = { modules = true },
        }
    end

    --- @param uri string
    --- @return string path
    local function uri_path(uri)
        return buildinfo.uri_to_path(uri)
    end

    write_file(DIR .. "/vec.cx", table.concat({
        "export type Vec = struct {",
        "    len: int;",
        "    items: int*;",
        "};",
        "",
        "export const MOD: int = 1000;",
        "",
        "export function vec_sum(v: Vec*): int",
        "{",
        "    return 0;",
        "}",
        "",
    }, "\n"))

    write_file(DIR .. "/main.cx", table.concat({
        'import { Vec, vec_sum, MOD } from "./vec.cx";',
        "",
        "function main(): int",
        "{",
        "    let v: Vec = {len: 0, items: 0};",
        "    return vec_sum(&v) + MOD;",
        "}",
        "",
    }, "\n"))

    ctx.check("lsp-graph: index resolves entry imports to exports", function()
        local s = server.new()
        local cfg = mod_config(DIR .. "/main.cx")
        local main_uri = buildinfo.path_to_uri(DIR .. "/main.cx")
        local vec_uri = buildinfo.path_to_uri(DIR .. "/vec.cx")
        local mf = assert(io.open(DIR .. "/main.cx", "r"))
        local vf = assert(io.open(DIR .. "/vec.cx", "r"))
        local mtext, vtext = mf:read("*a") or "", vf:read("*a") or ""
        mf:close()
        vf:close()
        -- vec.cx open (live text path), main.cx open too.
        local vec_doc = docs.open(s.store, vec_uri, vtext, 1, mod_config(DIR .. "/vec.cx"))
        local main_doc = docs.open(s.store, main_uri, mtext, 1, cfg)
        assert(#main_doc.errors == 0, "entry should parse")
        assert(#vec_doc.errors == 0, "dep should parse")
        local index = server.graph_for(s, main_uri, main_doc, cfg)
        assert(index.api ~= nil, "graph api missing")
        assert(#index.errors == 0, "unexpected graph errors: "
            .. tostring(index.errors[1] and index.errors[1].message or ""))
        assert(index.units[DIR .. "/vec.cx"] ~= nil, "dep unit missing")
        assert(index.units[DIR .. "/vec.cx"].from_store, "open doc should win")
        local ex = index.exports[DIR .. "/vec.cx"]
        assert(ex ~= nil and ex["vec_sum"] ~= nil, "vec_sum export missing")
        assert(ex["Vec"] ~= nil and ex["MOD"] ~= nil, "exports missing")
        local ws = graph.workspace_of(index, DIR .. "/main.cx")
        assert(#ws == 3, "expected 3 workspace names, got " .. #ws)
    end)

    ctx.check("lsp-graph: definition jumps across files", function()
        local s = server.new()
        local cfg = mod_config(DIR .. "/main.cx")
        local main_uri = buildinfo.path_to_uri(DIR .. "/main.cx")
        local vec_uri = buildinfo.path_to_uri(DIR .. "/vec.cx")
        local mf = assert(io.open(DIR .. "/main.cx", "r"))
        local vf = assert(io.open(DIR .. "/vec.cx", "r"))
        local mtext, vtext = mf:read("*a") or "", vf:read("*a") or ""
        mf:close()
        vf:close()
        docs.open(s.store, vec_uri, vtext, 1, mod_config(DIR .. "/vec.cx"))
        local main_doc = docs.open(s.store, main_uri, mtext, 1, cfg)
        -- `vec_sum` use is line 6 (`return vec_sum(&v) + MOD;`), col of name ~12.
        local found = server.definition_at(s, main_uri, main_doc, cfg, 6, 12)
        assert(found ~= nil, "cross-file definition missed")
        assert(found.uri == vec_uri,
            "jump should land in vec.cx, got " .. tostring(found.uri))
        assert(found.range.start.line == 7,
            "vec_sum decl is line 8 (0-based 7), got " .. tostring(found.range.start.line))
        -- `Vec` use on line 5 resolves to the type alias in vec.cx (line 1).
        local alias = server.definition_at(s, main_uri, main_doc, cfg, 5, 13)
        assert(alias ~= nil and alias.uri == vec_uri, "alias jump missed")
        assert(alias.range.start.line == 0, "alias decl is line 1")
    end)

    ctx.check("lsp-graph: completion offers imported exports", function()
        local s = server.new()
        local cfg = mod_config(DIR .. "/main.cx")
        local main_uri = buildinfo.path_to_uri(DIR .. "/main.cx")
        local vec_uri = buildinfo.path_to_uri(DIR .. "/vec.cx")
        local mf = assert(io.open(DIR .. "/main.cx", "r"))
        local vf = assert(io.open(DIR .. "/vec.cx", "r"))
        local mtext, vtext = mf:read("*a") or "", vf:read("*a") or ""
        mf:close()
        vf:close()
        docs.open(s.store, vec_uri, vtext, 1, mod_config(DIR .. "/vec.cx"))
        local main_doc = docs.open(s.store, main_uri, mtext, 1, cfg)
        -- Inside the body (line 6), `vec_` prefix position: completion is
        -- prefix-agnostic, so assert presence + origin detail instead.
        local items = server.complete_items(s, main_uri, main_doc, cfg, 6, 12)
        local seen = {}
        for _, it in ipairs(items) do
            seen[it.label] = it
        end
        assert(seen["vec_sum"] ~= nil, "imported fn missing from completion")
        assert(seen["MOD"] ~= nil, "imported const missing from completion")
        assert(seen["vec_sum"].detail == "from vec.cx",
            "origin detail wrong: " .. tostring(seen["vec_sum"].detail))
    end)

    ctx.check("lsp-graph: unopened deps resolve from disk", function()
        local s = server.new()
        local cfg = mod_config(DIR .. "/main.cx")
        local main_uri = buildinfo.path_to_uri(DIR .. "/main.cx")
        local mf = assert(io.open(DIR .. "/main.cx", "r"))
        local mtext = mf:read("*a") or ""
        mf:close()
        -- Only main.cx open: vec.cx must come from disk (from_store=false).
        local main_doc = docs.open(s.store, main_uri, mtext, 1, cfg)
        local index = server.graph_for(s, main_uri, main_doc, cfg)
        assert(#index.errors == 0, "disk dep should resolve")
        assert(index.units[DIR .. "/vec.cx"] ~= nil, "disk unit missing")
        assert(not index.units[DIR .. "/vec.cx"].from_store, "should be disk-backed")
        local found = server.definition_at(s, main_uri, main_doc, cfg, 6, 12)
        assert(found ~= nil, "disk-backed definition missed")
        assert(found.uri == buildinfo.path_to_uri(DIR .. "/vec.cx"),
            "wrong landing URI")
    end)

    ctx.check("lsp-graph: missing file and unknown export diagnose at the edge", function()
        local s = server.new()
        local cfg = mod_config(DIR .. "/bad.cx")
        local text = table.concat({
            'import { ghost } from "./nope.cx";',
            'import { vec_sum, bogus } from "./vec.cx";',
            "",
            "function main(): int",
            "{",
            "    return vec_sum(0);",
            "}",
            "",
        }, "\n")
        local uri = buildinfo.path_to_uri(DIR .. "/bad.cx")
        local doc = docs.open(s.store, uri, text, 1, cfg)
        assert(#doc.errors == 0, "bad.cx itself should parse")
        local index = server.graph_for(s, uri, doc, cfg)
        assert(#index.errors == 2, "expected 2 graph errors, got " .. #index.errors)
        local msgs = index.errors[1].message .. "\n" .. index.errors[2].message
        assert(msgs:find("cannot open", 1, true) ~= nil, "missing-file error lost")
        assert(msgs:find("has no export 'bogus'", 1, true) ~= nil,
            "unknown-export error lost:\n" .. msgs)
        -- Both diagnostics anchor on import lines 1-2 (0-based 0-1).
        for _, e in ipairs(index.errors) do
            local l = e.loc.line
            assert(l == 1 or l == 2, "edge loc wrong: " .. tostring(l))
        end
    end)

    ctx.check("lsp-graph: cycles diagnose without hanging", function()
        write_file(DIR .. "/cyc_a.cx", 'import { b_fn } from "./cyc_b.cx";\n'
            .. "export function a_fn(): int\n{\n    return 0;\n}\n")
        write_file(DIR .. "/cyc_b.cx", 'import { a_fn } from "./cyc_a.cx";\n'
            .. "export function b_fn(): int\n{\n    return 0;\n}\n")
        local s = server.new()
        local cfg = mod_config(DIR .. "/cyc_a.cx")
        local uri = buildinfo.path_to_uri(DIR .. "/cyc_a.cx")
        local f = assert(io.open(DIR .. "/cyc_a.cx", "r"))
        local text = f:read("*a") or ""
        f:close()
        local doc = docs.open(s.store, uri, text, 1, cfg)
        local index = server.graph_for(s, uri, doc, cfg)
        local found_cycle = false
        for _, e in ipairs(index.errors) do
            if e.message:find("import cycle", 1, true) ~= nil then
                found_cycle = true
            end
        end
        assert(found_cycle, "cycle diagnostic missing")
    end)

    ctx.check("lsp-graph: strict files get an empty index", function()
        local s = server.new()
        local cfg = buildinfo.default_config(DIR .. "/plain.cx")
        local uri = buildinfo.path_to_uri(DIR .. "/plain.cx")
        local doc = docs.open(s.store, uri, "let x: int = 1;\n", 1, cfg)
        local index = server.graph_for(s, uri, doc, cfg)
        assert(index.api == nil and #index.errors == 0, "strict index not empty")
        local ws = graph.workspace_of(index, uri_path(uri))
        assert(#ws == 0, "strict workspace not empty")
        local loc = query.definition(doc, 1, 5, ws)
        assert(loc ~= nil, "same-file definition broke")
    end)

    ctx.check("lsp-graph: repo 08 program indexes end to end", function()
        local s = server.new()
        local entry = "samples/programs/08_modules_main.cx"
        local dep = "samples/programs/08_modules_vec.cx"
        local cfg = mod_config(entry)
        local ef = assert(io.open(entry, "r"))
        local df = assert(io.open(dep, "r"))
        local etext, dtext = ef:read("*a") or "", df:read("*a") or ""
        ef:close()
        df:close()
        local euri = buildinfo.path_to_uri(entry)
        local duri = buildinfo.path_to_uri(dep)
        docs.open(s.store, duri, dtext, 1, mod_config(dep))
        local doc = docs.open(s.store, euri, etext, 1, cfg)
        assert(#doc.errors == 0, "08 main should parse with modules dialect")
        local index = server.graph_for(s, euri, doc, cfg)
        assert(#index.errors == 0, "08 graph should be clean: "
            .. tostring(index.errors[1] and index.errors[1].message or ""))
        local ws = graph.workspace_of(index, entry)
        assert(#ws == 4, "expected Vec+vec_sum+vec_scale+MOD, got " .. #ws)
        -- `vec_sum` call on line 9 (cols 32-38) jumps into the dep file.
        local found = server.definition_at(s, euri, doc, cfg, 9, 33)
        assert(found ~= nil and found.uri == duri, "08 jump missed")
    end)
end
