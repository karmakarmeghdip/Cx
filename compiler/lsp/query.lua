-- Scope-aware queries over a parsed doc (P4).
-- completion / hover / definition built from ast.walk over the partial
-- root plus the C prelude. No separate index: files are small and docs
-- reparse on every full-sync change.

local M = {}

local PRELUDE_TYPES = {
    "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
    "va_list", "wchar_t", "char16_t", "char32_t",
    "bool", "char", "short", "int", "long", "float", "double",
    "signed", "unsigned", "void", "nullptr_t",
}

local CORE_KEYWORDS = {
    "let", "const", "constexpr", "function", "type", "as", "cinit",
    "sizeof", "alignof", "_Generic", "struct", "union", "enum",
    "static", "extern", "thread_local", "inline", "static_assert",
    "if", "else", "while", "do", "for", "switch", "case", "default",
    "goto", "continue", "break", "return",
}

--- True when loc (bytes, 1-based) contains line/col.
--- @param loc table
--- @param line integer 1-based
--- @param col integer 1-based byte col
--- @return boolean
local function contains(loc, line, col)
    if loc == nil or type(loc.line) ~= "number" then
        return false
    end
    local sl, sc = loc.line, loc.col or 1
    local el, ec = loc.end_line or sl, loc.end_col or sc
    if line < sl or line > el then
        return false
    end
    if line == sl and col < sc then
        return false
    end
    if line == el and col >= ec then
        return false
    end
    return true
end

--- Walk helper returning all named declarations in a root.
--- @param root table|nil
--- @return table syms {functions={}, types={}, vars={}, tags={}, labels={}, fields={}, enums={}}
function M.symbols(root)
    local syms = {
        functions = {}, types = {}, vars = {},
        tags = {}, labels = {}, fields = {}, enums = {},
    }
    if root == nil then
        return syms
    end
    local ast = require("compiler.ast")
    ast.walk(root, function(n)
        ---@cast n table
        if type(n) ~= "table" or type(n.kind) ~= "string" then
            return
        end
        if n.kind == "Cx:FunctionDecl" and type(n.name) == "string" then
            syms.functions[#syms.functions + 1] = n
            syms.vars[#syms.vars + 1] = n
        elseif n.kind == "Cx:Binding" and type(n.name) == "string" then
            syms.vars[#syms.vars + 1] = n
        elseif n.kind == "Cx:Param" and type(n.name) == "string" then
            syms.vars[#syms.vars + 1] = n
        elseif n.kind == "Cx:TypeAlias" and type(n.name) == "string" then
            syms.types[#syms.types + 1] = n
        elseif n.kind == "Cx:RecordDecl" then
            if type(n.name) == "string" then
                syms.tags[#syms.tags + 1] = n
            end
        elseif n.kind == "Cx:EnumDecl" then
            if type(n.name) == "string" then
                syms.tags[#syms.tags + 1] = n
            end
        elseif n.kind == "Cx:Enumerator" and type(n.name) == "string" then
            syms.enums[#syms.enums + 1] = n
            syms.vars[#syms.vars + 1] = n
        elseif n.kind == "Cx:Field" and type(n.name) == "string" then
            syms.fields[#syms.fields + 1] = n
        elseif n.kind == "Cx:Label" and type(n.name) == "string" then
            syms.labels[#syms.labels + 1] = n
        end
    end)
    return syms
end

--- Completion items at a byte position. Context-sensitive on the
--- current line prefix: after `.`/`->` only members; after `:`/`as`
--- types first; after `goto` labels; else everything.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based byte column
--- @param entries table[]|nil extension entries (adds GNU keywords)
--- @return table[] items {label, kind, detail}
function M.complete(doc, line, byte_col, entries)
    local positions = require("compiler.lsp.positions")
    local text = doc.text or ""
    local starts = doc.starts or positions.line_starts(text)
    local line_text = positions.line_text(text, starts, line)
    local prefix = line_text:sub(1, math.max(byte_col - 1, 0))
    local syms = M.symbols(doc.expanded or doc.root)
    local items = {}
    local function add(label, kind, detail)
        items[#items + 1] = { label = label, kind = kind, detail = detail }
    end
    local member_ctx = prefix:match("[%.%>]%s*[%w_]*$") ~= nil
        or prefix:match("%->%s*[%w_]*$") ~= nil
    if member_ctx then
        for _, f in ipairs(syms.fields) do
            add(f.name, 5, "field")
        end
        return items
    end
    local type_ctx = prefix:match(":%s*[%w_]*$") ~= nil
        or prefix:match("%sas%s+[%w_]*$") ~= nil
    local label_ctx = prefix:match("goto%s+[%w_]*$") ~= nil
    if label_ctx then
        for _, l in ipairs(syms.labels) do
            add(l.name, 12, "label")
        end
        return items
    end
    if type_ctx then
        for _, t in ipairs(PRELUDE_TYPES) do
            add(t, 8, "builtin type")
        end
        for _, t in ipairs(syms.types) do
            add(t.name, 8, "type alias")
        end
        for _, t in ipairs(syms.tags) do
            local head = (t.tagkind or "struct") .. " " .. (t.name or "?")
            add(head, 8, "tag")
        end
        return items
    end
    for _, k in ipairs(CORE_KEYWORDS) do
        add(k, 14, "keyword")
    end
    if entries ~= nil then
        for _, e in ipairs(entries) do
            if e.mod.name == "Gnu" then
                add("__auto_type", 14, "gnu")
                add("__asm__", 14, "gnu")
                add("__label__", 14, "gnu")
                break
            end
        end
    end
    for _, t in ipairs(syms.types) do
        add(t.name, 8, "type alias")
    end
    for _, f in ipairs(syms.functions) do
        add(f.name, 3, "function")
    end
    for _, v in ipairs(syms.vars) do
        if v.kind ~= "Cx:FunctionDecl" then
            add(v.name, 6, "variable")
        end
    end
    for _, e in ipairs(syms.enums) do
        add(e.name, 13, "enumerator")
    end
    return items
end

--- Find the innermost node containing a position.
--- @param root table|nil
--- @param line integer
--- @param col integer byte col
--- @return table|nil node
function M.node_at(root, line, col)
    if root == nil then
        return nil
    end
    local best = nil
    local ast = require("compiler.ast")
    ast.walk(root, function(n)
        ---@cast n table
        if type(n) == "table" and type(n.kind) == "string"
            and contains(n.loc, line, col) then
            best = n
        end
    end)
    return best
end

--- Hover text for a position: kind + name + loc, plus lowered-C hint
--- for bindings/functions when expansion succeeded.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based
--- @return string|nil markdown
function M.hover(doc, line, byte_col)
    local n = M.node_at(doc.expanded or doc.root, line, byte_col)
    if n == nil then
        return nil
    end
    local loc = n.loc or {}
    local where = string.format("%s:%d:%d",
        tostring(loc.file or "?"), loc.line or 0, loc.col or 0)
    if n.kind == "Cx:Binding" then
        return string.format("```cx\nlet %s\n```\n— %s (%s)",
            tostring(n.name), n.kind, where)
    end
    if n.kind == "Cx:FunctionDecl" then
        return string.format("```cx\nfunction %s\n```\n— %s (%s)",
            tostring(n.name), n.kind, where)
    end
    if n.kind == "Cx:TypeAlias" then
        return string.format("```cx\ntype %s\n```\n— %s (%s)",
            tostring(n.name), n.kind, where)
    end
    if type(n.name) == "string" then
        return string.format("`%s` — %s (%s)", n.name, n.kind, where)
    end
    return string.format("%s (%s)", n.kind, where)
end

--- Go-to-definition: first declaration with a matching name in the
--- same file (functions, bindings, params, aliases, tags, labels,
--- enumerators, fields), falling back to workspace imports
--- (see graph.workspace_of) for cross-file jumps.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based
--- @param workspace table[]|nil {name, decl_kind, path, uri, loc}
--- @return table|nil loc compiler Loc of the definition
--- @return string|nil uri document URI (nil = same file)
function M.definition(doc, line, byte_col, workspace)
    local root = doc.expanded or doc.root
    local at = M.node_at(root, line, byte_col)
    if at == nil or type(at.name) ~= "string" then
        -- Cursor may sit on a use (Cx:Ident) without a name field;
        -- fall back to the word under the cursor.
        local positions = require("compiler.lsp.positions")
        local starts = doc.starts or positions.line_starts(doc.text or "")
        local lt = positions.line_text(doc.text or "", starts, line)
        local pre = lt:sub(1, math.max(byte_col - 1, 0)):match("[%w_]+$")
        local post = lt:sub(math.max(byte_col, 1)):match("^[%w_]+") or ""
        local word = (pre or "") .. post
        if word == "" then
            return nil
        end
        at = { name = word }
    end
    local want = at.name
    local syms = M.symbols(root)
    local pools = { syms.functions, syms.types, syms.vars,
        syms.tags, syms.labels, syms.enums, syms.fields }
    for _, pool in ipairs(pools) do
        for _, n in ipairs(pool) do
            if n.name == want and n.loc ~= nil then
                return n.loc, nil
            end
        end
    end
    for _, w in ipairs(workspace or {}) do
        if w.name == want and w.loc ~= nil then
            return w.loc, w.uri
        end
    end
    return nil
end

return M
