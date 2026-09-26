-- Codegen types: C declarators from Cx:Type nodes (inside-out).
-- Suffixes apply left to right; `*` after arrays parenthesizes
-- (`(*a)[4]`), arrays after `*` append (`*a[4]`), and arrays applied
-- after a parenthesized star nest inside (`(*a[3])[2]`).
-- Cross-printer calls (bound sizes, bit widths, param types) go through
-- the P table; P.print_expr/P.print_params are wired before first use.

local core = require("compiler.codegen.core")

local M = {}

--- Split trailing `[...]` groups: returns stem + run.
--- @param decl string
--- @return string stem
--- @return string run
local function split_arrays(decl)
    local i = #decl
    local depth = 0
    local start = i + 1
    while i > 0 do
        local c = decl:sub(i, i)
        if c == "]" then
            depth = depth + 1
        elseif c == "[" then
            depth = depth - 1
            if depth < 0 then
                break
            end
            if depth == 0 then
                start = i
            end
        elseif depth == 0 then
            break
        end
        i = i - 1
    end
    return decl:sub(1, start - 1), decl:sub(start)
end

--- @param P table printer table (P.print_expr)
--- @param s table # Cx:ArraySuffix
--- @param ctx CodegenCtx
--- @return string bound text including brackets
local function print_bound(P, s, ctx)
    if s.star then
        return "[*]"
    end
    local parts = {}
    if #s.quals > 0 then
        parts[#parts + 1] = table.concat(s.quals, " ")
    end
    if s.static then
        parts[#parts + 1] = "static"
    end
    if s.size ~= nil then
        parts[#parts + 1] = P.print_expr(s.size, ctx)
    end
    if #parts == 0 then
        return "[]"
    end
    return "[" .. table.concat(parts, " ") .. "]"
end

--- Print a full declaration: base spec + inside-out declarator.
--- drop_lead_const strips a duplicated leading `const` (const-introducer).
--- @param P table printer table (P.print_expr, P.print_params)
--- @param ty table # Cx:Type
--- @param name string declarator name ("" for bare types)
--- @param ctx CodegenCtx
--- @param drop_lead_const boolean|nil
--- @return string
local function print_decl(P, ty, name, ctx, drop_lead_const)
    local decl = name
    for _, s in ipairs(ty.suffixes) do
        if s.kind == "Cx:PtrSuffix" then
            local stars = "*"
            if #s.quals > 0 then
                stars = stars .. table.concat(s.quals, " ") .. " "
            end
            local stem, run = split_arrays(decl)
            if run == "" then
                decl = stars .. decl
            else
                decl = "(" .. stars .. stem .. ")" .. run
            end
        elseif s.kind == "Cx:ArraySuffix" then
            local bound = print_bound(P, s, ctx)
            local grp, rest = decl:match("^(%b())(.*)$")
            if grp ~= nil and rest ~= "" then
                decl = grp:sub(1, -2) .. bound .. ")" .. rest
            else
                decl = decl .. bound
            end
        else
            error("codegen: unknown suffix kind " .. tostring(s.kind), 0)
        end
    end
    local base = ty.base
    local quals = ty.quals
    if drop_lead_const and quals[1] == "const" then
        local rest = {}
        for i = 2, #quals do
            rest[#rest + 1] = quals[i]
        end
        quals = rest
    end
    local spec = ""
    if #quals > 0 then
        spec = table.concat(quals, " ") .. " "
    end
    if ty.atomic_prefix then
        spec = spec .. "_Atomic "
    end
    if base.kind == "Cx:BuiltinType" then
        local spell = base.spell
        if spell == "_BitInt" or spell:match(" _BitInt$") ~= nil then
            core.reject_if_msvc(ctx, ty.loc, "_BitInt")
        end
        if spell:match("^_Decimal") ~= nil then
            core.reject_if_msvc(ctx, ty.loc, base.spell)
        end
        if base.bitwidth ~= nil then
            spell = spell .. "(" .. P.print_expr(base.bitwidth, ctx) .. ")"
        end
        return core.join_decl(spec .. spell, decl)
    end
    if base.kind == "Cx:TaggedType" then
        return core.join_decl(spec .. base.tagkind .. " " .. base.name, decl)
    end
    if base.kind == "Cx:NamedType" then
        return core.join_decl(spec .. base.name, decl)
    end
    if base.kind == "Cx:FuncType" then
        local d = (decl == "") and "*" or decl
        local ret = print_decl(P, base.ret, "", ctx)
        return ret .. " (" .. d .. ")(" .. P.print_params(base.params, ctx) .. ")"
    end
    if base.kind == "Cx:ParenType" then
        -- Redundant parens around a function type are dropped (they are
        -- semantically null and would otherwise wrap the whole declarator).
        local inner = base.inner
        local ft = nil
        if inner.kind == "Cx:FuncType" then
            ft = inner
        elseif inner.kind == "Cx:Type" and inner.base.kind == "Cx:FuncType"
            and #inner.suffixes == 0 and #inner.quals == 0
            and not inner.atomic_prefix then
            ft = inner.base
        end
        if ft ~= nil then
            local d = (decl == "") and "*" or decl
            local ret = print_decl(P, ft.ret, "", ctx)
            return ret .. " (" .. d .. ")(" .. P.print_params(ft.params, ctx) .. ")"
        end
        return "(" .. print_decl(P, base.inner, "", ctx) .. ")"
            .. ((decl ~= "") and " " .. decl or "")
    end
    if base.kind == "Cx:TypeofType" then
        core.reject_if_msvc(ctx, ty.loc, base.op)
        local sub = nil
        if base.is_type then
            sub = print_decl(P, base.subject, "", ctx)
        else
            sub = P.print_expr(base.subject, ctx)
        end
        return core.join_decl(spec .. base.op .. "(" .. sub .. ")", decl)
    end
    if base.kind == "Cx:AtomicType" then
        return core.join_decl(spec .. "_Atomic(" .. print_decl(P, base.inner, "", ctx) .. ")", decl)
    end
    if base.kind == "Cx:ComplexType" then
        return core.join_decl(spec .. base.base.spell .. " " .. base.flavor, decl)
    end
    error("codegen: unknown type base kind " .. tostring(base.kind), 0)
end

--- Print a parameter list (empty means `(void)`).
--- @param P table printer table (P.print_decl)
--- @param params table # Cx:Param[]
--- @param ctx CodegenCtx
--- @return string
local function print_params(P, params, ctx)
    if #params == 0 then
        return "void"
    end
    local out = {}
    for _, p in ipairs(params) do
        if p.ellipsis then
            out[#out + 1] = "..."
        elseif p.name ~= nil then
            out[#out + 1] = P.print_decl(p.type, p.name, ctx)
        else
            out[#out + 1] = P.print_decl(p.type, "", ctx)
        end
    end
    return table.concat(out, ", ")
end

--- Register this section's printers on the shared table.
--- @param P table shared printer table
function M.define(P)
    --- @param ty table # Cx:Type
    --- @param name string
    --- @param ctx CodegenCtx
    --- @param drop_lead_const boolean|nil
    --- @return string
    P.print_decl = function(ty, name, ctx, drop_lead_const)
        return print_decl(P, ty, name, ctx, drop_lead_const)
    end
    --- @param params table # Cx:Param[]
    --- @param ctx CodegenCtx
    --- @return string
    P.print_params = function(params, ctx)
        return print_params(P, params, ctx)
    end
end

return M
