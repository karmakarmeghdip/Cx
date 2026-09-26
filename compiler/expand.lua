-- Expansion: bounded fixpoint Ext* -> Cx* rewrite loop (P5).
-- One node per pass, post-order (children before parents), deterministic
-- order (sorted fields). Unowned kinds, owned-but-nil results, root
-- replacement with a list, and budget exhaustion are all HARD errors with
-- node locations. Whole-AST writes go only through ctx.replace.

local ast = require("compiler.ast")

local M = {}

M.DEFAULT_BUDGET = 1024

---@class ExpandOpts
---@field target table|nil read-only target ({cc, std})
---@field dialect table|nil dialect flags
---@field budget integer|nil max passes (default 1024)

---@class ExpandCtx
---@field root table current tree root (updated when the root expands)
---@field target table read-only target
---@field dialect table dialect flags
---@field replace fun(node: table, repl: table|table[]) sanctioned mutation

--- Post-order collection of Ext:* nodes (deterministic: sorted fields,
--- arrays in order). Cycle-safe via the seen set.
--- @param v any node, container, or scalar
--- @param out table[] accumulator
--- @param seen table visited set
local function collect_post(v, out, seen)
    if ast.is_node(v) then
        if seen[v] then
            return
        end
        seen[v] = true
        local keys = {}
        for k in pairs(v) do
            if k ~= "kind" and k ~= "loc" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            collect_post(v[k], out, seen)
        end
        if v.kind:match("^Ext:") ~= nil then
            out[#out + 1] = v
        end
    elseif type(v) == "table" then
        if seen[v] then
            return
        end
        seen[v] = true
        for _, item in ipairs(v) do
            collect_post(item, out, seen)
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
            collect_post(v[k], out, seen)
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

--- Run the expansion fixpoint. Returns the (possibly new) root on success.
--- @param root table # AST root
--- @param expanders table<string, fun(ctx: ExpandCtx, node: table): table|table[]|nil>
--- @param o ExpandOpts|nil
--- @return table new root
--- @return integer passes used
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
        local found = {}
        collect_post(ctx.root, found, {})
        if #found == 0 then
            return ctx.root, passes
        end
        if passes >= budget then
            local n = found[1]
            error(at(n) .. "expansion budget exhausted ("
                .. budget .. " passes) at " .. n.kind, 0)
        end
        passes = passes + 1
        local node = found[1]
        local fn = expanders[node.kind]
        if fn == nil then
            error(at(node) .. "unexpanded extension node " .. node.kind
                .. " (no expander; bug or missing extension)", 0)
        end
        local repl = fn(ctx, node)
        if repl == nil then
            error(at(node) .. "expander for " .. node.kind .. " returned nil", 0)
        end
        if node == ctx.root then
            assert(ast.is_node(repl),
                "expand: replacing the root requires exactly one node")
            ctx.root = repl
        else
            ctx.replace(node, repl)
        end
    end
end

return M
