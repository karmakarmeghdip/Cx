-- P7 recovery tests: multi-error aggregates, partial trees, block-level
-- resume, the error cap, and loud propagation of real Lua bugs.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")
    local G = require("compiler.grammar_cx")

    --- Parse a unit WITHOUT the parse_unit aggregate: returns the partial
    --- root plus the env (whose .errors holds recovered failures).
    --- @param src string
    --- @param max_errors integer|nil
    --- @return table root
    --- @return table env
    local function parse_raw(src, max_errors)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src,
            grammar = G, max_errors = max_errors })
        local p = core.new(toks, env)
        local root = G.rules.parseTranslationUnit(p)
        assert(p:eof(), "recovery must consume to eof")
        return root, env
    end

    --- Parse expecting an aggregate failure from parse_unit.
    --- @param src string
    --- @return table aggregate error object
    local function must_aggregate(src)
        local toks = lexer.lex(src, "t.cx")
        local env = core.new_env({ file = "t.cx", src = src, grammar = G })
        local p = core.new(toks, env)
        local ok, err = pcall(core.parse_unit, p, G.rules.parseTranslationUnit, "test")
        assert(not ok, "must fail: " .. src)
        assert(core.is_parse_error(err), "must be a ParseError")
        return err
    end

    ctx.check("recovery: multi-error aggregate shape", function()
        local err = must_aggregate("let a: int = 1;\nlet broken !!!;\n???;\nlet b: int = 2;\n")
        local text = tostring(err)
        assert(text:find("2 parse errors:", 1, true) ~= nil, "header wrong:\n" .. text)
        assert(text:find("t.cx:2:12", 1, true) ~= nil, "first loc lost")
        assert(text:find("t.cx:3:1", 1, true) ~= nil, "second loc lost")
        assert(err.errors ~= nil and #err.errors == 2, "errors list wrong")
    end)

    ctx.check("recovery: single errors keep the classic shape", function()
        local toks = lexer.lex("let x: int = ;", "t.cx")
        local env = core.new_env({ file = "t.cx", src = "x", grammar = G })
        local p = core.new(toks, env)
        local ok, err = pcall(core.parse_unit, p, G.rules.parseTranslationUnit, "test")
        assert(not ok, "must fail")
        local text = tostring(err)
        assert(text:find("parse errors:", 1, true) == nil, "single must not aggregate")
        assert(text:find("t.cx:1:", 1, true) ~= nil, "loc missing: " .. text)
    end)

    ctx.check("recovery: valid decls survive around failures", function()
        local root, env = parse_raw(
            "let a: int = 1;\nlet broken !!!\nfunction f(): int { return 0; }\n???\nlet b: int = 2;\n")
        assert(#env.errors == 2, "two errors expected, got " .. #env.errors)
        local kinds = {}
        for _, n in ipairs(root.body) do
            kinds[#kinds + 1] = n.kind .. ":" .. (n.name or n.bindings and n.bindings[1].name or "")
        end
        assert(#root.body == 3, "a, f, b must survive: " .. table.concat(kinds, " "))
        assert(root.body[1].kind == "Cx:BindingDecl", "a lost")
        assert(root.body[2].kind == "Cx:FunctionDecl", "f lost")
        assert(root.body[3].kind == "Cx:BindingDecl", "b lost")
    end)

    ctx.check("recovery: block level resumes after bad statements", function()
        local root, env = parse_raw(
            "function f(): int {\nlet a: int = 1;\nbroken !!!\nlet b: int = 2;\nreturn a + b;\n}\n")
        assert(#env.errors == 1, "one error expected, got " .. #env.errors)
        local body = root.body[1].body
        assert(body.kind == "Cx:Block" and #body.items == 3, "siblings must survive")
        assert(body.items[3].kind == "Cx:Return", "return lost")
    end)

    ctx.check("recovery: directives survive error regions", function()
        local root, env = parse_raw("let broken !!!\n#include <x.h>\nlet ok: int = 1;\n")
        assert(#env.errors == 1, "one error expected")
        assert(#root.body == 2, "directive + decl must survive")
        assert(root.body[1].kind == "Cx:Directive", "directive lost")
    end)

    ctx.check("recovery: error cap aborts the flood", function()
        -- Each line is its own error region (`;` is the sync boundary).
        local big = ("!!!;\n"):rep(6)
        local toks = lexer.lex(big, "t.cx")
        local env = core.new_env({ file = "t.cx", src = big, grammar = G, max_errors = 3 })
        local p = core.new(toks, env)
        local ok, err = pcall(core.parse_unit, p, G.rules.parseTranslationUnit, "test")
        assert(not ok, "cap must trip")
        local text = tostring(err)
        assert(text:find("budget", 1, true) == nil, "cap is not budget")
        local count = 0
        for _ in text:gmatch("expected external declaration") do
            count = count + 1
        end
        assert(count == 3, "cap must stop at 3, got " .. count)
    end)

    ctx.check("recovery: real Lua bugs propagate untouched", function()
        local toks = lexer.lex("let a: int = 1;", "t.cx")
        local env = core.new_env({ file = "t.cx", src = "x", grammar = G })
        local p = core.new(toks, env)
        local ok, err = pcall(core.parse_unit, p, function()
            error("boom testified")
        end, "test")
        assert(not ok, "must fail")
        assert(not core.is_parse_error(err), "plain errors must not masquerade")
        assert(tostring(err):find("boom testified", 1, true) ~= nil, "message lost")
    end)

    ctx.check("recovery: unterminated block is a single clean error", function()
        local err = must_aggregate("function f(): void { let x: int = 1;")
        local text = tostring(err)
        assert(text:find("parse errors:", 1, true) == nil, "single, not aggregate")
        assert(text:find("'}' to close block", 1, true) ~= nil, "message wrong: " .. text)
    end)
end
