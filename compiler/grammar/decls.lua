-- Declarations: translation unit, bindings, functions, aliases, records,
-- unions, enums, static assertions (grammar section).
-- Follows samples/c-vs-cx.md (the syntax source of truth):
--   binding-declaration = attributes? declaration-specifiers?
--     ("let" | "const") binding ("," binding)* ";"
--   storage-class-specifier =
--     "static" | "extern" | "constexpr" | "thread_local" | "_Thread_local".
-- `constexpr` is a head specifier (`constexpr let x: T`), never an
-- introducer; `register`/`auto` are rejected in U.parse_decl_head.

local core = require("compiler.parser_core")
local ast = require("compiler.ast")
local U = require("compiler.grammar.util")

--- @param kind string
--- @param loc table
--- @param fields table|nil
--- @return table CxNode
local function N(kind, loc, fields)
    return ast.node(kind, loc, fields)
end

--- @param G CxGrammar
local function define(G)
    -- Forward: record bodies nest full record declarations.
    local finish_record
    --- Single `name [: type] [attrs] [= init]` (no semicolon; the caller
    --- owns terminators, so for-init headers share this).
    --- @param p Parser # Parser
    --- @return table Cx:Binding
    local function parse_binding(p)
        local nm = U.need_ident(p, "binding name")
        local ty = nil
        if U.at(p, "punct", ":") then
            p:next()
            ty = U.need(p, U.rules(p).parseType(p), "type")
        end
        local attrs = U.parse_attrs(p)
        local init = nil
        if U.at(p, "punct", "=") then
            p:next()
            init = U.need(p, U.rules(p).parseInitializer(p), "initializer")
        end
        if ty == nil and init == nil then
            p:fail("type or initializer for binding '" .. nm.name .. "'")
        end
        local eloc = nm.loc
        if ty ~= nil then
            eloc = ty.loc
        end
        if init ~= nil then
            eloc = init.loc
        end
        return N("Cx:Binding", U.span_loc(nm.loc, eloc), {
            name = nm.name, raw = nm.raw, type = ty, attrs = attrs, init = init,
        })
    end

    --- `head (let|const) binding (, binding)* ;`
    --- `constexpr` arrives in `head.specs` (specifier), never here as an
    --- introducer. `register`/`auto` never reach here (rejected in the head).
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc Loc
    --- @return table Cx:BindingDecl
    local function finish_binding(p, head, sloc)
        U.forbid_func_specs(p, head, "binding")
        local intro = p:next()
        local bindings = {}
        while true do
            bindings[#bindings + 1] = parse_binding(p)
            if U.at(p, "punct", ",") then
                p:next()
            else
                break
            end
        end
        local semi = U.expect_semi(p)
        return N("Cx:BindingDecl", U.span_loc(sloc, semi.loc), {
            introducer = intro.value, specifiers = head.specs,
            alignas = head.alignas, alignas_kind = head.alignas_kind,
            attrs = head.attrs, bindings = bindings,
        })
    end

    --- `head function name(params): ret ;|block`
    --- Spec function-specifier = "static" | "inline" | "_Noreturn" only.
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @return table Cx:FunctionDecl
    local function finish_function(p, head, sloc)
        for _, s in ipairs(head.specs) do
            if s ~= "static" and s ~= "inline" and s ~= "_Noreturn" then
                p:fail("'" .. s .. "' is not allowed on functions"
                    .. " (spec: only static|inline|_Noreturn)")
            end
        end
        core.expect(p, "keyword", "function", "'function'")
        local nm = U.need_ident(p, "function name")
        core.expect(p, "punct", "(", "'('")
        local params = {}
        if not U.at(p, "punct", ")") then
            if U.at(p, "ident", "void") and p:peek(2).value == ")" then
                p:next()
            else
                while true do
                    params[#params + 1] = U.rules(p).parseParam(p)
                    if U.at(p, "punct", ",") then
                        p:next()
                        if U.at(p, "punct", ")") then
                            break
                        end
                    else
                        break
                    end
                end
            end
        end
        core.expect(p, "punct", ")", "')'")
        core.expect(p, "punct", ":", "':'")
        local ret = U.need(p, U.rules(p).parseType(p), "return type")
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        local body = nil
        local eloc = ret.loc
        if U.at(p, "punct", ";") then
            eloc = p:peek().loc
            p:next()
        else
            body = U.need(p, U.rules(p).parseBlock(p), "function body")
            eloc = body.loc
        end
        return N("Cx:FunctionDecl", U.span_loc(sloc, eloc), {
            name = nm.name, raw = nm.raw, params = params, return_type = ret,
            specifiers = head.specs, attrs = head.attrs, body = body,
        })
    end

    --- Record body members (struct or union). Stops before `}`.
    --- @param p Parser # Parser
    --- @return table[] members
    local function parse_record_body(p)
        local members = {}
        while not U.at(p, "punct", "}") do
            if p:eof() then
                p:fail("'}' to close record body")
            end
            local t = p:peek()
            if t.kind == "directive" then
                p:next()
                members[#members + 1] = N("Cx:Directive", t.loc, { text = t.value, raw = t.raw })
            elseif t.kind == "punct" and t.value == ":" then
                local sloc = t.loc
                p:next()
                local width = U.need(p, U.rules(p).parseConditional(p), "bit-field width")
                local semi = U.expect_semi(p)
                members[#members + 1] = N("Cx:UnnamedBitfield",
                    U.span_loc(sloc, semi.loc), { width = width })
            elseif t.kind == "ident" and t.value == "static_assert" then
                members[#members + 1] = U.rules(p).parseStaticAssert(p)
            else
                local msloc = t.loc
                local attrs = U.parse_attrs(p)
                local t2 = p:peek()
                if t2.kind == "ident" and (t2.value == "struct" or t2.value == "union") then
                    members[#members + 1] = finish_record(p,
                        { specs = {}, alignas = nil, attrs = attrs }, msloc)
                else
                    local nm = U.need_ident(p, "member name")
                    core.expect(p, "punct", ":", "':'")
                    local ty = U.need(p, U.rules(p).parseType(p), "type")
                    for _, a in ipairs(U.parse_attrs(p)) do
                        attrs[#attrs + 1] = a
                    end
                    local width = nil
                    if U.at(p, "punct", ":") then
                        p:next()
                        width = U.need(p, U.rules(p).parseConditional(p), "bit-field width")
                    end
                    local semi = U.expect_semi(p)
                    members[#members + 1] = N("Cx:Field",
                        U.span_loc(msloc, semi.loc), {
                            name = nm.name, raw = nm.raw, type = ty,
                            width = width, attrs = attrs,
                        })
                end
            end
        end
        return members
    end

    --- `head (struct|union) [attrs] [name] [attrs] ({members} [attrs] ; | ;)`.
    --- The tag registers BEFORE the body so recursive fields resolve.
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @return table Cx:RecordDecl
    finish_record = function(p, head, sloc)
        local tk = core.expect(p, "ident", nil, "'struct' or 'union'")
        if tk.value ~= "struct" and tk.value ~= "union" then
            p:fail_at(tk, "'struct' or 'union'")
        end
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        local nm = U.ident_name(p)
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        if nm ~= nil then
            p.env:define_tag(tk.value, nm.name)
        end
        local members = nil
        local eloc = (nm ~= nil) and nm.loc or tk.loc
        if U.at(p, "punct", "{") then
            p:next()
            members = parse_record_body(p)
            local cl = core.expect(p, "punct", "}", "'}'")
            eloc = cl.loc
            for _, a in ipairs(U.parse_attrs(p)) do
                head.attrs[#head.attrs + 1] = a
            end
        end
        local trailing = U.parse_gnu_trailing(p)
        local semi = U.expect_semi(p)
        eloc = semi.loc
        return N("Cx:RecordDecl", U.span_loc(sloc, eloc), {
            tagkind = tk.value, name = (nm ~= nil) and nm.name or nil,
            raw_name = (nm ~= nil) and nm.raw or nil,
            members = members, attrs = head.attrs,
            gnu_trailing = trailing,
        })
    end

    --- `head enum [attrs] [name] [attrs] ( : type )? ({enumers} | empty)? [attrs] ;`
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @return table Cx:EnumDecl
    local function finish_enum(p, head, sloc)
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
            underlying = U.need(p, U.rules(p).parseType(p), "type")
        end
        if nm ~= nil then
            p.env:define_tag("enum", nm.name)
        end
        local enumerators = nil
        if U.at(p, "punct", "{") then
            p:next()
            enumerators = {}
            if not U.at(p, "punct", "}") then
                while true do
                    local en = U.need_ident(p, "enumerator")
                    local eattrs = U.parse_attrs(p)
                    local value = nil
                    if U.at(p, "punct", "=") then
                        p:next()
                        value = U.need(p, U.rules(p).parseConditional(p), "constant expression")
                    end
                    local eloc = en.loc
                    if value ~= nil then
                        eloc = value.loc
                    end
                    enumerators[#enumerators + 1] = N("Cx:Enumerator",
                        U.span_loc(en.loc, eloc), {
                            name = en.name, raw = en.raw,
                            value = value, attrs = eattrs,
                        })
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
        end
        local semi = U.expect_semi(p)
        return N("Cx:EnumDecl", U.span_loc(sloc, semi.loc), {
            name = (nm ~= nil) and nm.name or nil,
            raw_name = (nm ~= nil) and nm.raw or nil,
            underlying = underlying, enumerators = enumerators,
            attrs = head.attrs,
        })
    end

    --- `head type name [attrs] = (type | anonymous record) [attrs] ;`
    --- The alias registers as a typedef for the sizeof/typeof gate.
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @return table Cx:TypeAlias
    local function finish_alias(p, head, sloc)
        U.forbid_func_specs(p, head, "type alias")
        if #head.specs > 0 or head.alignas ~= nil then
            p:fail("storage classes are not allowed on type aliases")
        end
        core.expect(p, "keyword", "type", "'type'")
        local nm = U.need_ident(p, "type name")
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        core.expect(p, "punct", "=", "'='")
        local target = nil
        local t = p:peek()
        if t.kind == "ident" and (t.value == "struct" or t.value == "union")
            and (p:peek(2).kind == "attr_open" or p:peek(2).value == "{") then
            local tk = p:next()
            for _, a in ipairs(U.parse_attrs(p)) do
                head.attrs[#head.attrs + 1] = a
            end
            core.expect(p, "punct", "{", "'{'")
            local members = parse_record_body(p)
            local cl = core.expect(p, "punct", "}", "'}'")
            target = N("Cx:RecordDecl", U.span_loc(tk.loc, cl.loc), {
                tagkind = tk.value, members = members, attrs = {},
            })
        else
            target = U.need(p, U.rules(p).parseType(p), "type")
        end
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        local trailing = U.parse_gnu_trailing(p)
        local semi = U.expect_semi(p)
        p.env:define_typedef(nm.name)
        return N("Cx:TypeAlias", U.span_loc(sloc, semi.loc), {
            name = nm.name, raw = nm.raw, target = target, attrs = head.attrs,
            gnu_trailing = trailing,
        })
    end

    --- `head static_assert ( cond [, string] ) [attrs] ;` (file or member).
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @return table Cx:StaticAssert
    local function finish_static_assert(p, head, sloc)
        if #head.specs > 0 or head.alignas ~= nil then
            p:fail("storage classes are not allowed on static_assert")
        end
        core.expect(p, "ident", "static_assert", "'static_assert'")
        core.expect(p, "punct", "(", "'('")
        local test = U.need(p, U.rules(p).parseConditional(p), "constant expression")
        local message = nil
        if U.at(p, "punct", ",") then
            p:next()
            local mt = core.expect(p, "string", nil, "message string")
            message = mt.raw
        end
        core.expect(p, "punct", ")", "')'")
        for _, a in ipairs(U.parse_attrs(p)) do
            head.attrs[#head.attrs + 1] = a
        end
        local semi = U.expect_semi(p)
        return N("Cx:StaticAssert", U.span_loc(sloc, semi.loc), {
            test = test, message = message, attrs = head.attrs,
        })
    end

    --- Shared head+keyword dispatch. allow_function false inside blocks
    --- (nested functions are a GNU-dialect matter, P5). Returns nil
    --- (uncommitted) when the cursor does not start a declaration.
    --- @param p Parser # Parser
    --- @param head DeclHead # DeclHead
    --- @param sloc table
    --- @param allow_function boolean
    --- @return table|nil decl node
    local function finish_decl(p, head, sloc, allow_function)
        local t = p:peek()
        if t.kind == "keyword" then
            if t.value == "function" then
                if not allow_function then
                    return nil
                end
                return finish_function(p, head, sloc)
            elseif t.value == "let" or t.value == "const" then
                return finish_binding(p, head, sloc)
            elseif t.value == "type" then
                return finish_alias(p, head, sloc)
            end
            return nil
        end
        if t.kind == "ident" then
            if t.value == "struct" or t.value == "union" then
                return finish_record(p, head, sloc)
            elseif t.value == "enum" then
                return finish_enum(p, head, sloc)
            elseif t.value == "static_assert" then
                return finish_static_assert(p, head, sloc)
            end
        end
        return nil
    end

    --- One top-level item: directive, `[[...]];`, or any declaration.
    --- @param p Parser # Parser
    --- @return table|nil decl node (nil only when nothing matches)
    G.rules.parseExternalDecl = function(p)
        local t = p:peek()
        if t.kind == "directive" then
            p:next()
            return N("Cx:Directive", t.loc, { text = t.value, raw = t.raw })
        end
        local m = p:mark()
        local sloc = t.loc
        local head = U.parse_decl_head(p)
        local t2 = p:peek()
        if t2.kind == "keyword" and t2.value == "function" then
            return finish_function(p, head, sloc)
        end
        if t2.kind == "punct" and t2.value == ";" then
            if #head.specs > 0 or head.alignas ~= nil then
                p:fail("declaration")
            end
            p:next()
            return N("Cx:AttrsOnly", U.span_loc(sloc, t2.loc), { attrs = head.attrs })
        end
        local node = finish_decl(p, head, sloc, true)
        if node == nil then
            p:reset(m)
            return nil
        end
        return node
    end

    --- One block-level declaration (no functions, no AttrsOnly: those belong
    --- to statements). Nil + rewound when the cursor starts something else.
    --- @param p Parser # Parser
    --- @return table|nil decl node
    G.rules.parseBlockDecl = function(p)
        local t = p:peek()
        if t.kind == "directive" then
            p:next()
            return N("Cx:Directive", t.loc, { text = t.value, raw = t.raw })
        end
        local m = p:mark()
        local sloc = t.loc
        local head = U.parse_decl_head(p)
        local node = finish_decl(p, head, sloc, false)
        if node == nil then
            p:reset(m)
            return nil
        end
        return node
    end

    G.rules.parseBinding = parse_binding

    --- Full function declaration with its own head (entry for GNU nested
    --- functions; the external path below shares finish_function).
    --- @param p Parser # Parser
    --- @return table Cx:FunctionDecl
    G.rules.parseFunctionDecl = function(p)
        local sloc = p:peek().loc
        local head = U.parse_decl_head(p)
        return finish_function(p, head, sloc)
    end

    --- `static_assert ...` callable from record bodies (member position).
    --- @param p Parser # Parser
    --- @return table Cx:StaticAssert
    G.rules.parseStaticAssert = function(p)
        local sloc = p:peek().loc
        local head = U.parse_decl_head(p)
        return finish_static_assert(p, head, sloc)
    end

    --- Whole translation unit: external declarations to eof.
    --- @param p Parser # Parser
    --- @return table Cx:TranslationUnit
    G.rules.parseTranslationUnit = function(p)
        local ext = U.rules(p).parseExternalDecl
        local body = {}
        while not p:eof() do
            local ok, node = pcall(function()
                local n = ext(p)
                if n == nil then
                    p:fail("external declaration")
                end
                return n
            end)
            if ok then
                body[#body + 1] = node
            elseif not core.is_parse_error(node) then
                error(node, 0) -- Lua bug: propagate untouched
            elseif not core.record_error(p, node, true) then
                break
            end
        end
        return N("Cx:TranslationUnit",
            { file = p.env.file, line = 1, col = 1,
                end_line = p:peek().loc.line, end_col = p:peek().loc.col, offset = 1 },
            { body = body })
    end
end

return { define = define }
