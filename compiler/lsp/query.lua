-- LSP queries (P3-P5): context-sensitive completion, hover, go-to-definition.
-- Operates directly on the AST and token stream. Symbol tables are
-- built from ast.walk over the partial root plus the C prelude. No separate index:
-- an open doc is tiny, walk is instantaneous, and stale indices can't drift.

local core = require("compiler.parser_core")
local positions = require("compiler.lsp.positions")

local M = {}

-- C23 prelude names + standard keywordsCx keywords.
local C_KEYWORDS = {
    "let", "const", "constexpr", "function", "type", "as", "cinit",
    "sizeof", "alignof", "_Generic", "struct", "union", "enum",
    "static", "extern", "thread_local", "inline", "static_assert",
    "if", "else", "while", "do", "for", "switch", "case", "default",
    "goto", "continue", "break", "return",
}

local C_TYPES = {
    "void", "bool", "char", "short", "int", "long", "float", "double",
    "signed", "unsigned", "size_t", "ssize_t", "intptr_t", "uintptr_t",
    "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "_BitInt", "_Complex",
}

-- Built-in C library functions exposed without requiring headers.
local C_PRELUDE_FNS = {
    "printf", "fprintf", "sprintf", "snprintf",
    "malloc", "calloc", "realloc", "free",
    "memcpy", "memmove", "memset", "memcmp",
    "strlen", "strcmp", "strncmp", "strcpy", "strncpy", "strcat",
    "abort", "exit",
}

-- LSP CompletionItemKind constants
local KIND_KEYWORD = 14
local KIND_FUNCTION = 3
local KIND_VARIABLE = 6
local KIND_CLASS = 7 -- used for struct/union/enum tags
local KIND_INTERFACE = 8
local KIND_MODULE = 9
local KIND_FILE = 17
local KIND_TYPE_PARAMETER = 25
local KIND_SNIPPET = 15

--- Build a completion item.
--- @param label string
--- @param kind integer
--- @param detail string|nil
--- @return table
local function item(label, kind, detail)
    return {
        label = label,
        kind = kind,
        detail = detail,
        insertTextFormat = 1,
    }
end

--- True if loc covers (line, col). 1-based, half-open col end.
--- @param loc table Loc
--- @param line integer
--- @param col integer
--- @return boolean
local function contains(loc, line, col)
    if loc == nil or type(loc.line) ~= "number" then
        return false
    end
    if line < loc.line or line > (loc.end_line or loc.line) then
        return false
    end
    if loc.end_line ~= nil and loc.end_line > loc.line then
        if line == loc.line and col < loc.col then
            return false
        end
        if line == loc.end_line and loc.end_col ~= nil and col > loc.end_col then
            return false
        end
        return true
    end
    local sc = loc.col or 1
    local ec = loc.end_col or (sc + 1)
    return col >= sc and col <= ec
end

--- Collect declared symbols from an AST.
--- Safe on partial / error roots: walks whatever nodes exist.
--- @param root table|nil
--- @return table syms {functions={}, types={}, vars={}, tags={}, labels={}, fields={}, enums={}}
function M.symbols(root)
    local syms = {
        functions = {}, types = {}, vars = {},
        tags = {}, labels = {}, fields = {}, enums = {},
    }
    local ast = require("compiler.ast")
    if root == nil or not ast.is_node(root) then
        return syms
    end
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
--- token preceding the cursor.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based
--- @param entries table[]|nil extension entries
--- @param opts table|nil options e.g. {snippet_support=bool}
--- @return table[] items
function M.complete(doc, line, col, entries, opts)
    opts = opts or {}
    local out = {}
    local seen = {}
    local function add(it)
        if it ~= nil and it.label ~= nil and not seen[it.label] then
            seen[it.label] = true
            out[#out + 1] = it
        end
    end

    local starts = positions.line_starts(doc.text or "")
    local cur_line = positions.line_text(doc.text or "", starts, line)
    local prefix = cur_line:sub(1, math.max(col - 1, 0))

    -- 1. Extension completions take precedence if registered.
    if entries ~= nil then
        local ctx = { doc = doc, line = line, col = col, prefix = prefix, opts = opts }
        for _, e in ipairs(entries) do
            if type(e.mod.lsp_complete) == "function" then
                local ok, ext_items = pcall(e.mod.lsp_complete, ctx)
                if ok and type(ext_items) == "table" then
                    for _, it in ipairs(ext_items) do
                        add(it)
                    end
                end
            end
        end
    end

    -- Import module path completion e.g. from "./" or from "
    local path_lead = prefix:match("from%s*[\x22\x27]([^\x22\x27]*)$")
    if path_lead ~= nil then
        local doc_file = doc.uri:gsub("^file://", "")
        local dir = doc_file:match("^(.*)/[^/]+$") or "."
        local sub_dir = dir
        local prefix_dir = path_lead:match("^(.*)/")
        if prefix_dir then
            sub_dir = dir .. "/" .. prefix_dir
        end
        local p = io.popen("ls -1 " .. string.format("%q", sub_dir) .. " 2>/dev/null")
        if p then
            for f in p:lines() do
                if f:match("%.cx$") and f ~= doc_file:match("([^/]+)$") then
                    local label = f
                    if prefix_dir then
                        label = prefix_dir .. "/" .. f
                    elseif path_lead:sub(1, 2) == "./" then
                        label = "./" .. f
                    end
                    add(item(label, KIND_FILE, "module file"))
                end
            end
            p:close()
        end
        return out
    end

    -- Imported symbol completion inside `import { | } from "..."`
    local import_lead = prefix:match("import%s*{([^}]*)$")
    if import_lead ~= nil then
        local mod_path = cur_line:match("from%s*[\x22\x27]([^\x22\x27]+)[\x22\x27]")
        if mod_path ~= nil then
            local doc_file = doc.uri:gsub("^file://", "")
            local modules = require("compiler.modules")
            local ok_res, target_file = pcall(modules.resolve, doc_file, mod_path)
            if ok_res and target_file ~= nil then
                local f = io.open(target_file, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local docs = require("compiler.lsp.docs")
                    local target_doc = docs.parse_text(content, { file = target_file })
                    if target_doc.root ~= nil and target_doc.root.body ~= nil then
                        for _, n in ipairs(target_doc.root.body) do
                            local d = (n.kind == "Ext:Modules:Export" and n.decl) or n
                            if d.kind == "Cx:FunctionDecl" and type(d.name) == "string" then
                                add(item(d.name, KIND_FUNCTION, render_func_sig(d)))
                            elseif d.kind == "Cx:TypeAlias" and type(d.name) == "string" then
                                add(item(d.name, KIND_TYPE_PARAMETER, "type"))
                            elseif (d.kind == "Cx:RecordDecl" or d.kind == "Cx:EnumDecl") and type(d.name) == "string" then
                                add(item(d.name, KIND_CLASS, d.tag or "tag"))
                            elseif d.kind == "Cx:BindingDecl" and d.bindings ~= nil then
                                for _, b in ipairs(d.bindings) do
                                    if type(b.name) == "string" then
                                        add(item(b.name, KIND_VARIABLE, render_binding_type(b)))
                                    end
                                end
                            end
                        end
                        return out
                    end
                end
            end
        end
    end

    local prev_tok = nil
    local lexer = require("compiler.lexer")
    local ok_toks, toks = pcall(lexer.lex, doc.text, doc.uri)
    if ok_toks and toks ~= nil then
        for _, t in ipairs(toks) do
            if t.loc ~= nil and type(t.loc.line) == "number" then
                if t.loc.line < line or (t.loc.line == line and (t.loc.col or 1) < col) then
                    prev_tok = t
                else
                    break
                end
            end
        end
    end

    local ctx = "expr"
    if prev_tok ~= nil then
        local pt = prev_tok.value or prev_tok.text
        if pt == "type" or pt == "as" or pt == ":" then
            ctx = "type"
        elseif pt == "." or pt == "->" then
            ctx = "member"
        elseif pt == "struct" or pt == "union" or pt == "enum" then
            ctx = "tag"
        end
    end

    local root = doc.root
    local syms = M.symbols(root)

    if ctx == "tag" then
        for _, n in ipairs(syms.tags) do
            add(item(n.name, KIND_CLASS, n.kind:match(":(%w+)$")))
        end
        return out
    end

    if ctx == "type" then
        for _, ty in ipairs(C_TYPES) do
            add(item(ty, KIND_TYPE_PARAMETER, "type"))
        end
        for _, n in ipairs(syms.types) do
            add(item(n.name, KIND_TYPE_PARAMETER, "type alias"))
        end
        for _, n in ipairs(syms.tags) do
            add(item(n.name, KIND_CLASS, n.kind:match(":(%w+)$")))
        end
        return out
    end

    -- Expression context: keywords, locals/globals, prelude functions.
    for _, kw in ipairs(C_KEYWORDS) do
        add(item(kw, KIND_KEYWORD, "keyword"))
    end
    for _, fn in ipairs(syms.functions) do
        local sig = render_func_sig(fn)
        add(item(fn.name, KIND_FUNCTION, sig))
    end
    for _, v in ipairs(syms.vars) do
        local ty = render_binding_type(v)
        add(item(v.name, KIND_VARIABLE, ty))
    end
    for _, fn in ipairs(C_PRELUDE_FNS) do
        add(item(fn, KIND_FUNCTION, "prelude"))
    end
    for _, ty in ipairs(syms.types) do
        add(item(ty.name, KIND_TYPE_PARAMETER, "type alias"))
    end
    for _, ty in ipairs(C_TYPES) do
        add(item(ty, KIND_TYPE_PARAMETER, "type"))
    end

    return out
end

--- Render a short type description from an AST type node.
--- @param ty table|nil
--- @return string
function render_type(ty)
    if ty == nil then
        return "auto"
    end
    local k = ty.kind
    if k == "Cx:BuiltinType" then
        return ty.name or "void"
    elseif k == "Cx:TypeIdent" then
        return ty.name or "?"
    elseif k == "Cx:PointerType" then
        return render_type(ty.base) .. "*"
    elseif k == "Cx:ArrayType" then
        return render_type(ty.element) .. "[]"
    elseif k == "Cx:TagType" then
        return (ty.tag or "struct") .. " " .. (ty.name or "<anon>")
    elseif k == "Cx:FunctionType" then
        return "function"
    end
    return "?"
end

function render_func_sig(fn)
    local parts = {}
    for _, p in ipairs(fn.params or {}) do
        parts[#parts + 1] = (p.name or "_") .. ": " .. render_type(p.type)
    end
    local ret = render_type(fn.return_type)
    return "function " .. fn.name .. "(" .. table.concat(parts, ", ") .. "): " .. ret
end

function render_binding_type(v)
    if v.type ~= nil then
        return render_type(v.type)
    end
    if v.kind == "Cx:Param" then
        return render_type(v.type)
    end
    return "auto"
end

--- Find the innermost AST node enclosing (line, col).
--- @param root table|nil
--- @param line integer
--- @param col integer
--- @return table|nil
function M.node_at(root, line, col)
    local ast = require("compiler.ast")
    if root == nil or not ast.is_node(root) then
        return nil
    end
    local best = nil
    ast.walk(root, function(n)
        ---@cast n table
        if type(n) == "table" and type(n.kind) == "string"
            and contains(n.loc, line, col) then
            best = n
        end
    end)
    return best
end

--- Hover text for a position: kind + name + loc, plus lowered-C / extension
--- markdown hint when available.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based
--- @param entries table[]|nil extension entries
--- @return string|nil markdown
function M.hover(doc, line, byte_col, entries)
    local n = M.node_at(doc.expanded or doc.root, line, byte_col)
    if n == nil then
        return nil
    end

    -- Allow extensions to provide custom rich markdown hover.
    if entries ~= nil then
        for _, e in ipairs(entries) do
            if type(e.mod.lsp_hover) == "function" then
                local ok, md = pcall(e.mod.lsp_hover, n, { doc = doc, line = line, col = byte_col })
                if ok and type(md) == "string" and #md > 0 then
                    return md
                end
            end
        end
    end

    local file = (n.loc and n.loc.file) or doc.uri
    local l = (n.loc and n.loc.line) or line
    local c = (n.loc and n.loc.col) or byte_col
    local hdr = n.kind
    if type(n.name) == "string" then
        hdr = hdr .. " `" .. n.name .. "`"
    end
    local out = { hdr .. " (" .. file .. ":" .. l .. ":" .. c .. ")" }
    if n.kind == "Cx:FunctionDecl" then
        out[#out + 1] = "```cx\n" .. render_func_sig(n) .. "\n```"
    elseif n.kind == "Cx:Binding" then
        out[#out + 1] = "```cx\nlet " .. (n.name or "_") .. ": " .. render_binding_type(n) .. "\n```"
    elseif n.kind == "Cx:TypeAlias" then
        out[#out + 1] = "```cx\ntype " .. (n.name or "_") .. " = " .. render_type(n.target) .. "\n```"
    end
    return table.concat(out, "\n\n")
end

--- Definition lookup: return target Loc for the symbol under (line, col).
--- Searches locals, file scope, and workspace graph index.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param byte_col integer 1-based
--- @param workspace table[]|nil workspace symbols or index
--- @return table|nil loc
--- @return string|nil target_uri
function M.definition(doc, line, byte_col, workspace)
    local root = doc.expanded or doc.root
    local at = M.node_at(root, line, byte_col)
    if at == nil or type(at.name) ~= "string" then
        local starts = positions.line_starts(doc.text or "")
        local lt = positions.line_text(doc.text or "", starts, line)
        local pre = lt:sub(1, math.max(byte_col - 1, 0)):match("[%w_]+$")
        local post = lt:sub(math.max(byte_col, 1)):match("^[%w_]+") or ""
        local word = (pre or "") .. post
        if word == "" then
            return nil, nil
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
    if type(workspace) == "table" then
        if workspace.by_name ~= nil and workspace.by_name[want] ~= nil then
            local entry = workspace.by_name[want]
            return entry.loc, entry.uri
        end
        for _, w in ipairs(workspace) do
            if w.name == want and w.loc ~= nil then
                return w.loc, w.uri
            end
        end
    end
    if at.loc ~= nil then
        return at.loc, nil
    end
    return nil, nil
end

--- Signature help at cursor position: finds active call and parameter index.
--- @param doc table LspDoc
--- @param line integer 1-based
--- @param col integer 1-based
--- @param entries table[]|nil extension entries
--- @return table|nil SignatureHelp
function M.signature_help(doc, line, col, entries)
    local callee_name = nil
    local active_param = 0

    local n = M.node_at(doc.expanded or doc.root, line, col)
    local call = nil
    if n ~= nil then
        if n.kind == "Cx:Call" then
            call = n
        else
            local ast = require("compiler.ast")
            if doc.root ~= nil and ast.is_node(doc.root) then
                ast.walk(doc.root, function(candidate)
                    if candidate.kind == "Cx:Call" and contains(candidate.loc, line, col) then
                        call = candidate
                    end
                end)
            end
        end
    end

    if call ~= nil then
        if call.fn ~= nil and call.fn.kind == "Cx:Ident" then
            callee_name = call.fn.name
        elseif call.callee ~= nil and call.callee.kind == "Cx:Ident" then
            callee_name = call.callee.name
        end
        if call.args ~= nil and #call.args > 0 then
            for i, arg in ipairs(call.args) do
                if arg.loc ~= nil and (arg.loc.line < line or (arg.loc.line == line and (arg.loc.col or 1) <= col)) then
                    active_param = i - 1
                end
            end
        end
    else
        -- Fallback to text before cursor for incomplete/unparsed calls
        local starts = positions.line_starts(doc.text or "")
        local cur_line = positions.line_text(doc.text or "", starts, line)
        local prefix = cur_line:sub(1, math.max(col - 1, 0))
        local fn_match, args_part = prefix:match("([%w_]+)%s*%(([^()]*)$")
        if fn_match ~= nil then
            callee_name = fn_match
            for _ in args_part:gmatch(",") do
                active_param = active_param + 1
            end
        end
    end

    if callee_name == nil then
        return nil
    end

    local syms = M.symbols(doc.expanded or doc.root)
    local target_fn = nil
    for _, f in ipairs(syms.functions) do
        if f.name == callee_name then
            target_fn = f
            break
        end
    end

    if target_fn == nil then
        return nil
    end

    local params_info = {}
    local param_labels = {}
    for _, p in ipairs(target_fn.params or {}) do
        local plabel = (p.name or "_") .. ": " .. render_type(p.type)
        param_labels[#param_labels + 1] = plabel
        params_info[#params_info + 1] = { label = plabel }
    end

    local sig_label = "function " .. target_fn.name .. "(" .. table.concat(param_labels, ", ") .. "): " .. render_type(target_fn.return_type)

    return {
        signatures = {
            {
                label = sig_label,
                parameters = params_info,
                activeParameter = active_param,
            }
        },
        activeSignature = 0,
        activeParameter = active_param,
    }
end

--- Simple type inference for expressions initializing bindings.
--- @param expr table
--- @param syms table
--- @return string|nil
local function infer_init_type(expr, syms)
    if expr == nil or type(expr) ~= "table" then
        return nil
    end
    local k = expr.kind
    if k == "Cx:IntLit" or k == "Cx:IntegerLit" then
        return "int"
    elseif k == "Cx:FloatLit" then
        return "double"
    elseif k == "Cx:StringLit" then
        return "const char*"
    elseif k == "Cx:CharLit" then
        return "char"
    elseif k == "Cx:BoolLit" then
        return "bool"
    elseif k == "Cx:NullLit" then
        return "void*"
    elseif k == "Cx:Call" then
        local callee = (expr.fn or expr.callee)
        if callee ~= nil and callee.kind == "Cx:Ident" and syms ~= nil then
            for _, f in ipairs(syms.functions or {}) do
                if f.name == callee.name and f.return_type ~= nil then
                    return render_type(f.return_type)
                end
            end
        end
    end
    return nil
end

--- Inlay hints for omitted types and parameter names.
--- @param doc table LspDoc
--- @param range table LSP Range {start={line,character}, end={line,character}}
--- @param entries table[]|nil extension entries
--- @param encoding string|nil "utf-8" or "utf-16"
--- @return table[] InlayHint list
function M.inlay_hints(doc, range, entries, encoding)
    encoding = encoding or "utf-8"
    local positions = require("compiler.lsp.positions")
    local starts = positions.line_starts(doc.text)
    local syms = M.symbols(doc.expanded or doc.root)
    local hints = {}

    local ast = require("compiler.ast")
    if doc.root ~= nil and ast.is_node(doc.root) then
        ast.walk(doc.root, function(n)
            if type(n) ~= "table" or type(n.kind) ~= "string" or n.loc == nil then
                return
            end
            local k = n.kind
            -- 1. Inferred type on Cx:Binding where type was omitted: `let x = 42;`
            if k == "Cx:Binding" and n.type == nil and n.init ~= nil and type(n.name) == "string" then
                local ty_str = infer_init_type(n.init, syms)
                if ty_str ~= nil then
                    local line = n.loc.line
                    local lt = positions.line_text(doc.text, starts, line)
                    local col = (n.loc.col or 1) + #n.name
                    local char_pos = positions.byte_col_to_char(lt, col, encoding)
                    hints[#hints + 1] = {
                        position = { line = line - 1, character = char_pos },
                        label = ": " .. ty_str,
                        kind = 1, -- Type
                        paddingLeft = true,
                    }
                end
            -- 2. Parameter name hint on Cx:Call arguments: `add(a: 1, b: 2)`
            elseif k == "Cx:Call" and (n.fn or n.callee) ~= nil and (n.fn or n.callee).kind == "Cx:Ident" and n.args ~= nil and #n.args > 0 then
                local callee = (n.fn or n.callee).name
                local target_fn = nil
                for _, f in ipairs(syms.functions) do
                    if f.name == callee then
                        target_fn = f
                        break
                    end
                end
                if target_fn ~= nil and target_fn.params ~= nil then
                    for i, arg in ipairs(n.args) do
                        local p = target_fn.params[i]
                        if p ~= nil and type(p.name) == "string" and arg.loc ~= nil then
                            local line = arg.loc.line
                            local lt = positions.line_text(doc.text, starts, line)
                            local char_pos = positions.byte_col_to_char(lt, arg.loc.col or 1, encoding)
                            hints[#hints + 1] = {
                                position = { line = line - 1, character = char_pos },
                                label = p.name .. ":",
                                kind = 2, -- Parameter
                                paddingRight = true,
                            }
                        end
                    end
                end
            end
        end)
    end

    -- Dispatch extension inlay hints.
    if entries ~= nil then
        for _, e in ipairs(entries) do
            if type(e.mod.lsp_inlay_hints) == "function" then
                local ok, ext_hints = pcall(e.mod.lsp_inlay_hints, doc, {
                    range = range,
                    syms = syms,
                    encoding = encoding,
                })
                if ok and type(ext_hints) == "table" then
                    for _, h in ipairs(ext_hints) do
                        hints[#hints + 1] = h
                    end
                end
            end
        end
    end

    return hints
end

--- Document symbols for file outline and symbol search.
--- @param doc table LspDoc
--- @param encoding string|nil "utf-8" or "utf-16"
--- @return table[] DocumentSymbol list
function M.document_symbols(doc, encoding)
    encoding = encoding or "utf-8"
    local positions = require("compiler.lsp.positions")
    local starts = positions.line_starts(doc.text)
    local symbols = {}

    local ast = require("compiler.ast")
    if doc.root == nil or not ast.is_node(doc.root) or doc.root.body == nil then
        return symbols
    end

    for _, n in ipairs(doc.root.body) do
        if type(n) == "table" and type(n.kind) == "string" and n.loc ~= nil then
            local r = positions.loc_to_range(n.loc, doc.text, starts, encoding)
            local k = n.kind
            if k == "Cx:FunctionDecl" and type(n.name) == "string" then
                local sig = render_func_sig(n)
                symbols[#symbols + 1] = {
                    name = n.name,
                    detail = sig,
                    kind = 12, -- Function
                    range = r,
                    selectionRange = r,
                }
            elseif k == "Cx:TypeAlias" and type(n.name) == "string" then
                symbols[#symbols + 1] = {
                    name = n.name,
                    detail = render_type(n.target),
                    kind = 26, -- TypeParameter / Interface
                    range = r,
                    selectionRange = r,
                }
            elseif k == "Cx:RecordDecl" then
                local children = {}
                for _, m in ipairs(n.members or {}) do
                    if m.kind == "Cx:Field" and type(m.name) == "string" and m.loc ~= nil then
                        local mr = positions.loc_to_range(m.loc, doc.text, starts, encoding)
                        children[#children + 1] = {
                            name = m.name,
                            detail = render_type(m.type),
                            kind = 8, -- Field
                            range = mr,
                            selectionRange = mr,
                        }
                    end
                end
                symbols[#symbols + 1] = {
                    name = n.name or "<anonymous>",
                    detail = n.tag or "struct",
                    kind = 23, -- Struct
                    range = r,
                    selectionRange = r,
                    children = #children > 0 and children or nil,
                }
            elseif k == "Cx:EnumDecl" then
                local children = {}
                for _, e in ipairs(n.enumerators or {}) do
                    if e.kind == "Cx:Enumerator" and type(e.name) == "string" and e.loc ~= nil then
                        local er = positions.loc_to_range(e.loc, doc.text, starts, encoding)
                        children[#children + 1] = {
                            name = e.name,
                            detail = "enum constant",
                            kind = 22, -- EnumMember
                            range = er,
                            selectionRange = er,
                        }
                    end
                end
                symbols[#symbols + 1] = {
                    name = n.name or "<anonymous>",
                    detail = "enum",
                    kind = 10, -- Enum
                    range = r,
                    selectionRange = r,
                    children = #children > 0 and children or nil,
                }
            elseif k == "Cx:Binding" and type(n.name) == "string" then
                symbols[#symbols + 1] = {
                    name = n.name,
                    detail = render_binding_type(n),
                    kind = 13, -- Variable
                    range = r,
                    selectionRange = r,
                }
            end
        end
    end

    return symbols
end

return M
