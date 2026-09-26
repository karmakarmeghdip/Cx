-- Codegen statements: line-based emitters for blocks, selection,
-- iteration, jumps, labels and expression statements.
-- Spec `statement = attributes? ...`: attributes must reach C, never be
-- dropped (reliability). Declarations double as block items via
-- P.emit_decl; block lists recurse through P.emit_block_items.

local core = require("compiler.codegen.core")

local M = {}

--- Register this section's emitters on the shared table.
--- @param P table shared printer table (P.print_expr, P.emit_decl, P.binding_string)
function M.define(P)
    local emit_stmt
    local emit_block_items

    --- @param E table Emitter
    --- @param n table statement node
    emit_stmt = function(E, n)
        core.MARK(E, n.loc)
        local ctx = E.ctx
        local k = n.kind
        --- Emit `{` items `}` leaving the cursor after `}` (caller ends the line).
        --- @param b table # Cx:Block
        local function emit_braced(b)
            core.W(E, "{")
            core.NL(E)
            E.ind = E.ind + 1
            emit_block_items(E, b.items)
            E.ind = E.ind - 1
            core.W(E, "}")
        end

        --- Emit a branch body after a header already on the line.
        --- @param stmt table statement node
        local function emit_branch(stmt)
            if stmt.kind == "Cx:Block" then
                emit_braced(stmt)
            else
                core.NL(E)
                E.ind = E.ind + 1
                emit_stmt(E, stmt)
                E.ind = E.ind - 1
            end
        end

        --- End the line unless already ended.
        local function end_line()
            if E.cur ~= "" then
                core.NL(E)
            end
        end

        --- Spec attributes prefix (see module header).
        --- @param node table statement node
        --- @return string "" or "[[a]] [[b]] " prefix
        local function stmt_prefix(node)
            local attrs = node.attrs
            if attrs == nil or #attrs == 0 then
                return ""
            end
            local parts = {}
            for _, a in ipairs(attrs) do
                parts[#parts + 1] = core.attr_str(a)
            end
            return table.concat(parts, " ") .. " "
        end

        if k == "Cx:Block" then
            if #n.items == 0 then
                core.LINE(E, "{}")
                return
            end
            emit_braced(n)
            core.NL(E)
            return
        end
        if k == "Cx:If" then
            core.W(E, stmt_prefix(n) .. "if (" .. P.print_expr(n.cond, ctx) .. ") ")
            emit_branch(n["then"])
            local els = n.els
            while els ~= nil and els.kind == "Cx:If" do
                if E.cur == "" then
                    core.W(E, "else " .. stmt_prefix(els))
                else
                    core.W(E, " else " .. stmt_prefix(els))
                end
                core.W(E, "if (" .. P.print_expr(els.cond, ctx) .. ") ")
                emit_branch(els["then"])
                els = els.els
            end
            if els ~= nil then
                if E.cur == "" then
                    core.W(E, "else")
                else
                    core.W(E, " else")
                end
                emit_branch(els)
            end
            end_line()
            return
        end
        if k == "Cx:While" then
            core.W(E, stmt_prefix(n) .. "while (" .. P.print_expr(n.cond, ctx) .. ") ")
            emit_branch(n.body)
            end_line()
            return
        end
        if k == "Cx:DoWhile" then
            core.W(E, stmt_prefix(n) .. "do ")
            emit_branch(n.body)
            if E.cur == "" then
                core.W(E, "while (" .. P.print_expr(n.cond, ctx) .. ");")
            else
                core.W(E, " while (" .. P.print_expr(n.cond, ctx) .. ");")
            end
            core.NL(E)
            return
        end
        if k == "Cx:For" then
            local init = ""
            if n.init ~= nil then
                if n.init.kind == "Cx:BindingDecl" then
                    init = P.binding_string(E, n.init)
                else
                    init = P.print_expr(n.init, ctx)
                end
            end
            local header = "for (" .. init .. ";"
            if n.cond ~= nil then
                header = header .. " " .. P.print_expr(n.cond, ctx)
            end
            header = header .. ";"
            if n.step ~= nil then
                header = header .. " " .. P.print_expr(n.step, ctx)
            end
            core.W(E, stmt_prefix(n) .. header .. ") ")
            emit_branch(n.body)
            end_line()
            return
        end
        if k == "Cx:Switch" then
            core.W(E, stmt_prefix(n) .. "switch (" .. P.print_expr(n.cond, ctx) .. ") ")
            emit_branch(n.body)
            end_line()
            return
        end
        if k == "Cx:Return" then
            local pre = stmt_prefix(n)
            if n.value ~= nil then
                core.LINE(E, pre .. "return " .. P.print_expr(n.value, ctx) .. ";")
            else
                core.LINE(E, pre .. "return;")
            end
            return
        end
        if k == "Cx:Break" then
            core.LINE(E, stmt_prefix(n) .. "break;")
            return
        end
        if k == "Cx:Continue" then
            core.LINE(E, stmt_prefix(n) .. "continue;")
            return
        end
        if k == "Cx:Goto" then
            core.LINE(E, stmt_prefix(n) .. "goto " .. n.label .. ";")
            return
        end
        if k == "Cx:Gnu:ComputedGoto" then
            core.gnu_check(ctx, n)
            core.LINE(E, "goto " .. P.print_expr(n.target, ctx) .. ";")
            return
        end
        if k == "Cx:Gnu:LabelDecl" then
            core.gnu_check(ctx, n)
            core.LINE(E, "__label__ " .. table.concat(n.names, ", ") .. ";")
            return
        end
        if k == "Cx:Gnu:AsmStmt" then
            core.gnu_check(ctx, n)
            local quals = ""
            if #n.quals > 0 then
                quals = " " .. table.concat(n.quals, " ")
            end
            local payload = ctx.src:sub(n.start_offset, n.end_offset)
            core.LINE(E, "__asm__" .. quals .. " (" .. payload .. ");")
            return
        end
        if k == "Cx:ExprStmt" then
            local parts = {}
            for _, a in ipairs(n.attrs) do
                parts[#parts + 1] = core.attr_str(a)
            end
            if n.expr ~= nil then
                parts[#parts + 1] = P.print_expr(n.expr, ctx)
            end
            if #parts == 0 then
                core.LINE(E, ";")
            else
                core.LINE(E, table.concat(parts, " ") .. ";")
            end
            return
        end
        if k == "Cx:Label" or k == "Cx:Case" or k == "Cx:Default"
            or k == "Cx:Gnu:CaseRange" then
            if k == "Cx:Gnu:CaseRange" then
                core.gnu_check(ctx, n)
            end
            local s = ""
            for _, a in ipairs(n.attrs or {}) do
                s = s .. core.attr_str(a) .. " "
            end
            if k == "Cx:Label" then
                s = s .. n.name .. ":"
            elseif k == "Cx:Case" then
                s = s .. "case " .. P.print_expr(n.value, ctx) .. ":"
            elseif k == "Cx:Gnu:CaseRange" then
                s = s .. "case " .. P.print_expr(n.lo, ctx)
                    .. " ... " .. P.print_expr(n.hi, ctx) .. ":"
            else
                s = s .. "default:"
            end
            core.LINE(E, s)
            return
        end
        -- Declarations double as block items.
        P.emit_decl(E, n)
    end

    --- Emit block items (each owns its lines).
    --- @param E table Emitter
    --- @param items table[]
    emit_block_items = function(E, items)
        for _, it in ipairs(items) do
            emit_stmt(E, it)
        end
    end

    P.emit_stmt = emit_stmt
    P.emit_block_items = emit_block_items
end

return M
