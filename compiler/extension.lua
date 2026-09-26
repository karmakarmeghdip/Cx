-- Extension registry: validation, and per-parse grammar assembly (P5).
-- Extensions add syntax (extend_grammar) and node rewrites (expanders) but
-- never replace the lexer and never silently change core C23 semantics.
-- Assembly copies the base grammar tables, so the strict grammar object is
-- never mutated by dialect registration (regression-tested).

local M = {}

---@class CxExtension
---@field name string extension name, e.g. "Gnu" (used in Ext:<Name>:* kinds)
---@field extend_grammar fun(G: table, env: table) adds syntax only
---@field expanders table<string, fun(ctx: table, node: table): table|table[]|nil>
---@field graph_api CxGraphApi|nil optional graph-scope frontend (driver
--- extensions): classifiers over whole TUs, linked by compiler/modules.lua
--- via CxCompiler:program. May be present with empty expanders when all
--- rewriting happens at graph scope (e.g. modules).

---@class CxGraphApi
---@field imports_of fun(root: table): table[] top-level import edges
--- ({node, names, path, loc}), source order
---@field exports_of fun(root: table, path: string): table<string, table>
--- export table (name -> {node, decl, loc}); duplicates are hard errors

--- Validate an extension module shape. Raises on any violation.
--- @param name string registry key, e.g. "gnu"
--- @param mod CxExtension
function M.validate(name, mod)
    assert(type(name) == "string" and #name > 0, "extension: name must be a non-empty string")
    assert(type(mod) == "table", "extension '" .. name .. "': module must be a table")
    assert(type(mod.name) == "string" and #mod.name > 0,
        "extension '" .. name .. "': mod.name must be a non-empty string")
    assert(type(mod.extend_grammar) == "function",
        "extension '" .. name .. "': mod.extend_grammar must be a function")
    assert(type(mod.expanders) == "table",
        "extension '" .. name .. "': mod.expanders must be a table")
    for kind, fn in pairs(mod.expanders) do
        assert(type(kind) == "string" and type(fn) == "function",
            "extension '" .. name .. "': expander for '" .. tostring(kind)
            .. "' must be a function")
    end
    if mod.graph_api ~= nil then
        assert(type(mod.graph_api) == "table",
            "extension '" .. name .. "': graph_api must be a table")
        assert(type(mod.graph_api.imports_of) == "function",
            "extension '" .. name .. "': graph_api.imports_of must be a function")
        assert(type(mod.graph_api.exports_of) == "function",
            "extension '" .. name .. "': graph_api.exports_of must be a function")
    end
end

--- Shallow-copy one grammar table level (arrays shared only when frozen).
--- @param t table
--- @return table
local function copy_table(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

--- Assemble a parse-ready grammar: fresh tables from the base, then each
--- registered extension's extend_grammar in registration order.
--- env = {target: table, dialect: table} (read-only target, dialect flags).
--- @param base table base grammar (compiler.grammar_cx)
--- @param ext_list table[] {{name: string, mod: CxExtension}} in order
--- @param env table {target: table, dialect: table}
--- @return table assembled grammar
function M.assemble(base, ext_list, env)
    assert(type(base) == "table", "assemble: base grammar must be a table")
    assert(type(ext_list) == "table", "assemble: ext_list must be an array")
    assert(type(env) == "table", "assemble: env must be a table")
    local G = {
        keywords = {},
        prefix = copy_table(base.prefix or {}),
        infix = copy_table(base.infix or {}),
        rules = copy_table(base.rules or {}),
    }
    for _, k in ipairs(base.keywords or {}) do
        G.keywords[#G.keywords + 1] = k
    end
    for _, entry in ipairs(ext_list) do
        entry.mod.extend_grammar(G, env)
    end
    return G
end

--- Collect registered expanders (later registrations win on kind clashes),
--- preserving deterministic order for diagnostics.
--- @param ext_list table[] {{name: string, mod: CxExtension}} in order
--- @return table<string, fun(ctx: table, node: table): table|table[]|nil>
function M.collect_expanders(ext_list)
    local out = {}
    for _, entry in ipairs(ext_list) do
        for kind, fn in pairs(entry.mod.expanders) do
            out[kind] = fn
        end
    end
    return out
end

return M
