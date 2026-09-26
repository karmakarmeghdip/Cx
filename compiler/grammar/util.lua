-- Shared grammar helpers (no syntax of their own): spelling sets, the
-- type-vs-expression gate, attributes, declaration heads, loc spans.
-- Rule functions live in the section modules and look each other up
-- through G.rules (keeps P5 wrapping possible).

local core = require("compiler.parser_core")

local U = {}

-- Words that lex as plain idents but behave as keywords in type positions.
U.BUILTINS = {
    void = true, char = true, short = true, int = true, long = true,
    float = true, double = true, signed = true, unsigned = true,
    bool = true, char8_t = true, char16_t = true, char32_t = true,
    wchar_t = true, size_t = true, ptrdiff_t = true, nullptr_t = true,
    va_list = true, _Decimal32 = true, _Decimal64 = true, _Decimal128 = true,
}

U.QUALS = { const = true, volatile = true, restrict = true }
U.TAGSPECS = { struct = true, union = true, enum = true }
U.TYPEOF_OPS = { typeof = true, typeof_unqual = true, __typeof__ = true }

--- Type qualifier (or _Atomic) at this token? `const` lexes as a keyword
--- (it introduces bindings too); volatile/restrict/_Atomic lex as idents.
--- @param t LexToken
--- @return boolean
function U.is_qual(t)
    if t.kind ~= "ident" and t.kind ~= "keyword" then
        return false
    end
    return U.QUALS[t.value] ~= nil or t.value == "_Atomic"
end

-- Permissive head set; per-decl validation rejects the clear-cut mistakes.
-- Spec (samples/c-vs-cx.md) storage-class-specifier =
--   "static" | "extern" | "constexpr" | "thread_local" | "_Thread_local".
-- `register` and `auto` are rejected (use plain `let` / inferred `let`).
U.STORAGE = {
    static = true, extern = true, constexpr = true,
    thread_local = true, _Thread_local = true,
    inline = true, _Noreturn = true,
}

-- Valid on functions only; rejected on bindings/aliases elsewhere.
U.FUNC_ONLY_SPECS = { inline = true, _Noreturn = true }

--- Next token matches kind (+ optional spelling)?
--- @param p Parser # Parser
--- @param kind string
--- @param value string|nil
--- @return boolean
function U.at(p, kind, value)
    local t = p:peek()
    return t.kind == kind and (value == nil or t.value == value)
end

--- Could the cursor start a type? Qualifiers, tag introducers, typeof
--- operators, _Atomic, builtin spellings, or a known typedef name.
--- Anything else (notably unknown identifiers) starts an expression.
--- `const` arrives as a keyword token; the rest as idents.
--- @param p Parser # Parser
--- @return boolean
function U.likely_type(p)
    local t = p:peek()
    if t.kind ~= "ident" and t.kind ~= "keyword" then
        return false
    end
    local v = t.value
    if U.QUALS[v] or U.TAGSPECS[v] or U.TYPEOF_OPS[v] or U.BUILTINS[v] then
        return true
    end
    if v == "_Atomic" then
        return true
    end
    return p.env:is_typename(v)
end

--- Consume one identifier (never a keyword). Returns name + @ flag + loc, or nil.
--- @param p Parser # Parser
--- @return table|nil {name: string, raw: boolean, loc: table}
function U.ident_name(p)
    local t = p:peek()
    if t.kind ~= "ident" then
        return nil
    end
    p:next()
    return { name = t.value, raw = t.raw_ident == true, loc = t.loc }
end

--- Committed value: `v` must be non-nil or raise `expected <what>`.
--- Returns v narrowed for the analyzer (and the reader).
--- @param p Parser # Parser
--- @param v any parsed value (nil-able rule result)
--- @param what string expectation name
--- @return any # the value, non-nil
function U.need(p, v, what)
    if v == nil then
        p:fail(what)
    end
    assert(v ~= nil, "grammar.util: unreachable need state")
    return v
end

--- Committed identifier: raises `expected <what>` when absent.
--- @param p Parser # Parser
--- @param what string|nil expectation name (default "identifier")
--- @return table # {name: string, raw: boolean, loc: table}, never nil
function U.need_ident(p, what)
    return U.need(p, U.ident_name(p), what or "identifier")
end

--- Merge two locs (or nodes/tokens carrying .loc) into one span.
--- @param a table loc or carrier
--- @param b table loc or carrier
--- @return table Loc
function U.span_loc(a, b)
    local la = a.loc or a
    local lb = b.loc or b
    return {
        file = la.file, line = la.line, col = la.col,
        end_line = lb.end_line, end_col = lb.end_col, offset = la.offset,
    }
end

--- Expect `;` with a stable message.
--- @param p Parser # Parser
--- @return table token
function U.expect_semi(p)
    return core.expect(p, "punct", ";", "';'")
end

--- Parse zero or more `[[...]]` groups; each entry is the raw inner text
--- (token raws joined with single spaces; nesting tracked).
--- @param p Parser # Parser
--- @return string[]
function U.parse_attrs(p)
    local out = {}
    while p:peek().kind == "attr_open" do
        p:next()
        local parts = {}
        local depth = 1
        while true do
            local t = p:peek()
            if t.kind == "eof" then
                p:fail("']]' to close '[['")
            end
            p:next()
            if t.kind == "attr_open" then
                depth = depth + 1
                parts[#parts + 1] = t.raw
            elseif t.kind == "attr_close" then
                depth = depth - 1
                if depth == 0 then
                    break
                end
                parts[#parts + 1] = t.raw
            else
                parts[#parts + 1] = t.raw
            end
        end
        out[#out + 1] = table.concat(parts, " ")
    end
    return out
end

---@class DeclHead
---@field specs string[] storage-class spellings in source order
---@field alignas string|nil exact raw alignas/_Alignas argument text (never reflowed)
---@field alignas_kind string|nil "alignas" | "_Alignas" source spelling
---@field attrs string[]

--- Parse a declaration head: storage classes, alignas, attributes, any order.
--- In GNU mode (p.env.dialect.gnu) also accepts leading `__extension__`
--- and `__attribute__((...))` as raw full-text attrs (verbatim rule).
--- Spec: `constexpr` is a head specifier (`constexpr let x: T`), never a
--- binding introducer. It lexes as a keyword, so it needs its own branch
--- here (the ident STORAGE check below cannot see it). `register`/`auto`
--- are rejected with a dedicated message (spec: remove them).
--- @param p Parser # Parser
--- @return DeclHead
function U.parse_decl_head(p)
    ---@type DeclHead
    local head = { specs = {}, alignas = nil, alignas_kind = nil, attrs = {} }
    local gnu = p.env.dialect.gnu
    while true do
        local t = p:peek()
        if t.kind == "attr_open" then
            for _, s in ipairs(U.parse_attrs(p)) do
                head.attrs[#head.attrs + 1] = s
            end
        elseif t.kind == "keyword" and t.value == "constexpr" then
            head.specs[#head.specs + 1] = t.value
            p:next()
        elseif t.kind == "ident" and (t.value == "register" or t.value == "auto") then
            p:fail("'" .. t.value .. "' is not allowed in Cx (spec: remove it;"
                .. ((t.value == "auto")
                    and " use `let x = ...` for inference)"
                    or " use plain `let`)"))
        elseif t.kind == "ident" and U.STORAGE[t.value] then
            head.specs[#head.specs + 1] = t.value
            p:next()
        elseif gnu and t.kind == "ident" and t.value == "__extension__" then
            head.attrs[#head.attrs + 1] = "__extension__"
            p:next()
        elseif gnu and t.kind == "ident" and t.value == "__attribute__" then
            local start = t.loc.offset
            p:next()
            local inner = core.balanced(p, "(", ")")
            if inner == nil then
                p:fail("'(' after __attribute__")
            end
            assert(inner ~= nil, "grammar.util: unreachable attribute state")
            local close = inner[#inner]
            head.attrs[#head.attrs + 1] =
                p.env.src:sub(start, core.loc_end_offset(p.env, close.loc) - 1)
        elseif t.kind == "ident" and (t.value == "alignas" or t.value == "_Alignas") then
            local aw = t.value
            p:next()
            local inner = core.balanced(p, "(", ")")
            if inner == nil then
                p:fail("'(' after alignas")
            end
            assert(inner ~= nil, "grammar.util: unreachable alignas state")
            -- Exact byte slice (never reflowed): from just past `(` to `)`.
            local open_tok = inner[1]
            local close_tok = inner[#inner]
            head.alignas_kind = aw
            head.alignas = p.env.src:sub(open_tok.loc.offset + 1, close_tok.loc.offset - 1)
        else
            break
        end
    end
    return head
end

--- Reject function-only specifiers outside function declarations.
--- @param p Parser # Parser
--- @param head DeclHead
--- @param what string construct name for the message
function U.forbid_func_specs(p, head, what)
    for _, s in ipairs(head.specs) do
        if U.FUNC_ONLY_SPECS[s] then
            p:fail("'" .. s .. "' is only allowed on functions (" .. what .. ")")
        end
    end
end

--- Opaque source span for a cinit-style region: byte offsets into env.src.
--- @param p Parser # Parser
--- @param open_tok LexToken
--- @param close_tok LexToken
--- @return integer start_offset
--- @return integer end_offset
function U.cinit_span(p, open_tok, close_tok)
    return open_tok.loc.offset, core.loc_end_offset(p.env, close_tok.loc)
end

--- Half-loc for one side of a split `[[` / `]]` token.
--- @param loc Loc
--- @param first boolean true for the first character's span
--- @return table Loc
local function half_loc(loc, first)
    if first then
        return { file = loc.file, line = loc.line, col = loc.col,
            end_line = loc.line, end_col = loc.col + 1, offset = loc.offset }
    end
    return { file = loc.file, line = loc.line, col = loc.col + 1,
        end_line = loc.end_line, end_col = loc.end_col, offset = loc.offset + 1 }
end

--- Consume `[`, splitting a merged `[[` (nested array opens) via pushback.
--- The synthetic second bracket inherits the merged token's trailing
--- trivia, so verbatim reconstruction keeps working. Soft nil when neither
--- follows (nothing consumed).
--- @param p Parser # Parser
--- @return table|nil opening bracket token
function U.open_bracket(p)
    local t = p:peek()
    if t.kind == "punct" and t.value == "[" then
        p:next()
        return t
    end
    if t.kind == "attr_open" then
        p:next()
        p:unget({ kind = "punct", value = "[", raw = "[",
            loc = half_loc(t.loc, false), leading = {}, trailing = t.trailing })
        return { kind = "punct", value = "[", raw = "[",
            loc = half_loc(t.loc, true), leading = t.leading, trailing = {} }
    end
    return nil
end

--- Consume `]`, splitting a merged `]]` (nested array closes) via pushback.
--- Soft nil when neither follows (nothing consumed).
--- @param p Parser # Parser
--- @return table|nil closing bracket token
function U.close_bracket(p)
    local t = p:peek()
    if t.kind == "punct" and t.value == "]" then
        p:next()
        return t
    end
    if t.kind == "attr_close" then
        p:next()
        p:unget({ kind = "punct", value = "]", raw = "]",
            loc = half_loc(t.loc, false), leading = {}, trailing = t.trailing })
        return { kind = "punct", value = "]", raw = "]",
            loc = half_loc(t.loc, true), leading = t.leading, trailing = {} }
    end
    return nil
end

--- Trailing `__attribute__((...))` groups after a record body or alias
--- target (GNU mode only): exact raw texts. Nil when absent or strict.
--- @param p Parser # Parser
--- @return string[]|nil
function U.parse_gnu_trailing(p)
    if not p.env.dialect.gnu then
        return nil
    end
    local out = {}
    while U.at(p, "ident", "__attribute__") do
        local start = p:peek().loc.offset
        p:next()
        local inner = core.balanced(p, "(", ")")
        if inner == nil then
            p:fail("'(' after __attribute__")
        end
        assert(inner ~= nil, "grammar.util: unreachable trailing state")
        local close = inner[#inner]
        out[#out + 1] = p.env.src:sub(start, core.loc_end_offset(p.env, close.loc) - 1)
    end
    if #out == 0 then
        return nil
    end
    return out
end

--- Active grammar tables for this parse (the ASSEMBLED grammar: base plus
--- any registered extensions). Core rules must resolve cross-references
--- through these — never through a captured base G — or dialect wrapping
--- (P5) stays invisible to them. The driver sets env.grammar; tests set it
--- to the grammar under test.
--- @param p Parser # Parser
--- @return table rules table of the active grammar
function U.rules(p)
    local g = p.env.grammar
    assert(g ~= nil and g.rules ~= nil,
        "grammar: env.grammar must hold the assembled G (driver or test setup)")
    return g.rules
end

--- @param p Parser # Parser
--- @return table Pratt prefix table of the active grammar
function U.prefix(p)
    local g = p.env.grammar
    assert(g ~= nil and g.prefix ~= nil,
        "grammar: env.grammar must hold the assembled G (driver or test setup)")
    return g.prefix
end

--- @param p Parser # Parser
--- @return table Pratt infix table of the active grammar
function U.infix(p)
    local g = p.env.grammar
    assert(g ~= nil and g.infix ~= nil,
        "grammar: env.grammar must hold the assembled G (driver or test setup)")
    return g.infix
end

return U
