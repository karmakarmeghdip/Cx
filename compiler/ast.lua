-- AST utilities and core node kinds (P1 scaffold).
-- Two families, distinguished by `kind` prefix (see AGENTS.md section 5):
--   native:    kind = "Cx:..."  (codegen knows these exhaustively, P4+)
--   extension: kind = "Ext:..." (must be expanded first, P5+)
-- The AST is a plain Lua table tree (no metatables on hot paths).
-- P1 defines only Cx:TranslationUnit and Cx:Directive; the full Cx:*
-- catalog lands with the P3 grammar.

local M = {}

---@class Loc
---@field file string source file name
---@field line integer 1-based start line
---@field col integer 1-based start column (bytes, not code points)
---@field end_line integer 1-based end line (exclusive end position)
---@field end_col integer 1-based end column (bytes, exclusive)
---@field offset integer byte offset of the start in the spliced source

---@class CxNode
---@field kind string "Cx:..." or "Ext:..." node kind
---@field loc Loc source location

---@class CxTranslationUnit: CxNode
---@field kind string # "Cx:TranslationUnit"
---@field body CxNode[] top-level declarations and directives, in order

---@class CxDirective: CxNode
---@field kind string # "Cx:Directive"
---@field text string phase-4 directive text (splices stripped)
---@field raw string|nil verbatim logical line (splices kept; codegen emits this)

-- P3 core-language kinds (built by compiler/grammar/*, consumed by P4 codegen).
-- Conventions: `attrs` is string[] of raw `[[...]]` inners; absent optionals
-- are nil (never false); child order is source order.

---@class CxAttrsOnly: CxNode
---@field attrs string[]

---@class CxFunctionDecl: CxNode
---@field name string
---@field raw boolean true when declared via @escape
---@field params CxParam[]
---@field return_type CxNode a Cx:Type
---@field specifiers string[] e.g. {"static","inline"}
---@field attrs string[]
---@field body CxNode|nil Cx:Block, or nil for a prototype

---@class CxBindingDecl: CxNode
---@field introducer string "let" | "const" (+ "__auto_type" in gnu mode)
---@field specifiers string[] storage classes (static/extern/constexpr/thread_local/...), validated per position
---@field alignas string|nil raw alignas argument text
---@field alignas_kind string|nil "alignas" | "_Alignas" source spelling
---@field attrs string[]
---@field bindings CxBinding[]

---@class CxBinding: CxNode
---@field name string
---@field raw boolean
---@field type CxNode|nil Cx:Type (nil only with an inferred init)
---@field attrs string[]
---@field init CxNode|nil initializer (any init kind or expression)

---@class CxTypeAlias: CxNode
---@field name string
---@field raw boolean
---@field target CxNode Cx:Type or anonymous Cx:RecordDecl
---@field attrs string[]
---@field gnu_trailing string[]|nil trailing GNU attributes (gnu mode only)

---@class CxRecordDecl: CxNode
---@field tagkind string "struct" | "union"
---@field name string|nil nil for anonymous members
---@field raw_name boolean|nil
---@field members table[]|nil nil for `struct S;` forward declarations
---@field attrs string[]
---@field gnu_trailing string[]|nil trailing GNU attributes (gnu mode only)

---@class CxEnumDecl: CxNode
---@field name string|nil
---@field raw_name boolean|nil
---@field underlying CxNode|nil Cx:Type after `:` (nil when absent)
---@field enumerators CxEnumerator[]|nil nil for forward declarations
---@field attrs string[]

---@class CxEnumerator: CxNode
---@field name string
---@field raw boolean
---@field value CxNode|nil conditional expression
---@field attrs string[]

---@class CxStaticAssert: CxNode
---@field test CxNode conditional expression
---@field message string|nil raw string literal (with quotes)
---@field attrs string[]

---@class CxField: CxNode
---@field name string
---@field raw boolean
---@field type CxNode Cx:Type
---@field width CxNode|nil bit-field width (second colon)
---@field attrs string[]

---@class CxUnnamedBitfield: CxNode
---@field width CxNode

---@class CxParam: CxNode
---@field name string|nil nil for bare-type and `...` params
---@field raw boolean|nil
---@field type CxNode|nil Cx:Type (nil for `...`)
---@field ellipsis boolean

---@class CxType: CxNode
---@field quals string[] leading const/volatile/restrict
---@field atomic_prefix boolean `_Atomic` specifier before the base
---@field base CxNode one of the *Type bases below
---@field suffixes CxNode[] Cx:PtrSuffix/Cx:ArraySuffix, applied left to right

---@class CxBuiltinType: CxNode
---@field spell string e.g. "unsigned int"; "_BitInt" carries bitwidth instead
---@field bitwidth CxNode|nil conditional expression for _BitInt(N)

---@class CxTaggedType: CxNode
---@field tagkind string "struct" | "union" | "enum"
---@field name string

---@class CxNamedType: CxNode
---@field name string typedef/alias reference (unchecked at parse time)

---@class CxFuncType: CxNode
---@field params CxParam[] (name always nil here)
---@field ret CxNode Cx:Type

---@class CxParenType: CxNode
---@field inner CxNode Cx:Type

---@class CxTypeofType: CxNode
---@field op string "typeof" | "typeof_unqual" | "__typeof__"
---@field subject CxNode Cx:Type or expression
---@field is_type boolean

---@class CxAtomicType: CxNode
---@field inner CxNode Cx:Type

---@class CxComplexType: CxNode
---@field base CxBuiltinType
---@field flavor string "_Complex" | "_Imaginary" (named flavor: `kind` is reserved for the node kind)

---@class CxPtrSuffix: CxNode
---@field quals string[]

---@class CxArraySuffix: CxNode
---@field quals string[]
---@field static boolean [static N] contract
---@field star boolean [*] (unspecified bound)
---@field size CxNode|nil bound expression (nil for [] and [*])

---@class CxArrayLit: CxNode
---@field items CxNode[] initializers (empty for [])

---@class CxRecordLit: CxNode
---@field fields table[] {name: string, value: CxNode} in source order (empty for {})

---@class CxCompoundLit: CxNode
---@field static boolean `(static T)` storage form
---@field type CxNode Cx:Type
---@field init CxNode initializer (any init kind or scalar expression)

---@class CxCinit: CxNode
---@field start_offset integer byte offset of `{` in env.src
---@field end_offset integer byte offset just past `}` in env.src

---@class CxIdent: CxNode
---@field name string
---@field raw boolean

---@class CxIntLit: CxNode
---@field text string raw spelling
---@class CxFloatLit: CxNode
---@field text string raw spelling
---@class CxCharLit: CxNode
---@field text string raw spelling (prefix + quotes)

---@class CxStringLit: CxNode
---@field parts string[] raw adjacent literals (C concatenates)

---@class CxCall: CxNode
---@field fn CxNode
---@field args CxNode[] no-comma expressions

---@class CxIndex: CxNode
---@field arr CxNode
---@field idx CxNode

---@class CxMember: CxNode
---@field obj CxNode
---@field field string
---@field arrow boolean true for `->`

---@class CxPostfix: CxNode
---@field op string "++" | "--"
---@field target CxNode

---@class CxUnary: CxNode
---@field op string "&"|"*"|"+"|"-"|"~"|"!"|"++"|"--"
---@field target CxNode

---@class CxSizeof: CxNode
---@field subject CxNode Cx:Type or expression
---@field is_type boolean

---@class CxAlignof: CxNode
---@field type CxNode Cx:Type

---@class CxCastAs: CxNode
---@field target CxNode
---@field type CxNode Cx:Type (one node per `as`; chains nest left)

---@class CxBinary: CxNode
---@field op string
---@field l CxNode
---@field r CxNode

---@class CxTernary: CxNode
---@field cond CxNode
---@field then CxNode
---@field els CxNode

---@class CxAssign: CxNode
---@field op string "="|"*="|"/="|"%="|"+="|"-="|"<<="|">>="|"&="|"^="|"|="
---@field l CxNode
---@field r CxNode

---@class CxComma: CxNode
---@field items CxNode[] flat, in order

---@class CxGenericSel: CxNode
---@field controlling CxNode expression
---@field assocs CxGenericAssoc[]

---@class CxGenericAssoc: CxNode
---@field type CxNode|nil Cx:Type (nil for default)
---@field is_default boolean
---@field value CxNode no-comma expression

---@class CxBlock: CxNode
---@field items CxNode[]

---@class CxIf: CxNode
---@field cond CxNode
---@field then CxNode statement
---@field els CxNode|nil statement
---@field attrs string[]

---@class CxWhile: CxNode
---@field cond CxNode
---@field body CxNode statement
---@field attrs string[]

---@class CxDoWhile: CxNode
---@field body CxNode statement
---@field cond CxNode
---@field attrs string[]

---@class CxFor: CxNode
---@field init CxNode|nil Cx:BindingDecl (no trailing semi) or expression
---@field cond CxNode|nil
---@field step CxNode|nil
---@field body CxNode statement
---@field attrs string[]

---@class CxSwitch: CxNode
---@field cond CxNode
---@field body CxNode statement
---@field attrs string[]

---@class CxReturn: CxNode
---@field value CxNode|nil
---@field attrs string[]

---@class CxBreak: CxNode
---@field attrs string[]
---@class CxContinue: CxNode
---@field attrs string[]

---@class CxGoto: CxNode
---@field label string
---@field attrs string[]

---@class CxExprStmt: CxNode
---@field expr CxNode|nil (nil for bare `;`, possibly with attrs)
---@field attrs string[]

---@class CxLabel: CxNode
---@field name string
---@field raw boolean

---@class CxCase: CxNode
---@field value CxNode conditional expression

---@class CxDefault: CxNode

-- P5 GNU kinds. Parse markers live under Ext:Gnu:* (gnu grammar only) and
-- expand 1:1 into printable Cx:Gnu:* mirrors (or raise for non-gnu
-- targets). Codegen knows Cx:Gnu:* exhaustively and never sees Ext:*.
-- Leading `__attribute__((...))` / `__extension__` ride the plain `attrs`
-- channel as full raw text (verbatim rule in codegen); trailing record /
-- alias attributes use the gnu_trailing fields below.

---@class ExtGnuStmtExpr: CxNode
---@field items table[] block items; the last is the value expression
---@class CxGnuStmtExpr: CxNode
---@field items table[]

---@class ExtGnuCaseRange: CxNode
---@field lo table conditional expression
---@field hi table conditional expression
---@field attrs string[]
---@class CxGnuCaseRange: CxNode
---@field lo table
---@field hi table
---@field attrs string[]

---@class ExtGnuOmitMiddle: CxNode
---@field cond table
---@field els table
---@class CxGnuOmitMiddle: CxNode
---@field cond table
---@field els table

---@class ExtGnuComputedGoto: CxNode
---@field target table expression (`*` is the deref inside)
---@class CxGnuComputedGoto: CxNode
---@field target table

---@class ExtGnuLabelAddr: CxNode
---@field name string
---@class CxGnuLabelAddr: CxNode
---@field name string

---@class ExtGnuKRFunction: CxNode
---@field name string
---@field raw boolean
---@field specs string[] e.g. {"static"}
---@field attrs string[]
---@field ret table|nil Cx:Type (nil for implicit-int ancients)
---@field params string[] bare K&R parameter names
---@field lines table[] {start_offset, end_offset} decl-line slices
---@field body table Cx:Block
---@class CxGnuKRFunction: CxNode
---@field name string
---@field raw boolean
---@field specs string[]
---@field attrs string[]
---@field ret table|nil
---@field params string[]
---@field lines table[]
---@field body table

---@class ExtGnuNestedFunc: CxNode
---@field decl table Cx:FunctionDecl
---@class CxGnuNestedFunc: CxNode
---@field decl table

---@class ExtGnuLabelDecl: CxNode
---@field names string[]
---@class CxGnuLabelDecl: CxNode
---@field names string[]

---@class ExtGnuAsmStmt: CxNode
---@field quals string[] e.g. {"volatile"}
---@field start_offset integer payload start in env.src
---@field end_offset integer payload end in env.src
---@class CxGnuAsmStmt: CxNode
---@field quals string[]
---@field start_offset integer
---@field end_offset integer

---@class ExtGnuAlignof: CxNode
---@field type table Cx:Type
---@class CxGnuAlignof: CxNode
---@field type table

--- Transient wrapper for trailing `__attribute__((...))` (record bodies,
--- alias targets). The expander unwraps it onto gnu_trailing (gnu) or
--- raises (non-gnu); it never reaches codegen.
---@class ExtGnuTrailing: CxNode
---@field node table Cx:RecordDecl | Cx:TypeAlias
---@field attrs string[] raw attribute texts

-- Modules kinds. Parse markers live under Ext:Modules:* (modules grammar
-- only) and are consumed whole-graph by compiler/modules.lua before
-- expansion; they never reach codegen.
---@class ExtModulesImport: CxNode
---@field names string[] imported symbol names, in source order
---@field path string decoded module path as written (quotes stripped)
---@class ExtModulesExport: CxNode
---@field decl table the exported Cx declaration node

--- True when v looks like an AST node (plain table with a string kind).
--- Loc tables and trivia entries return false.
--- @param v any
--- @return boolean
function M.is_node(v)
    return type(v) == "table" and type(v.kind) == "string"
end

--- Build a node. The only sanctioned constructor, so `kind`/`loc`
--- are always present.
--- @param kind string "Cx:..." or "Ext:..." kind
--- @param loc Loc source location
--- @param fields table|nil extra fields (kind/loc keys are rejected)
--- @return CxNode
function M.node(kind, loc, fields)
    assert(type(kind) == "string" and (kind:match("^Cx:") ~= nil or kind:match("^Ext:") ~= nil),
        "ast.node: kind must be 'Cx:...' or 'Ext:...', got " .. tostring(kind))
    assert(type(loc) == "table" and type(loc.file) == "string"
        and type(loc.line) == "number" and type(loc.col) == "number",
        "ast.node: loc must be a Loc ({file, line, col, ...})")
    assert(fields == nil or type(fields) == "table", "ast.node: fields must be a table or nil")
    ---@type CxNode
    local n = { kind = kind, loc = loc }
    if fields ~= nil then
        assert(fields.kind == nil and fields.loc == nil, "ast.node: fields must not contain kind/loc")
        for k, v in pairs(fields) do
            n[k] = v
        end
    end
    return n
end

--- Build a Cx:TranslationUnit root.
--- @param loc Loc source location
--- @param body CxNode[] top-level nodes in order
--- @return CxTranslationUnit
function M.translation_unit(loc, body)
    assert(type(body) == "table", "ast.translation_unit: body must be an array of nodes")
    for i, child in ipairs(body) do
        assert(M.is_node(child), "ast.translation_unit: body[" .. i .. "] is not a node")
    end
    local n = M.node("Cx:TranslationUnit", loc, { body = body })
    ---@cast n CxTranslationUnit
    return n
end

--- Build a Cx:Directive node (verbatim preprocessor line).
--- @param loc Loc source location
--- @param text string directive logical line, without trailing newline
--- @return CxDirective
function M.directive(loc, text)
    assert(type(text) == "string", "ast.directive: text must be a string")
    local n = M.node("Cx:Directive", loc, { text = text })
    ---@cast n CxDirective
    return n
end

--- Visit tables in deterministic order: array part first (ipairs),
--- then remaining hash keys (pairs, skipping array indices).
--- @param t table
--- @param fn fun(v: any, k: any)
local function each_value(t, fn)
    local n = #t
    for i = 1, n do
        fn(t[i], i)
    end
    for k, v in pairs(t) do
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
            fn(v, k)
        end
    end
end

--- Pre-order walk. `fn(node)` runs before its children; returning
--- exactly `false` prunes that subtree. Traversal order is deterministic
--- (array parts in order). `loc` subtrees are never descended into.
--- @param root CxNode
--- @param fn fun(node: CxNode): boolean|nil
function M.walk(root, fn)
    assert(M.is_node(root), "ast.walk: root must be a node")
    assert(type(fn) == "function", "ast.walk: fn must be a function")
    local function visit_value(v)
        if M.is_node(v) then
            if fn(v) ~= false then
                for k2, v2 in pairs(v) do
                    if k2 ~= "loc" and k2 ~= "kind" then
                        visit_value(v2)
                    end
                end
            end
        elseif type(v) == "table" then
            each_value(v, function(item)
                visit_value(item)
            end)
        end
    end
    if fn(root) ~= false then
        for k, v in pairs(root) do
            if k ~= "loc" and k ~= "kind" then
                visit_value(v)
            end
        end
    end
end

--- Collect every `Ext:*` node in the tree (pre-order, deterministic).
--- Codegen (P4) asserts this is empty; expanders (P5) use it to find work.
--- @param root CxNode
--- @return CxNode[]
function M.collect_ext(root)
    assert(M.is_node(root), "ast.collect_ext: root must be a node")
    local out = {}
    M.walk(root, function(n)
        if n.kind:match("^Ext:") ~= nil then
            out[#out + 1] = n
        end
    end)
    return out
end

---@class ReplaceCtx
---@field root CxNode tree to search (whole-AST reads allowed; writes only via replace)

--- Find the direct parent container of `node` under `root`.
--- @param root CxNode
--- @param node CxNode
--- @return table|nil parent array or field table
--- @return any|nil key index or field name within parent
local function find_parent(root, node)
    local seen = {}
    local found_parent = nil
    local found_key = nil
    local function search(container)
        if found_parent ~= nil or seen[container] then
            return
        end
        seen[container] = true
        each_value(container, function(v, k)
            if found_parent ~= nil then
                return
            end
            if v == node then
                found_parent = container
                found_key = k
            elseif type(v) == "table" and k ~= "loc" then
                search(v)
            end
        end)
    end
    search(root)
    return found_parent, found_key
end

--- Replace `node` with `replacements` (one node, or an array of nodes;
--- an empty array deletes). Array members splice in place; struct fields
--- take exactly one node. Never hand-splice parent arrays — always use this.
--- @param ctx ReplaceCtx
--- @param node CxNode node to replace (must not be ctx.root itself)
--- @param replacements CxNode|CxNode[]
function M.replace(ctx, node, replacements)
    assert(type(ctx) == "table" and M.is_node(ctx.root), "ast.replace: ctx.root must be a node")
    assert(M.is_node(node), "ast.replace: node must be a node")
    assert(node ~= ctx.root, "ast.replace: cannot replace ctx.root itself")
    local list
    if M.is_node(replacements) then
        list = { replacements }
    else
        assert(type(replacements) == "table", "ast.replace: replacements must be a node or array of nodes")
        list = replacements
        for i, r in ipairs(list) do
            assert(M.is_node(r), "ast.replace: replacements[" .. i .. "] is not a node")
        end
    end
    local parent, key = find_parent(ctx.root, node)
    assert(parent ~= nil, "ast.replace: node not found under ctx.root")
    if type(key) == "number" then
        table.remove(parent, key)
        for i, r in ipairs(list) do
            table.insert(parent, key + i - 1, r)
        end
    else
        assert(#list == 1, "ast.replace: struct field takes exactly one node, got " .. #list)
        parent[key] = list[1]
    end
end

--- Deterministic s-expression dump for tests and debugging.
--- Field order is sorted; child order is source order. Locs are omitted
--- unless opts.loc == true (rendered compactly as loc=file:line:col).
--- @param root CxNode
--- @param opts table|nil {loc: boolean|nil}
--- @return string
function M.dump(root, opts)
    assert(M.is_node(root), "ast.dump: root must be a node")
    opts = opts or {}
    local with_loc = opts.loc == true
    local lines = {}

    --- @param v any
    --- @return string
    local function scalar(v)
        if type(v) == "string" then
            return string.format("%q", v)
        end
        return tostring(v)
    end

    --- @param t any
    --- @return boolean
    local function is_arr(t)
        if type(t) ~= "table" then
            return false
        end
        local n = #t
        for k in pairs(t) do
            if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
                return false
            end
        end
        return true
    end

    local put
    --- @param n CxNode
    --- @param ind string
    local function put_node(n, ind)
        local short = n.kind:match("^Cx:(.+)$") or n.kind
        local head = { "(" .. short }
        if with_loc and type(n.loc) == "table" then
            head[#head + 1] = string.format("loc=%s:%d:%d",
                tostring(n.loc.file), n.loc.line or 0, n.loc.col or 0)
        end
        local keys = {}
        for k in pairs(n) do
            if k ~= "kind" and k ~= "loc" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local kids = {}
        for _, k in ipairs(keys) do
            local v = n[k]
            if type(v) == "table" then
                kids[#kids + 1] = { k, v }
            else
                head[#head + 1] = tostring(k) .. "=" .. scalar(v)
            end
        end
        if #kids == 0 then
            lines[#lines + 1] = ind .. table.concat(head, " ") .. ")"
            return
        end
        lines[#lines + 1] = ind .. table.concat(head, " ")
        for _, kid in ipairs(kids) do
            local k, v = kid[1], kid[2]
            if is_arr(v) and #v > 0 then
                lines[#lines + 1] = ind .. "  " .. tostring(k) .. ":"
                for i, item in ipairs(v) do
                    lines[#lines + 1] = ind .. "    [" .. i .. "]:"
                    put(item, ind .. "      ")
                end
            elseif is_arr(v) then
                lines[#lines + 1] = ind .. "  " .. tostring(k) .. " = []"
            else
                lines[#lines + 1] = ind .. "  " .. tostring(k) .. ":"
                put(v, ind .. "    ")
            end
        end
        lines[#lines + 1] = ind .. ")"
    end
    --- @param v any
    --- @param ind string
    put = function(v, ind)
        if M.is_node(v) then
            put_node(v, ind)
        elseif type(v) == "table" then
            if is_arr(v) then
                if #v == 0 then
                    lines[#lines + 1] = ind .. "[]"
                else
                    for i, item in ipairs(v) do
                        lines[#lines + 1] = ind .. "[" .. i .. "]:"
                        put(item, ind .. "  ")
                    end
                end
            else
                local ks = {}
                for k in pairs(v) do
                    ks[#ks + 1] = k
                end
                table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
                if #ks == 0 then
                    lines[#lines + 1] = ind .. "{}"
                end
                for _, k in ipairs(ks) do
                    local item = v[k]
                    if type(item) == "table" then
                        lines[#lines + 1] = ind .. tostring(k) .. ":"
                        put(item, ind .. "  ")
                    else
                        lines[#lines + 1] = ind .. tostring(k) .. " = " .. scalar(item)
                    end
                end
            end
        else
            lines[#lines + 1] = ind .. scalar(v)
        end
    end
    put(root, "")
    return table.concat(lines, "\n") .. "\n"
end

return M
