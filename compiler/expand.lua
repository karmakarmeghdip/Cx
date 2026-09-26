-- Expansion: bounded fixpoint Ext* -> Cx* rewrite loop (P5).
-- Each round collects the whole Ext frontier (post-order, children before
-- parents) and expands it in order. Nodes an expander creates mid-round --
-- including other extensions' kinds (chained interop) -- are discovered by
-- the next round's collection, so a generation chain costs one round per
-- level (optimal: a node cannot expand before it exists) while mirrors
-- finish in a single productive round. Budget counts node expansions.
-- Liveness (slot identity + ancestor walk, with per-round shift tracking
-- for array splices) skips entries detached out-of-band; staleness only
-- ever defers work to the next round, never drops it. Unowned kinds,
-- owned-but-nil results, root replacement with a list, and budget
-- exhaustion are all HARD errors with node locations. Expander-requested
-- writes go through ctx.replace; in-round splices use the recorded
-- parent links directly (same semantics as ast.replace, no research).

local ast = require("compiler.ast")

local M = {}

M.DEFAULT_BUDGET = 1024

---@class ExpandOpts
---@field target table|nil read-only target ({cc, std})
---@field dialect table|nil dialect flags
---@field budget integer|nil max node expansions (default 1024)

---@class ExpandCtx
---@field root table current tree root (updated when the root expands)
---@field target table read-only target
---@field dialect table dialect flags
---@field replace fun(node: table, repl: table|table[]) sanctioned mutation

---@class ParentLink
---@field parent table container holding the node
---@field key any index or field name within parent

--- Post-order collection of Ext:* nodes (deterministic: sorted fields,
--- arrays in order), recording every visited container's parent link for
--- the round's liveness checks and shift-tracked splices. Cycle-safe via
--- the seen set (first path wins).
--- @param v any node, container, or scalar
--- @param out table[] accumulator (Ext nodes, children first)
--- @param parents table<table, ParentLink> link per visited table
--- @param seen table visited set
--- @param parent table|nil container holding v
--- @param key any|nil index or field name of v within parent
local function collect_post(v, out, parents, seen, parent, key)
    if ast.is_node(v) then
        if seen[v] then
            return
        end
        seen[v] = true
        if parent ~= nil then
            parents[v] = { parent = parent, key = key }
        end
        local keys = {}
        for k in pairs(v) do
            if k ~= "kind" and k ~= "loc" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            collect_post(v[k], out, parents, seen, v, k)
        end
        if v.kind:match("^Ext:") ~= nil then
            out[#out + 1] = v
        end
    elseif type(v) == "table" then
        if seen[v] then
            return
        end
        seen[v] = true
        if parent ~= nil then
            parents[v] = { parent = parent, key = key }
        end
        for i, item in ipairs(v) do
            collect_post(item, out, parents, seen, v, i)
        end
        local n = #v
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            collect_post(v[k], out, parents, seen, v, k)
        end
    end
end

--- Format a node location for error messages.
--- @param n table # CxNode
--- @return string "file:line:col: "
local function at(n)
    local loc = n.loc or {}
    return string.format("%s:%d:%d: ",
        tostring(loc.file or "?"), loc.line or 0, loc.col or 0)
end

--- True when `node` is still attached under `root` through the recorded
--- links. Array keys pass through the round's shift table (sibling list
--- splices move pending slots exactly and cheaply). A false verdict only
--- defers the node to the next round's fresh collection -- never wrong,
--- never lost. Detached nodes (out-of-band ancestor replacement) also
--- read false, so no expander ever runs on a dead subtree.
--- @param parents table<table, ParentLink> this round's links
--- @param shifts table<table, integer> cumulative index delta per array
--- @param root table current tree root
--- @param node table candidate Ext node
--- @return boolean
local function live(parents, shifts, root, node)
    local cur = node
    while cur ~= root do
        local link = parents[cur]
        if link == nil then
            return false
        end
        local key = link.key
        if type(key) == "number" then
            key = key + (shifts[link.parent] or 0)
        end
        if link.parent[key] ~= cur then
            return false
        end
        cur = link.parent
    end
    return true
end

--- Normalize an expander result to a validated node list (mirrors
--- ast.replace's acceptance rules).
--- @param repl table|table[] expander result
--- @return table[] list of replacement nodes
local function as_list(repl)
    if ast.is_node(repl) then
        return { repl }
    end
    assert(type(repl) == "table",
        "expand: replacement must be a node or array of nodes")
    local list = repl
    for i, r in ipairs(list) do
        assert(ast.is_node(r),
            "expand: replacements[" .. i .. "] is not a node")
    end
    return list
end

--- Run the expansion fixpoint. Returns the (possibly new) root on success.
--- @param root table # AST root
--- @param expanders table<string, fun(ctx: ExpandCtx, node: table): table|table[]|nil>
--- @param o ExpandOpts|nil
--- @return table new root
--- @return integer expansions performed
function M.expand(root, expanders, o)
    assert(ast.is_node(root), "expand: root must be a node")
    assert(type(expanders) == "table", "expand: expanders must be a table")
    o = o or {}
    local budget = o.budget or M.DEFAULT_BUDGET
    assert(type(budget) == "number" and budget >= 1, "expand: budget must be >= 1")
    ---@type ExpandCtx
    local ctx = nil
    --- @param node table
    --- @param repl table|table[]
    local function do_replace(node, repl)
        return ast.replace({ root = ctx.root }, node, repl)
    end
    ctx = {
        root = root,
        target = o.target or {},
        dialect = o.dialect or {},
        replace = do_replace,
    }
    local passes = 0
    while true do
        local found, parents = {}, {}
        collect_post(ctx.root, found, parents, {}, nil, nil)
        if #found == 0 then
            return ctx.root, passes
        end
        local shifts = {}
        for _, node in ipairs(found) do
            if live(parents, shifts, ctx.root, node) then
                if passes >= budget then
                    error(at(node) .. "expansion budget exhausted ("
                        .. budget .. " passes) at " .. node.kind, 0)
                end
                local fn = expanders[node.kind]
                if fn == nil then
                    error(at(node) .. "unexpanded extension node " .. node.kind
                        .. " (no expander; bug or missing extension)", 0)
                end
                local repl = fn(ctx, node)
                if repl == nil then
                    error(at(node) .. "expander for " .. node.kind
                        .. " returned nil", 0)
                end
                local list = as_list(repl)
                passes = passes + 1
                if node == ctx.root then
                    assert(ast.is_node(list[1]) and #list == 1,
                        "expand: replacing the root requires exactly one node")
                    ctx.root = list[1]
                else
                    local link = parents[node]
                    assert(link ~= nil, "expand: live node lacks a parent link")
                    local key = link.key
                    if type(key) == "number" then
                        key = key + (shifts[link.parent] or 0)
                        table.remove(link.parent, key)
                        for i, r in ipairs(list) do
                            table.insert(link.parent, key + i - 1, r)
                        end
                        shifts[link.parent] = (shifts[link.parent] or 0)
                            + #list - 1
                    else
                        assert(#list == 1,
                            "expand: struct field takes exactly one node, got "
                            .. #list)
                        link.parent[key] = list[1]
                    end
                end
            end
        end
    end
end

return M
