-- Defer extension: block-scoped LIFO cleanup lowering (P5).
-- Syntax: `defer <statement>;` or `defer { <statements> }`
-- Lowers to standard C control flow across GCC, Clang, MSVC, and TCC
-- with zero vendor extensions, zero runtime dependencies, and zero overhead.
-- Cleanups run in LIFO order at normal scope exits, early returns, breaks,
-- and continues. Return values are evaluated prior to cleanup execution.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

local M = {}

M.name = "Defer"

--- Deep-clone an AST subtree so duplicated cleanups own unique nodes.
--- @param n any
--- @return any
local function clone_ast(n)
    if type(n) ~= "table" then
        return n
    end
    local copy = {}
    for k, v in pairs(n) do
        copy[k] = clone_ast(v)
    end
    return copy
end

--- Validate that a deferred body does not contain escaping jumps.
--- @param p Parser
--- @param stmt table
local function validate_defer_body(p, stmt)
    local loops = 0
    local switches = 0
    ast.walk(stmt, function(n)
        local k = n.kind
        if k == "Cx:While" or k == "Cx:For" or k == "Cx:DoWhile" then
            loops = loops + 1
        elseif k == "Cx:Switch" then
            switches = switches + 1
        elseif k == "Cx:Return" then
            error(core.parse_error(p.env, n.loc,
                "cannot 'return' from inside a defer body"), 0)
        elseif k == "Cx:Goto" then
            error(core.parse_error(p.env, n.loc,
                "cannot 'goto' from inside a defer body"), 0)
        elseif k == "Cx:Break" then
            if loops == 0 and switches == 0 then
                error(core.parse_error(p.env, n.loc,
                    "cannot 'break' from inside a defer body"), 0)
            end
        elseif k == "Cx:Continue" then
            if loops == 0 then
                error(core.parse_error(p.env, n.loc,
                    "cannot 'continue' from inside a defer body"), 0)
            end
        elseif k == "Cx:Defer:Item" then
            error(core.parse_error(p.env, n.loc,
                "nested 'defer' statements are not allowed"), 0)
        end
    end)
end

--- Parse one `defer <stmt>;` block item.
--- @param G CxGrammar
--- @param p Parser
--- @return table Cx:Defer:Item
local function parse_defer(G, p)
    local sloc = p:peek().loc
    p:next() -- 'defer'
    local stmt = U.need(p, G.rules.parseStatement(p), "statement after 'defer'")
    validate_defer_body(p, stmt)
    return ast.node("Cx:Defer:Item", U.span_loc(sloc, stmt.loc), { stmt = stmt })
end

--- True if an AST node contains any Cx:Defer:Item.
--- @param node table
--- @return boolean
local function has_defer(node)
    local found = false
    ast.walk(node, function(n)
        if n.kind == "Cx:Defer:Item" then
            found = true
            return false
        end
    end)
    return found
end

--- True when `stmt` is an unconditional terminating jump.
--- @param stmt table|nil
--- @return boolean
local function definitely_terminates(stmt)
    if stmt == nil then
        return false
    end
    local k = stmt.kind
    if k == "Cx:Return" or k == "Cx:Break" or k == "Cx:Continue" or k == "Cx:Goto" then
        return true
    end
    if k == "Cx:Block" then
        local items = stmt.items
        if items ~= nil and #items > 0 then
            return definitely_terminates(items[#items])
        end
        return false
    end
    if k == "Cx:If" then
        if stmt.els ~= nil and definitely_terminates(stmt["then"])
            and definitely_terminates(stmt.els) then
            return true
        end
        return false
    end
    return false
end

--- Scope object for tracking active defers.
---@class DeferScope
---@field kind string "function" | "block" | "loop" | "switch"
---@field defers table[] statements in registration order
---@field parent DeferScope|nil

--- Collect all defers from `scope` up to the function root (innermost to outermost, LIFO).
--- @param scope DeferScope
--- @return table[]
local function collect_defers_to_function(scope)
    local list = {}
    local cur = scope
    while cur ~= nil do
        for i = #cur.defers, 1, -1 do
            list[#list + 1] = clone_ast(cur.defers[i])
        end
        cur = cur.parent
    end
    return list
end

--- Collect all defers from `scope` up to the nearest loop (for continue).
--- @param scope DeferScope
--- @return table[]
local function collect_defers_to_loop(scope)
    local list = {}
    local cur = scope
    while cur ~= nil do
        for i = #cur.defers, 1, -1 do
            list[#list + 1] = clone_ast(cur.defers[i])
        end
        if cur.kind == "loop" then
            break
        end
        cur = cur.parent
    end
    return list
end

--- Collect all defers from `scope` up to the nearest loop or switch (for break).
--- @param scope DeferScope
--- @return table[]
local function collect_defers_to_loop_or_switch(scope)
    local list = {}
    local cur = scope
    while cur ~= nil do
        for i = #cur.defers, 1, -1 do
            list[#list + 1] = clone_ast(cur.defers[i])
        end
        if cur.kind == "loop" or cur.kind == "switch" then
            break
        end
        cur = cur.parent
    end
    return list
end

--- Lower a function declaration containing defers into standard C control flow.
--- @param decl table Cx:FunctionDecl
--- @return table Cx:FunctionDecl
local function lower_function(decl)
    local ret_counter = 0
    local fn_ret_type = decl.return_type

    local rewrite_stmt
    local rewrite_block

    --- Rewrite a `return` statement, evaluating value before cleanups.
    --- @param ret table Cx:Return
    --- @param scope DeferScope
    --- @return table Cx:Block | Cx:Return
    local function rewrite_return(ret, scope)
        local defers = collect_defers_to_function(scope)
        if #defers == 0 then
            return ret
        end
        local loc = ret.loc
        local blk_items = {}
        if ret.value ~= nil then
            ret_counter = ret_counter + 1
            local var_name = "__cx_ret_" .. tostring(ret_counter)
            -- Use the function's return type for clean portability across all C standards.
            local binding = ast.node("Cx:Binding", loc, {
                name = var_name,
                raw = false,
                type = clone_ast(fn_ret_type),
                attrs = {},
                init = ret.value,
            })
            local decl_node = ast.node("Cx:BindingDecl", loc, {
                introducer = "let",
                specifiers = {},
                alignas = nil,
                attrs = {},
                bindings = { binding },
            })
            blk_items[#blk_items + 1] = decl_node
            for _, d in ipairs(defers) do
                blk_items[#blk_items + 1] = d
            end
            local ret_ident = ast.node("Cx:Ident", loc, { name = var_name, raw = false })
            blk_items[#blk_items + 1] = ast.node("Cx:Return", loc, {
                value = ret_ident,
                attrs = ret.attrs or {},
            })
        else
            for _, d in ipairs(defers) do
                blk_items[#blk_items + 1] = d
            end
            blk_items[#blk_items + 1] = ast.node("Cx:Return", loc, {
                value = nil,
                attrs = ret.attrs or {},
            })
        end
        return ast.node("Cx:Block", loc, { items = blk_items })
    end

    --- Rewrite a `break` statement with enclosing loop/switch cleanups.
    --- @param brk table Cx:Break
    --- @param scope DeferScope
    --- @return table Cx:Block | Cx:Break
    local function rewrite_break(brk, scope)
        local defers = collect_defers_to_loop_or_switch(scope)
        if #defers == 0 then
            return brk
        end
        local loc = brk.loc
        local blk_items = {}
        for _, d in ipairs(defers) do
            blk_items[#blk_items + 1] = d
        end
        blk_items[#blk_items + 1] = brk
        return ast.node("Cx:Block", loc, { items = blk_items })
    end

    --- Rewrite a `continue` statement with enclosing loop cleanups.
    --- @param cont table Cx:Continue
    --- @param scope DeferScope
    --- @return table Cx:Block | Cx:Continue
    local function rewrite_continue(cont, scope)
        local defers = collect_defers_to_loop(scope)
        if #defers == 0 then
            return cont
        end
        local loc = cont.loc
        local blk_items = {}
        for _, d in ipairs(defers) do
            blk_items[#blk_items + 1] = d
        end
        blk_items[#blk_items + 1] = cont
        return ast.node("Cx:Block", loc, { items = blk_items })
    end

    --- Rewrite a single statement or block in an existing scope.
    --- @param stmt table
    --- @param scope DeferScope
    --- @return table
    local function rewrite_stmt_in_scope(stmt, scope)
        if stmt.kind == "Cx:Block" then
            return rewrite_block(stmt, scope.kind, scope.parent)
        end
        return rewrite_stmt(stmt, scope)
    end

    --- Rewrite a statement within `current_scope`.
    --- @param stmt table
    --- @param current_scope DeferScope
    --- @return table
    rewrite_stmt = function(stmt, current_scope)
        local k = stmt.kind
        if k == "Cx:Block" then
            return rewrite_block(stmt, "block", current_scope)
        elseif k == "Cx:If" then
            local then_scope = { kind = "block", defers = {}, parent = current_scope }
            stmt["then"] = rewrite_stmt_in_scope(stmt["then"], then_scope)
            if stmt.els ~= nil then
                local els_scope = { kind = "block", defers = {}, parent = current_scope }
                stmt.els = rewrite_stmt_in_scope(stmt.els, els_scope)
            end
            return stmt
        elseif k == "Cx:While" then
            local loop_scope = { kind = "loop", defers = {}, parent = current_scope }
            stmt.body = rewrite_stmt_in_scope(stmt.body, loop_scope)
            return stmt
        elseif k == "Cx:DoWhile" then
            local loop_scope = { kind = "loop", defers = {}, parent = current_scope }
            stmt.body = rewrite_stmt_in_scope(stmt.body, loop_scope)
            return stmt
        elseif k == "Cx:For" then
            local loop_scope = { kind = "loop", defers = {}, parent = current_scope }
            stmt.body = rewrite_stmt_in_scope(stmt.body, loop_scope)
            return stmt
        elseif k == "Cx:Switch" then
            local switch_scope = { kind = "switch", defers = {}, parent = current_scope }
            stmt.body = rewrite_stmt_in_scope(stmt.body, switch_scope)
            return stmt
        elseif k == "Cx:Return" then
            return rewrite_return(stmt, current_scope)
        elseif k == "Cx:Break" then
            return rewrite_break(stmt, current_scope)
        elseif k == "Cx:Continue" then
            return rewrite_continue(stmt, current_scope)
        elseif k == "Cx:Goto" then
            local defers = collect_defers_to_function(current_scope)
            if #defers > 0 then
                local loc = stmt.loc or {}
                error(string.format("%s:%d:%d: 'goto' across active defer scopes is not supported",
                    tostring(loc.file or "?"), loc.line or 0, loc.col or 0), 0)
            end
            return stmt
        else
            return stmt
        end
    end

    --- Rewrite a block and append fallthrough defers in LIFO order.
    --- @param block table Cx:Block
    --- @param scope_kind string
    --- @param parent_scope DeferScope|nil
    --- @return table Cx:Block
    rewrite_block = function(block, scope_kind, parent_scope)
        local scope = { kind = scope_kind, defers = {}, parent = parent_scope }
        local new_items = {}
        for _, item in ipairs(block.items) do
            if item.kind == "Cx:Defer:Item" then
                scope.defers[#scope.defers + 1] = item.stmt
            else
                local rw = rewrite_stmt(item, scope)
                new_items[#new_items + 1] = rw
            end
        end
        if not definitely_terminates(new_items[#new_items]) then
            for i = #scope.defers, 1, -1 do
                new_items[#new_items + 1] = clone_ast(scope.defers[i])
            end
        end
        block.items = new_items
        return block
    end

    if decl.body ~= nil then
        decl.body = rewrite_block(decl.body, "function", nil)
    end
    return decl
end

--- @param G CxGrammar
--- @param env table {target: table, dialect: table}
function M.extend_grammar(G, env)
    assert(env ~= nil and env.dialect ~= nil, "defer: env needs dialect")
    if not env.dialect.defer and not env.dialect.scope then
        return
    end

    -- Hook block items: parse `defer <stmt>;`
    local core_block_item = G.rules.parseBlockItem
    assert(core_block_item ~= nil, "defer: core block item missing")
    G.rules.parseBlockItem = function(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "defer" then
            return parse_defer(G, p)
        end
        return core_block_item(p)
    end

    -- Hook top-level declarations: wrap functions containing defer in Ext:Defer:Func
    local core_ext = G.rules.parseExternalDecl
    assert(core_ext ~= nil, "defer: core external decl missing")
    G.rules.parseExternalDecl = function(p)
        local node = core_ext(p)
        if node ~= nil and node.kind == "Cx:FunctionDecl" and node.body ~= nil and has_defer(node.body) then
            return ast.node("Ext:Defer:Func", node.loc, { decl = node })
        end
        return node
    end

    -- Hook nested functions if present
    local core_fn = G.rules.parseFunctionDecl
    if core_fn ~= nil then
        G.rules.parseFunctionDecl = function(p)
            local node = core_fn(p)
            if node ~= nil and node.kind == "Cx:FunctionDecl" and node.body ~= nil and has_defer(node.body) then
                return ast.node("Ext:Defer:Func", node.loc, { decl = node })
            end
            return node
        end
    end
end

M.expanders = {
    ["Ext:Defer:Func"] = function(_, node)
        local decl = node.decl
        return lower_function(decl)
    end,
}

function M.lsp_complete(ctx)
    if ctx.prefix:match(":[sw_]*$") or ctx.prefix:match("[.:>][sw_]*$") then
        return nil
    end
    return {
        {
            label = "defer",
            kind = 14,
            detail = "LIFO scope cleanup",
            insertText = "defer ${1:cleanup()};",
            insertTextFormat = 2,
        },
        {
            label = "defer { ... }",
            kind = 15,
            detail = "LIFO scope cleanup block",
            insertText = "defer {\n\t${1:/* cleanup */}\n}",
            insertTextFormat = 2,
        },
    }
end

function M.lsp_hover(node, ctx)
    local k = node.kind
    if k == "Cx:Defer:Item" or k == "Ext:Defer:Func" then
        return "### Defer Statement\nExecutes cleanup statement in LIFO order upon exiting the enclosing lexical block, loop iteration, or function."
    end
    return nil
end

function M.lsp_token(node)
    local k = node.kind
    if k == "Cx:Defer:Item" then
        return "keyword", {}
    elseif k == "Ext:Defer:Func" then
        return "function", {}
    end
    return "keyword", {}
end

return M
