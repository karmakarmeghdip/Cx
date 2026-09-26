-- Modules extension: ESM-style import/export (see TODO.md section 2.A).
-- Grammar half parses top-level `import { a, b } from "path";` and
-- `export <decl>` into Ext:Modules:* markers. Unlike gnu.lua there are no
-- per-node expanders: resolution is a whole-graph driver pass
-- (compiler/modules.lua, CxCompiler:program), which consumes every
-- Ext:Modules:* node before expansion. Any survivor is a hard error via
-- the usual codegen Ext check. Gated by dialect.modules.
--
-- v1 scope: named imports only (`import *` rejected); `export` prefixes
-- one external declaration (no `export { … }` lists); top level only.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

local M = {}

M.name = "Modules"

--- @param kind string
--- @param loc table
--- @param fields table|nil
--- @return table CxNode
local function N(kind, loc, fields)
    return ast.node(kind, loc, fields)
end

--- Decode a plain `"path"` literal token. Only unprefixed double-quoted
--- literals are accepted (paths never need escapes or u8 prefixes).
--- @param p Parser # Parser
--- @return string decoded path
local function take_path(p)
    local tok = core.expect(p, "string", nil, "module path string")
    if tok.value:sub(1, 1) ~= '"' then
        p:fail_at(tok, "plain module path string")
    end
    assert(tok.value:sub(-1, -1) == '"', "modules: unreachable quote state")
    return tok.value:sub(2, -2)
end

--- Parse `import { a, b } from "path" ;` (the `import` ident is next).
--- @param p Parser # Parser
--- @return table Ext:Modules:Import
local function parse_import(p)
    local sloc = p:peek().loc
    p:next() -- import
    if U.at(p, "punct", "*") then
        p:fail("namespace imports are not supported in v1 (use named imports)")
    end
    core.expect(p, "punct", "{", "'{' after import")
    local names = {}
    if not U.at(p, "punct", "}") then
        while true do
            local nm = U.need_ident(p, "imported name")
            names[#names + 1] = nm.name
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
    if #names == 0 then
        p:fail("import list must name at least one symbol")
    end
    core.expect(p, "punct", "}", "'}'")
    local from = p:peek()
    if from.kind ~= "ident" or from.value ~= "from" then
        p:fail("'from'")
    end
    p:next()
    local path = take_path(p)
    local semi = U.expect_semi(p)
    return N("Ext:Modules:Import", U.span_loc(sloc, semi.loc),
        { names = names, path = path })
end

--- Parse `export <decl>` (the `export` ident is next). The inner
--- declaration reuses the wrapped external-decl rule so head specifiers,
--- attributes, and all decl forms behave identically with/without export.
--- @param p Parser # Parser
--- @param core_ext fun(p: table): table|nil wrapped parseExternalDecl
--- @return table Ext:Modules:Export
local function parse_export(p, core_ext)
    local sloc = p:peek().loc
    p:next() -- export
    local t = p:peek()
    if t.kind == "directive" then
        p:fail("expected declaration after 'export'")
    end
    if t.kind == "ident" and t.value == "export" then
        p:fail("export of export (drop the inner 'export')")
    end
    if t.kind == "punct" and t.value == "{" then
        p:fail("export lists are not supported in v1 (use `export <decl>`)")
    end
    local decl = core_ext(p)
    if decl == nil then
        p:fail("expected declaration after 'export'")
    end
    assert(decl ~= nil, "modules: unreachable export state")
    if decl.kind == "Cx:Directive" or decl.kind == "Cx:AttrsOnly" then
        p:fail_at(decl.loc, "expected declaration after 'export'")
    end
    return N("Ext:Modules:Export", U.span_loc(sloc, decl.loc), { decl = decl })
end

--- @param G CxGrammar
--- @param env table {target: table, dialect: table}
function M.extend_grammar(G, env)
    assert(env ~= nil and env.dialect ~= nil, "modules: env needs dialect")
    if not env.dialect.modules then
        return
    end

    -- Top level: import/export markers, then the wrapped core rule.
    local core_ext = G.rules.parseExternalDecl
    assert(core_ext ~= nil, "modules: core external decl missing")
    G.rules.parseExternalDecl = function(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "import" then
            return parse_import(p)
        end
        if t.kind == "ident" and t.value == "export" then
            return parse_export(p, core_ext)
        end
        return core_ext(p)
    end

    -- Block level: imports/exports are top-level only; fail loudly
    -- instead of falling through to expression-statement confusion.
    local core_item = G.rules.parseBlockItem
    assert(core_item ~= nil, "modules: core block item missing")
    G.rules.parseBlockItem = function(p)
        local t = p:peek()
        if t.kind == "ident" and (t.value == "import" or t.value == "export") then
            p:fail("import/export are top-level only")
        end
        return core_item(p)
    end
end

-- No per-node expanders by design: resolution is graph-scope, driven by
-- M.graph_api through compiler/modules.lua (see AGENTS.md section 7).
-- A different module syntax reuses that driver with its own classifiers.
M.expanders = {}

--- Format a loc as `file:line:col` (graph-error diagnostics).
--- @param loc table|nil
--- @return string
local function at(loc)
    loc = loc or {}
    return string.format("%s:%d:%d",
        tostring(loc.file or "?"), loc.line or 0, loc.col or 0)
end

--- Top-level import edges in source order.
--- @param root table Cx:TranslationUnit
--- @return CxImportEdge[]
local function imports_of(root)
    local out = {}
    for _, node in ipairs(root.body) do
        if node.kind == "Ext:Modules:Import" then
            out[#out + 1] = {
                node = node, names = node.names,
                path = node.path, loc = node.loc,
            }
        end
    end
    return out
end

--- Export table: name -> {node, decl, loc}. Every binding in an exported
--- BindingDecl is mapped (importing any one injects the whole
--- declaration). Duplicates are hard errors.
--- @param root table Cx:TranslationUnit
--- @param path string file path (for errors)
--- @return table<string, CxExportEntry>
local function exports_of(root, path)
    local exports = {}
    for _, node in ipairs(root.body) do
        if node.kind == "Ext:Modules:Export" then
            local decl = node.decl
            local names = {}
            if decl.kind == "Cx:FunctionDecl" or decl.kind == "Cx:TypeAlias" then
                names = { decl.name }
            elseif decl.kind == "Cx:BindingDecl" then
                for _, b in ipairs(decl.bindings) do
                    names[#names + 1] = b.name
                end
            elseif decl.kind == "Cx:RecordDecl" or decl.kind == "Cx:EnumDecl" then
                if decl.name == nil then
                    error("modules: cannot export anonymous " .. decl.kind
                        .. " in " .. path .. " (at " .. at(node.loc)
                        .. "; wrap it in a `type` alias)", 0)
                end
                names = { decl.name }
            else
                error("modules: cannot export " .. tostring(decl.kind)
                    .. " in " .. path .. " (at " .. at(node.loc) .. ")", 0)
            end
            for _, name in ipairs(names) do
                if exports[name] ~= nil then
                    error("modules: duplicate export '" .. name .. "' in "
                        .. path .. " (at " .. at(node.loc) .. ")", 0)
                end
                exports[name] = { node = node, decl = decl, loc = node.loc }
            end
        end
    end
    return exports
end

--- Graph frontend for the driver (compiler/modules.lua): the only
--- per-syntax code in the whole multi-file pipeline. A Rust-style
--- `mod`/`use`/`pub` frontend supplies its own pair over its own
--- marker kinds and reuses the driver untouched.
M.graph_api = {
    imports_of = imports_of,
    exports_of = exports_of,
}

return M
