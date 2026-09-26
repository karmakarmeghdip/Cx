-- Expressions: the full C precedence chain as Pratt tables (grammar section).
-- Registers G.prefix, G.infix and G.rules.parseExpression/parseNoComma/
-- parseConditional. `as` is a LEFT-folding infix at prec 14 (tighter than
-- */%, looser than unary); see the plan note on the stale example.cx table.
-- Postfix ([], (), ., ->, ++, --) applies inside every prefix function so it
-- binds tightest for primaries and unary operands alike.

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

-- After `( Type )`, only these CANNOT start an initializer: fall back to a
-- parenthesized expression instead of a compound literal.
local NO_INIT = {
    [")"] = true, ["]"] = true, ["}"] = true, [";"] = true,
    [","] = true, [":"] = true, ["?"] = true,
}

-- Unary operands parse at this floor: tighter than `as` (14), so
-- `-x as int` reads `(-x) as int`.
local UNARY_MIN = 15

    --- @param G CxGrammar
local function define(G)
    --- A parsed type can open a compound literal unless it is a bare
    --- unknown identifier (then it is a parenthesized expression).
    --- @param p Parser # Parser
    --- @param ty table # Cx:Type
    --- @return boolean
    local function compound_plausible(p, ty)
        local b = ty.base
        if b ~= nil and b.kind == "Cx:NamedType"
            and not p.env:is_typename(b.name) then
            if #ty.suffixes == 0 and #ty.quals == 0 and not ty.atomic_prefix then
                return false
            end
        end
        return true
    end

    --- @param p Parser # Parser
    --- @param node table
    --- @return table
    local function apply_postfix(p, node)
        while true do
            local t = p:peek()
            if t.kind == "punct" and t.value == "[" then
                p:next()
                local idx = U.need(p, U.rules(p).parseExpression(p), "expression")
                local cl = core.expect(p, "punct", "]", "']'")
                node = N("Cx:Index", U.span_loc(node.loc, cl.loc), { arr = node, idx = idx })
            elseif t.kind == "punct" and t.value == "(" then
                p:next()
                local args = {}
                if not U.at(p, "punct", ")") then
                    local first = U.need(p, U.rules(p).parseNoComma(p), "expression")
                    args[1] = first
                    while U.at(p, "punct", ",") do
                        p:next()
                        local a = U.need(p, U.rules(p).parseNoComma(p), "expression")
                        args[#args + 1] = a
                    end
                end
                local cl = core.expect(p, "punct", ")", "')'")
                node = N("Cx:Call", U.span_loc(node.loc, cl.loc), { fn = node, args = args })
            elseif t.kind == "punct" and (t.value == "." or t.value == "->") then
                local arrow = t.value == "->"
                local sloc = node.loc
                p:next()
                local f = core.expect(p, "ident", nil, "member name")
                node = N("Cx:Member", U.span_loc(sloc, f.loc),
                    { obj = node, field = f.value, arrow = arrow })
            elseif t.kind == "punct" and (t.value == "++" or t.value == "--") then
                p:next()
                node = N("Cx:Postfix", U.span_loc(node.loc, t.loc),
                    { op = t.value, target = node })
            else
                return node
            end
        end
    end

    --- `( ... )`: compound literal when `(static? T)` is followed by an
    --- initializer start, else a parenthesized expression. The type attempt
    --- is pcall-guarded: committed sub-spans inside must not leak errors
    --- into what may be an ordinary parenthesization. A bare UNKNOWN name
    --- is never a compound type (`(x) + 1` stays paren-plus): the typedef
    --- gate decides, so real aliases (registered by `type`) still work.
    --- @param p Parser # Parser
    --- @param tok LexToken
    --- @return table
    local function prefix_paren(p, tok)
        local sloc = tok.loc
        local m = p:mark()
        local static = false
        if U.at(p, "ident", "static") then
            static = true
            p:next()
        end
        local ok, ty = pcall(G.rules.parseType, p)
        if ok and ty ~= nil and compound_plausible(p, ty) and U.at(p, "punct", ")") then
            p:next()
            local nx = p:peek()
            if nx.kind ~= "eof" and not NO_INIT[nx.value] then
                local init = U.need(p, U.rules(p).parseInitializer(p), "initializer")
                return N("Cx:CompoundLit", U.span_loc(sloc, init.loc),
                    { static = static, type = ty, init = init })
            end
        end
        p:reset(m)
        local e = core.expr(p, U.prefix(p), U.infix(p), 0)
        core.expect(p, "punct", ")", "')'")
        return e
    end

    --- Adjacent string literals concatenate (parts preserved verbatim).
    --- @param p Parser # Parser
    --- @param tok LexToken
    --- @return table
    local function prefix_string(p, tok)
        local parts = { tok.value }
        local eloc = tok.loc
        while p:peek().kind == "string" do
            local t = p:next()
            parts[#parts + 1] = t.value
            eloc = t.loc
        end
        return N("Cx:StringLit", U.span_loc(tok.loc, eloc), { parts = parts })
    end

    --- @param op string
    --- @return fun(p: table, tok: table): table
    local function prefix_unary(op)
        return function(p, tok)
            local target = core.expr(p, U.prefix(p), U.infix(p), UNARY_MIN)
            return N("Cx:Unary", U.span_loc(tok.loc, target.loc),
                { op = op, target = target })
        end
    end

    --- sizeof(T-or-expr): unknown leading identifiers go the expression way.
    --- @param p Parser # Parser
    --- @param tok table
    --- @return table
    local function prefix_sizeof(p, tok)
        local sloc = tok.loc
        core.expect(p, "punct", "(", "'(' after sizeof")
        local subj = nil
        local is_type = false
        if U.likely_type(p) then
            subj = U.need(p, U.rules(p).parseType(p), "type")
            is_type = true
        else
            subj = U.need(p, U.rules(p).parseExpression(p), "expression")
        end
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Cx:Sizeof", U.span_loc(sloc, cl.loc),
            { subject = subj, is_type = is_type })
    end

    --- alignof(T): type only, parens required.
    --- @param p Parser # Parser
    --- @param tok table
    --- @return table
    local function prefix_alignof(p, tok)
        local sloc = tok.loc
        core.expect(p, "punct", "(", "'(' after alignof")
        local ty = U.need(p, U.rules(p).parseType(p), "type")
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Cx:Alignof", U.span_loc(sloc, cl.loc), { type = ty })
    end

    --- _Generic(controlling, type: value, ..., default: value).
    --- @param p Parser # Parser
    --- @param tok table
    --- @return table
    local function prefix_generic(p, tok)
        local sloc = tok.loc
        core.expect(p, "punct", "(", "'(' after _Generic")
        local controlling = U.need(p, U.rules(p).parseNoComma(p), "expression")
        core.expect(p, "punct", ",", "','")
        local assocs = {}
        while true do
            local ty = nil
            local is_default = false
            if U.at(p, "ident", "default") then
                p:next()
                is_default = true
            else
                ty = U.rules(p).parseType(p)
                if ty == nil then
                    p:fail("type")
                end
            end
            core.expect(p, "punct", ":", "':'")
            local val = U.need(p, U.rules(p).parseNoComma(p), "expression")
            assocs[#assocs + 1] = N("Cx:GenericAssoc", U.span_loc(controlling.loc, val.loc),
                { type = ty, is_default = is_default, value = val })
            if U.at(p, "punct", ",") then
                p:next()
            else
                break
            end
        end
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Cx:GenericSel", U.span_loc(sloc, cl.loc),
            { controlling = controlling, assocs = assocs })
    end

    --- @param text string
    --- @return fun(p: table, tok: table): table
    local function prefix_lit(text)
        return function(_, tok)
            return N(text, tok.loc, { text = tok.value })
        end
    end

    G.prefix["ident"] = function(_, tok)
        return N("Cx:Ident", tok.loc, { name = tok.value, raw = tok.raw_ident == true })
    end
    G.prefix["int"] = prefix_lit("Cx:IntLit")
    G.prefix["float"] = prefix_lit("Cx:FloatLit")
    G.prefix["char"] = prefix_lit("Cx:CharLit")
    G.prefix["string"] = prefix_string
    G.prefix["("] = prefix_paren
    G.prefix["sizeof"] = prefix_sizeof
    G.prefix["alignof"] = prefix_alignof
    G.prefix["_Generic"] = prefix_generic
    for _, op in ipairs({ "&", "*", "+", "-", "~", "!", "++", "--" }) do
        G.prefix[op] = prefix_unary(op)
    end

    -- Postfix binds tightest: wrap every prefix function.
    for k, fn in pairs(G.prefix) do
        G.prefix[k] = function(p, tok)
            return apply_postfix(p, fn(p, tok))
        end
    end

    --- @param op string
    --- @return fun(p: table, left: table, tok: table, next_min: number): table
    local function infix_bin(op)
        return function(p, left, _, next_min)
            local right = core.expr(p, U.prefix(p), U.infix(p), next_min)
            return N("Cx:Binary", U.span_loc(left.loc, right.loc),
                { op = op, l = left, r = right })
        end
    end

    --- @param p Parser # Parser
    --- @param left table
    --- @param tok table
    --- @param next_min number
    --- @return table
    local function infix_assign(p, left, tok, next_min)
        local right = core.expr(p, U.prefix(p), U.infix(p), next_min)
        return N("Cx:Assign", U.span_loc(left.loc, right.loc),
            { op = tok.value, l = left, r = right })
    end

    G.infix[","] = {
        prec = 1,
        assoc = "left",
        parse = function(p, left, _, next_min)
            local right = core.expr(p, U.prefix(p), U.infix(p), next_min)
            if type(left) == "table" and left.kind == "Cx:Comma" then
                left.items[#left.items + 1] = right
                return left
            end
            return N("Cx:Comma", U.span_loc(left.loc, right.loc),
                { items = { left, right } })
        end,
    }
    for _, op in ipairs({ "=", "*=", "/=", "%=", "+=", "-=", "<<=", ">>=", "&=", "^=", "|=" }) do
        G.infix[op] = { prec = 2, assoc = "right", parse = infix_assign }
    end
    G.infix["?"] = {
        prec = 3,
        assoc = "right",
        parse = function(p, left, _, next_min)
            local then_ = core.expr(p, U.prefix(p), U.infix(p), 0)
            core.expect(p, "punct", ":", "':'")
            local els = core.expr(p, U.prefix(p), U.infix(p), next_min)
            return N("Cx:Ternary", U.span_loc(left.loc, els.loc),
                { cond = left, ["then"] = then_, els = els })
        end,
    }
    G.infix["||"] = { prec = 4, assoc = "left", parse = infix_bin("||") }
    G.infix["&&"] = { prec = 5, assoc = "left", parse = infix_bin("&&") }
    G.infix["|"] = { prec = 6, assoc = "left", parse = infix_bin("|") }
    G.infix["^"] = { prec = 7, assoc = "left", parse = infix_bin("^") }
    G.infix["&"] = { prec = 8, assoc = "left", parse = infix_bin("&") }
    for _, op in ipairs({ "==", "!=" }) do
        G.infix[op] = { prec = 9, assoc = "left", parse = infix_bin(op) }
    end
    for _, op in ipairs({ "<", ">", "<=", ">=" }) do
        G.infix[op] = { prec = 10, assoc = "left", parse = infix_bin(op) }
    end
    for _, op in ipairs({ "<<", ">>" }) do
        G.infix[op] = { prec = 11, assoc = "left", parse = infix_bin(op) }
    end
    for _, op in ipairs({ "+", "-" }) do
        G.infix[op] = { prec = 12, assoc = "left", parse = infix_bin(op) }
    end
    for _, op in ipairs({ "*", "/", "%" }) do
        G.infix[op] = { prec = 13, assoc = "left", parse = infix_bin(op) }
    end
    G.infix["as"] = {
        prec = 14,
        assoc = "left",
        parse = function(p, left, tok)
            assert(tok.value == "as", "grammar.exprs: 'as' parser misdispatched")
            local ty = U.need(p, U.rules(p).parseType(p), "type")
            return N("Cx:CastAs", U.span_loc(left.loc, ty.loc),
                { target = left, type = ty })
        end,
    }

    --- Full expression (comma included).
    --- @param p Parser # Parser
    --- @return table
    G.rules.parseExpression = function(p)
        return core.expr(p, U.prefix(p), U.infix(p), 0)
    end
    --- No-comma expression (args, bounds, generic values, return values... ).
    --- Comma would escape the enclosing list, so floor the Pratt loop at 2.
    --- @param p Parser # Parser
    --- @return table|nil
    G.rules.parseNoComma = function(p)
        return core.expr(p, U.prefix(p), U.infix(p), 2)
    end
    --- Conditional expression (case labels, enum/bit widths, assertions).
    --- @param p Parser # Parser
    --- @return table|nil
    G.rules.parseConditional = function(p)
        return core.expr(p, U.prefix(p), U.infix(p), 3)
    end
end

return { define = define }
