-- Initializers: array/record/cinit/compound literals + the initializer
-- entry (grammar section). Array items and record fields recurse through
-- parseInitializer; scalar/string initializers are plain expressions.

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
    --- `[items]` (empty `[]` allowed); trailing comma tolerated, like C.
    --- A merged `[[` opens two levels (nested literals); `]]` closes.
    --- @param p Parser # Parser
    --- @return table|nil Cx:ArrayLit
    local function parse_array_lit(p)
        local open = U.open_bracket(p)
        if open == nil then
            return nil
        end
        local sloc = open.loc
        --- @return boolean
        local function at_close()
            local pk = p:peek()
            return (pk.kind == "punct" and pk.value == "]") or pk.kind == "attr_close"
        end
        local items = {}
        local closer = nil
        if not at_close() then
            while true do
                local it = U.need(p, U.rules(p).parseInitializer(p), "initializer")
                items[#items + 1] = it
                if U.at(p, "punct", ",") then
                    p:next()
                    if at_close() then
                        closer = U.close_bracket(p)
                        break
                    end
                else
                    break
                end
            end
        end
        if closer == nil then
            closer = U.close_bracket(p)
            if closer == nil then
                p:fail("']'")
            end
        end
        assert(closer ~= nil, "grammar.inits: unreachable close state")
        return N("Cx:ArrayLit", U.span_loc(sloc, closer.loc), { items = items })
    end

    --- `{name: init, ...}` (empty `{}` allowed); trailing comma tolerated.
    --- @param p Parser # Parser
    --- @return table|nil Cx:RecordLit
    local function parse_record_lit(p)
        if not U.at(p, "punct", "{") then
            return nil
        end
        local sloc = p:peek().loc
        p:next()
        local fields = {}
        if not U.at(p, "punct", "}") then
            while true do
                local nm = U.need_ident(p, "field name")
                core.expect(p, "punct", ":", "':'")
                local val = U.need(p, U.rules(p).parseInitializer(p), "initializer")
                fields[#fields + 1] = { name = nm.name, value = val }
                if U.at(p, "punct", ",") then
                    p:next()
                    if U.at(p, "punct", "}") then
                        break
                    end
                else
                    break
                end
            end
        end
        local cl = core.expect(p, "punct", "}", "'}'")
        return N("Cx:RecordLit", U.span_loc(sloc, cl.loc), { fields = fields })
    end

    --- `cinit { ... }`: opaque balanced region kept as byte offsets into
    --- env.src (directives like #embed survive verbatim).
    --- @param p Parser # Parser
    --- @return table|nil Cx:Cinit
    local function parse_cinit(p)
        if not core.keyword(p, "cinit") then
            return nil
        end
        local open = core.expect(p, "punct", "{", "'{' after cinit")
        local depth = 1
        while true do
            if p:eof() then
                p:fail("'}' to close cinit '{'")
            end
            local t = p:next()
            if t.value == "{" then
                depth = depth + 1
            elseif t.value == "}" then
                depth = depth - 1
                if depth == 0 then
                    local s, e = U.cinit_span(p, open, t)
                    return N("Cx:Cinit", U.span_loc(open.loc, t.loc),
                        { start_offset = s, end_offset = e })
                end
            end
        end
    end

    --- Any initializer: array, record, cinit, or scalar expression.
    --- (Compound literals arrive via the expression `(` prefix.) Scalar
    --- initializers are comma-free: `let x = (a, b)` needs the parens.
    --- @param p Parser # Parser
    --- @return table|nil initializer node
    local function parse_initializer(p)
        local kind = p:peek().kind
        local value = p:peek().value
        if (kind == "punct" and value == "[") or kind == "attr_open" then
            return parse_array_lit(p)
        end
        if kind == "punct" and value == "{" then
            return parse_record_lit(p)
        end
        if kind == "keyword" and value == "cinit" then
            return parse_cinit(p)
        end
        return U.rules(p).parseNoComma(p)
    end

    G.rules.parseInitializer = parse_initializer
    G.rules.parseArrayLit = parse_array_lit
    G.rules.parseRecordLit = parse_record_lit
end

return { define = define }
