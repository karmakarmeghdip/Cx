-- Semantic-token derivation from Cx/Ext ASTs (P3).
-- The server parses each file with its own assembled grammar (strict vs
-- dialect), so tokens are always dialect-correct — no static grammar can
-- do this for extensions. Mapping is centralized for Cx:* kinds; Ext:*
-- kinds first try the optional `mod.lsp_token(node)` hook (same pattern
-- as extend_grammar/expanders), then fall back to the expanded-kind
-- mapping, then to `keyword`.

local M = {}

--- Fixed legend (order matters; indices are 0-based on the wire).
M.legend = {
    tokenTypes = {
        "keyword", "type", "struct", "enum", "function", "variable",
        "parameter", "property", "label", "macro", "comment", "string",
        "number", "operator", "namespace",
    },
    tokenModifiers = {
        "declaration", "definition", "readonly", "deprecated", "defaultLibrary",
    },
}

--- Reverse lookup tables built on first use.
local type_index = nil
local mod_index = nil

local function ensure_index()
    if type_index ~= nil then
        return
    end
    type_index = {}
    for i, t in ipairs(M.legend.tokenTypes) do
        type_index[t] = i - 1
    end
    mod_index = {}
    for i, m in ipairs(M.legend.tokenModifiers) do
        mod_index[m] = i - 1
    end
end

--- Bitmask for a modifier list.
--- @param mods string[]
--- @return integer
local function mod_mask(mods)
    ensure_index()
    assert(mod_index ~= nil, "tokens: legend index missing")
    local mask = 0
    for _, m in ipairs(mods or {}) do
        local b = mod_index[m]
        if b ~= nil then
            mask = mask + (2 ^ b)
        end
    end
    return mask
end

--- Token type index by name.
--- @param t string
--- @return integer
local function tok(t)
    ensure_index()
    assert(type_index ~= nil, "tokens: legend index missing")
    return type_index[t] or type_index["keyword"]
end

-- Central Cx:* mapping: kind -> {type, modifiers}.
local CX_MAP = {
    ["Cx:Binding"] = { "variable", { "declaration" } },
    ["Cx:BindingDecl"] = { "keyword", {} },
    ["Cx:FunctionDecl"] = { "function", { "declaration" } },
    ["Cx:Param"] = { "parameter", { "declaration" } },
    ["Cx:TypeAlias"] = { "type", { "declaration" } },
    ["Cx:RecordDecl"] = { "struct", { "declaration" } },
    ["Cx:EnumDecl"] = { "enum", { "declaration" } },
    ["Cx:Enumerator"] = { "enum", { "declaration" } },
    ["Cx:Field"] = { "property", { "declaration" } },
    ["Cx:Directive"] = { "macro", {} },
    ["Cx:StaticAssert"] = { "keyword", {} },
    ["Cx:Ident"] = { "variable", {} },
    ["Cx:TypeIdent"] = { "type", {} },
    ["Cx:TagType"] = { "struct", {} },
    ["Cx:Call"] = { "function", {} },
    ["Cx:Member"] = { "property", {} },
    ["Cx:Label"] = { "label", { "declaration" } },
    ["Cx:Goto"] = { "label", {} },
    ["Cx:Return"] = { "keyword", {} },
    ["Cx:If"] = { "keyword", {} },
    ["Cx:While"] = { "keyword", {} },
    ["Cx:For"] = { "keyword", {} },
    ["Cx:Switch"] = { "keyword", {} },
    ["Cx:Case"] = { "label", {} },
}

--- Default mapping for a node kind (hook fallback included).
--- @param kind string
--- @param entries table[]|nil assembled extension entries for hook lookup
--- @param node table|nil node (passed to hooks)
--- @return integer type_idx
--- @return integer mods_mask
function M.map_kind(kind, entries, node)
    if kind:sub(1, 4) == "Ext:" and entries ~= nil and node ~= nil then
        local name = kind:match("^Ext:([^:]+):")
        for _, e in ipairs(entries) do
            if e.mod.name == name and type(e.mod.lsp_token) == "function" then
                local ok, t, mods = pcall(e.mod.lsp_token, node)
                if ok and type(t) == "string" then
                    return tok(t), mod_mask(mods)
                end
            end
        end
        -- Fallback: mirror kind (Ext:Gnu:X -> Cx:Gnu:X mapping below).
        local mirror = "Cx:" .. kind:sub(5)
        if CX_MAP[mirror] ~= nil then
            local m = CX_MAP[mirror]
            return tok(m[1]), mod_mask(m[2])
        end
        -- GNU mirrors share the struct/function shape of their Cx twins.
        if kind:find("Func", 1, true) then
            return tok("function"), mod_mask({})
        end
        if kind:find("Label", 1, true) or kind:find("Goto", 1, true)
            or kind:find("Case", 1, true) then
            return tok("label"), mod_mask({})
        end
        return tok("keyword"), mod_mask({})
    end
    local m = CX_MAP[kind]
    if m ~= nil then
        return tok(m[1]), mod_mask(m[2])
    end
    if kind == "Cx:TranslationUnit" then
        return tok("namespace"), mod_mask({})
    end
    return tok("variable"), mod_mask({})
end

--- Collect {loc, kind} spans from a tree (pre-order, source order where
--- possible). Only nodes with valid locs are emitted.
--- @param root table|nil
--- @param out table[] accumulator {loc, kind, node}
local function collect(root, out)
    if root == nil then
        return
    end
    local ast = require("compiler.ast")
    ast.walk(root, function(n)
        if type(n) == "table" and type(n.kind) == "string" and n.loc ~= nil
            and type(n.loc.line) == "number" then
            out[#out + 1] = { loc = n.loc, kind = n.kind, node = n }
        end
    end)
end

--- Build the full semantic-token data array (LSP delta-encoded uvarints:
--- {deltaLine, deltaStart, length, tokenType, tokenModifiers} * N).
--- Uses the POST-expansion tree when available (Cx:Gnu mirrors), plus
--- pre-expansion Ext nodes so unexpanded diagnostics still highlight.
--- @param doc table LspDoc (root/expanded/text)
--- @param entries table[]|nil extension entries for hooks
--- @param encoding string|nil "utf-8" (default) or "utf-16"
--- @return integer[] data
function M.full(doc, entries, encoding)
    encoding = encoding or "utf-8"
    local positions = require("compiler.lsp.positions")
    local spans = {}
    collect(doc.expanded or doc.root, spans)
    if doc.expanded ~= doc.root then
        collect(doc.root, spans)
    end
    -- Sort by start position for delta encoding.
    table.sort(spans, function(a, b)
        local x, y = a.loc, b.loc
        if x.line ~= y.line then return x.line < y.line end
        return (x.col or 1) < (y.col or 1)
    end)
    local starts = positions.line_starts(doc.text)
    local data = {}
    local pl, pc = 0, 0
    for _, s in ipairs(spans) do
        local r = positions.loc_to_range(s.loc, doc.text, starts, encoding)
        local len = 0
        if r.start.line == r["end"].line then
            len = r["end"].character - r.start.character
        else
            -- Multi-line node: emit only the first-line fragment length.
            local first = positions.line_text(doc.text, starts, r.start.line + 1)
            len = #first - r.start.character
        end
        if len > 0 then
            local dl = r.start.line - pl
            local dc = (dl == 0) and (r.start.character - pc) or r.start.character
            local tt, tm = M.map_kind(s.kind, entries, s.node)
            data[#data + 1] = dl
            data[#data + 1] = dc
            data[#data + 1] = len
            data[#data + 1] = tt
            data[#data + 1] = tm
            pl, pc = r.start.line, r.start.character
        end
    end
    return data
end

return M
