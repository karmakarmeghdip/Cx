-- Codegen expressions: Cx expression nodes -> C text with minimal parens.
-- Type positions (sizeof(T), alignof, casts, generics, compounds) call
-- back into P.print_decl; statement expressions call P.emit_stmt.
-- Cross-printer calls resolve through P at call time.

local core = require("compiler.codegen.core")

local M = {}

--- Register this section's printers on the shared table.
--- @param P table shared printer table (P.print_decl, P.emit_stmt)
function M.define(P)
    local print_expr
    local print_init

    --- @param n table expression node
    --- @param ctx CodegenCtx
    --- @return string
    print_expr = function(n, ctx)
        local k = n.kind
        if k == "Cx:Ident" then
            return n.name
        end
        if k == "Cx:IntLit" or k == "Cx:FloatLit" or k == "Cx:CharLit" then
            if k == "Cx:IntLit" and n.text:match("[Ww][Bb]$") ~= nil then
                core.reject_if_msvc(ctx, n.loc, "bit-precise literal '" .. n.text .. "'")
            end
            return n.text
        end
        if k == "Cx:StringLit" then
            return table.concat(n.parts, " ")
        end
        if k == "Cx:Call" then
            local fn = print_expr(n.fn, ctx)
            if core.prec_of(n.fn) ~= nil then
                fn = "(" .. fn .. ")"
            end
            local args = {}
            for _, a in ipairs(n.args) do
                args[#args + 1] = print_expr(a, ctx)
            end
            return fn .. "(" .. table.concat(args, ", ") .. ")"
        end
        if k == "Cx:Index" then
            local arr = print_expr(n.arr, ctx)
            if core.prec_of(n.arr) ~= nil then
                arr = "(" .. arr .. ")"
            end
            return arr .. "[" .. print_expr(n.idx, ctx) .. "]"
        end
        if k == "Cx:Member" then
            local obj = print_expr(n.obj, ctx)
            if core.prec_of(n.obj) ~= nil then
                obj = "(" .. obj .. ")"
            end
            return obj .. (n.arrow and "->" or ".") .. n.field
        end
        if k == "Cx:Postfix" then
            local t = print_expr(n.target, ctx)
            if core.prec_of(n.target) ~= nil or n.target.kind == "Cx:Unary"
                or n.target.kind == "Cx:CastAs" then
                t = "(" .. t .. ")"
            end
            return t .. n.op
        end
        if k == "Cx:Unary" then
            local t = print_expr(n.target, ctx)
            local p = core.prec_of(n.target)
            if p ~= nil and p < 15 then
                t = "(" .. t .. ")"
            end
            return n.op .. t
        end
        if k == "Cx:Sizeof" then
            local s = nil
            if n.is_type then
                s = P.print_decl(n.subject, "", ctx)
            else
                s = print_expr(n.subject, ctx)
            end
            return "sizeof(" .. s .. ")"
        end
        if k == "Cx:Alignof" then
            core.reject_if_msvc(ctx, n.loc, "alignof")
            return "alignof(" .. P.print_decl(n.type, "", ctx) .. ")"
        end
        if k == "Cx:CastAs" then
            local t = print_expr(n.target, ctx)
            local p = core.prec_of(n.target)
            if p ~= nil and p < 15 and n.target.kind ~= "Cx:CastAs" then
                t = "(" .. t .. ")"
            end
            return "(" .. P.print_decl(n.type, "", ctx) .. ")" .. t
        end
        if k == "Cx:Binary" then
            local p = core.PREC[n.op]
            assert(p ~= nil, "codegen: unknown binary op " .. tostring(n.op))
            local l = print_expr(n.l, ctx)
            local lp = core.prec_of(n.l)
            if lp ~= nil and lp < p then
                l = "(" .. l .. ")"
            end
            local r = print_expr(n.r, ctx)
            local rp = core.prec_of(n.r)
            if rp ~= nil and (rp < p or rp == p) then
                r = "(" .. r .. ")"
            end
            return l .. " " .. n.op .. " " .. r
        end
        if k == "Cx:Ternary" then
            local c = print_expr(n.cond, ctx)
            local cp = core.prec_of(n.cond)
            if cp ~= nil and cp <= 3 then
                c = "(" .. c .. ")"
            end
            local els = print_expr(n.els, ctx)
            if core.prec_of(n.els) == 1 then
                els = "(" .. els .. ")"
            end
            return c .. " ? " .. print_expr(n["then"], ctx) .. " : " .. els
        end
        if k == "Cx:Assign" then
            local r = print_expr(n.r, ctx)
            if core.prec_of(n.r) == 1 then
                r = "(" .. r .. ")"
            end
            return print_expr(n.l, ctx) .. " " .. n.op .. " " .. r
        end
        if k == "Cx:Comma" then
            local items = {}
            for _, it in ipairs(n.items) do
                local s = print_expr(it, ctx)
                if core.prec_of(it) == 1 then
                    s = "(" .. s .. ")"
                end
                items[#items + 1] = s
            end
            return table.concat(items, ", ")
        end
        if k == "Cx:GenericSel" then
            local parts = {}
            for _, a in ipairs(n.assocs) do
                local head = nil
                if a.is_default then
                    head = "default"
                else
                    head = P.print_decl(a.type, "", ctx)
                end
                parts[#parts + 1] = head .. ": " .. print_expr(a.value, ctx)
            end
            local c = print_expr(n.controlling, ctx)
            if core.prec_of(n.controlling) == 1 then
                c = "(" .. c .. ")"
            end
            return "_Generic(" .. c .. ", " .. table.concat(parts, ", ") .. ")"
        end
        if k == "Cx:CompoundLit" then
            local ty = P.print_decl(n.type, "", ctx)
            local pre = n.static and "(static " or "("
            return pre .. ty .. ")" .. print_init(n.init, ctx)
        end
        if k == "Cx:Gnu:OmitMiddle" then
            core.gnu_check(ctx, n)
            return print_expr(n.cond, ctx) .. " ?: " .. print_expr(n.els, ctx)
        end
        if k == "Cx:Gnu:LabelAddr" then
            core.gnu_check(ctx, n)
            return "&&" .. n.name
        end
        if k == "Cx:Gnu:Alignof" then
            core.gnu_check(ctx, n)
            return "__alignof__(" .. P.print_decl(n.type, "", ctx) .. ")"
        end
        if k == "Cx:Gnu:StmtExpr" then
            core.gnu_check(ctx, n)
            local sub = { lines = {}, cur = "", ind = 0,
                last_file = nil, last_line = nil, ctx = ctx }
            for _, it in ipairs(n.items) do
                P.emit_stmt(sub, it)
            end
            if sub.cur ~= "" then
                sub.lines[#sub.lines + 1] = sub.cur:gsub("%s+$", "")
                sub.cur = ""
            end
            if #sub.lines == 0 then
                return "({})"
            end
            local has_dir = ctx.line_markers
            if not has_dir then
                for _, it in ipairs(n.items) do
                    if it.kind == "Cx:Directive" then
                        has_dir = true
                        break
                    end
                end
            end
            if has_dir then
                -- Directives and #line markers must stay on their own lines.
                return "({\n" .. table.concat(sub.lines, "\n") .. "\n})"
            end
            local flat = {}
            for _, ln in ipairs(sub.lines) do
                flat[#flat + 1] = ln:gsub("^%s+", "")
            end
            return "({ " .. table.concat(flat, " ") .. " })"
        end
        error("codegen: cannot print expression kind " .. tostring(k), 0)
    end

    --- @param n table initializer node or expression
    --- @param ctx CodegenCtx
    --- @return string
    print_init = function(n, ctx)
        if n.kind == "Cx:ArrayLit" then
            local items = {}
            for _, it in ipairs(n.items) do
                items[#items + 1] = print_init(it, ctx)
            end
            return "{" .. table.concat(items, ", ") .. "}"
        end
        if n.kind == "Cx:RecordLit" then
            local fields = {}
            for _, f in ipairs(n.fields) do
                fields[#fields + 1] = "." .. f.name .. " = " .. print_init(f.value, ctx)
            end
            return "{" .. table.concat(fields, ", ") .. "}"
        end
        if n.kind == "Cx:Cinit" then
            return ctx.src:sub(n.start_offset, n.end_offset - 1)
        end
        return print_expr(n, ctx)
    end

    P.print_expr = print_expr
    P.print_init = print_init
end

return M
