-- Workspace graph index for cross-file queries (P5).
-- Builds the import graph reachable from an entry file using the
-- registered graph extension's classifiers (compiler/modules.lua driver
-- semantics: resolve, DFS, cycles, export tables, missing-export checks)
-- but WITHOUT linking: linking mutates roots in place, while LSP docs
-- own theirs. Open documents satisfy dependencies first (live text);
-- anything else is read from disk and tolerantly parsed with the entry
-- file's config (one program = one compiler, like CxCompiler:program).
-- All failures become normalized diagnostics; real Lua bugs propagate.

local docs = require("compiler.lsp.docs")
local buildinfo = require("compiler.lsp.buildinfo")

local M = {}

--- Max files per graph (runaway-import guard).
M.MAX_FILES = 64

---@class LspGraphUnit
---@field root table|nil pre-expansion tolerant root (nil when unparseable)
---@field src string file text ("" when unreadable)
---@field uri string document URI for the unit
---@field from_store boolean true when text came from an open document

---@class LspGraphIndex
---@field entry string entry file path
---@field order string[] file paths, dependencies first
---@field units table<string, LspGraphUnit> path -> unit
---@field exports table<string, table<string, table>> path -> name -> {decl, loc}
---@field errors table[] normalized {loc={...}, message=...}
---@field stamps table<string, string> path -> cache stamp
---@field api table|nil graph frontend classifiers (for workspace_of)

--- First registered graph extension's classifiers (AGENTS.md: exactly one
--- graph extension per program; LSP tolerates none by returning nil).
--- @param entries table[] {{name:string, mod:table}}
--- @return table|nil api {imports_of, exports_of}
function M.find_graph_api(entries)
    for _, e in ipairs(entries or {}) do
        if e.mod ~= nil and e.mod.graph_api ~= nil then
            return e.mod.graph_api
        end
    end
    return nil
end

--- Stamp for cache validation: open-doc version, else disk mtime
--- (cheap stat, no reads). Missing files stamp as "missing".
--- @param store table doc store
--- @param uri string|nil open-document URI for path (may be nil)
--- @param path string file path
--- @return string
function M.stamp(store, uri, path)
    if uri ~= nil then
        local doc = docs.get(store, uri)
        -- Open text shadows disk only when it parsed (build() falls back
        -- to disk for root-less docs, so the stamp must too).
        if doc ~= nil and doc.root ~= nil then
            return "v" .. tostring(doc.version)
        end
    end
    local buildkit = require("compiler.buildkit")
    local mt = buildkit.mtime(path)
    if mt == nil then
        return "missing"
    end
    return "m" .. tostring(mt)
end

--- Lexically normalize a file path for index keys (strip leading
--- `./`; deeper `.`/`..` are already collapsed by modules.resolve).
--- @param path string
--- @return string
local function norm_path(path)
    return (path:gsub("^%./+", ""))
end

--- Find an open-document URI whose path matches `path` (exact or
--- suffix, mirroring buildinfo.config_for).
--- @param store table doc store
--- @param path string file path
--- @return string|nil uri
local function open_uri_for(store, path)
    for uri, _ in pairs(store.docs) do
        local p = buildinfo.uri_to_path(uri)
        if p == path or p:sub(-#path) == path or path:sub(-#p) == p then
            return uri
        end
    end
    return nil
end

--- Build the graph index for an entry file.
--- @param entry_path string entry .cx path (as in Loc.file)
--- @param entry_unit table {root:table|nil, src:string} parsed entry (pre-expansion)
--- @param store table doc store (open docs preferred)
--- @param config table entry file config (entries/target/std/cc)
--- @param dep_cache table|nil disk-parse cache path -> {stamp, root, src, nerr}
---   (owned by the caller; keyed by M.stamp so unchanged deps skip reparse)
--- @return LspGraphIndex index (errors embedded, never raises on Cx errors)
function M.build(entry_path, entry_unit, store, config, dep_cache)
    entry_path = norm_path(entry_path)
    local modules = require("compiler.modules")
    local api = M.find_graph_api(config.entries)
    ---@type LspGraphIndex
    local index = {
        entry = entry_path, order = {}, units = {},
        exports = {}, errors = {}, stamps = {}, api = api,
    }
    if api == nil then
        return index
    end
    local function fail(loc, message)
        local list = docs.normalize_error(message, entry_path)
        -- normalize_error splits "f:l:c: msg"; force the edge loc so the
        -- diagnostic lands on the import that caused it.
        for _, item in ipairs(list) do
            if loc ~= nil then
                item.loc = {
                    file = loc.file or entry_path,
                    line = loc.line or 1, col = loc.col or 1,
                    end_line = loc.end_line or loc.line or 1,
                    end_col = loc.end_col or loc.col or 1,
                }
            end
            index.errors[#index.errors + 1] = item
        end
    end
    local state = {} ---@type table<string, string> "visiting"|"done"
    local failed = {} ---@type table<string, boolean> diagnosed at visit time
    local stack = {} ---@type string[]
    local function uri_for(path)
        local uri = open_uri_for(store, path)
        if uri ~= nil then
            return uri
        end
        return buildinfo.path_to_uri(path)
    end
    local function visit(path, from_loc)
        if state[path] == "done" then
            return
        end
        if state[path] == "visiting" then
            local chain = {}
            local inside = false
            for _, p in ipairs(stack) do
                if p == path then
                    inside = true
                end
                if inside then
                    chain[#chain + 1] = p
                end
            end
            chain[#chain + 1] = path
            fail(from_loc, "modules: import cycle: " .. table.concat(chain, " -> "))
            return
        end
        if #stack >= M.MAX_FILES then
            fail(from_loc, "modules: import graph exceeds "
                .. tostring(M.MAX_FILES) .. " files at '" .. path .. "'")
            return
        end
        state[path] = "visiting"
        stack[#stack + 1] = path
        local root, src, from_store
        if path == entry_path then
            root, src, from_store = entry_unit.root, entry_unit.src or "", true
        else
            local uri = open_uri_for(store, path)
            local open_doc = (uri ~= nil) and docs.get(store, uri) or nil
            if open_doc ~= nil and open_doc.root ~= nil then
                root, src, from_store = open_doc.root, open_doc.text or "", true
                if from_loc ~= nil and #open_doc.errors > 0 then
                    fail(from_loc, "modules: imported file '" .. path .. "' has "
                        .. tostring(#open_doc.errors) .. " parse error(s)")
                end
            else
                local f = io.open(path, "r")
                if f == nil then
                    if from_loc ~= nil then
                        fail(from_loc, "modules: cannot open '" .. path .. "'")
                    else
                        fail(nil, "modules: cannot open '" .. path .. "'")
                    end
                    failed[path] = true
                    table.remove(stack)
                    state[path] = "done"
                    return
                end
                local text = f:read("*a") or ""
                f:close()
                local stamp = M.stamp(store, nil, path)
                local hit = (dep_cache ~= nil) and dep_cache[path] or nil
                local nerr = 0
                if hit ~= nil and hit.stamp == stamp then
                    root, src, nerr = hit.root, hit.src, hit.nerr or 0
                else
                    local dep_config = {
                        file = path, target = config.target, std = config.std,
                        cc = config.cc, entries = config.entries,
                        dialect = config.dialect,
                    }
                    local doc = docs.parse_text(text, dep_config)
                    root, src, nerr = doc.root, text, #doc.errors
                    if dep_cache ~= nil then
                        dep_cache[path] = { stamp = stamp, root = root,
                            src = src, nerr = nerr }
                    end
                end
                from_store = false
                -- Dependency parse errors belong to the dep file (published
                -- when it is opened); the entry only gets an edge-anchored
                -- summary so ranges stay in the right document.
                if from_loc ~= nil and nerr > 0 then
                    fail(from_loc, "modules: imported file '" .. path .. "' has "
                        .. tostring(nerr) .. " parse error(s)")
                end
            end
        end
        if root == nil then
            fail(from_loc, "modules: cannot parse '" .. path .. "'")
            failed[path] = true
            table.remove(stack)
            state[path] = "done"
            return
        end
        index.units[path] = {
            root = root, src = src or "",
            uri = uri_for(path), from_store = from_store,
        }
        local ok_edges, edges = pcall(api.imports_of, root)
        if not ok_edges then
            fail(from_loc, edges)
            table.remove(stack)
            state[path] = "done"
            return
        end
        for _, edge in ipairs(edges) do
            visit(modules.resolve(path, edge.path), edge.loc)
        end
        table.remove(stack)
        state[path] = "done"
        index.order[#index.order + 1] = path
    end
    visit(entry_path, nil)
    -- Export tables + missing-export checks (link_graph semantics,
    -- read-only: no splicing, no prototype synthesis).
    for _, path in ipairs(index.order) do
        local unit = index.units[path]
        if unit ~= nil and unit.root ~= nil then
            local ok, ex = pcall(api.exports_of, unit.root, path)
            if ok then
                local flat = {}
                for name, entry in pairs(ex) do
                    flat[name] = { decl = entry.decl, loc = entry.loc }
                end
                index.exports[path] = flat
            else
                fail(nil, ex)
                index.exports[path] = {}
            end
        else
            index.exports[path] = {}
        end
    end
    for _, path in ipairs(index.order) do
        local unit = index.units[path]
        if unit ~= nil and unit.root ~= nil then
            local ok_edges, edges = pcall(api.imports_of, unit.root)
            if ok_edges then
                for _, edge in ipairs(edges) do
                    local target = modules.resolve(path, edge.path)
                    local tex = index.exports[target]
                    if tex == nil then
                        -- Missing/unparseable targets were already diagnosed
                        -- at visit time (failed set); anything else is an
                        -- internal inconsistency worth one error.
                        if not failed[target] then
                            fail(edge.loc, "modules: cannot open '" .. target .. "'")
                        end
                    else
                        for _, name in ipairs(edge.names) do
                            if tex[name] == nil then
                                local avail = {}
                                for k in pairs(tex) do
                                    avail[#avail + 1] = k
                                end
                                table.sort(avail)
                                fail(edge.loc, "modules: '" .. target
                                    .. "' has no export '" .. name
                                    .. "'; available: " .. table.concat(avail, ", "))
                            end
                        end
                    end
                end
            end
        end
    end
    for _, path in ipairs(index.order) do
        local unit = index.units[path]
        index.stamps[path] = M.stamp(store,
            (unit ~= nil) and unit.uri or nil, path)
    end
    return index
end

--- Visible workspace names for an entry file: every name imported by the
--- entry, resolved to its export {decl, loc, path, uri}.
--- @param index LspGraphIndex
--- @param entry_path string
--- @return table[] items {name, decl_kind, path, uri, loc}
function M.workspace_of(index, entry_path)
    local out = {}
    if index == nil then
        return out
    end
    entry_path = norm_path(entry_path)
    local modules = require("compiler.modules")
    local unit = index.units[entry_path]
    if unit == nil or unit.root == nil then
        return out
    end
    local api = index.api
    if api == nil then
        return out
    end
    local ok, edges = pcall(api.imports_of, unit.root)
    if not ok then
        return out
    end
    local seen = {}
    for _, edge in ipairs(edges) do
        local target = modules.resolve(entry_path, edge.path)
        local tex = index.exports[target]
        local tunit = index.units[target]
        if tex ~= nil and tunit ~= nil then
            for _, name in ipairs(edge.names) do
                if not seen[name] and tex[name] ~= nil then
                    seen[name] = true
                    out[#out + 1] = {
                        name = name,
                        decl_kind = tex[name].decl.kind,
                        path = target,
                        uri = tunit.uri,
                        loc = tex[name].loc,
                    }
                end
            end
        end
    end
    return out
end

return M
