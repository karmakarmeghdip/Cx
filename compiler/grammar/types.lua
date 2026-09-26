-- Types, qualifiers, ordered suffixes, declarator params (grammar section).
-- Registers G.rules.parseType and G.rules.parseParam. Cross-section calls go
-- through G.rules (P5-wrappable). Named references are UNCHECKED at parse
-- time (headers are opaque, so libc types like FILE* have no declarations
-- to check against); only reserved words are refused as type names.

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

--- Words that can never be a typedef reference: fail instead of silently
--- accepting them as a Cx:NamedType.
--- @param v string
--- @return boolean
local function reserved_word(v)
    return U.QUALS[v] ~= nil or U.STORAGE[v] ~= nil or U.TAGSPECS[v] ~= nil
        or U.TYPEOF_OPS[v] ~= nil or v == "_Atomic"
        or v == "alignas" or v == "_Alignas"
end

--- @param G CxGrammar
local function define(G)
    --- @param p Parser # Parser
    --- @return table|nil Cx:BuiltinType
    local function parse_builtin(p)
        local m = p:mark()
        local sloc = p:peek().loc
        local words = {}
        local eloc = sloc
        while true do
            local t = p:peek()
            if t.kind ~= "ident" or not U.BUILTINS[t.value] then
                break
            end
            words[#words + 1] = t.value
            eloc = t.loc
            p:next()
        end
        local bitwidth = nil
        if U.at(p, "ident", "_BitInt") then
            p:next()
            if not core.token(p, "punct", "(") then
                p:reset(m)
                return nil
            end
            bitwidth = U.need(p, U.rules(p).parseConditional(p), "constant expression")
            local cl = core.expect(p, "punct", ")", "')'")
            eloc = cl.loc
            words[#words + 1] = "_BitInt"
        elseif #words == 0 then
            p:reset(m)
            return nil
        end
        return N("Cx:BuiltinType", U.span_loc(sloc, eloc), {
            spell = table.concat(words, " "), bitwidth = bitwidth,
        })
    end

    --- @param p Parser # Parser
    --- @return table|nil Cx:TaggedType
    local function parse_tagged(p)
        local t = p:peek()
        if t.kind ~= "ident" or not U.TAGSPECS[t.value] then
            return nil
        end
        if p:peek(2).kind ~= "ident" then
            return nil
        end
        local sloc = t.loc
        local tagkind = p:next().value
        local nm = U.ident_name(p)
        assert(nm ~= nil, "grammar.types: unreachable tagged state")
        return N("Cx:TaggedType", U.span_loc(sloc, nm.loc),
            { tagkind = tagkind, name = nm.name })
    end

    --- @param p Parser # Parser
    --- @return table|nil Cx:NamedType
    local function parse_named(p)
        local t = p:peek()
        if t.kind ~= "ident" or reserved_word(t.value) then
            return nil
        end
        p:next()
        return N("Cx:NamedType", t.loc, { name = t.value })
    end

    --- Parameter-type list for `(...) => T`: void | ... | types + trailing ....
    --- Soft nil (caller rewinds) when the list is malformed.
    --- @param p Parser # Parser
    --- @return table|nil Cx:Param[]
    local function parse_func_type_params(p)
        local params = {}
        if U.at(p, "punct", ")") then
            return params
        end
        if U.at(p, "ident", "void") and p:peek(2).value == ")" then
            p:next()
            return params
        end
        while true do
            if U.at(p, "punct", "...") then
                local t = p:next()
                params[#params + 1] = N("Cx:Param", t.loc, { ellipsis = true })
                break
            end
            local ty = U.rules(p).parseType(p)
            if ty == nil then
                return nil
            end
            params[#params + 1] = N("Cx:Param", ty.loc, { type = ty, ellipsis = false })
            if U.at(p, "punct", ",") then
                p:next()
                if U.at(p, "punct", ")") then
                    break
                end
            else
                break
            end
        end
        return params
    end

    --- `(params) => ret`. Soft nil (rewound) without the arrow.
    --- @param p Parser # Parser
    --- @return table|nil Cx:FuncType
    local function parse_funtype(p)
        if not U.at(p, "punct", "(") then
            return nil
        end
        local m = p:mark()
        local sloc = p:peek().loc
        p:next()
        local params = parse_func_type_params(p)
        if params == nil then
            p:reset(m)
            return nil
        end
        local cl = core.token(p, "punct", ")")
        if cl == nil or not U.at(p, "punct", "=>") then
            p:reset(m)
            return nil
        end
        p:next()
        local ret = U.need(p, U.rules(p).parseType(p), "type")
        return N("Cx:FuncType", U.span_loc(sloc, ret.loc), { params = params, ret = ret })
    end

    --- `(T)` grouping inside type positions.
    --- @param p Parser # Parser
    --- @return table|nil Cx:ParenType
    local function parse_paren_type(p)
        if not U.at(p, "punct", "(") then
            return nil
        end
        local m = p:mark()
        local sloc = p:peek().loc
        p:next()
        local inner = U.rules(p).parseType(p)
        if inner == nil then
            p:reset(m)
            return nil
        end
        local cl = core.token(p, "punct", ")")
        if cl == nil then
            p:reset(m)
            return nil
        end
        return N("Cx:ParenType", U.span_loc(sloc, cl.loc), { inner = inner })
    end

    --- typeof/typeof_unqual/__typeof__ `(T-or-expr)`. Committed after the
    --- operator: the subject gate (U.likely_type) sends unknown leading
    --- identifiers down the expression path, everything else down types.
    --- @param p Parser # Parser
    --- @return table|nil Cx:TypeofType
    local function parse_typeof(p)
        local t = p:peek()
        if t.kind ~= "ident" or not U.TYPEOF_OPS[t.value] then
            return nil
        end
        local sloc = t.loc
        local op = p:next().value
        core.expect(p, "punct", "(", "'(' after " .. op)
        local subj = nil
        local is_type = false
        if U.likely_type(p) then
            subj = U.need(p, U.rules(p).parseType(p), "type")
            is_type = true
        else
            subj = U.need(p, U.rules(p).parseExpression(p), "expression")
        end
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Cx:TypeofType", U.span_loc(sloc, cl.loc),
            { op = op, subject = subj, is_type = is_type })
    end

    --- `_Atomic(T)` constructor form (`_Atomic T` is a parseType prefix).
    --- @param p Parser # Parser
    --- @return table|nil Cx:AtomicType
    local function parse_atomic_type(p)
        if not U.at(p, "ident", "_Atomic") or p:peek(2).value ~= "(" then
            return nil
        end
        local sloc = p:peek().loc
        p:next()
        p:next()
        local inner = U.need(p, U.rules(p).parseType(p), "type")
        local cl = core.expect(p, "punct", ")", "')'")
        return N("Cx:AtomicType", U.span_loc(sloc, cl.loc), { inner = inner })
    end

    --- One type base, in committed-safe order. Only nil (never raises)
    --- except inside already-committed sub-spans (typeof/sizeof subjects
    --- call parseType directly, where raising is correct).
    --- @param p Parser # Parser
    --- @return table|nil base node
    local function parse_base(p)
        local b = parse_builtin(p)
        if b ~= nil then
            local t = p:peek()
            if t.kind == "ident" and (t.value == "_Complex" or t.value == "_Imaginary") then
                p:next()
                return N("Cx:ComplexType", U.span_loc(b.loc, t.loc),
                    { base = b, flavor = t.value })
            end
            return b
        end
        b = parse_tagged(p)
        if b ~= nil then
            return b
        end
        b = parse_funtype(p)
        if b ~= nil then
            return b
        end
        b = parse_paren_type(p)
        if b ~= nil then
            return b
        end
        b = parse_typeof(p)
        if b ~= nil then
            return b
        end
        b = parse_atomic_type(p)
        if b ~= nil then
            return b
        end
        return parse_named(p)
    end

    --- `*` + qualifier loop.
    --- @param p Parser # Parser
    --- @return table|nil Cx:PtrSuffix
    local function parse_ptr_suffix(p)
        if not U.at(p, "punct", "*") then
            return nil
        end
        local sloc = p:peek().loc
        local star = p:next()
        local quals = {}
        local eloc = star.loc
        while true do
            local t = p:peek()
            if U.is_qual(t) then
                quals[#quals + 1] = t.value
                eloc = t.loc
                p:next()
            else
                break
            end
        end
        return N("Cx:PtrSuffix", U.span_loc(sloc, eloc), { quals = quals })
    end

    --- `[quals static? quals (expr | * | empty)]`. Bound is comma-free.
    --- @param p Parser # Parser
    --- @return table|nil Cx:ArraySuffix
    local function parse_array_suffix(p)
        if not U.at(p, "punct", "[") then
            return nil
        end
        local sloc = p:peek().loc
        p:next()
        local quals = {}
        while true do
            local t = p:peek()
            if U.is_qual(t) then
                quals[#quals + 1] = t.value
                p:next()
            else
                break
            end
        end
        local static = false
        if U.at(p, "ident", "static") then
            static = true
            p:next()
        end
        while true do
            local t = p:peek()
            if U.is_qual(t) then
                quals[#quals + 1] = t.value
                p:next()
            else
                break
            end
        end
        local star = false
        local size = nil
        local cl = nil
        if U.at(p, "punct", "*") and p:peek(2).value == "]" then
            star = true
            p:next()
            cl = core.expect(p, "punct", "]", "']'")
        elseif U.at(p, "punct", "]") then
            cl = p:next()
        else
            size = U.need(p, U.rules(p).parseNoComma(p), "array bound")
            cl = core.expect(p, "punct", "]", "']'")
        end
        return N("Cx:ArraySuffix", U.span_loc(sloc, cl.loc), {
            quals = quals, static = static, star = star, size = size,
        })
    end

    --- Full type: quals* _Atomic? base suffix*. Soft nil (rewound) without
    --- a base; suffixes apply strictly left to right.
    --- @param p Parser # Parser
    --- @return table|nil Cx:Type
    local function parse_type(p)
        local m = p:mark()
        local sloc = p:peek().loc
        local quals = {}
        local atomic_prefix = false
        while true do
            local t = p:peek()
            if U.is_qual(t) and t.value ~= "_Atomic" then
                quals[#quals + 1] = t.value
                p:next()
            elseif t.kind == "ident" and t.value == "_Atomic"
                and p:peek(2).value ~= "(" and not atomic_prefix then
                atomic_prefix = true
                p:next()
            else
                break
            end
        end
        local base = parse_base(p)
        if base == nil then
            p:reset(m)
            return nil
        end
        local suffixes = core.suffix_loop(p, { parse_ptr_suffix, parse_array_suffix })
        local endloc = base.loc
        if #suffixes > 0 then
            endloc = suffixes[#suffixes].loc
        end
        return N("Cx:Type", U.span_loc(sloc, endloc), {
            quals = quals, atomic_prefix = atomic_prefix,
            base = base, suffixes = suffixes,
        })
    end

    G.rules.parseType = parse_type

    --- One function-declarator parameter: `...` | `name: T` | bare `T`.
    --- @param p Parser # Parser
    --- @return table Cx:Param (raises when no parameter follows)
    G.rules.parseParam = function(p)
        if U.at(p, "punct", "...") then
            local t = p:next()
            return N("Cx:Param", t.loc, { ellipsis = true })
        end
        local t = p:peek()
        if t.kind == "ident" and p:peek(2).value == ":" then
            local sloc = t.loc
            local nm = U.need_ident(p, "parameter name")
            core.expect(p, "punct", ":", "':'")
            local ty = U.need(p, U.rules(p).parseType(p), "type")
            return N("Cx:Param", U.span_loc(sloc, ty.loc),
                { name = nm.name, raw = nm.raw, type = ty, ellipsis = false })
        end
        local ty = U.need(p, U.rules(p).parseType(p), "parameter")
        return N("Cx:Param", ty.loc, { type = ty, ellipsis = false })
    end
end

return { define = define }
