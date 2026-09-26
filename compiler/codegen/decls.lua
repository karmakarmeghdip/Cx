-- Codegen declarations: bindings, functions, records, enums, aliases.
-- Function bodies and record members recurse through P.emit_block_items /
-- P.emit_stmt; type positions use P.print_decl / P.print_expr.

local core = require("compiler.codegen.core")

local M = {}

--- Register this section's emitters on the shared table.
--- @param P table shared printer table
function M.define(P)
    --- Print one binding declarator (type + name + attrs + init, no specs).
    --- drop_lead_const strips a duplicated leading `const` when the `const`
    --- introducer already provides it (`const x: const int` -> `const int x`).
    --- @param E table Emitter (for ctx only)
    --- @param b table # Cx:Binding
    --- @param with_type boolean print the type (false when sharing)
    --- @param drop_lead_const boolean|nil
    --- @return string
    local function print_binding(E, b, with_type, drop_lead_const)
        local ctx = E.ctx
        local s = ""
        if with_type then
            if b.type ~= nil then
                s = P.print_decl(b.type, b.name, ctx, drop_lead_const)
            else
                s = "auto " .. b.name
            end
        else
            s = b.name
        end
        for _, a in ipairs(b.attrs) do
            s = s .. " " .. core.attr_str(a)
        end
        if b.init ~= nil then
            local istr = P.print_init(b.init, ctx)
            if b.init.kind == "Cx:Comma" then
                istr = "(" .. istr .. ")"
            end
            s = s .. " = " .. istr
        end
        return s
    end

    --- Full binding declaration string without the trailing `;`.
    --- Multi-bindings share the first type when all spell identically.
    --- @param E table Emitter
    --- @param n table # Cx:BindingDecl
    --- @return string
    local function binding_string(E, n)
        local ctx = E.ctx
        local head = {}
        for _, a in ipairs(n.attrs) do
            head[#head + 1] = core.attr_str(a)
        end
        if n.alignas ~= nil then
            head[#head + 1] = (n.alignas_kind or "alignas") .. "(" .. n.alignas .. ")"
        end
        for _, s in ipairs(n.specifiers) do
            head[#head + 1] = s
        end
        local lead_const = false
        if n.introducer == "const" then
            head[#head + 1] = "const"
            lead_const = true
        elseif n.introducer ~= "let" then
            -- Dialect introducers (e.g. GNU __auto_type) pass through verbatim.
            head[#head + 1] = n.introducer
            if n.introducer:sub(1, 2) == "__" then
                core.reject_if_msvc(ctx, n.loc, n.introducer)
            end
        end
        local first = n.bindings[1]
        assert(first ~= nil, "codegen: binding decl needs a binding")
        --- @param b table # Cx:Binding
        --- @return string comparable type spelling ("auto" when inferred)
        local function type_spell(b)
            if b.type == nil then
                return "auto"
            end
            return P.print_decl(b.type, "", ctx, lead_const)
        end
        local first_spell = type_spell(first)
        local share = true
        for i = 2, #n.bindings do
            if type_spell(n.bindings[i]) ~= first_spell then
                share = false
                break
            end
        end
        local parts = {}
        for i, b in ipairs(n.bindings) do
            local wt = (not share) or i == 1
            if wt and b.type == nil and n.introducer:sub(1, 2) == "__" then
                -- Dialect introducers that ARE the type (e.g. __auto_type):
                -- the head already spells it, so the binding stays bare.
                wt = false
            end
            parts[#parts + 1] = print_binding(E, b, wt, lead_const)
        end
        local decl = table.concat(parts, ", ")
        if #head == 0 then
            return decl
        end
        return table.concat(head, " ") .. " " .. decl
    end

    local emit_decl

    --- Emit a braced body on its own lines (function-style layout).
    --- @param E table Emitter
    --- @param body table # Cx:Block (or a lone statement, defensively)
    local function emit_body_block(E, body)
        if body.kind == "Cx:Block" and #body.items == 0 then
            core.LINE(E, "{}")
            return
        end
        core.LINE(E, "{")
        E.ind = E.ind + 1
        if body.kind == "Cx:Block" then
            P.emit_block_items(E, body.items)
        else
            P.emit_stmt(E, body)
        end
        E.ind = E.ind - 1
        core.LINE(E, "}")
    end

    --- Emit a C function definition or prototype from a FunctionDecl node.
    --- Shared by top-level functions and GNU nested functions.
    --- @param E table Emitter
    --- @param n table # Cx:FunctionDecl
    local function emit_function(E, n)
        local ctx = E.ctx
        core.check_gnu_attrs(ctx, n.loc, n.attrs)
        local head = {}
        for _, a in ipairs(n.attrs) do
            head[#head + 1] = core.attr_str(a)
        end
        for _, s in ipairs(n.specifiers) do
            head[#head + 1] = s
        end
        local fname = n.name .. "(" .. P.print_params(n.params, ctx) .. ")"
        local decl = P.print_decl(n.return_type, fname, ctx)
        local s = decl
        if #head > 0 then
            s = table.concat(head, " ") .. " " .. decl
        end
        if n.body == nil then
            core.LINE(E, s .. ";")
            return
        end
        core.LINE(E, s)
        emit_body_block(E, n.body)
    end

    --- Emit one declaration (top-level or block item).
    --- @param E table Emitter
    --- @param n table decl node
    emit_decl = function(E, n)
        core.MARK(E, n.loc)
        local ctx = E.ctx
        local k = n.kind
        if k == "Cx:Directive" then
            E.lines[#E.lines + 1] = n.raw or n.text
            core.UNMARK(E)
            return
        end
        if k == "Cx:AttrsOnly" then
            local parts = {}
            for _, a in ipairs(n.attrs) do
                parts[#parts + 1] = core.attr_str(a)
            end
            if #parts == 0 then
                core.LINE(E, ";")
            else
                core.LINE(E, table.concat(parts, " ") .. ";")
            end
            return
        end
        if k == "Cx:FunctionDecl" then
            emit_function(E, n)
            return
        end
        if k == "Cx:Gnu:NestedFunc" then
            core.gnu_check(ctx, n)
            emit_function(E, n.decl)
            return
        end
        if k == "Cx:Gnu:KRFunction" then
            core.gnu_check(ctx, n)
            local head = {}
            for _, a in ipairs(n.attrs) do
                head[#head + 1] = core.attr_str(a)
            end
            for _, s in ipairs(n.specs) do
                head[#head + 1] = s
            end
            local fname = n.name .. "(" .. table.concat(n.params, ", ") .. ")"
            local decl = fname
            if n.ret ~= nil then
                decl = P.print_decl(n.ret, fname, ctx)
            end
            local s = decl
            if #head > 0 then
                s = table.concat(head, " ") .. " " .. decl
            end
            core.LINE(E, s)
            for _, ln in ipairs(n.lines) do
                E.lines[#E.lines + 1] = ctx.src:sub(ln.start_offset, ln.end_offset - 1)
            end
            core.UNMARK(E)
            emit_body_block(E, n.body)
            return
        end
        if k == "Cx:BindingDecl" then
            core.check_gnu_attrs(ctx, n.loc, n.attrs)
            core.LINE(E, binding_string(E, n) .. ";")
            return
        end
        if k == "Cx:TypeAlias" then
            core.check_gnu_attrs(ctx, n.loc, n.attrs)
            local head = {}
            for _, a in ipairs(n.attrs) do
                head[#head + 1] = core.attr_str(a)
            end
            local trailer = ""
            if n.gnu_trailing ~= nil then
                core.gnu_check(ctx, n)
                trailer = " " .. table.concat(n.gnu_trailing, " ")
            end
            if n.target.kind == "Cx:RecordDecl" then
                -- Anonymous record target (`type R = struct { … };`):
                -- `typedef struct { … } R;`. The grammar only builds
                -- nameless records here, so a name is an invariant breach.
                assert(n.target.name == nil,
                    "codegen: named record cannot be an alias target")
                local open = "typedef " .. n.target.tagkind .. " {"
                if #head > 0 then
                    open = table.concat(head, " ") .. " " .. open
                end
                core.LINE(E, open)
                E.ind = E.ind + 1
                for _, m in ipairs(n.target.members) do
                    emit_decl(E, m)
                end
                E.ind = E.ind - 1
                core.LINE(E, "}" .. trailer .. " " .. n.name .. ";")
                return
            end
            local decl = "typedef " .. P.print_decl(n.target, n.name, ctx)
            decl = decl .. trailer .. ";"
            if #head == 0 then
                core.LINE(E, decl)
            else
                core.LINE(E, table.concat(head, " ") .. " " .. decl)
            end
            return
        end
        if k == "Cx:RecordDecl" then
            core.check_gnu_attrs(ctx, n.loc, n.attrs)
            local head = {}
            for _, a in ipairs(n.attrs) do
                head[#head + 1] = core.attr_str(a)
            end
            local s = n.tagkind
            if n.name ~= nil then
                s = s .. " " .. n.name
            end
            local trailer = ""
            if n.gnu_trailing ~= nil then
                core.gnu_check(ctx, n)
                trailer = " " .. table.concat(n.gnu_trailing, " ")
            end
            if n.members == nil then
                if #head > 0 then
                    s = table.concat(head, " ") .. " " .. s
                end
                core.LINE(E, s .. trailer .. ";")
                return
            end
            if #head > 0 then
                core.LINE(E, table.concat(head, " ") .. " " .. s .. " {")
            else
                core.LINE(E, s .. " {")
            end
            E.ind = E.ind + 1
            for _, m in ipairs(n.members) do
                emit_decl(E, m)
            end
            E.ind = E.ind - 1
            core.LINE(E, "}" .. trailer .. ";")
            return
        end
        if k == "Cx:Field" then
            local s = ""
            for _, a in ipairs(n.attrs) do
                s = s .. core.attr_str(a) .. " "
            end
            s = s .. P.print_decl(n.type, n.name, ctx)
            if n.width ~= nil then
                s = s .. " : " .. P.print_expr(n.width, ctx)
            end
            core.LINE(E, s .. ";")
            return
        end
        if k == "Cx:UnnamedBitfield" then
            -- C has no typeless bit-fields: `unsigned` carries no storage here
            -- (`: 0` only ends the allocation unit).
            core.LINE(E, "unsigned : " .. P.print_expr(n.width, ctx) .. ";")
            return
        end
        if k == "Cx:EnumDecl" then
            core.check_gnu_attrs(ctx, n.loc, n.attrs)
            local head = {}
            for _, a in ipairs(n.attrs) do
                head[#head + 1] = core.attr_str(a)
            end
            local s = "enum"
            if n.name ~= nil then
                s = s .. " " .. n.name
            end
            if n.underlying ~= nil then
                s = s .. " : " .. P.print_decl(n.underlying, "", ctx)
            end
            if n.enumerators == nil then
                if #head > 0 then
                    s = table.concat(head, " ") .. " " .. s
                end
                core.LINE(E, s .. ";")
                return
            end
            if #head > 0 then
                core.LINE(E, table.concat(head, " ") .. " " .. s .. " {")
            else
                core.LINE(E, s .. " {")
            end
            E.ind = E.ind + 1
            for _, e in ipairs(n.enumerators) do
                local es = e.name
                for _, a in ipairs(e.attrs) do
                    es = es .. " " .. core.attr_str(a)
                end
                if e.value ~= nil then
                    es = es .. " = " .. P.print_expr(e.value, ctx)
                end
                core.LINE(E, es .. ",")
            end
            E.ind = E.ind - 1
            core.LINE(E, "};")
            return
        end
        if k == "Cx:StaticAssert" then
            core.check_gnu_attrs(ctx, n.loc, n.attrs)
            local s = ""
            for _, a in ipairs(n.attrs) do
                s = s .. core.attr_str(a) .. " "
            end
            s = s .. "static_assert(" .. P.print_expr(n.test, ctx)
            if n.message ~= nil then
                s = s .. ", " .. n.message
            end
            core.LINE(E, s .. ");")
            return
        end
        error("codegen: cannot print declaration kind " .. tostring(k), 0)
    end

    --- Emit one translation-unit item.
    --- @param E table Emitter
    --- @param n table decl node
    local function emit_top(E, n)
        emit_decl(E, n)
    end

    P.binding_string = binding_string
    P.emit_decl = emit_decl
    P.emit_top = emit_top
end

return M
