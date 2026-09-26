-- P2 parser-core tests: a NON-Cx toy grammar (arithmetic + postfix marks +
-- comma lists) proves the combinators, Pratt driver, suffix loop, env and
-- error format. Core must stay AST-agnostic, so toy nodes are plain tables.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")

    -- Forward-declared so prefix closures can recurse through both tables.
    local prefix, infix

    --- Toy number leaf.
    --- @param tok table
    --- @return table
    local function num_node(tok)
        return { op = "num", text = tok.value, loc = tok.loc }
    end

    prefix = {
        int = function(_, tok)
            return num_node(tok)
        end,
        float = function(_, tok)
            return num_node(tok)
        end,
        ["-"] = function(p, tok)
            return { op = "neg", r = core.expr(p, prefix, infix, 30), loc = tok.loc }
        end,
        ["("] = function(p, _)
            local e = core.expr(p, prefix, infix, 0)
            core.expect(p, "punct", ")", "')'")
            return e
        end,
    }

    --- Binary infix builder.
    --- @param opname string
    --- @return fun(p: table, left: table, tok: table, next_min: number): table
    local function bin(opname)
        return function(p, left, tok, next_min)
            return { op = opname, l = left,
                r = core.expr(p, prefix, infix, next_min), loc = tok.loc }
        end
    end

    infix = {
        ["+"] = { prec = 10, assoc = "left", parse = bin("add") },
        ["-"] = { prec = 10, assoc = "left", parse = bin("sub") },
        ["*"] = { prec = 20, assoc = "left", parse = bin("mul") },
        ["/"] = { prec = 20, assoc = "left", parse = bin("div") },
        ["^"] = { prec = 30, assoc = "right", parse = bin("pow") },
    }

    --- Parse src as one toy expression (real lexer tokens: proves core<->lexer fit).
    --- @param src string
    --- @return table tree
    --- @return table parser (for cursor-level tests, prefer parse_parts)
    local function parse_toy(src)
        local toks = lexer.lex(src, "t.toy")
        local env = core.new_env({ file = "t.toy", src = src })
        local p = core.new(toks, env)
        local tree = core.parse_unit(p,
            function(pp)
                return core.expr(pp, prefix, infix, 0)
            end, "expression")
        return tree, p
    end

    --- Cursor over src without running the top-level rule (cursor-level tests).
    --- @param src string
    --- @return table parser
    local function cursor(src)
        local toks = lexer.lex(src, "t.toy")
        local env = core.new_env({ file = "t.toy", src = src })
        return core.new(toks, env)
    end

    --- S-expression shape of a toy tree.
    --- @param n table
    --- @return string
    local function shape(n)
        if n.op == "num" then
            return n.text
        end
        if n.op == "neg" then
            return "(-" .. shape(n.r) .. ")"
        end
        local sym = { add = "+", sub = "-", mul = "*", div = "/", pow = "^" }
        local s = sym[n.op]
        assert(s ~= nil, "shape: unknown op " .. tostring(n.op))
        return "(" .. shape(n.l) .. s .. shape(n.r) .. ")"
    end

    ctx.check("core: Pratt precedence (* over +)", function()
        assert(shape(parse_toy("1+2*3")) == "(1+(2*3))", "precedence wrong")
    end)

    ctx.check("core: left assoc folds left, right assoc folds right", function()
        assert(shape(parse_toy("10-2-3")) == "((10-2)-3)", "left assoc wrong")
        assert(shape(parse_toy("2^3^4")) == "(2^(3^4))", "right assoc wrong")
    end)

    ctx.check("core: prefix minus and parens", function()
        assert(shape(parse_toy("-1*2")) == "((-1)*2)", "prefix precedence wrong")
        -- NB: `--5` lexes as one `--` token (longest match, like C);
        -- spaced `- -5` is the double-prefix form.
        assert(shape(parse_toy("- -5")) == "(-(-5))", "double prefix wrong")
        assert(shape(parse_toy("(1+2)*3")) == "((1+2)*3)", "parens wrong")
    end)

    ctx.check("core: truncated input errors with loc + snippet + caret", function()
        local ok, err = pcall(parse_toy, "1+")
        assert(not ok, "truncated expr must fail")
        local msg = tostring(err)
        assert(msg:find("t.toy:1:3", 1, true) ~= nil, "loc missing: " .. msg)
        assert(msg:find("expected expression", 1, true) ~= nil, "what missing: " .. msg)
        assert(msg:find("1+", 1, true) ~= nil, "snippet missing: " .. msg)
        assert(msg:find("  ^", 1, true) ~= nil, "caret missing: " .. msg)
    end)

    ctx.check("core: trailing garbage names end of input", function()
        local ok, err = pcall(parse_toy, "1 2")
        assert(not ok, "trailing garbage must fail")
        local msg = tostring(err)
        assert(msg:find("expected end of input, found '2'", 1, true) ~= nil, "msg wrong: " .. msg)
    end)

    ctx.check("core: choice backtracks soft failures in order", function()
        local function tw(word)
            return function(p)
                return core.token(p, "ident", word)
            end
        end
        local rule = core.choice(
            core.seq(tw("a"), tw("b")),
            core.seq(tw("a"), tw("c")))
        local p = cursor("a c")
        local out = core.parse_unit(p, rule, "toy")
        assert(out[1].value == "a" and out[2].value == "c", "second branch must win")
    end)

    ctx.check("core: committed expect raises at the right column", function()
        local rule = core.seq(
            function(p)
                return core.keyword(p, "let")
            end,
            function(p)
                return core.expect(p, "ident", nil, "name")
            end)
        local p = cursor("let 5")
        local ok, err = pcall(rule, p)
        assert(not ok, "bad binding must fail")
        err = tostring(err)
        assert(err:find("t.toy:1:5", 1, true) ~= nil, "col wrong: " .. err)
        assert(err:find("expected name, found '5'", 1, true) ~= nil, "msg wrong: " .. err)
    end)

    ctx.check("core: suffix_loop accumulates toy postfix marks in order", function()
        local function bang(p)
            if core.token(p, "punct", "!") then
                return { op = "fact" }
            end
            return nil
        end
        local function quest(p)
            if core.token(p, "punct", "?") then
                return { op = "opt" }
            end
            return nil
        end
        local p = cursor("5!?!")
        local n = core.token(p, "int")
        assert(n ~= nil and n.value == "5", "number wrong")
        local sufs = core.suffix_loop(p, { bang, quest })
        assert(#sufs == 3, "must collect 3 suffixes, got " .. #sufs)
        assert(sufs[1].op == "fact" and sufs[2].op == "opt" and sufs[3].op == "fact",
            "suffix order wrong")
        assert(p:eof(), "suffixes must consume to eof")
    end)

    ctx.check("core: delimited+sepBy lists, strict trailing comma", function()
        local function lp(p)
            return core.token(p, "punct", "(")
        end
        local function rp(p)
            return core.token(p, "punct", ")")
        end
        local function comma(p)
            return core.token(p, "punct", ",")
        end
        local function item(p)
            return core.token(p, "ident")
        end
        local list = core.delimited(lp, core.sepBy(item, comma), rp, "toy list")
        local p = cursor("(a, b, c)")
        local out = core.parse_unit(p, list, "toy list")
        assert(#out == 3 and out[1].value == "a" and out[3].value == "c", "list wrong")
        local p2 = cursor("(a, b,)")
        local ok, err = pcall(core.parse_unit, p2, list, "toy list")
        assert(not ok, "trailing comma must fail at close")
        assert(tostring(err):find("closing part of toy list", 1, true) ~= nil,
            "close msg wrong: " .. tostring(err))
    end)

    ctx.check("core: balanced returns the raw nested span", function()
        local p = cursor("{ a { b } c }")
        local span = core.balanced(p, "{", "}")
        assert(span ~= nil, "balanced must match")
        local vals = {}
        for _, t in ipairs(span) do
            vals[#vals + 1] = t.value
        end
        assert(table.concat(vals, " ") == "{ a { b } c }", "span wrong: " .. table.concat(vals, " "))
        assert(p:eof(), "balanced must consume the whole span")
        local p2 = cursor("a")
        assert(core.balanced(p2, "{", "}") == nil, "non-open must be soft nil")
        local p3 = cursor("{ a")
        local ok, err = pcall(core.balanced, p3, "{", "}")
        assert(not ok and tostring(err):find("to close", 1, true) ~= nil,
            "unterminated must be hard: " .. tostring(err))
    end)

    ctx.check("core: lookahead peeks, try rewinds, many guards empty match", function()
        local p = cursor("a b")
        local la = core.lookahead(function(pp)
            return core.token(pp, "ident", "a")
        end)
        assert(la(p) ~= nil and la(p).value == "a", "lookahead must see 'a'")
        assert(core.token(p, "ident", "a") ~= nil, "lookahead must not consume")
        local p2 = cursor("a c")
        local seq_ab = core.seq(
            function(pp)
                return core.token(pp, "ident", "a")
            end,
            function(pp)
                return core.token(pp, "ident", "b")
            end)
        assert(p2:try(seq_ab) == nil, "try must yield nil")
        assert(core.token(p2, "ident", "a") ~= nil, "try must rewind")
        local empty = function(_)
            return {}
        end
        local p3 = cursor("x")
        local ok, err = pcall(core.parse_unit, p3, core.many(empty), "toy")
        assert(not ok and tostring(err):find("without consuming", 1, true) ~= nil,
            "zero-width many must be loud: " .. tostring(err))
    end)

    ctx.check("core: many1/opt basics", function()
        local ints = core.many1(function(p)
            return core.token(p, "int")
        end)
        local p = cursor("1 2")
        local out = core.parse_unit(p, ints, "ints")
        assert(#out == 2, "many1 must take both")
        local p2 = cursor("x")
        assert(p2:try(ints) == nil, "many1 must be soft nil on empty")
        local signed = core.seq(
            core.opt(function(p)
                return core.token(p, "punct", "-")
            end),
            function(p)
                return core.expect(p, "int", nil, "number")
            end)
        local p3 = cursor("-5")
        local s = core.parse_unit(p3, signed, "signed")
        assert(s[1] ~= nil and s[2].value == "5", "opt must take '-'")
        local p4 = cursor("5")
        local s2 = core.parse_unit(p4, signed, "signed")
        assert(s2[1] == false and s2[2].value == "5", "opt must yield false cleanly")
    end)

    ctx.check("env: prelude visible, typedef shadowing follows scopes", function()
        local env = core.new_env({ file = "t.toy", src = "" })
        assert(env:is_typename("size_t"), "prelude size_t missing")
        assert(env:is_typename("va_list"), "prelude va_list missing")
        assert(not env:is_typename("foo"), "foo must start unknown")
        env:define_typedef("T")
        assert(env:is_typename("T"), "T must be visible")
        env:push_scope()
        env:define_typedef("U")
        assert(env:is_typename("U") and env:is_typename("T"), "inner scope wrong")
        env:pop_scope()
        assert(not env:is_typename("U"), "U must die with its scope")
        assert(env:is_typename("T"), "T must survive in global scope")
        assert(pcall(function()
            env:pop_scope()
        end) == false, "popping global scope must fail")
    end)

    ctx.check("env: tags live apart from typedefs", function()
        local env = core.new_env({ file = "t.toy", src = "" })
        env:define_tag("struct", "Point")
        assert(env:lookup_tag("struct", "Point"), "struct tag missing")
        assert(not env:lookup_tag("union", "Point"), "union must differ")
        assert(not env:is_typename("Point"), "tag must not leak into typedefs")
        env:push_scope()
        assert(env:lookup_tag("struct", "Point"), "outer tag must show through")
        env:pop_scope()
    end)

    ctx.check("env: target is read-only, dialect passes through", function()
        local env = core.new_env({ file = "t.toy", src = "", target = { cc = "clang" },
            dialect = { gnu = true } })
        assert(env.target.cc == "clang", "target read broken")
        assert(env.dialect.gnu == true, "dialect broken")
        local ok, err = pcall(function()
            env.target.cc = "msvc"
        end)
        assert(not ok and tostring(err):find("read-only", 1, true) ~= nil,
            "target write must raise: " .. tostring(err))
    end)

    ctx.check("core: cursor demands trailing eof, peek never yields nil", function()
        local env = core.new_env({ file = "t.toy", src = "a" })
        local lone = { kind = "ident", value = "a",
            loc = { file = "t.toy", line = 1, col = 1, end_line = 1, end_col = 2, offset = 1 } }
        local ok = pcall(core.new, { lone }, env)
        assert(not ok, "tokens without eof must fail")
        local p = cursor("a")
        assert(not p:eof(), "must not start at eof")
        p:next()
        assert(p:eof(), "must reach eof after 'a'")
        assert(p:peek().kind == "eof" and p:peek(5).kind == "eof", "peek must clamp to eof")
    end)
end
