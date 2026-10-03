-- LSP semantic tokens provider (P3).
-- Delta-encodes semantic tokens from lexer tokens and AST nodes into
-- standard LSP format: uvarint triples/quintuples.

local positions = require("compiler.lsp.positions")

local M = {}

M.legend = {
    tokenTypes = {
        "keyword", "type", "struct", "enum", "function", "variable",
        "parameter", "property", "label", "macro", "comment", "string",
        "number", "operator", "namespace", "decorator", "interface", "typeParameter",
    },
    tokenModifiers = {
        "declaration", "definition", "readonly", "static", "deprecated",
        "abstract", "async", "modification", "documentation", "defaultLibrary",
    },
}
M.TOKEN_TYPES = M.legend.tokenTypes
M.TOKEN_MODIFIERS = M.legend.tokenModifiers

local type_indices = {}
for i, name in ipairs(M.TOKEN_TYPES) do
    type_indices[name] = i - 1
end

local mod_indices = {}
for i, name in ipairs(M.TOKEN_MODIFIERS) do
    mod_indices[name] = bit.lshift(1, i - 1)
end

--- @param name string
--- @return integer index 0-based
local function tok(name)
    return type_indices[name] or 0
end

--- @param mods string[]|nil
--- @return integer bitmask
local function modmask(mods)
    if mods == nil then
        return 0
    end
    local m = 0
    for _, name in ipairs(mods) do
        local b = mod_indices[name]
        if b ~= nil then
            m = bit.bor(m, b)
        end
    end
    return m
end

--- Map lexer token kind / keyword / type into LSP token type index and modifier mask.
--- @param t table lexer Token
--- @return integer|nil token_type_index
--- @return integer modifier_mask
function M.map_token(t)
    local k = t.kind
    if k == "comment" then
        return tok("comment"), 0
    elseif k == "string" or k == "char" then
        return tok("string"), 0
    elseif k == "int" or k == "float" or k == "number" then
        return tok("number"), 0
    elseif k == "keyword" then
        return tok("keyword"), 0
    elseif k == "type" then
        return tok("type"), 0
    elseif k == "ident" then
        return tok("variable"), 0
    elseif k == "directive" then
        return tok("macro"), 0
    elseif k == "punct" then
        local p = t.value or t.text
        if p == "|>" or p == "->" or p == "=>" then
            return tok("operator"), 0
        end
    end
    return nil, 0
end

--- Map AST node kinds (especially extension and GNU nodes) to semantic token type and modifiers.
--- Extensions can define `lsp_token(node)` returning (type_name, modifier_table).
--- @param kind string
--- @param entries table[]|nil extension entries
--- @param node table|nil full AST node
--- @return integer token_type_index
--- @return integer modifier_mask
function M.map_kind(kind, entries, node)
    -- Allow registered extensions first chance to classify their own nodes.
    if entries ~= nil and node ~= nil then
        for _, e in ipairs(entries) do
            if type(e.mod.lsp_token) == "function" then
                local ok, t_name, t_mods = pcall(e.mod.lsp_token, node)
                if ok and type(t_name) == "string" then
                    return tok(t_name), modmask(t_mods)
                end
            end
        end
    end

    if kind:sub(1, 4) == "Ext:" or kind:sub(1, 7) == "Cx:Gnu:" then
        if kind == "Cx:Gnu:StmtExpr" or kind == "Ext:Gnu:StatementExpr" then
            return tok("macro"), modmask({ "defaultLibrary" })
        elseif kind == "Cx:Gnu:Asm" or kind == "Ext:Gnu:Asm" then
            return tok("keyword"), 0
        elseif kind == "Cx:Gnu:Attribute" or kind == "Ext:Gnu:Attribute" then
            return tok("decorator"), 0
        elseif kind:match("Pipe") or kind:match("Slot") then
            return tok("operator"), 0
        elseif kind:match("Defer") then
            return tok("keyword"), 0
        elseif kind:match("Variant") then
            return tok("enum"), 0
        end
        return tok("macro"), 0
    end

    if kind == "Cx:FunctionDecl" then
        return tok("function"), modmask({ "declaration" })
    elseif kind == "Cx:Binding" then
        return tok("variable"), modmask({ "declaration" })
    elseif kind == "Cx:Param" then
        return tok("parameter"), modmask({ "declaration" })
    elseif kind == "Cx:TypeAlias" then
        return tok("type"), modmask({ "declaration" })
    elseif kind == "Cx:RecordDecl" then
        return tok("struct"), modmask({ "declaration" })
    elseif kind == "Cx:EnumDecl" then
        return tok("enum"), modmask({ "declaration" })
    elseif kind == "Cx:Enumerator" then
        return tok("enumMember"), modmask({ "readonly" })
    elseif kind == "Cx:Field" then
        return tok("property"), 0
    end
    return tok("variable"), 0
end

--- Collect AST refinements over the parse tree.
--- @param root table|nil
--- @param entries table[]|nil
--- @return table exact_map map of line:col -> {type, mods}
--- @return table<string, boolean> known_fns
--- @return table<string, boolean> known_types
--- @return table[] ext_spans
local function build_ast_index(root, entries)
    local exact = {}
    local known_fns = {}
    local known_types = {}
    local ext_spans = {}
    local ast = require("compiler.ast")
    if root == nil or not ast.is_node(root) then
        return exact, known_fns, known_types, ext_spans
    end
    ast.walk(root, function(n)
        if type(n) ~= "table" or type(n.kind) ~= "string" then
            return
        end
        local k = n.kind
        if k == "Cx:FunctionDecl" and type(n.name) == "string" then
            known_fns[n.name] = true
        elseif k == "Cx:TypeAlias" and type(n.name) == "string" then
            known_types[n.name] = true
        elseif k == "Cx:RecordDecl" and type(n.name) == "string" then
            known_types[n.name] = true
        elseif k == "Cx:EnumDecl" and type(n.name) == "string" then
            known_types[n.name] = true
        elseif k == "Cx:Call" and n.callee ~= nil and n.callee.kind == "Cx:Ident" and n.callee.loc ~= nil then
            local loc = n.callee.loc
            exact[loc.line .. ":" .. loc.col] = { type = tok("function"), mods = 0 }
        elseif k == "Cx:TypeIdent" and n.loc ~= nil then
            exact[n.loc.line .. ":" .. n.loc.col] = { type = tok("type"), mods = 0 }
        elseif k == "Cx:TagType" and n.loc ~= nil then
            exact[n.loc.line .. ":" .. n.loc.col] = { type = tok("struct"), mods = 0 }
        elseif (k:sub(1, 4) == "Ext:" or k:sub(1, 7) == "Cx:Gnu:") and n.loc ~= nil and type(n.loc.line) == "number" then
            local t_idx, m_mask = M.map_kind(k, entries, n)
            local slen = 2
            if n.loc.end_line == n.loc.line and n.loc.end_col ~= nil then
                slen = math.max(n.loc.end_col - n.loc.col, 1)
            end
            if k == "Cx:Gnu:StmtExpr" or k == "Ext:Gnu:StatementExpr" then
                slen = 2
            end
            ext_spans[#ext_spans + 1] = {
                line = n.loc.line,
                col = n.loc.col or 1,
                length = slen,
                type = t_idx,
                mods = m_mask,
            }
        end
    end)
    return exact, known_fns, known_types, ext_spans
end

--- Collect all raw spans {line, col, length, type, mods} from lexer tokens.
--- Comments are preserved through leading trivia attached to tokens.
--- @param toks table[]
--- @param text string source code
--- @param exact table exact loc map from AST
--- @param known_fns table<string, boolean>
--- @param known_types table<string, boolean>
--- @return table[] raw_spans
local function collect_lexer_spans(toks, text, exact, known_fns, known_types)
    local raw = {}

    local function add_trivia(tr_list)
        if tr_list == nil then
            return
        end
        for _, tr in ipairs(tr_list) do
            if tr.kind == "comment" and tr.loc ~= nil and type(tr.loc.line) == "number" and tr.loc.end_line == tr.loc.line then
                local len = (tr.loc.end_col or (tr.loc.col + 1)) - tr.loc.col
                if len > 0 then
                    raw[#raw + 1] = {
                        line = tr.loc.line,
                        col = tr.loc.col,
                        length = len,
                        type = tok("comment"),
                        mods = 0,
                    }
                end
            end
        end
    end

    for _, t in ipairs(toks) do
        add_trivia(t.leading or t.leading_trivia)
        if t.loc ~= nil and type(t.loc.line) == "number" and t.loc.end_line == t.loc.line then
            local t_idx, m_mask = M.map_token(t)
            if t_idx ~= nil then
                local key = t.loc.line .. ":" .. t.loc.col
                if exact[key] ~= nil then
                    t_idx = exact[key].type
                    m_mask = bit.bor(m_mask, exact[key].mods)
                elseif t.kind == "ident" then
                    local name = t.value or t.text
                    if known_fns[name] then
                        t_idx = tok("function")
                    elseif known_types[name] then
                        t_idx = tok("type")
                    end
                end

                local len = (t.loc.end_col or (t.loc.col + 1)) - t.loc.col
                if len > 0 then
                    raw[#raw + 1] = {
                        line = t.loc.line,
                        col = t.loc.col,
                        length = len,
                        type = t_idx,
                        mods = m_mask,
                    }
                end
            end
        end
        add_trivia(t.trailing or t.trailing_trivia)
    end
    return raw
end

--- Fallback AST token collection (when lexer fails completely).
--- @param root table|nil
--- @param out table[]
local function collect_ast_fallback(root, out)
    local ast = require("compiler.ast")
    if root == nil or not ast.is_node(root) then
        return
    end
    ast.walk(root, function(n)
        if type(n) == "table" and type(n.kind) == "string" and n.loc ~= nil
            and type(n.loc.line) == "number" then
            out[#out + 1] = { loc = n.loc, kind = n.kind, node = n }
        end
    end)
end

--- Build the full semantic-token data array (LSP delta-encoded uvarints:
--- {deltaLine, deltaStart, length, tokenType, tokenModifiers} * N).
--- Uses lexer tokens & trivia for physical base coverage + AST symbols
--- for identifier refinement and extension node classification.
--- @param doc table LspDoc (root/expanded/text)
--- @param entries table[]|nil extension entries for hooks
--- @param encoding string|nil "utf-8" (default) or "utf-16"
--- @return integer[] data
function M.full(doc, entries, encoding)
    encoding = encoding or "utf-8"
    local positions = require("compiler.lsp.positions")
    local starts = positions.line_starts(doc.text)
    local lexer = require("compiler.lexer")

    local root = doc.expanded or doc.root
    local exact, known_fns, known_types, ext_spans = build_ast_index(root, entries)

    local ok_lex, toks = pcall(lexer.lex, doc.text, doc.uri)
    local raw_spans = {}
    if ok_lex and toks ~= nil then
        raw_spans = collect_lexer_spans(toks, doc.text, exact, known_fns, known_types)
    else
        -- Fallback: produce tokens from partial AST if lexer failed
        local ast_items = {}
        collect_ast_fallback(root, ast_items)
        for _, it in ipairs(ast_items) do
            local t_idx, m_mask = M.map_kind(it.kind, entries, it.node)
            local slen = 1
            if it.loc.end_line == it.loc.line and it.loc.end_col ~= nil then
                slen = math.max(it.loc.end_col - it.loc.col, 1)
            end
            raw_spans[#raw_spans + 1] = {
                line = it.loc.line,
                col = it.loc.col or 1,
                length = slen,
                type = t_idx,
                mods = m_mask,
            }
        end
    end

    -- Append extension spans that were discovered via AST
    for _, sp in ipairs(ext_spans) do
        raw_spans[#raw_spans + 1] = sp
    end

    -- Sort spans deterministically: line first, then column
    table.sort(raw_spans, function(a, b)
        if a.line ~= b.line then
            return a.line < b.line
        end
        return a.col < b.col
    end)

    -- LSP Delta-encoding
    local data = {}
    local prev_line = 1
    local prev_col = 1
    for _, span in ipairs(raw_spans) do
        if span.line >= prev_line then
            local lt = positions.line_text(doc.text, starts, span.line)
            local char_pos = positions.byte_col_to_char(lt, span.col, encoding)
            local char_len = positions.byte_len_to_char(lt, span.col, span.length, encoding)

            local delta_line = span.line - prev_line
            local delta_start
            if delta_line == 0 then
                local prev_char = positions.byte_col_to_char(lt, prev_col, encoding)
                delta_start = char_pos - prev_char
            else
                delta_start = char_pos
            end

            if delta_start >= 0 and char_len > 0 then
                data[#data + 1] = delta_line
                data[#data + 1] = delta_start
                data[#data + 1] = char_len
                data[#data + 1] = span.type
                data[#data + 1] = span.mods

                prev_line = span.line
                prev_col = span.col
            end
        end
    end

    return data
end

return M
