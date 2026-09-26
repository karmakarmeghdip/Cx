-- P1 AST unit tests: node/walk/collect_ext/replace plus the two P1 kinds.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local ast = require("compiler.ast")

    --- Build a Loc without a lexer.
    --- @param line integer
    --- @param col integer
    --- @return Loc
    local function loc(line, col)
        return { file = "t.cx", line = line, col = col,
            end_line = line, end_col = col + 1, offset = 1 }
    end

    ctx.check("ast: node sets kind/loc/fields, plain tables", function()
        local n = ast.node("Cx:Directive", loc(1, 1), { text = "#x" })
        ---@cast n any
        assert(n.kind == "Cx:Directive", "kind missing")
        assert(n.loc.line == 1 and n.text == "#x", "fields missing")
        assert(getmetatable(n) == nil, "nodes must be plain tables (LuaJIT hot path)")
    end)

    ctx.check("ast: node rejects bad kinds and shapes", function()
        assert(pcall(ast.node, "Foo", loc(1, 1)) == false, "bare kind must fail")
        assert(pcall(ast.node, "Cx:Directive", nil) == false, "nil loc must fail")
        assert(pcall(ast.node, "Cx:Directive", loc(1, 1), { kind = "x" }) == false,
            "kind in fields must fail")
        assert(pcall(ast.node, "Ext:Gnu:StmtExpr", loc(1, 1)) == true,
            "Ext: kinds must be constructible")
    end)

    ctx.check("ast: translation_unit/directive helpers validate", function()
        local d = ast.directive(loc(2, 1), "#include <stdio.h>")
        assert(d.kind == "Cx:Directive", "directive kind wrong")
        local tu = ast.translation_unit(loc(1, 1), { d })
        assert(tu.kind == "Cx:TranslationUnit" and #tu.body == 1, "tunit shape wrong")
        ---@type any
        local bad_body = { "nope" }
        assert(pcall(ast.translation_unit, loc(1, 1), bad_body) == false,
            "non-node body member must fail")
    end)

    ctx.check("ast: walk is pre-order and prunes on false", function()
        local leaf = ast.node("Cx:Directive", loc(3, 1), { text = "#b" })
        local mid = ast.node("Cx:Directive", loc(2, 1), { text = "#a", child = leaf })
        local root = ast.translation_unit(loc(1, 1), { mid })
        local seen = {}
        ast.walk(root, function(n)
            seen[#seen + 1] = n.kind .. ":" .. tostring(n.loc.line)
        end)
        assert(#seen == 3, "must visit root+mid+leaf, got " .. #seen)
        assert(seen[1] == "Cx:TranslationUnit:1", "root first: " .. tostring(seen[1]))
        assert(seen[3] == "Cx:Directive:3", "leaf last: " .. tostring(seen[3]))
        local pruned = {}
        ast.walk(root, function(n)
            pruned[#pruned + 1] = n.kind
            if n.loc.line == 2 then
                return false
            end
        end)
        assert(#pruned == 2, "prune must skip leaf, got " .. #pruned)
    end)

    ctx.check("ast: collect_ext finds only Ext:* nodes", function()
        local e1 = ast.node("Ext:Gnu:StmtExpr", loc(1, 1))
        local e2 = ast.node("Ext:Gnu:Asm", loc(2, 1))
        local plain = ast.directive(loc(3, 1), "#x")
        local root = ast.translation_unit(loc(1, 1), { e1, plain, e2 })
        local found = ast.collect_ext(root)
        assert(#found == 2, "must find 2 ext nodes, got " .. #found)
        assert(found[1] == e1 and found[2] == e2, "ext order/identity wrong")
        local clean = ast.translation_unit(loc(1, 1), { plain })
        assert(#ast.collect_ext(clean) == 0, "Cx-only tree must yield none")
    end)

    ctx.check("ast: replace splices arrays (single, list, delete)", function()
        local a = ast.directive(loc(1, 1), "#a")
        local b = ast.directive(loc(2, 1), "#b")
        local c = ast.directive(loc(3, 1), "#c")
        local root = ast.translation_unit(loc(1, 1), { a, b, c })
        local ctxr = { root = root }
        local x = ast.directive(loc(9, 1), "#x")
        ast.replace(ctxr, b, x)
        assert(root.body[2] == x and #root.body == 3, "single replace wrong")
        local y = ast.directive(loc(9, 1), "#y")
        local z = ast.directive(loc(9, 1), "#z")
        ast.replace(ctxr, x, { y, z })
        assert(root.body[2] == y and root.body[3] == z and #root.body == 4,
            "list splice wrong")
        ast.replace(ctxr, y, {})
        assert(root.body[2] == z and #root.body == 3, "delete via {} wrong")
    end)

    ctx.check("ast: replace rewrites struct fields, rejects misuse", function()
        local inner = ast.directive(loc(2, 1), "#in")
        local holder = ast.node("Cx:Directive", loc(1, 1), { text = "#h", child = inner })
        ---@cast holder any
        local root = ast.translation_unit(loc(1, 1), { holder })
        local ctxr = { root = root }
        local repl = ast.directive(loc(5, 1), "#r")
        ast.replace(ctxr, inner, repl)
        assert(holder.child == repl, "field replace wrong")
        assert(pcall(ast.replace, ctxr, repl, { repl, repl }) == false,
            "multi-node field replace must fail")
        assert(pcall(ast.replace, ctxr, root, repl) == false,
            "replacing ctx.root must fail")
        assert(pcall(ast.replace, ctxr, ast.directive(loc(7, 1), "#ghost"), repl) == false,
            "replacing a detached node must fail")
    end)

    ctx.check("ast: is_node rejects loc/trivia/plain tables", function()
        assert(ast.is_node(ast.directive(loc(1, 1), "#x")) == true, "node must pass")
        assert(ast.is_node(loc(1, 1)) == false, "loc must fail")
        assert(ast.is_node({ kind = 5 }) == false, "non-string kind must fail")
        assert(ast.is_node({}) == false, "empty table must fail")
        assert(ast.is_node("#x") == false, "string must fail")
    end)
end
