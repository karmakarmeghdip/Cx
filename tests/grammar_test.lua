-- P3 grammar tests: per-construct units, 01-06 structural acceptance via
-- parse_file, strict negatives (07 + malformed snippets). Assertions are
-- structural (P4 goldens own output fidelity).
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")
    local ast = require("compiler.ast")
    local G = require("compiler.grammar_cx")

    --- Parse src with a unit rule (translation unit by default), demanding eof.
    --- @param src string
    --- @param rule string|nil G.rules entry (default parseTranslationUnit)
    --- @return table root
    local function unit(src, rule)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        return core.parse_unit(p, G.rules[rule or "parseTranslationUnit"], "test")
    end

    --- @param src string
    --- @return table expression node
    local function expr(src)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local e = G.rules.parseExpression(p)
        assert(e ~= nil, "expression must parse: " .. src)
        assert(p:eof(), "trailing tokens in: " .. src)
        return e
    end

    --- @param src string
    --- @return table Cx:Type node
    local function typ(src)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local t = G.rules.parseType(p)
        assert(t ~= nil, "type must parse: " .. src)
        assert(p:eof(), "trailing tokens in: " .. src)
        return t
    end

    --- @param src string block source
    --- @return table[] block items
    local function block(src)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local b = G.rules.parseBlock(p)
        assert(b ~= nil and p:eof(), "block must parse: " .. src)
        return b.items
    end

    --- @param src string statement source (must yield exactly one item)
    --- @return table statement node
    local function stmt(src)
        local items = block("{ " .. src .. " }")
        assert(#items == 1, "want one statement in: " .. src)
        return items[1]
    end

    --- @param src string
    --- @return table initializer node
    local function init(src)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local v = G.rules.parseInitializer(p)
        assert(v ~= nil, "initializer must parse: " .. src)
        assert(p:eof(), "trailing tokens in: " .. src)
        return v
    end

    --- Must-fail helper: unit() must raise mentioning `want`.
    --- @param src string
    --- @param want string|nil substring of the error
    local function must_fail(src, want)
        local ok, err = pcall(unit, src)
        assert(not ok, "must fail but parsed: " .. src)
        if want ~= nil then
            assert(tostring(err):find(want, 1, true) ~= nil,
                "error missing '" .. want .. "': " .. tostring(err))
        end
    end

    --- Collect nodes of a kind under root.
    --- @param root table
    --- @param kind string
    --- @return table[]
    local function find_all(root, kind)
        local out = {}
        ast.walk(root, function(n)
            if n.kind == kind then
                out[#out + 1] = n
            end
        end)
        return out
    end

    --- First node of a kind under root (or nil).
    --- @param root table
    --- @param kind string
    --- @return table|nil
    local function find_one(root, kind)
        local found = nil
        ast.walk(root, function(n)
            if found == nil and n.kind == kind then
                found = n
            end
        end)
        return found
    end

    -- Types ------------------------------------------------------------

    ctx.check("grammar: suffix order is significant", function()
        local a = typ("int[4]*")
        assert(a.suffixes[1].kind == "Cx:ArraySuffix", "first must be array")
        assert(a.suffixes[2].kind == "Cx:PtrSuffix", "second must be pointer")
        local b = typ("int*[4]")
        assert(b.suffixes[1].kind == "Cx:PtrSuffix", "first must be pointer")
        assert(b.suffixes[2].kind == "Cx:ArraySuffix", "second must be array")
        local c = typ("((int) => int)*[3]")
        assert(c.base.kind == "Cx:ParenType", "outer parens kept, got " .. c.base.kind)
        assert(c.base.inner.kind == "Cx:Type", "paren wraps a type")
        assert(c.base.inner.base.kind == "Cx:FuncType", "inner must be funtype")
        assert(#c.suffixes == 2, "funtype needs ptr+array suffixes")
    end)

    ctx.check("grammar: qualifiers sit in the right places", function()
        local t = typ("const int* const")
        assert(t.quals[1] == "const", "leading const lost")
        assert(t.suffixes[1].quals[1] == "const", "trailing const lost")
        local u = typ("int* restrict")
        assert(u.suffixes[1].quals[1] == "restrict", "restrict lost")
        local v = typ("const int* volatile")
        assert(v.suffixes[1].quals[1] == "volatile", "volatile lost")
    end)

    ctx.check("grammar: array bounds (static, const, VLA, star, empty)", function()
        local s = typ("int[static 4]")
        assert(s.suffixes[1].static == true, "static contract lost")
        assert(s.suffixes[1].size.text == "4", "bound wrong")
        local c = typ("int[const WIDTH]")
        assert(c.suffixes[1].quals[1] == "const", "bound quals lost")
        assert(c.suffixes[1].size.kind == "Cx:Ident", "VLA bound must be expr")
        local e = typ("char[]")
        assert(e.suffixes[1].size == nil and e.suffixes[1].star == false, "[] wrong")
        local st = typ("int[*]")
        assert(st.suffixes[1].star == true, "[*] wrong")
        local sz = typ("char[sizeof(text)]")
        assert(sz.suffixes[1].size.kind == "Cx:Sizeof", "sizeof bound wrong")
    end)

    ctx.check("grammar: typeof subjects (type vs expression gate)", function()
        local e = typ("typeof(x)")
        assert(e.base.kind == "Cx:TypeofType", "typeof node wrong")
        assert(e.base.is_type == false, "unknown name goes expr way")
        assert(e.base.subject.kind == "Cx:Ident", "subject must be ident")
        local t = typ("typeof_unqual(const int)")
        assert(t.base.is_type == true, "const int goes type way")
        assert(t.base.subject.base.spell == "int", "subject type wrong")
    end)

    ctx.check("grammar: funtype arrows and void elision", function()
        local f = typ("(int, char*) => int")
        assert(f.base.kind == "Cx:FuncType", "arrow base wrong")
        assert(#f.base.params == 2, "arrow params wrong")
        assert(f.base.params[2].type.suffixes[1].kind == "Cx:PtrSuffix", "char* wrong")
        local v = typ("(void) => void")
        assert(#v.base.params == 0, "(void) must elide")
        local e = typ("(...) => void")
        assert(e.base.params[1].ellipsis == true, "... param wrong")
    end)

    ctx.check("grammar: _Atomic, _BitInt, _Complex corners", function()
        local a = typ("_Atomic(int)")
        assert(a.base.kind == "Cx:AtomicType", "_Atomic(T) wrong")
        local b = typ("_Atomic int")
        assert(b.atomic_prefix == true, "_Atomic prefix lost")
        local c = typ("unsigned _BitInt(37)")
        assert(c.base.spell == "unsigned _BitInt", "bitint spell wrong: " .. c.base.spell)
        assert(c.base.bitwidth ~= nil, "bitint width lost")
        local d = typ("double _Complex")
        assert(d.base.kind == "Cx:ComplexType" and d.base.flavor == "_Complex",
            "complex wrong")
    end)

    -- Expressions --------------------------------------------------------

    ctx.check("grammar: as chains fold left, binds between * and unary", function()
        local c = expr("x as int as float")
        assert(c.kind == "Cx:CastAs", "outer must be cast")
        assert(c.target.kind == "Cx:CastAs", "chain must fold left")
        local d = expr("a as float / b")
        assert(d.kind == "Cx:Binary" and d.op == "/", "as must beat /")
        assert(d.l.kind == "Cx:CastAs", "lhs must be the cast")
        local n = expr("-x as int")
        assert(n.kind == "Cx:CastAs" and n.target.kind == "Cx:Unary",
            "-x as int must read (-x) as int")
        local v = expr("value as void")
        assert(v.type.base.spell == "void", "as void wrong")
    end)

    ctx.check("grammar: sizeof/alignof matrix", function()
        local t = expr("sizeof(int)")
        assert(t.kind == "Cx:Sizeof" and t.is_type == true, "sizeof(T) wrong")
        local e = expr("sizeof(value)")
        assert(e.is_type == false and e.subject.kind == "Cx:Ident", "sizeof(expr) wrong")
        local d = expr("sizeof(*heap)")
        assert(d.subject.kind == "Cx:Unary" and d.subject.op == "*", "sizeof(*p) wrong")
        local a = expr("alignof(max_align_t)")
        assert(a.kind == "Cx:Alignof", "alignof wrong")
        must_fail("let s: int = sizeof x;", "'(' after sizeof")
    end)

    ctx.check("grammar: full operator chain shape", function()
        local t = expr("a + b * c")
        assert(t.op == "+" and t.r.op == "*", "precedence wrong")
        local a = expr("x = y = 0")
        assert(a.kind == "Cx:Assign" and a.r.kind == "Cx:Assign", "assign must fold right")
        local c = expr("(p += 2, p * 3)")
        assert(c.kind == "Cx:Comma" and #c.items == 2, "comma wrong")
        local q = expr("ok ? a : b")
        assert(q.kind == "Cx:Ternary", "ternary wrong")
        local u = expr("!done && n > 0 || quit")
        assert(u.op == "||" and u.l.op == "&&", "logic precedence wrong")
    end)

    ctx.check("grammar: postfix nest (index/member/call/inc)", function()
        local i = expr("m[0][2]")
        assert(i.kind == "Cx:Index" and i.arr.kind == "Cx:Index", "index chain wrong")
        local m = expr("p->x")
        assert(m.kind == "Cx:Member" and m.arrow == true and m.field == "x", "arrow wrong")
        local cc = expr("takes_callback(cb)(7)")
        assert(cc.kind == "Cx:Call" and cc.fn.kind == "Cx:Call", "call-call wrong")
        local d = expr("*p++")
        assert(d.kind == "Cx:Unary" and d.target.kind == "Cx:Postfix", "*p++ wrong")
        local v = expr("va_arg(a, int)")
        assert(v.kind == "Cx:Call" and #v.args == 2, "va_arg shape wrong")
        assert(v.args[2].kind == "Cx:Ident", "type arg stays ident")
    end)

    ctx.check("grammar: _Generic associations incl. default", function()
        local g = expr("_Generic(v, int: 1, const int*: 2, default: 0)")
        assert(g.kind == "Cx:GenericSel" and #g.assocs == 3, "assoc count wrong")
        assert(g.assocs[2].type.suffixes[1].kind == "Cx:PtrSuffix", "assoc type wrong")
        assert(g.assocs[3].is_default == true and g.assocs[3].type == nil,
            "default assoc wrong")
    end)

    ctx.check("grammar: adjacent strings concatenate, compounds work", function()
        local s = expr('"a" "b"')
        assert(s.kind == "Cx:StringLit" and #s.parts == 2, "concat wrong")
        local c = unit("type P = int; let p: P = (P){x: 1};")
        local found = find_one(c, "Cx:CompoundLit")
        assert(found ~= nil and found.static == false, "compound lost")
        local a = init("(const int[])[1, 2]")
        assert(a.kind == "Cx:CompoundLit", "array compound wrong")
        assert(a.init.kind == "Cx:ArrayLit" and #a.init.items == 2, "compound init wrong")
        local p = expr("(x) + 1")
        assert(p.kind == "Cx:Binary", "(x)+1 must stay paren-plus, got " .. p.kind)
    end)

    -- Initializers ----------------------------------------------------------

    ctx.check("grammar: nested/matrix/empty/trailing-comma initializers", function()
        local m = init("[[1, 2], [3, 4]]")
        assert(m.kind == "Cx:ArrayLit" and #m.items == 2, "matrix wrong")
        assert(m.items[1].kind == "Cx:ArrayLit", "nested rows wrong")
        local e1 = init("[]")
        assert(e1.kind == "Cx:ArrayLit" and #e1.items == 0, "[] wrong")
        local e2 = init("{}")
        assert(e2.kind == "Cx:RecordLit" and #e2.fields == 0, "{} wrong")
        local t = init("[1, 2,]")
        assert(#t.items == 2, "array trailing comma wrong")
        local r = init("{x: 1,}")
        assert(#r.fields == 1 and r.fields[1].name == "x", "record trailing comma wrong")
        local s = init('"Cx"')
        assert(s.kind == "Cx:StringLit", "string init wrong")
    end)

    ctx.check("grammar: cinit stays an opaque byte range", function()
        local src = "let a: int[8] = cinit {[7] = 7, [2] = 2};"
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local root = core.parse_unit(p, G.rules.parseTranslationUnit, "test")
        local c = find_one(root, "Cx:Cinit")
        assert(c ~= nil, "cinit lost")
        assert(src:sub(c.start_offset, c.end_offset - 1) == "{[7] = 7, [2] = 2}",
            "cinit slice wrong")
    end)

    -- Declarations -----------------------------------------------------------

    ctx.check("grammar: bindings (storage, multi, inference, rules)", function()
        local r = unit("static let a: int = 1, b: int = 2;")
        local d = r.body[1]
        assert(d.kind == "Cx:BindingDecl" and #d.bindings == 2, "multi-binding wrong")
        assert(d.specifiers[1] == "static", "spec lost")
        local i = unit("let inferred = 40 + 2;")
        assert(i.body[1].bindings[1].type == nil, "inference must omit type")
        local u = unit("let value: int;")
        assert(u.body[1].bindings[1].init == nil, "uninit wrong")
        local g = unit("constexpr let step: int = 2;")
        assert(g.body[1].specifiers[1] == "constexpr", "constexpr must be a head spec")
        assert(g.body[1].introducer == "let", "constexpr prefixes let")
        must_fail("register let step: int = 2;", "not allowed")
        must_fail("constexpr limit: int = 2;", "external declaration")
        local t = unit("alignas(16) static let a: int [[maybe_unused]];")
        local b = t.body[1].bindings[1]
        assert(t.body[1].alignas == "16" and b.attrs[1] == "maybe_unused",
            "alignas/trailing attrs wrong")
        must_fail("let x;", "type or initializer")
        must_fail("let a, b: int = 1;", "type or initializer")
        must_fail("inline let x: int = 1;", "only allowed on functions")
        must_fail("auto x = 1;", "not allowed")
    end)

    ctx.check("grammar: functions (protos, params, attrs, specs)", function()
        local r = unit("static function add(l: int, r: int): int { return l + r; }")
        local f = r.body[1]
        assert(f.kind == "Cx:FunctionDecl" and f.body ~= nil, "def wrong")
        assert(#f.params == 2 and f.params[1].name == "l", "params wrong")
        local p = unit("function ignored(int, char*): int;")
        assert(p.body[1].body == nil, "proto needs nil body")
        assert(p.body[1].params[1].name == nil, "bare param keeps no name")
        local v = unit("function e(...): void; function f(void): int;")
        assert(v.body[1].params[1].ellipsis == true, "... wrong")
        assert(#v.body[2].params == 0, "(void) must elide")
        local a = unit('[[nodiscard]] static function f(x: int): int [[deprecated]];')
        assert(a.body[1].attrs[1] == "nodiscard", "leading attrs lost")
        assert(a.body[1].attrs[2] == "deprecated", "trailing attrs lost")
        local n = unit("static _Noreturn function t(): void;")
        assert(n.body[1].specifiers[2] == "_Noreturn", "noreturn lost")
        must_fail("function f()", "':'")
        must_fail("extern function f(): void;", "not allowed on functions")
        must_fail("constexpr function f(): void;", "not allowed on functions")
    end)

    ctx.check("grammar: aliases (incl. anonymous records, typename export)", function()
        local r = unit("type R = struct { x: int; };")
        assert(r.body[1].target.kind == "Cx:RecordDecl", "anon target wrong")
        assert(r.body[1].target.name == nil, "anon must be nameless")
        local s = unit("type P = int; let sz: size_t = sizeof(P);")
        local sz = find_one(s, "Cx:Sizeof")
        assert(sz ~= nil and sz.is_type == true, "alias must feed the gate")
        must_fail("static type X = int;", "not allowed on type aliases")
    end)

    ctx.check("grammar: records (recursion, bitfields, anon, asserts)", function()
        local r = unit("struct node { value: int; next: struct node*; };")
        local rec = r.body[1]
        assert(rec.members[2].type.base.kind == "Cx:TaggedType", "recursion wrong")
        local b = unit("struct bits { low: unsigned int: 3; : 0; high: signed int: 5; };")
        assert(b.body[1].members[1].width.text == "3", "width wrong")
        assert(b.body[1].members[2].kind == "Cx:UnnamedBitfield", ": 0 wrong")
        local n = unit("struct o { struct { l: int; }; tail: int; };")
        assert(n.body[1].members[1].kind == "Cx:RecordDecl", "anon member wrong")
        assert(n.body[1].members[1].name == nil, "anon must be nameless")
        local f = unit("struct s;")
        assert(f.body[1].members == nil, "forward needs nil body")
        local flex = unit("struct b { n: size_t; data: unsigned char[]; };")
        assert(flex.body[1].members[2].type.suffixes[1].size == nil, "flexible [] wrong")
    end)

    ctx.check("grammar: enums (underlying, trailing comma, enum attrs)", function()
        local r = unit("enum color : unsigned char { RED, GREEN = 10, BLUE, };")
        local e = r.body[1]
        assert(e.underlying.base.spell == "unsigned char", "underlying wrong")
        assert(#e.enumerators == 3 and e.enumerators[2].value.text == "10",
            "enumerators wrong")
        local a = unit("enum f { NONE [[deprecated]] = 0 };")
        assert(a.body[1].enumerators[1].attrs[1] == "deprecated", "enum attrs wrong")
        local fwd = unit("enum e : int;")
        assert(fwd.body[1].enumerators == nil, "enum forward wrong")
    end)

    ctx.check("grammar: misc decls (asserts, attrs-only, raw idents)", function()
        local s = unit('static_assert(sizeof(int) >= 2, "msg"); static_assert(1);')
        assert(#s.body == 2 and s.body[2].message == nil, "assert forms wrong")
        local a = unit("[[maybe_unused]]; ;")
        assert(a.body[1].kind == "Cx:AttrsOnly" and a.body[2].kind == "Cx:AttrsOnly",
            "attr-only/bare semi wrong")
        local r = unit("static let @let: int = 1;")
        assert(r.body[1].bindings[1].raw == true, "@escape lost")
    end)

    -- Statements -------------------------------------------------------------

    ctx.check("grammar: selection/iteration/jumps/labels", function()
        local i = stmt("if (a) { b(); } else if (c) { d(); } else { e(); }")
        assert(i.kind == "Cx:If" and i.els.kind == "Cx:If", "else-if chain wrong")
        local w = stmt("while (n > 0) { --n; }")
        assert(w.kind == "Cx:While", "while wrong")
        local d = stmt("do { x(); } while (ok);")
        assert(d.kind == "Cx:DoWhile", "do-while wrong")
        local f = stmt("for (let i: int = 0, n: int = 9; i < n; ++i) { x(i); }")
        assert(f.kind == "Cx:For" and #f.init.bindings == 2, "for-let wrong")
        local e = stmt("for (;;) { break; }")
        assert(e.init == nil and e.cond == nil and e.step == nil, "for(;;) wrong")
        local s = stmt("switch (v) { case 0: a(); break; default: b(); }")
        assert(s.kind == "Cx:Switch", "switch wrong")
        local g = stmt("goto done;")
        assert(g.kind == "Cx:Goto" and g.label == "done", "goto wrong")
        local done_items = block("{ done: ; }")
        assert(done_items[1].kind == "Cx:Label", "label wrong")
        assert(done_items[2].expr == nil, "empty stmt wrong")
        local trail = block("{ finished: }")
        assert(trail[1].kind == "Cx:Label", "trailing label wrong")
        local ft = stmt("[[fallthrough]];")
        assert(ft.expr == nil and ft.attrs[1] == "fallthrough", "attr stmt wrong")
        local r = stmt("return;")
        assert(r.kind == "Cx:Return" and r.value == nil, "bare return wrong")
        local b = stmt("{ static let calls: int; }")
        assert(b.items[1].kind == "Cx:BindingDecl", "block static let wrong")
    end)

    -- Cross-cutting -----------------------------------------------------------

    ctx.check("grammar: keyword table matches the lexer", function()
        -- Dialect-only operator words (added by extensions, gated by flags).
        local dialect_extra = { __alignof__ = true }
        local seen = {}
        for _, k in ipairs(G.keywords) do
            seen[k] = true
        end
        for k in pairs(require("compiler.lexer").KEYWORDS) do
            assert(seen[k] or dialect_extra[k],
                "lexer keyword missing from G: " .. k)
        end
        for _, k in ipairs(G.keywords) do
            assert(require("compiler.lexer").KEYWORDS[k], "G keyword missing from lexer: " .. k)
        end
    end)

    ctx.check("grammar: dump renders nested shapes", function()
        local root = unit("let x: int = 1;")
        local d = ast.dump(root)
        assert(d:find("(TranslationUnit", 1, true) ~= nil, "dump root wrong")
        assert(d:find("(BindingDecl", 1, true) ~= nil, "dump decl wrong")
        assert(d:find('name="x"', 1, true) ~= nil, "dump field wrong")
    end)

    ctx.check("grammar: parse_file seam works", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/01_hello_args.cx")
        assert(root.kind == "Cx:TranslationUnit" and #root.body == 3, "seam wrong")
    end)

    -- Samples 01-06 ------------------------------------------------------------

    ctx.check("sample 01: greeting (directive + 2 functions)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/01_hello_args.cx")
        assert(#root.body == 3, "01 item count wrong")
        assert(root.body[1].kind == "Cx:Directive", "01 include lost")
        assert(root.body[2].name == "greet" and root.body[3].name == "main", "01 fns wrong")
        assert(root.body[2].specifiers[1] == "static", "01 static lost")
        assert(#root.body[3].params == 2, "01 main params wrong")
    end)

    ctx.check("sample 02: numbers/control (7 items, for-let present)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/02_numbers_control.cx")
        assert(#root.body == 7, "02 item count wrong: " .. #root.body)
        local fors = find_all(root, "Cx:For")
        assert(#fors >= 1, "02 needs a for")
        local has_let = false
        for _, f in ipairs(fors) do
            if f.init ~= nil and f.init.kind == "Cx:BindingDecl" then
                has_let = true
            end
        end
        assert(has_let, "02 for-let init lost")
    end)

    ctx.check("sample 03: arrays (static bound, VLA, multi for-let)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/03_arrays_strings_memory.cx")
        assert(#root.body == 8, "03 item count wrong: " .. #root.body)
        local fns = {}
        for _, n in ipairs(root.body) do
            if n.kind == "Cx:FunctionDecl" then
                fns[#fns + 1] = n.name
            end
        end
        assert(#fns == 4 and fns[3] == "fill_row", "03 functions wrong")
        local fill = nil
        for _, n in ipairs(root.body) do
            if n.kind == "Cx:FunctionDecl" and n.name == "fill_row" then
                fill = n
            end
        end
        assert(fill ~= nil, "fill_row missing")
        assert(fill.params[1].type.suffixes[1].static == true, "static bound lost")
        local vlas = 0
        for _, b in ipairs(find_all(root, "Cx:Binding")) do
            if b.name == "variable_length" then
                vlas = vlas + 1
            end
        end
        assert(vlas == 1, "VLA binding lost")
    end)

    ctx.check("sample 04: records/callbacks (alias shapes, as-enum)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/04_records_callbacks.cx")
        assert(#root.body == 16, "04 item count wrong: " .. #root.body)
        local alias = nil
        for _, n in ipairs(root.body) do
            if n.kind == "Cx:TypeAlias" and n.name == "binary_operation" then
                alias = n
            end
        end
        assert(alias ~= nil, "alias missing")
        assert(alias.target.base.kind == "Cx:ParenType", "alias parens lost")
        assert(alias.target.base.inner.kind == "Cx:Type", "paren wraps a type")
        assert(alias.target.base.inner.base.kind == "Cx:FuncType", "alias funtype lost")
        assert(alias.target.suffixes[1].kind == "Cx:PtrSuffix", "alias ptr lost")
        local found = false
        for _, c in ipairs(find_all(root, "Cx:CastAs")) do
            if c.type.base.kind == "Cx:TaggedType" then
                found = true
            end
        end
        assert(found, "point.x as enum color lost")
    end)

    ctx.check("sample 05: declarations (constexpr spec, Generic, asserts)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/05_declarations_preprocessor.cx")
        local has_constexpr = false
        local has_alignas = false
        for _, d in ipairs(find_all(root, "Cx:BindingDecl")) do
            for _, s in ipairs(d.specifiers) do
                assert(s ~= "register", "05 must not use register (spec rejects it)")
                if s == "constexpr" then
                    has_constexpr = true
                end
            end
            assert(d.introducer == "let" or d.introducer == "const",
                "05 introducer must be let|const (spec)")
            if d.alignas ~= nil then
                has_alignas = true
            end
        end
        assert(has_constexpr, "05 constexpr spec lost")
        assert(has_alignas, "05 alignas lost")
        assert(#find_all(root, "Cx:GenericSel") == 1, "05 _Generic lost")
        assert(#find_all(root, "Cx:StaticAssert") == 1, "05 static_assert lost")
    end)

    ctx.check("sample 06: syntax reference (utf-8, ucn, embed, bitfields)", function()
        local Cx = require("compiler.init")
        local root = Cx.new():parse_file("samples/programs/06_syntax_reference.cx")
        assert(#root.body == 214, "06 item count wrong: " .. #root.body)
        local names = {}
        for _, b in ipairs(find_all(root, "Cx:Binding")) do
            names[b.name] = true
        end
        assert(names["Ångstrom"], "06 utf-8 ident lost")
        assert(names["\\u00C5ngstromAlias"], "06 ucn ident lost")
        local f = io.open("samples/programs/06_syntax_reference.cx", "r")
        assert(f ~= nil, "06 source missing")
        local src = f:read("*a")
        f:close()
        local embedded = false
        for _, c in ipairs(find_all(root, "Cx:Cinit")) do
            if src:sub(c.start_offset, c.end_offset - 1):find("#embed", 1, true) then
                embedded = true
            end
        end
        assert(embedded, "06 #embed cinit lost")
        local has_underlying = false
        for _, e in ipairs(find_all(root, "Cx:EnumDecl")) do
            if e.underlying ~= nil then
                has_underlying = true
            end
        end
        assert(has_underlying, "06 enum underlying lost")
        assert(#find_all(root, "Cx:UnnamedBitfield") == 1, "06 ': 0' lost")
        local fall = false
        for _, s in ipairs(find_all(root, "Cx:ExprStmt")) do
            if s.expr == nil and s.attrs[1] == "fallthrough" then
                fall = true
            end
        end
        assert(fall, "06 [[fallthrough]]; lost")
        local labels = {}
        for _, l in ipairs(find_all(root, "Cx:Label")) do
            labels[l.name] = true
        end
        assert(labels["finished"], "06 trailing label lost")
    end)

    -- Negatives ------------------------------------------------------------------

    ctx.check("negatives: strict rejects 07 and malformed snippets", function()
        local Cx = require("compiler.init")
        local ok = pcall(function()
            Cx.new():parse_file("samples/programs/07_gnu_extensions.cx")
        end)
        assert(not ok, "07 must fail in strict mode")
        must_fail("let a, b: int = 1;", "type or initializer")
        must_fail("function f()", "':'")
        must_fail("static type X = int;", "not allowed on type aliases")
    end)
end
