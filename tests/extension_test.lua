-- P5 extension machinery tests: registry validation, assembly hygiene,
-- and the expansion fixpoint (order, budget, hard errors).
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local ast = require("compiler.ast")
    local extension = require("compiler.extension")
    local expand = require("compiler.expand")

    --- @param line integer
    --- @return table Loc
    local function loc(line)
        return { file = "t.cx", line = line, col = 1,
            end_line = line, end_col = 2, offset = 1 }
    end

    --- @param kind string
    --- @return table node with no fields
    local function leaf(kind)
        return ast.node(kind, loc(1), {})
    end

    ctx.check("extension: validate accepts good modules", function()
        extension.validate("gnu", { name = "Gnu",
            extend_grammar = function() end, expanders = {} })
        extension.validate("modules", { name = "Modules",
            extend_grammar = function() end, expanders = {},
            graph_api = { imports_of = function() return {} end,
                exports_of = function() return {} end } })
        assert(true)
    end)

    ctx.check("extension: validate rejects malformed modules", function()
        local function bad(name, mod, what)
            local ok, err = pcall(extension.validate, name, mod)
            assert(not ok, what .. " must fail")
            assert(tostring(err):find("extension", 1, true) ~= nil,
                "error must name the extension")
        end
        bad("", {}, "empty name")
        bad("x", {}, "empty module")
        bad("x", { extend_grammar = function() end, expanders = {} }, "missing mod.name")
        bad("x", { name = "X", expanders = {} }, "missing extend_grammar")
        bad("x", { name = "X", extend_grammar = function() end }, "missing expanders")
        bad("x", { name = "X", extend_grammar = function() end,
            expanders = { ["Ext:X:A"] = 42 } }, "non-function expander")
        bad("x", { name = "X", extend_grammar = function() end,
            expanders = {}, graph_api = {} }, "empty graph_api")
        bad("x", { name = "X", extend_grammar = function() end,
            expanders = {}, graph_api = { imports_of = function() end } },
            "graph_api without exports_of")
    end)

    ctx.check("extension: assembly copies, base stays strict", function()
        local base = require("compiler.grammar_cx")
        local gnu = require("compiler.extensions.gnu")
        local before_item = base.rules.parseBlockItem
        local before_paren = base.prefix["("]
        local G = extension.assemble(base, { { name = "gnu", mod = gnu } },
            { target = { cc = "clang", std = "gnu23" }, dialect = { gnu = true } })
        assert(G.rules.parseBlockItem ~= before_item, "assembly must wrap")
        assert(base.rules.parseBlockItem == before_item, "base must not mutate")
        assert(base.prefix["("] == before_paren, "base prefix must not mutate")
        assert(G.prefix["&&"] ~= nil, "assembled G must gain gnu rules")
        assert(base.prefix["&&"] == nil, "base must not gain gnu rules")
        -- No flag, no rules (defensive gate inside extend_grammar).
        local G2 = extension.assemble(base, { { name = "gnu", mod = gnu } },
            { target = {}, dialect = {} })
        assert(G2.rules.parseBlockItem == before_item, "flag-off must not install")
    end)

    ctx.check("extension: later registrations win expander clashes", function()
        local got = extension.collect_expanders({
            { name = "a", mod = { name = "A",
                extend_grammar = function() end,
                expanders = { ["Ext:X:N"] = function() return "first" end } } },
            { name = "b", mod = { name = "B",
                extend_grammar = function() end,
                expanders = { ["Ext:X:N"] = function() return "second" end } } },
        })
        assert(got["Ext:X:N"]({}, {}) == "second", "later registration must win")
    end)

    ctx.check("expand: multi-level fixpoint converges in order", function()
        local order = {}
        local expanders = {
            ["Ext:T:Inner"] = function(_, node)
                order[#order + 1] = "inner"
                return ast.node("Cx:Directive", node.loc, { text = "#i" })
            end,
            ["Ext:T:Outer"] = function(_, node)
                order[#order + 1] = "outer"
                return ast.node("Cx:Directive", node.loc, { text = "#o" })
            end,
        }
        local root = ast.translation_unit(loc(1), {
            ast.node("Ext:T:Outer", loc(1), {
                child = ast.node("Ext:T:Inner", loc(1), {}),
            }),
        })
        local out, passes = expand.expand(root, expanders, { target = {}, dialect = {} })
        assert(passes == 2, "two levels need two passes, got " .. passes)
        assert(order[1] == "inner" and order[2] == "outer", "children expand first")
        assert(#ast.collect_ext(out) == 0, "no Ext may remain")
    end)

    ctx.check("expand: budget exhaustion names kind+loc", function()
        local expanders = {
            ["Ext:T:Loop"] = function(_, node)
                return ast.node("Ext:T:Loop", node.loc, {})
            end,
        }
        local root = ast.translation_unit(loc(1), { leaf("Ext:T:Loop") })
        local ok, err = pcall(expand.expand, root, expanders,
            { target = {}, dialect = {}, budget = 3 })
        assert(not ok and tostring(err):find("budget exhausted", 1, true) ~= nil,
            "budget must trip: " .. tostring(err))
        assert(tostring(err):find("Ext:T:Loop", 1, true) ~= nil, "kind must show")
    end)

    ctx.check("expand: unowned and nil results are hard errors", function()
        local root = ast.translation_unit(loc(1), { leaf("Ext:T:Ghost") })
        local ok, err = pcall(expand.expand, root, {}, { target = {}, dialect = {} })
        assert(not ok and tostring(err):find("no expander", 1, true) ~= nil,
            "unowned must fail: " .. tostring(err))
        local root2 = ast.translation_unit(loc(1), { leaf("Ext:T:Nil") })
        local ok2, err2 = pcall(expand.expand, root2,
            { ["Ext:T:Nil"] = function() return nil end },
            { target = {}, dialect = {} })
        assert(not ok2 and tostring(err2):find("returned nil", 1, true) ~= nil,
            "nil must fail: " .. tostring(err2))
    end)

    ctx.check("expand: replace splices lists, root swaps wholesale", function()
        local a = leaf("Cx:Directive")
        local b = ast.node("Ext:T:Item", loc(1), {})
        local root = ast.translation_unit(loc(1), { a, b })
        local out = expand.expand(root,
            { ["Ext:T:Item"] = function(_, node)
                return {
                    ast.node("Cx:Directive", node.loc, { text = "#1" }),
                    ast.node("Cx:Directive", node.loc, { text = "#2" }),
                }
            end },
            { target = {}, dialect = {} })
        assert(#out.body == 3, "list splice must insert two, got " .. #out.body)
        -- Root replacement yields a new root object.
        local root2 = ast.node("Ext:T:Root", loc(1), {})
        local out2 = expand.expand(root2,
            { ["Ext:T:Root"] = function(_, node)
                return ast.node("Cx:Directive", node.loc, { text = "#r" })
            end },
            { target = {}, dialect = {} })
        assert(out2 ~= root2 and out2.kind == "Cx:Directive", "root must swap")
        -- Root replacement with a list is rejected.
        local ok = pcall(expand.expand, ast.node("Ext:T:Root2", loc(1), {}),
            { ["Ext:T:Root2"] = function() return {} end },
            { target = {}, dialect = {} })
        assert(not ok, "list-for-root must fail")
    end)
end
