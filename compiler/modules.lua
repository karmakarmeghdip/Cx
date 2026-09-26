-- Graph driver: syntax-agnostic machinery for graph-scope extensions
-- (TODO.md 2.A, AGENTS.md section 7). A graph frontend (e.g.
-- compiler/extensions/modules.lua) only classifies markers; this module
-- owns everything generic: path resolution, graph DFS with cycle errors,
-- export-table assembly, prototype synthesis over Cx declarations, and
-- splice-in-place linking. A Rust-style `mod`/`use`/`pub` frontend reuses
-- all of it by supplying its own node classifiers — no init.lua change.
--
-- v1 scope: relative (or absolute) paths, `.cx` appended when missing,
-- unique basenames per program, cycles rejected, named imports only.

local ast = require("compiler.ast")

local M = {}

---@class CxImportEdge
---@field node table the import marker node (spliced away at link)
---@field names string[] requested symbol names, in source order
---@field path string decoded module path as written (quotes stripped)
---@field loc table source location of the marker

---@class CxExportEntry
---@field node table the export marker node (unwrapped at link)
---@field decl table the exported Cx declaration node
---@field loc table source location of the marker

---@class CxGraphApi frontend classifiers (the only per-syntax code)
---@field imports_of fun(root: table): CxImportEdge[] top-level imports, source order
---@field exports_of fun(root: table, path: string): table<string, CxExportEntry> name -> entry

--- Format a loc as `file:line:col`.
--- @param loc table|nil
--- @return string
local function at(loc)
    loc = loc or {}
    return string.format("%s:%d:%d",
        tostring(loc.file or "?"), loc.line or 0, loc.col or 0)
end

--- Collapse `.`/`..` segments lexically (no filesystem access).
--- @param path string
--- @return string
local function normalize(path)
    local rooted = path:sub(1, 1) == "/"
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == "." or seg == "" then
            -- skip
        elseif seg == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif not rooted then
                parts[#parts + 1] = ".."
            end
        else
            parts[#parts + 1] = seg
        end
    end
    local out = table.concat(parts, "/")
    if rooted then
        out = "/" .. out
    end
    if out == "" then
        out = rooted and "/" or "."
    end
    return out
end

--- Resolve an import path against the importing file. Appends `.cx` when
--- the path has no extension. Absolute paths pass through; anything else
--- joins onto the importer's directory.
--- @param importer string importing file path (as given)
--- @param path string decoded path from the import edge
--- @return string normalized target path
function M.resolve(importer, path)
    assert(type(importer) == "string", "modules.resolve: importer required")
    assert(type(path) == "string" and #path > 0, "modules.resolve: path required")
    if path:sub(-3) ~= ".cx" then
        path = path .. ".cx"
    end
    if path:sub(1, 1) == "/" then
        return normalize(path)
    end
    local dir = importer:match("^(.*)/[^/]*$")
    if dir == nil or dir == "" then
        return normalize(path)
    end
    return normalize(dir .. "/" .. path)
end

---@class ModuleUnit
---@field root table Cx:TranslationUnit (linked in place)
---@field src string file text (cinit slices)

---@class ModuleGraph
---@field order string[] file paths, dependencies first
---@field units table<string, ModuleUnit>

--- Parse the full import graph reachable from `entry` (depth-first,
--- dependencies first in `order`). `parse_fn(path)` must return
--- `root, src` like `compile_source`; edge discovery comes from
--- `api.imports_of`. Cycles and unreadable files are hard errors naming
--- the chain.
--- @param entry string entry .cx path
--- @param parse_fn fun(path: string): table, string
--- @param api CxGraphApi frontend classifiers
--- @return ModuleGraph
function M.build_graph(entry, parse_fn, api)
    assert(type(entry) == "string", "modules.build_graph: entry required")
    assert(type(parse_fn) == "function", "modules.build_graph: parse_fn required")
    assert(type(api) == "table" and type(api.imports_of) == "function",
        "modules.build_graph: api.imports_of required")
    ---@type ModuleGraph
    local graph = { order = {}, units = {} }
    local state = {} ---@type table<string, string> path -> "visiting"|"done"
    local stack = {} ---@type string[] current DFS chain

    --- @param path string
    --- @param from_loc table|nil import loc that led here (nil for entry)
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
            error("modules: import cycle: " .. table.concat(chain, " -> "), 0)
        end
        state[path] = "visiting"
        stack[#stack + 1] = path
        local probe = io.open(path, "r")
        if probe == nil then
            if from_loc ~= nil then
                error("modules: cannot open '" .. path
                    .. "' (imported at " .. at(from_loc) .. ")", 0)
            end
            error("modules: cannot open '" .. path .. "'", 0)
        end
        probe:close()
        local root, src = parse_fn(path)
        assert(ast.is_node(root), "modules: parse_fn must return a node")
        graph.units[path] = { root = root, src = src or "" }
        for _, edge in ipairs(api.imports_of(root)) do
            visit(M.resolve(path, edge.path), edge.loc)
        end
        table.remove(stack)
        state[path] = "done"
        graph.order[#graph.order + 1] = path
    end

    visit(entry, nil)
    return graph
end

--- Deep-copy an AST subtree. Loc tables are shared by reference
--- (immutable); the tree itself is freshly owned by the caller.
--- @param node table CxNode
--- @return table copy
local function clone(node)
    local seen = {}
    local function copy(v)
        if type(v) ~= "table" then
            return v
        end
        if seen[v] then
            return seen[v]
        end
        if v == node or ast.is_node(v) then
            local out = {}
            seen[v] = out
            for k, item in pairs(v) do
                if k == "loc" then
                    out[k] = item
                else
                    out[k] = copy(item)
                end
            end
            return out
        end
        local out = {}
        seen[v] = out
        for k, item in pairs(v) do
            out[copy(k)] = copy(item)
        end
        return out
    end
    local out = copy(node)
    assert(ast.is_node(out), "modules.clone: node required")
    return out
end

--- Build the importable prototype for an exported declaration (freshly
--- cloned). Functions lose their bodies; bindings become `extern` and
--- lose initializers (`static` exports are rejected); aliases, records,
--- and enums clone whole (self-contained definitions).
--- @param decl table exported Cx declaration
--- @param path string exporting file (for errors)
--- @return table prototype node
function M.prototype_of(decl, path)
    if decl.kind == "Cx:FunctionDecl" then
        local out = clone(decl)
        out.body = nil
        return out
    end
    if decl.kind == "Cx:TypeAlias"
        or decl.kind == "Cx:RecordDecl"
        or decl.kind == "Cx:EnumDecl" then
        return clone(decl)
    end
    if decl.kind == "Cx:BindingDecl" then
        for _, s in ipairs(decl.specifiers) do
            if s == "static" then
                error("modules: cannot export static binding in " .. path
                    .. " (at " .. at(decl.loc)
                    .. "; remove static or drop export)", 0)
            end
        end
        local out = clone(decl)
        local has_extern = false
        for _, s in ipairs(out.specifiers) do
            if s == "extern" then
                has_extern = true
                break
            end
        end
        if not has_extern then
            table.insert(out.specifiers, 1, "extern")
        end
        for _, b in ipairs(out.bindings) do
            b.init = nil
        end
        return out
    end
    error("modules: cannot export " .. tostring(decl.kind)
        .. " in " .. path .. " (at " .. at(decl.loc) .. ")", 0)
end

--- Link a built graph in place: every import edge becomes its prototypes
--- (spliced where the marker stood, types stably first so uses never
--- precede typedefs), every export marker unwraps to its inner
--- declaration. Missing exports and leftover markers are hard errors
--- with locations.
--- @param graph ModuleGraph
--- @param api CxGraphApi frontend classifiers
function M.link_graph(graph, api)
    assert(type(graph) == "table", "modules.link_graph: graph required")
    assert(type(api) == "table" and type(api.imports_of) == "function"
        and type(api.exports_of) == "function",
        "modules.link_graph: api.imports_of/exports_of required")
    local export_of = {} ---@type table<string, table<string, CxExportEntry>>
    for _, path in ipairs(graph.order) do
        export_of[path] = api.exports_of(graph.units[path].root, path)
    end
    -- One linear body rebuild per TU: import edges become their prototypes
    -- (types stably first so uses never precede typedefs), export markers
    -- unwrap to their declarations. No per-node parent research: markers
    -- are direct body members by contract.
    for _, path in ipairs(graph.order) do
        local unit = graph.units[path]
        local splice = {} ---@type table<table, table[]> marker node -> replacements
        for _, edge in ipairs(api.imports_of(unit.root)) do
            local target = M.resolve(path, edge.path)
            local tunit = graph.units[target]
            assert(tunit ~= nil, "modules: unreachable target state")
            local protos = {}
            for _, name in ipairs(edge.names) do
                local entry = export_of[target][name]
                if entry == nil then
                    local avail = {}
                    for k in pairs(export_of[target]) do
                        avail[#avail + 1] = k
                    end
                    table.sort(avail)
                    error("modules: '" .. target .. "' has no export '"
                        .. name .. "' (imported at " .. at(edge.loc)
                        .. "; available: " .. table.concat(avail, ", ") .. ")", 0)
                end
                protos[#protos + 1] = M.prototype_of(entry.decl, target)
            end
            -- Types first (stable): a prototype may name an imported
            -- typedef, so definitions precede uses whatever the order
            -- in the import list.
            do
                local types_first = {}
                local rest = {}
                for _, pr in ipairs(protos) do
                    if pr.kind == "Cx:TypeAlias"
                        or pr.kind == "Cx:RecordDecl"
                        or pr.kind == "Cx:EnumDecl" then
                        types_first[#types_first + 1] = pr
                    else
                        rest[#rest + 1] = pr
                    end
                end
                for _, pr in ipairs(rest) do
                    types_first[#types_first + 1] = pr
                end
                protos = types_first
            end
            splice[edge.node] = protos
        end
        for _, entry in pairs(export_of[path]) do
            splice[entry.node] = { entry.decl }
        end
        local body, changed = {}, false
        for _, node in ipairs(unit.root.body) do
            local repl = splice[node]
            if repl ~= nil then
                changed = true
                for _, r in ipairs(repl) do
                    body[#body + 1] = r
                end
            else
                body[#body + 1] = node
            end
        end
        if changed then
            unit.root.body = body
        end
    end
    for _, path in ipairs(graph.order) do
        local unit = graph.units[path]
        for _, edge in ipairs(api.imports_of(unit.root)) do
            error("modules: unlinked " .. edge.node.kind .. " in " .. path
                .. " (at " .. at(edge.loc) .. ")", 0)
        end
        for _, entry in pairs(api.exports_of(unit.root, path)) do
            error("modules: unlinked " .. entry.node.kind .. " in " .. path
                .. " (at " .. at(entry.loc) .. ")", 0)
        end
    end
end

return M
