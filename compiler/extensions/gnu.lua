-- GNU C dialect extension (P5): the FIRST real extension module.
-- Grammar half parses GNU-only forms (gated by dialect.gnu) into Ext:Gnu:*
-- markers; the expander half rewrites them 1:1 into printable Cx:Gnu:*
-- mirrors for GNU-capable targets (cc ~= "msvc") and raises otherwise.
-- Lenient core paths already cover __auto_type/__int128/__typeof__ (unchecked
-- names), __builtin_* calls (plain idents), union casts, old/range
-- designators (opaque cinit), empty structs and zero-length arrays.
-- See AGENTS.md section 7 and samples/programs/07_gnu_extensions.*.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

local M = {}

M.name = "Gnu"

--- @param kind string
--- @param loc table
--- @param fields table|nil
--- @return table CxNode
local function N(kind, loc, fields)
    return ast.node(kind, loc, fields)
end

--- Target gate shared by all GNU expanders.
--- @param ctx ExpandCtx
--- @param node table
local function gnu_only(ctx, node)
    if ctx.target.cc == "msvc" then
        local loc = node.loc or {}
        error(string.format("%s:%d:%d: %s requires a GNU toolchain (target cc=msvc)",
            tostring(loc.file or "?"), loc.line or 0, loc.col or 0, node.kind), 0)
    end
end

--- Parse `({ items })` — the `(` is already consumed by the Pratt driver.
--- @param G CxGrammar
--- @param p Parser # Parser
--- @param tok LexToken
--- @return table Ext:Gnu:StmtExpr
local function parse_stmt_expr(G, p, tok)
    local sloc = tok.loc
    core.expect(p, "punct", "{", "'{'")
    local items = {}
    while not U.at(p, "punct", "}") do
        if p:eof() then
            p:fail("'}' to close statement expression")
        end
        local it = U.need(p, G.rules.parseBlockItem(p), "block item")
        items[#items + 1] = it
    end
    core.expect(p, "punct", "}", "'}'")
    local cl = core.expect(p, "punct", ")", "')'")
    return N("Ext:Gnu:StmtExpr", U.span_loc(sloc, cl.loc), { items = items })
end

--- Parse one `__asm__ quals(payload);` statement.
--- @param p Parser # Parser
--- @return table Ext:Gnu:AsmStmt
local function parse_asm(p)
    local sloc = p:peek().loc
    p:next() -- __asm__
    local quals = {}
    while true do
        local q = p:peek()
        if q.kind ~= "ident" then
            break
        end
        local after = p:peek(2)
        if after.kind ~= "ident"
            and not (after.kind == "punct" and after.value == "(") then
            break
        end
        quals[#quals + 1] = q.value
        p:next()
    end
    local inner = core.balanced(p, "(", ")")
    if inner == nil then
        p:fail("'(' after __asm__")
    end
    assert(inner ~= nil, "gnu: unreachable asm state")
    local open = inner[1]
    local close = inner[#inner]
    local semi = U.expect_semi(p)
    return N("Ext:Gnu:AsmStmt", U.span_loc(sloc, semi.loc), {
        quals = quals,
        start_offset = open.loc.offset + 1,
        end_offset = close.loc.offset - 1,
    })
end

--- Parse `goto <non-ident expression> ;`.
--- @param G CxGrammar
--- @param p Parser # Parser
--- @return table Ext:Gnu:ComputedGoto
local function parse_computed_goto(G, p)
    local sloc = p:peek().loc
    p:next() -- goto
    local target = U.need(p, G.rules.parseNoComma(p), "expression")
    local semi = U.expect_semi(p)
    return N("Ext:Gnu:ComputedGoto", U.span_loc(sloc, semi.loc), { target = target })
end

--- Probe for the K&R shape: [specs] type name `(`. Pure lookahead with a
--- pcall guard (probe errors mean "not K&R": rewind and delegate).
--- @param G CxGrammar
--- @param p Parser # Parser
--- @return boolean
local function kr_shape(G, p)
    local m = p:mark()
    local ok, is_kr = pcall(function()
        U.parse_decl_head(p)
        if G.rules.parseType(p) == nil then
            return false
        end
        if U.ident_name(p) == nil then
            return false
        end
        return U.at(p, "punct", "(")
    end)
    p:reset(m)
    return ok and is_kr
end

--- Parse a full K&R definition (shape already probed). Parameter
--- declaration lines stay raw offset slices (plain C, never Cx).
--- @param G CxGrammar
--- @param p Parser # Parser
--- @return table Ext:Gnu:KRFunction
local function parse_kr(G, p)
    local sloc = p:peek().loc
    local head = U.parse_decl_head(p)
    local ret = U.need(p, G.rules.parseType(p), "return type")
    local nm = U.need_ident(p, "function name")
    core.expect(p, "punct", "(", "'('")
    local params = {}
    if not U.at(p, "punct", ")") then
        while true do
            local pn = U.need_ident(p, "parameter name")
            params[#params + 1] = pn.name
            if U.at(p, "punct", ",") then
                p:next()
            else
                break
            end
        end
    end
    core.expect(p, "punct", ")", "')'")
    local lines = {}
    while not U.at(p, "punct", "{") do
        if p:eof() then
            p:fail("'{' to begin K&R body")
        end
        local start = p:peek().loc.offset
        local stop = nil
        while true do
            if p:eof() then
                p:fail("';' in K&R declarations")
            end
            local t = p:next()
            if t.kind == "punct" and t.value == ";" then
                stop = core.loc_end_offset(p.env, t.loc)
                break
            end
            if t.kind == "punct" and t.value == "{" then
                p:fail("';' in K&R declarations")
            end
        end
        assert(stop ~= nil, "gnu: unreachable K&R line state")
        lines[#lines + 1] = { start_offset = start, end_offset = stop }
    end
    local body = U.need(p, G.rules.parseBlock(p), "function body")
    return N("Ext:Gnu:KRFunction", U.span_loc(sloc, body.loc), {
        name = nm.name, raw = nm.raw, specs = head.specs, attrs = head.attrs,
        ret = ret, params = params, lines = lines, body = body,
    })
end

--- Parse `__auto_type name = init [, ...] ;` (GNU inferred binding).
--- Spelling is preserved verbatim (golden keeps `__auto_type`).
--- @param G CxGrammar
--- @param p Parser # Parser
--- @return table Cx:BindingDecl
local function parse_auto(G, p)
    local sloc = p:peek().loc
    p:next() -- __auto_type
    local bindings = {}
    while true do
        bindings[#bindings + 1] = U.need(p, G.rules.parseBinding(p), "binding")
        if U.at(p, "punct", ",") then
            p:next()
        else
            break
        end
    end
    local semi = U.expect_semi(p)
    return N("Cx:BindingDecl", U.span_loc(sloc, semi.loc), {
        introducer = "__auto_type", specifiers = {}, alignas = nil,
        attrs = {}, bindings = bindings,
    })
end

--- @param G CxGrammar
--- @param env table {target: table, dialect: table}
function M.extend_grammar(G, env)
    assert(env ~= nil and env.dialect ~= nil, "gnu: env needs dialect")
    if not env.dialect.gnu then
        return
    end

    -- `({ ... })` statement expressions: wrap the core `(` prefix.
    local core_paren = G.prefix["("]
    assert(core_paren ~= nil, "gnu: core ( prefix missing")
    G.prefix["("] = function(p, tok)
        if U.at(p, "punct", "{") then
            return parse_stmt_expr(G, p, tok)
        end
        return core_paren(p, tok)
    end

    -- `&&name` label addresses (prefix only; `&&` stays infix otherwise).
    G.prefix["&&"] = function(p, tok)
        local nm = U.need_ident(p, "label name")
        return N("Ext:Gnu:LabelAddr", U.span_loc(tok.loc, nm.loc), { name = nm.name })
    end

    -- `__alignof__(T)` (the lexer keyword makes op_key dispatch by value).
    G.prefix["__alignof__"] = function(p, tok)
        local sloc = tok.loc
        core.expect(p, "punct", "(", "'(' after __alignof__")
        local ty = U.need(p, G.rules.parseType(p), "type")
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Ext:Gnu:Alignof", U.span_loc(sloc, cl.loc), { type = ty })
    end

    -- `value ?: fallback`: wrap the core `?` spec, delegating full ternaries.
    local core_q = G.infix["?"]
    assert(core_q ~= nil, "gnu: core ?: spec missing")
    G.infix["?"] = {
        prec = core_q.prec,
        assoc = core_q.assoc,
        parse = function(p, left, tok, next_min)
            if U.at(p, "punct", ":") then
                p:next()
                local els = core.expr(p, G.prefix, G.infix, next_min)
                return N("Ext:Gnu:OmitMiddle", U.span_loc(left.loc, els.loc),
                    { cond = left, els = els })
            end
            return core_q.parse(p, left, tok, next_min)
        end,
    }

    -- Block items: __auto_type decls, case ranges, __label__ decls,
    -- nested functions.
    local core_item = G.rules.parseBlockItem
    assert(core_item ~= nil, "gnu: core block item missing")
    G.rules.parseBlockItem = function(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "__auto_type" then
            return parse_auto(G, p)
        end
        if t.kind == "ident" and t.value == "case" then
            local m = p:mark()
            local sloc = t.loc
            p:next()
            local lo = G.rules.parseConditional(p)
            if lo ~= nil and U.at(p, "punct", "...") then
                p:next()
                local hi = U.need(p, G.rules.parseConditional(p), "constant expression")
                local cl = core.expect(p, "punct", ":", "':'")
                return N("Ext:Gnu:CaseRange", U.span_loc(sloc, cl.loc),
                    { lo = lo, hi = hi })
            end
            p:reset(m)
        elseif t.kind == "ident" and t.value == "__label__" then
            local sloc = t.loc
            p:next()
            local names = {}
            while true do
                local nm = U.need_ident(p, "label name")
                names[#names + 1] = nm.name
                if U.at(p, "punct", ",") then
                    p:next()
                else
                    break
                end
            end
            local semi = U.expect_semi(p)
            return N("Ext:Gnu:LabelDecl", U.span_loc(sloc, semi.loc), { names = names })
        elseif t.kind == "keyword" and t.value == "function" then
            local decl = G.rules.parseFunctionDecl(p)
            return N("Ext:Gnu:NestedFunc", decl.loc, { decl = decl })
        end
        return core_item(p)
    end

    -- Statements: __asm__ and computed goto.
    local core_stmt = G.rules.parseStatement
    assert(core_stmt ~= nil, "gnu: core statement missing")
    G.rules.parseStatement = function(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "__asm__" then
            return parse_asm(p)
        end
        if t.kind == "ident" and t.value == "goto" then
            local t2 = p:peek(2)
            if t2.kind ~= "ident" then
                return parse_computed_goto(G, p)
            end
        end
        return core_stmt(p)
    end

    -- Top level: __auto_type decls and K&R definitions.
    local core_ext = G.rules.parseExternalDecl
    assert(core_ext ~= nil, "gnu: core external decl missing")
    G.rules.parseExternalDecl = function(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "__auto_type" then
            return parse_auto(G, p)
        end
        if kr_shape(G, p) then
            return parse_kr(G, p)
        end
        return core_ext(p)
    end
end

-- Mirrors: Ext:Gnu:X -> Cx:Gnu:X (fields preserved) for GNU targets.
local MIRRORS = {
    ["Ext:Gnu:StmtExpr"] = "Cx:Gnu:StmtExpr",
    ["Ext:Gnu:CaseRange"] = "Cx:Gnu:CaseRange",
    ["Ext:Gnu:OmitMiddle"] = "Cx:Gnu:OmitMiddle",
    ["Ext:Gnu:ComputedGoto"] = "Cx:Gnu:ComputedGoto",
    ["Ext:Gnu:LabelAddr"] = "Cx:Gnu:LabelAddr",
    ["Ext:Gnu:KRFunction"] = "Cx:Gnu:KRFunction",
    ["Ext:Gnu:NestedFunc"] = "Cx:Gnu:NestedFunc",
    ["Ext:Gnu:LabelDecl"] = "Cx:Gnu:LabelDecl",
    ["Ext:Gnu:AsmStmt"] = "Cx:Gnu:AsmStmt",
    ["Ext:Gnu:Alignof"] = "Cx:Gnu:Alignof",
}

M.expanders = {}
for ek, ck in pairs(MIRRORS) do
    M.expanders[ek] = function(ctx, node)
        gnu_only(ctx, node)
        local fields = {}
        for k, v in pairs(node) do
            if k ~= "kind" and k ~= "loc" then
                fields[k] = v
            end
        end
        return ast.node(ck, node.loc, fields)
    end
end

return M
