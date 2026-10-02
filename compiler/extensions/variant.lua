-- Variant extension: tagged unions / sum types using enum syntax (P5).
-- Syntax:
--   enum Shape {
--       Circle(double),
--       Point,
--   };
-- If no variants have payloads `(T)`, it behaves as a standard C23 enum.
-- If at least one variant has a payload `(T)`:
--   - Lowers to a tag enum `<Name>_Tag`,
--   - A wrapper struct `<Name>` with tag and anonymous union of payloads,
--   - A type alias `type <Name> = struct <Name>;`,
--   - Inline constructor helper functions `<Name>_<Variant>(...)`.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

local M = {}

M.name = "Variant"

--- Deep-clone an AST subtree so duplicated nodes own unique tables.
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

--- Wrap a base type node into a valid Cx:Type node.
--- @param base table
--- @param loc table|nil
--- @return table Cx:Type
local function make_type(base, loc)
    return ast.node("Cx:Type", loc or base.loc, {
        quals = {},
        atomic_prefix = false,
        base = base,
        suffixes = {},
    })
end

--- Try to parse a tagged union variant enum.
--- If no variant has a payload `(T)`, returns nil and leaves parsing to core enum.
--- @param G table # CxGrammar
--- @param p Parser # Parser
--- @param head DeclHead # DeclHead
--- @param sloc Loc # start loc
--- @param is_block_scope boolean # true when parsing inside a block
--- @return table|nil Ext:Variant:EnumDecl
local function try_parse_variant_enum(G, p, head, sloc, is_block_scope)
    core.expect(p, "ident", "enum", "'enum'")
    for _, a in ipairs(U.parse_attrs(p)) do
        head.attrs[#head.attrs + 1] = a
    end
    local nm = U.ident_name(p)
    for _, a in ipairs(U.parse_attrs(p)) do
        head.attrs[#head.attrs + 1] = a
    end
    local underlying = nil
    if U.at(p, "punct", ":") then
        p:next()
        underlying = U.need(p, G.rules.parseType(p), "type")
    end
    if not U.at(p, "punct", "{") then
        -- Forward declaration without body (e.g. `enum Shape;`)
        return nil
    end
    p:next() -- consume '{'

    local variants = {}
    local any_payload = false
    if not U.at(p, "punct", "}") then
        while true do
            local en = U.need_ident(p, "enumerator")
            local eattrs = U.parse_attrs(p)
            local payload = nil
            if U.at(p, "punct", "(") then
                p:next()
                payload = U.need(p, G.rules.parseType(p), "payload type")
                core.expect(p, "punct", ")", "')' to close variant payload")
                any_payload = true
            end
            local value = nil
            if U.at(p, "punct", "=") then
                p:next()
                value = U.need(p, G.rules.parseConditional(p), "constant expression")
            end
            local eloc = en.loc
            if value ~= nil then
                eloc = value.loc
            elseif payload ~= nil then
                eloc = payload.loc
            end
            variants[#variants + 1] = {
                name = en.name,
                raw = en.raw,
                loc = U.span_loc(en.loc, eloc),
                attrs = eattrs,
                payload = payload,
                value = value,
            }
            if U.at(p, "punct", ",") then
                p:next()
                if U.at(p, "punct", "}") then
                    break
                end
            else
                break
            end
        end
    end
    core.expect(p, "punct", "}", "'}'")
    for _, a in ipairs(U.parse_attrs(p)) do
        head.attrs[#head.attrs + 1] = a
    end
    local semi = U.expect_semi(p)

    if not any_payload then
        -- No variant had a payload: leave as standard C enum
        return nil
    end

    if nm == nil then
        error(core.parse_error(p.env, sloc, "variant enums with payloads must have a name"), 0)
    end

    if is_block_scope then
        error(core.parse_error(p.env, sloc, "variant enums with payloads may only be declared at file scope"), 0)
    end

    local seen = {}
    for _, v in ipairs(variants) do
        if seen[v.name] then
            error(core.parse_error(p.env, v.loc, "duplicate variant '" .. v.name .. "' in enum " .. nm.name), 0)
        end
        seen[v.name] = true
    end

    -- Register typename and tags in the environment so following code can use `Name` as a type!
    p.env:define_typedef(nm.name)
    p.env:define_tag("struct", nm.name)
    p.env:define_typedef(nm.name .. "_Tag")
    p.env:define_tag("enum", nm.name .. "_Tag")

    return ast.node("Ext:Variant:EnumDecl", U.span_loc(sloc, semi.loc), {
        name = nm.name,
        raw_name = nm.raw,
        attrs = head.attrs,
        underlying = underlying,
        variants = variants,
    })
end

--- @param G table # CxGrammar
--- @param env table # {target: table, dialect: table}
function M.extend_grammar(G, env)
    assert(env ~= nil and env.dialect ~= nil, "variant: env needs dialect")
    if not env.dialect.variant then
        return
    end

    local core_ext = G.rules.parseExternalDecl
    assert(core_ext ~= nil, "variant: core parseExternalDecl missing")
    G.rules.parseExternalDecl = function(p)
        local m = p:mark()
        local sloc = p:peek().loc
        local head = U.parse_decl_head(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "enum" then
            local node = try_parse_variant_enum(G, p, head, sloc, false)
            if node ~= nil then
                return node
            end
        end
        p:reset(m)
        return core_ext(p)
    end

    local core_block = G.rules.parseBlockDecl
    assert(core_block ~= nil, "variant: core parseBlockDecl missing")
    G.rules.parseBlockDecl = function(p)
        local m = p:mark()
        local sloc = p:peek().loc
        local head = U.parse_decl_head(p)
        local t = p:peek()
        if t.kind == "ident" and t.value == "enum" then
            local node = try_parse_variant_enum(G, p, head, sloc, true)
            if node ~= nil then
                return node
            end
        end
        p:reset(m)
        return core_block(p)
    end
end

M.expanders = {
    ["Ext:Variant:EnumDecl"] = function(_ctx, node)
        local name = node.name
        local loc = node.loc or {}
        local tag_enum_name = name .. "_Tag"

        -- 1. Tag Enum: enum <Name>_Tag { <Name>_Tag_<Variant> [= val], ... };
        local tag_enumerators = {}
        for _, v in ipairs(node.variants) do
            local tag_const_name = tag_enum_name .. "_" .. v.name
            tag_enumerators[#tag_enumerators + 1] = ast.node("Cx:Enumerator", v.loc, {
                name = tag_const_name,
                raw = v.raw,
                value = v.value,
                attrs = v.attrs,
            })
        end
        local tag_enum = ast.node("Cx:EnumDecl", loc, {
            name = tag_enum_name,
            raw_name = false,
            underlying = node.underlying,
            enumerators = tag_enumerators,
            attrs = {},
        })

        -- 2. Tag TypeAlias: type <Name>_Tag = enum <Name>_Tag;
        local tag_alias = ast.node("Cx:TypeAlias", loc, {
            name = tag_enum_name,
            target = make_type(ast.node("Cx:TaggedType", loc, {
                tagkind = "enum",
                name = tag_enum_name,
            }), loc),
            attrs = {},
        })

        -- 3. Wrapper struct with anonymous union:
        -- struct <Name> {
        --     enum <Name>_Tag tag;
        --     union {
        --         <PayloadType> <VariantName>;
        --         ...
        --     };
        -- };
        local struct_members = {}
        -- Field 1: tag
        struct_members[#struct_members + 1] = ast.node("Cx:Field", loc, {
            name = "tag",
            type = make_type(ast.node("Cx:TaggedType", loc, {
                tagkind = "enum",
                name = tag_enum_name,
            }), loc),
            attrs = {},
        })

        -- Anonymous union for variants with payloads
        local union_members = {}
        for _, v in ipairs(node.variants) do
            if v.payload ~= nil then
                union_members[#union_members + 1] = ast.node("Cx:Field", v.loc, {
                    name = v.name,
                    type = clone_ast(v.payload),
                    attrs = {},
                })
            end
        end

        if #union_members > 0 then
            struct_members[#struct_members + 1] = ast.node("Cx:RecordDecl", loc, {
                tagkind = "union",
                name = nil,
                members = union_members,
                attrs = {},
            })
        end

        local struct_decl = ast.node("Cx:RecordDecl", loc, {
            tagkind = "struct",
            name = name,
            raw_name = node.raw_name,
            members = struct_members,
            attrs = node.attrs or {},
        })

        -- 4. Struct TypeAlias: type <Name> = struct <Name>;
        local struct_alias = ast.node("Cx:TypeAlias", loc, {
            name = name,
            target = make_type(ast.node("Cx:TaggedType", loc, {
                tagkind = "struct",
                name = name,
            }), loc),
            attrs = {},
        })

        -- 5. Constructor helper functions
        local replacements = {
            tag_enum,
            tag_alias,
            struct_decl,
            struct_alias,
        }

        for _, v in ipairs(node.variants) do
            local fn_name = name .. "_" .. v.name
            local tag_const_name = tag_enum_name .. "_" .. v.name
            local ret_type = make_type(ast.node("Cx:TaggedType", v.loc, {
                tagkind = "struct",
                name = name,
            }), v.loc)

            local params = {}
            local lit_fields = {
                {
                    name = "tag",
                    value = ast.node("Cx:Ident", v.loc, { name = tag_const_name }),
                },
            }

            if v.payload ~= nil then
                params[#params + 1] = ast.node("Cx:Param", v.loc, {
                    name = "_0",
                    type = clone_ast(v.payload),
                    ellipsis = false,
                })
                lit_fields[#lit_fields + 1] = {
                    name = v.name,
                    value = ast.node("Cx:Ident", v.loc, { name = "_0" }),
                }
            end

            local compound_lit = ast.node("Cx:CompoundLit", v.loc, {
                type = clone_ast(ret_type),
                static = false,
                init = ast.node("Cx:RecordLit", v.loc, {
                    fields = lit_fields,
                }),
            })

            local ret_stmt = ast.node("Cx:Return", v.loc, {
                value = compound_lit,
            })

            local body = ast.node("Cx:Block", v.loc, {
                items = { ret_stmt },
            })

            local fn_decl = ast.node("Cx:FunctionDecl", v.loc, {
                name = fn_name,
                raw = false,
                specifiers = { "static", "inline" },
                attrs = { "maybe_unused" },
                params = params,
                return_type = ret_type,
                body = body,
            })

            replacements[#replacements + 1] = fn_decl
        end

        return replacements
    end,
}

return M
