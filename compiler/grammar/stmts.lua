-- Statements: blocks, selection, iteration, jumps, labels (grammar section).
-- `if/switch/while/...` lex as ordinary idents (only let/function/type/as/
-- cinit are keywords); dispatching on them is correct because C reserves
-- every one of these words. Statement nodes also carry `attrs` (emitted
-- verbatim by P4 codegen) wherever the sketch permits attributes.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

--- @param kind string
--- @param loc table
--- @param fields table|nil
--- @return table CxNode
local function N(kind, loc, fields)
    return ast.node(kind, loc, fields)
end

--- @param G CxGrammar
local function define(G)
    --- `[[a]] foo:` | `[[a]] case expr:` | `[[a]] default:`.
    --- Nil + rewound when the cursor does not start a label.
    --- @param p Parser # Parser
    --- @return table|nil Cx:Label | Cx:Case | Cx:Default
    local function parse_label(p)
        local m = p:mark()
        local sloc = p:peek().loc
        local attrs = U.parse_attrs(p)
        local t = p:peek()
        if t.kind ~= "ident" then
            p:reset(m)
            return nil
        end
        if t.value == "case" then
            p:next()
            local val = U.need(p, U.rules(p).parseConditional(p), "constant expression")
            local cl = core.expect(p, "punct", ":", "':'")
            return N("Cx:Case", U.span_loc(sloc, cl.loc), { value = val, attrs = attrs })
        end
        if t.value == "default" then
            p:next()
            local cl = core.expect(p, "punct", ":", "':'")
            return N("Cx:Default", U.span_loc(sloc, cl.loc), { attrs = attrs })
        end
        if t.value == "struct" or t.value == "union" or t.value == "enum"
            or t.value == "static_assert" then
            p:reset(m)
            return nil
        end
        if p:peek(2).value ~= ":" then
            p:reset(m)
            return nil
        end
        local nm = U.ident_name(p)
        assert(nm ~= nil, "grammar.stmts: unreachable label state")
        local cl = p:next()
        return N("Cx:Label", U.span_loc(sloc, cl.loc),
            { name = nm.name, raw = nm.raw, attrs = attrs })
    end

    --- @param p Parser # Parser
    --- @param word string statement introducer
    --- @return boolean
    local function at_word(p, word)
        local t = p:peek()
        return t.kind == "ident" and t.value == word
    end

    --- @param p Parser # Parser
    --- @param word string
    local function expect_word(p, word)
        if not at_word(p, word) then
            p:fail("'" .. word .. "'")
        end
        p:next()
    end

    --- `if (e) s [else s]`
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_if(p, sloc, attrs)
        expect_word(p, "if")
        core.expect(p, "punct", "(", "'('")
        local cond = U.need(p, U.rules(p).parseExpression(p), "expression")
        core.expect(p, "punct", ")", "')'")
        local then_ = U.need(p, U.rules(p).parseStatement(p), "statement")
        local els = nil
        if at_word(p, "else") then
            p:next()
            els = U.need(p, U.rules(p).parseStatement(p), "statement")
        end
        return N("Cx:If", U.span_loc(sloc, els ~= nil and els.loc or then_.loc),
            { cond = cond, ["then"] = then_, els = els, attrs = attrs })
    end

    --- `switch (e) s`
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_switch(p, sloc, attrs)
        expect_word(p, "switch")
        core.expect(p, "punct", "(", "'('")
        local cond = U.need(p, U.rules(p).parseExpression(p), "expression")
        core.expect(p, "punct", ")", "')'")
        local body = U.need(p, U.rules(p).parseStatement(p), "statement")
        return N("Cx:Switch", U.span_loc(sloc, body.loc),
            { cond = cond, body = body, attrs = attrs })
    end

    --- `while (e) s`
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_while(p, sloc, attrs)
        expect_word(p, "while")
        core.expect(p, "punct", "(", "'('")
        local cond = U.need(p, U.rules(p).parseExpression(p), "expression")
        core.expect(p, "punct", ")", "')'")
        local body = U.need(p, U.rules(p).parseStatement(p), "statement")
        return N("Cx:While", U.span_loc(sloc, body.loc),
            { cond = cond, body = body, attrs = attrs })
    end

    --- `do s while (e) [attrs] ;`
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_do(p, sloc, attrs)
        expect_word(p, "do")
        local body = U.need(p, U.rules(p).parseStatement(p), "statement")
        expect_word(p, "while")
        core.expect(p, "punct", "(", "'('")
        local cond = U.need(p, U.rules(p).parseExpression(p), "expression")
        core.expect(p, "punct", ")", "')'")
        for _, a in ipairs(U.parse_attrs(p)) do
            attrs[#attrs + 1] = a
        end
        local semi = U.expect_semi(p)
        return N("Cx:DoWhile", U.span_loc(sloc, semi.loc),
            { body = body, cond = cond, attrs = attrs })
    end

    --- `for (init; cond; step) s`. The let-binding init omits its semicolon:
    --- the header's first `;` terminates it.
    --- Spec for-initializer = ("let" | "const") binding ("," binding)*
    ---   | expression (no head specifiers/alignas/attrs there).
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_for(p, sloc, attrs)
        expect_word(p, "for")
        core.expect(p, "punct", "(", "'('")
        local init = nil
        if U.at(p, "punct", ";") then
            p:next()
        else
            local isloc = p:peek().loc
            local head = U.parse_decl_head(p)
            local t = p:peek()
            if t.kind == "keyword"
                and (t.value == "let" or t.value == "const") then
                if #head.specs > 0 or head.alignas ~= nil or #head.attrs > 0 then
                    p:fail("storage classes are not allowed in for initializers"
                        .. " (spec: only let|const bindings)")
                end
                local intro = p:next()
                local bindings = {}
                while true do
                    bindings[#bindings + 1] = U.rules(p).parseBinding(p)
                    if U.at(p, "punct", ",") then
                        p:next()
                    else
                        break
                    end
                end
                init = N("Cx:BindingDecl",
                    U.span_loc(isloc, bindings[#bindings].loc), {
                    introducer = intro.value, specifiers = head.specs,
                    alignas = head.alignas, alignas_kind = head.alignas_kind,
                    attrs = head.attrs, bindings = bindings,
                })
                U.expect_semi(p)
            else
                if #head.specs > 0 or head.alignas ~= nil or #head.attrs > 0 then
                    p:fail("declaration")
                end
                init = U.need(p, U.rules(p).parseExpression(p), "expression")
                U.expect_semi(p)
            end
        end
        local cond = nil
        if U.at(p, "punct", ";") then
            p:next()
        else
            cond = U.need(p, U.rules(p).parseExpression(p), "expression")
            U.expect_semi(p)
        end
        local step = nil
        if not U.at(p, "punct", ")") then
            step = U.need(p, U.rules(p).parseExpression(p), "expression")
        end
        core.expect(p, "punct", ")", "')'")
        local body = U.need(p, U.rules(p).parseStatement(p), "statement")
        return N("Cx:For", U.span_loc(sloc, body.loc),
            { init = init, cond = cond, step = step, body = body, attrs = attrs })
    end

    --- Jumps: `goto L [attrs];` | `continue [attrs];` | `break [attrs];` |
    --- `return [expr] [attrs];`
    --- @param p Parser # Parser
    --- @param sloc table
    --- @param attrs string[]
    --- @return table
    local function parse_jump(p, sloc, attrs)
        local t = p:peek()
        if t.value == "goto" then
            p:next()
            local nm = U.need_ident(p, "label name")
            for _, a in ipairs(U.parse_attrs(p)) do
                attrs[#attrs + 1] = a
            end
            local semi = U.expect_semi(p)
            return N("Cx:Goto", U.span_loc(sloc, semi.loc),
                { label = nm.name, attrs = attrs })
        end
        if t.value == "continue" or t.value == "break" then
            p:next()
            for _, a in ipairs(U.parse_attrs(p)) do
                attrs[#attrs + 1] = a
            end
            local semi = U.expect_semi(p)
            local kind = (t.value == "continue") and "Cx:Continue" or "Cx:Break"
            return N(kind, U.span_loc(sloc, semi.loc), { attrs = attrs })
        end
        p:next() -- return
        local value = nil
        if not U.at(p, "punct", ";") then
            value = U.need(p, U.rules(p).parseExpression(p), "expression")
        end
        for _, a in ipairs(U.parse_attrs(p)) do
            attrs[#attrs + 1] = a
        end
        local semi = U.expect_semi(p)
        return N("Cx:Return", U.span_loc(sloc, semi.loc),
            { value = value, attrs = attrs })
    end

    --- One statement: block, selection, iteration, jump, or `attrs? expr? ;`.
    --- Nil only before `}`/eof (the block loop owns those boundaries).
    --- @param p Parser # Parser
    --- @return table|nil statement node
    local function parse_statement(p)
        local t = p:peek()
        if t.kind == "punct" and t.value == "}" then
            return nil
        end
        if t.kind == "eof" then
            return nil
        end
        local sloc = t.loc
        local attrs = U.parse_attrs(p)
        local t2 = p:peek()
        if t2.kind == "punct" and t2.value == "{" then
            if #attrs > 0 then
                p:fail("attributes are not allowed on blocks")
            end
            return U.rules(p).parseBlock(p)
        end
        if t2.kind == "ident" and t2.value == "if" then
            return parse_if(p, sloc, attrs)
        end
        if t2.kind == "ident" and t2.value == "switch" then
            return parse_switch(p, sloc, attrs)
        end
        if t2.kind == "ident" and t2.value == "while" then
            return parse_while(p, sloc, attrs)
        end
        if t2.kind == "ident" and t2.value == "do" then
            return parse_do(p, sloc, attrs)
        end
        if t2.kind == "ident" and t2.value == "for" then
            return parse_for(p, sloc, attrs)
        end
        if t2.kind == "ident"
            and (t2.value == "goto" or t2.value == "continue"
                or t2.value == "break" or t2.value == "return") then
            return parse_jump(p, sloc, attrs)
        end
        local expr = nil
        if not U.at(p, "punct", ";") then
            expr = U.need(p, U.rules(p).parseExpression(p), "expression")
        end
        local semi = U.expect_semi(p)
        return N("Cx:ExprStmt", U.span_loc(sloc, semi.loc),
            { expr = expr, attrs = attrs })
    end

    --- `{ items }` where items mix declarations, statements, labels and
    --- directives. A trailing label needs no statement after it (C23).
    --- @param p Parser # Parser
    --- @return table|nil Cx:Block (nil when `{` is not next)
    G.rules.parseBlock = function(p)
        if not U.at(p, "punct", "{") then
            return nil
        end
        local sloc = p:peek().loc
        p:next()
        local item_rule = U.rules(p).parseBlockItem
        local items = {}
        while not U.at(p, "punct", "}") do
            if p:eof() then
                p:fail("'}' to close block")
            end
            local ok, item = pcall(function()
                local it = item_rule(p)
                if it == nil then
                    p:fail("block item")
                end
                return it
            end)
            if ok then
                items[#items + 1] = item
            elseif not core.is_parse_error(item) then
                error(item, 0) -- Lua bug: propagate untouched
            elseif not core.record_error(p, item, false) then
                break
            end
        end
        local cl = p:next()
        return N("Cx:Block", U.span_loc(sloc, cl.loc), { items = items })
    end

    --- One block item: label, declaration, or statement, in that order.
    --- @param p Parser
    --- @return table|nil block item node
    G.rules.parseBlockItem = function(p)
        local l = parse_label(p)
        if l ~= nil then
            return l
        end
        local d = U.rules(p).parseBlockDecl(p)
        if d ~= nil then
            return d
        end
        return U.rules(p).parseStatement(p)
    end

    G.rules.parseStatement = parse_statement
end

return { define = define }
