-- Pipe operator extension: pipeline expressions with slot placeholder '_' (P5).
-- Syntax: `<left> |> <right>`
-- Lowers to nested function calls or expressions in C23.
-- If `<right>` contains the slot placeholder `_`:
--   `_` is replaced with `<left>`.
--   `_` may appear at most once to prevent duplicate side effects.
-- If `<right>` does not contain `_`:
--   - If `<right>` is a function call `f(...)`: `<left>` is prepended as first argument: `f(<left>, ...)`.
--   - If `<right>` is an identifier/member/index/unary/cast: `<right>(<left>)`.
--   - Otherwise (e.g. literals or binary expressions without `_`): raises a clear error.
-- Precedence: 3 (left-associative), looser than arithmetic/comparison/bitwise/logical,
-- tighter than assignment (=).

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

local M = {}

M.name = "Pipe"

--- Check if a node is an unescaped slot placeholder '_'.
--- Escaped '@_' (raw identifier) is treated as a regular variable name.
--- @param n any
--- @return boolean
local function is_placeholder(n)
    if not ast.is_node(n) or n.kind ~= "Cx:Ident" then
        return false
    end
    ---@cast n CxIdent
    return n.name == "_" and not n.raw
end

--- Count occurrences of placeholder '_' in an AST subtree.
--- @param node table
--- @return integer
local function count_placeholders(node)
    local count = 0
    ast.walk(node, function(n)
        if is_placeholder(n) then
            count = count + 1
        end
    end)
    return count
end

--- Replace the single placeholder '_' in `node` with `replacement`.
--- @param n any
--- @param replacement table
--- @return any
local function replace_placeholder(n, replacement)
    if not ast.is_node(n) then
        return n
    end
    if is_placeholder(n) then
        return replacement
    end
    for k, v in pairs(n) do
        if k ~= "loc" and k ~= "kind" then
            if ast.is_node(v) then
                if is_placeholder(v) then
                    n[k] = replacement
                else
                    replace_placeholder(v, replacement)
                end
            elseif type(v) == "table" then
                for i, child in ipairs(v) do
                    if ast.is_node(child) then
                        if is_placeholder(child) then
                            v[i] = replacement
                        else
                            replace_placeholder(child, replacement)
                        end
                    end
                end
            end
        end
    end
    return n
end

--- Check if an AST node is a plausible callable expression.
--- @param n table
--- @return boolean
local function is_callable_target(n)
    local k = n.kind
    return k == "Cx:Ident"
        or k == "Cx:Member"
        or k == "Cx:Index"
        or k == "Cx:Unary"
        or k == "Cx:CastAs"
end

M.expanders = {
    ["Ext:Pipe:Infix"] = function(_, node)
        local input = node.left
        local target = node.right
        local loc = node.loc or {}

        local slots = count_placeholders(target)
        if slots > 1 then
            error(string.format("%s:%d:%d: pipe placeholder '_' may only appear once in pipe target",
                tostring(loc.file or "?"), loc.line or 0, loc.col or 0), 0)
        end

        if slots == 1 then
            if is_placeholder(target) then
                return input
            end
            return replace_placeholder(target, input)
        end

        -- slots == 0: thread-first or call wrapper
        if target.kind == "Cx:Call" then
            table.insert(target.args, 1, input)
            return target
        end

        if is_callable_target(target) then
            return ast.node("Cx:Call", U.span_loc(node.loc, target.loc), {
                fn = target,
                args = { input },
            })
        end

        error(string.format("%s:%d:%d: pipe target expression requires a function call or '_' placeholder",
            tostring(loc.file or "?"), loc.line or 0, loc.col or 0), 0)
    end,
}

--- @param G table # CxGrammar
--- @param env table # {target: table, dialect: table}
function M.extend_grammar(G, env)
    assert(env ~= nil and env.dialect ~= nil, "pipe: env needs dialect")
    if not env.dialect.pipe then
        return
    end

    G.infix["|>"] = {
        prec = 3,
        assoc = "left",
        parse = function(p, left, _, next_min)
            local right = core.expr(p, U.prefix(p), U.infix(p), next_min)
            return ast.node("Ext:Pipe:Infix", U.span_loc(left.loc, right.loc), {
                left = left,
                right = right,
            })
        end,
    }
end

function M.lsp_hover(node, ctx)
    local k = node.kind
    if k == "Ext:Pipe:Infix" then
        return "### Pipeline Operator (`|>`);\nThreads the left-hand expression into the right-hand function call as the first argument, or replaces the `_` placeholder."
    elseif k == "Ext:Pipe:Slot" then
        return "### Pipe Placeholder (`_`)\nRepresents the piped left-hand expression in the target call."
    end
    return nil
end

function M.lsp_token(node)
    local k = node.kind
    if k == "Ext:Pipe:Infix" then
        return "operator", {}
    elseif k == "Ext:Pipe:Slot" then
        return "variable", {}
    end
    return "operator", {}
end

return M
