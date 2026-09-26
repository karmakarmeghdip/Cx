-- P1 lexer unit tests: example.cx prefix golden plus targeted edge cases
-- (splicing, directives, @ident, keyword boundaries, literal matrix,
-- attributes, trivia attachment, error loc+snippet).
-- Each file must return `function run(ctx)`.

local PREFIX_LINES = 60
local SNAPSHOT = "tests/goldens/lexer_example_prefix.tokens"

--- Read a whole file or return nil.
--- @param path string
--- @return string|nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local body = f:read("*a")
    f:close()
    return body
end

--- First PREFIX_LINES lines of samples/example.cx, each newline-terminated.
--- @return string
local function example_prefix()
    local body = assert(read_file("samples/example.cx"), "samples/example.cx missing")
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
        if #lines >= PREFIX_LINES then
            break
        end
    end
    assert(#lines == PREFIX_LINES, "example.cx shorter than expected")
    return table.concat(lines, "\n") .. "\n"
end

--- Deterministic one-line quoting for snapshot values.
--- @param s string
--- @return string
local function esc(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"))
end

--- Serialize one trivia entry.
--- @param tag string "L" | "T"
--- @param tr table
--- @return string
local function fmt_trivia(tag, tr)
    return string.format("  %s %s \"%s\"", tag, tr.kind, esc(tr.value))
end

--- Serialize one token (header + trivia detail lines).
--- @param t table
--- @return string
local function fmt_token(t)
    local head = string.format("%d:%d-%d:%d %s \"%s\"%s",
        t.loc.line, t.loc.col, t.loc.end_line, t.loc.end_col,
        t.kind, esc(t.value), t.raw_ident and " raw" or "")
    local parts = { head }
    for _, tr in ipairs(t.leading) do
        parts[#parts + 1] = fmt_trivia("L", tr)
    end
    for _, tr in ipairs(t.trailing) do
        parts[#parts + 1] = fmt_trivia("T", tr)
    end
    return table.concat(parts, "\n")
end

--- Serialize a full token array for golden comparison.
--- @param toks table
--- @return string
local function serialize(toks)
    local parts = {}
    for _, t in ipairs(toks) do
        parts[#parts + 1] = fmt_token(t)
    end
    return table.concat(parts, "\n") .. "\n"
end

--- Kind sequence of a token array (debug shorthand).
--- @param toks table
--- @return string
local function kinds(toks)
    local out = {}
    for _, t in ipairs(toks) do
        out[#out + 1] = t.kind .. ":" .. t.value
    end
    return table.concat(out, " ")
end

---@param ctx TestCtx
return function(ctx)
    local lexer = require("compiler.lexer")

    ctx.check("lexer: example.cx prefix golden (lines 1-60)", function()
        local toks = lexer.lex(example_prefix(), "samples/example.cx")
        local text = serialize(toks)
        local snap = read_file(SNAPSHOT)
        if snap == nil then
            if ctx.bless then
                os.execute("mkdir -p tests/goldens 2>/dev/null")
                local f = assert(io.open(SNAPSHOT, "w"), "cannot write snapshot")
                f:write(text)
                f:close()
            else
                error("missing " .. SNAPSHOT .. " (run `luajit tests/run.lua --bless`, then review)", 0)
            end
        else
            assert(text == snap, "prefix token stream drifted (bless only after review)")
        end
    end)

    ctx.check("lexer: prefix opens with non-nesting comment fallout + #define", function()
        local toks = lexer.lex(example_prefix(), "samples/example.cx")
        -- Lines 3-9 exercise non-nesting /* */: the `/*` on line 8 closes at
        -- the first `*/` ("Be careful */"), so line 9's leftover `*/` lexes
        -- as two puncts (lenient lexer; the parser rejects it later).
        assert(toks[1].kind == "punct" and toks[1].value == "*", "tok1 wrong: " .. kinds(toks):sub(1, 80))
        assert(toks[1].loc.line == 9 and toks[1].loc.col == 1, "tok1 loc wrong")
        assert(toks[2].kind == "punct" and toks[2].value == "/", "tok2 wrong")
        local dir = toks[3]
        assert(dir.kind == "directive", "third token must be directive, got " .. dir.kind)
        assert(dir.value == "#define DAYS_IN_YEAR 365", "directive not opaque: " .. dir.value)
        assert(#dir.leading >= 3, "directive must carry comment/ws leading trivia")
        local comments = 0
        for _, tr in ipairs(dir.leading) do
            if tr.kind == "comment" then
                comments = comments + 1
            end
        end
        assert(comments >= 4, "directive leading must hold the macro comments")
    end)

    ctx.check("lexer: keywords match whole tokens only", function()
        local toks = lexer.lex("letter type_name functionx asy cinit9 let", "t.cx")
        local want = { "ident", "ident", "ident", "ident", "ident", "keyword" }
        assert(#toks == #want + 1, "token count wrong: " .. kinds(toks))
        for i, k in ipairs(want) do
            assert(toks[i].kind == k, "tok " .. i .. " must be " .. k .. ", got " .. toks[i].kind)
        end
        assert(toks[6].value == "let", "keyword value wrong")
    end)

    ctx.check("lexer: @ident is one ident token with raw flag", function()
        local toks = lexer.lex("let @let: int = 1;", "t.cx")
        assert(toks[1].kind == "keyword" and toks[1].value == "let", "let wrong")
        local id = toks[2]
        assert(id.kind == "ident", "@let must be ident, got " .. id.kind)
        assert(id.value == "let" and id.raw == "@let" and id.raw_ident == true,
            "@let payload wrong: value=" .. id.value .. " raw=" .. id.raw)
        assert(toks[3].kind == "punct" and toks[3].value == ":", "colon wrong")
        local ok = pcall(lexer.lex, "let @ 1;", "t.cx")
        assert(not ok, "stray @ must fail")
    end)

    ctx.check("lexer: line splicing happens before tokenizing", function()
        local toks = lexer.lex("in\\\nt x;", "t.cx")
        assert(toks[1].kind == "ident" and toks[1].value == "int",
            "spliced ident wrong: " .. kinds(toks))
        local dtoks = lexer.lex("#def\\\nine X 1\n", "t.cx")
        assert(dtoks[1].kind == "directive" and dtoks[1].value == "#define X 1",
            "spliced directive wrong: " .. kinds(dtoks))
        local ctoks = lexer.lex("// a\\\nb\nx", "t.cx")
        assert(ctoks[1].kind == "ident" and ctoks[1].value == "x",
            "spliced comment must join lines: " .. kinds(ctoks))
        assert(ctoks[1].leading[1].kind == "comment"
            and ctoks[1].leading[1].value == "// ab",
            "spliced comment text wrong")
    end)

    ctx.check("lexer: integer/float matrix stays raw with right kinds", function()
        local cases = {
            { "0b1010'0101", "int" }, { "1'000'000", "int" },
            { "42wb", "int" }, { "42uwb", "int" }, { "0xffu", "int" },
            { "0o17", "int" }, { "10", "int" },
            { "0.0f", "float" }, { "1e123", "float" }, { ".5", "float" },
            { "0x1p3", "float" }, { "1.5e-3", "float" },
        }
        for _, c in ipairs(cases) do
            local toks = lexer.lex("x = " .. c[1] .. ";", "t.cx")
            assert(toks[3].kind == c[2] and toks[3].value == c[1],
                c[1] .. " must lex as " .. c[2] .. ", got " .. kinds(toks))
        end
    end)

    ctx.check("lexer: strings/chars keep prefixes, escapes, quotes", function()
        local cases = {
            { '"hi"', "string" }, { '"a\\n"', "string" }, { 'u8"\\u00e9"', "string" },
            { "'a'", "char" }, { "'\\n'", "char" }, { "L'x'", "char" },
        }
        for _, c in ipairs(cases) do
            local toks = lexer.lex("x = " .. c[1] .. ";", "t.cx")
            assert(toks[3].kind == c[2] and toks[3].raw == c[1] and toks[3].value == c[1],
                c[1] .. " must lex as " .. c[2] .. " verbatim, got " .. kinds(toks))
        end
        -- A bare `u` before a string is an identifier, not a prefix.
        local toks = lexer.lex('u "s";', "t.cx")
        assert(toks[1].kind == "ident" and toks[1].value == "u", "bare u must be ident")
        assert(toks[2].kind == "string", "string after ident wrong")
    end)

    ctx.check("lexer: [[ ]] are single tokens, as is postfix", function()
        local toks = lexer.lex("[[nodiscard]] function f(): int; a[i] x as float", "t.cx")
        assert(toks[1].kind == "attr_open", "[[ must be attr_open, got " .. toks[1].kind)
        assert(toks[3].kind == "attr_close", "]] must be attr_close, got " .. toks[3].kind)
        local ks = kinds(toks)
        assert(ks:find("keyword:as", 1, true) ~= nil, "as keyword missing: " .. ks)
        assert(ks:find("punct:[", 1, true) ~= nil, "single [ missing: " .. ks)
    end)

    ctx.check("lexer: directives are opaque one-token lines", function()
        local toks = lexer.lex("#if defined(FEATURE)\n#define V 1\n#else\n#endif\nint a;\n", "t.cx")
        assert(toks[1].kind == "directive" and toks[1].value == "#if defined(FEATURE)",
            "directive 1 wrong")
        assert(toks[2].kind == "directive" and toks[2].value == "#define V 1",
            "directive 2 wrong")
        assert(toks[3].kind == "directive" and toks[4].kind == "directive",
            "branch directives wrong: " .. kinds(toks))
        assert(toks[5].kind == "ident" and toks[5].value == "int", "code after directives wrong")
        local ok = pcall(lexer.lex, "x # y;", "t.cx")
        assert(not ok, "mid-line # must fail")
    end)

    ctx.check("lexer: Loc tracks lines/cols/offsets exactly", function()
        local toks = lexer.lex("a\nbb", "t.cx")
        assert(toks[1].loc.line == 1 and toks[1].loc.col == 1, "a loc wrong")
        assert(toks[1].loc.end_line == 1 and toks[1].loc.end_col == 2, "a end wrong")
        assert(toks[1].loc.offset == 1, "a offset wrong")
        assert(toks[2].loc.line == 2 and toks[2].loc.col == 1, "bb loc wrong")
        assert(toks[2].loc.end_col == 3 and toks[2].loc.offset == 3, "bb end/offset wrong")
        assert(toks[3].kind == "eof" and toks[3].loc.line == 2 and toks[3].loc.col == 3,
            "eof loc wrong")
    end)

    ctx.check("lexer: trailing trivia stays same-line, rest leads next", function()
        local toks = lexer.lex("x = 1; // c\ny", "t.cx")
        local semi = toks[4]
        assert(semi.value == ";", "semi wrong: " .. kinds(toks))
        assert(#semi.trailing == 2, "; must trail ws+comment, got " .. #semi.trailing)
        assert(semi.trailing[2].kind == "comment" and semi.trailing[2].value == "// c",
            "trailing comment wrong")
        assert(toks[5].value == "y" and #toks[5].leading == 1
            and toks[5].leading[1].value == "\n", "newline must lead y")
    end)

    ctx.check("lexer: errors carry file:line:col + snippet", function()
        local ok, err = pcall(lexer.lex, 'let x = "ab\n', "t.cx")
        assert(not ok, "unterminated string must fail")
        assert(tostring(err):find("t.cx:1:12", 1, true) ~= nil, "loc missing: " .. tostring(err))
        assert(tostring(err):find("unterminated string", 1, true) ~= nil, "what missing: " .. tostring(err))
        assert(tostring(err):find('let x = "ab', 1, true) ~= nil, "snippet missing: " .. tostring(err))
        local ok2, err2 = pcall(lexer.lex, "/* never ends", "u.cx")
        assert(not ok2 and tostring(err2):find("u.cx:1:14", 1, true) ~= nil
            and tostring(err2):find("unterminated block comment", 1, true) ~= nil,
            "comment error wrong: " .. tostring(err2))
        local ok3 = pcall(lexer.lex, "let \\ x;", "t.cx")
        assert(not ok3, "stray backslash must fail")
    end)

    ctx.check("lexer: => is one punct (arrow types)", function()
        local toks = lexer.lex("((int) => int)*", "t.cx")
        local want_kinds = { "punct", "punct", "ident", "punct", "punct",
            "ident", "punct", "punct", "eof" }
        local want_values = { "(", "(", "int", ")", "=>", "int", ")", "*", "" }
        assert(#toks == #want_kinds, "token count wrong: " .. kinds(toks))
        for i, k in ipairs(want_kinds) do
            assert(toks[i].kind == k and toks[i].value == want_values[i],
                "tok " .. i .. " wrong: " .. toks[i].kind .. " " .. toks[i].value)
        end
    end)

    ctx.check("lexer: UTF-8 and \\u idents lex whole", function()
        local toks = lexer.lex("let Ångstrom: int = 1;", "t.cx")
        assert(toks[2].kind == "ident" and toks[2].value == "Ångstrom",
            "utf-8 ident wrong: " .. kinds(toks))
        local toks2 = lexer.lex("let \\u00C5x: int = 2;", "t.cx")
        assert(toks2[2].kind == "ident" and toks2[2].value == "\\u00C5x",
            "ucn ident wrong: " .. kinds(toks2))
        local ok, err = pcall(lexer.lex, "let \\uz: int;", "t.cx")
        assert(not ok and tostring(err):find("universal character", 1, true) ~= nil,
            "bad ucn must fail: " .. tostring(err))
    end)
end
