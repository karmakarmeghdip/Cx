-- P7 fuzzer: token soup + byte-mutated samples through lex + parse, under
-- the strict and GNU grammars. Oracle: every case either succeeds or fails
-- with a located error (`file:line:col:`); bare Lua crashes, assert traces
-- without locations, and hangs all fail the run. Deterministic for a fixed
-- --fuzz-seed (default 1); bounded counts keep the suite fast.
-- Each file must return `function run(ctx)`.

local SOUP_CASES = 150
local SOUP_MAX_TOKENS = 25
local MUT_PER_FILE = 15
local MUT_MAX_EDITS = 3

local SAMPLES = {
    "samples/programs/01_hello_args.cx",
    "samples/programs/02_numbers_control.cx",
    "samples/programs/03_arrays_strings_memory.cx",
    "samples/programs/04_records_callbacks.cx",
    "samples/programs/05_declarations_preprocessor.cx",
    "samples/programs/06_syntax_reference.cx",
    "samples/programs/07_gnu_extensions.cx",
}

-- Token soup alphabet (lexer-relevant spellings; nesting stays shallow
-- because cases are short, so C-stack overflow is out of reach).
local PIECES = {
    "let", "function", "type", "as", "cinit", "const", "constexpr",
    "sizeof", "alignof", "_Generic", "typeof", "struct", "union", "enum",
    "int", "char", "float", "double", "void", "unsigned", "long",
    "static", "extern", "return", "if", "else", "while", "for",
    "a", "foo", "x1", "_x", " guess", "Point",
    "0", "42", "1'000", "0xff", "0b101", "3.14", "1e3", "42wb",
    "'a'", "'\\n'", "\"s\"", "u8\"u\"",
    "+", "-", "*", "/", "%", "=", "==", "!=", "<", ">", "<=", ">=",
    "<<", ">>", "&&", "||", "!", "~", "&", "|", "^", "?", ":", ";",
    ",", ".", "...", "->", "=>", "(", ")", "[", "]", "{", "}",
    "[[", "]]", "++", "--", "+=", "#", "@foo", "@",
}

---@param ctx TestCtx
return function(ctx)
    local core = require("compiler.parser_core")
    local lexer = require("compiler.lexer")
    local base_G = require("compiler.grammar_cx")

    --- Deterministic PRNG (LCG): returns 1..n per call.
    --- @param seed integer
    --- @return fun(n: integer): integer
    local function rng(seed)
        local s = seed % 2147483648
        if s <= 0 then
            s = s + 2147483646
        end
        return function(n)
            s = (s * 1103515245 + 12345) % 2147483648
            return (s % n) + 1
        end
    end

    --- Assembled GNU grammar (built once; rules are stateless across parses).
    --- @return table G
    local function gnu_grammar()
        local extension = require("compiler.extension")
        local gnu = require("compiler.extensions.gnu")
        return extension.assemble(base_G, { { name = "gnu", mod = gnu } },
            { target = { cc = "clang", std = "gnu23" }, dialect = { gnu = true } })
    end

    --- The oracle: success, or a located file:line:col: failure.
    --- Anything else (Lua bugs, assert traces, hangs) fails loudly.
    --- @param err any caught value
    --- @param label string case description
    local function assert_clean(err, label)
        local msg = tostring(err)
        assert(msg:find(":%d+:%d+:", 1) ~= nil,
            "unclean failure in " .. label .. ": " .. msg:sub(1, 200))
    end

    --- Run one source through lex + unit + expression entries, both grammars.
    --- @param src string
    --- @param label string
    --- @param gnuG table assembled GNU grammar
    local function check_source(src, label, gnuG)
        for _, G in ipairs({ base_G, gnuG }) do
            local ok1, toks = pcall(lexer.lex, src, "fuzz.cx")
            if not ok1 then
                assert_clean(toks, label .. " lex")
            else
                for _, entry in ipairs({ "parseTranslationUnit", "parseExpression" }) do
                    local rule = G.rules[entry]
                    if rule ~= nil then
                        local env = core.new_env({ file = "fuzz.cx", src = src,
                            grammar = G })
                        local p = core.new(toks, env)
                        local ok2, err = pcall(core.parse_unit, p, rule, "test")
                        if not ok2 then
                            assert_clean(err, label .. " " .. entry)
                        end
                    end
                end
            end
        end
    end

    ctx.check("fuzz: token soup never escapes clean errors", function()
        local rand = rng(ctx.fuzz_seed or 1)
        local gnuG = gnu_grammar()
        for i = 1, SOUP_CASES do
            local parts = {}
            local n = rand(SOUP_MAX_TOKENS)
            for _ = 1, n do
                parts[#parts + 1] = PIECES[rand(#PIECES)]
            end
            local sep = (rand(2) == 1) and " " or "\n"
            check_source(table.concat(parts, sep), "soup#" .. i, gnuG)
        end
    end)

    ctx.check("fuzz: mutated samples never escape clean errors", function()
        local rand = rng((ctx.fuzz_seed or 1) * 31 + 7)
        local gnuG = gnu_grammar()
        local mut_bytes = "ab12_ ;,(){}[]+-*=!<>\"'"
        for _, path in ipairs(SAMPLES) do
            local f = assert(io.open(path, "r"), "missing " .. path)
            local src = f:read("*a")
            f:close()
            for i = 1, MUT_PER_FILE do
                local chars = {}
                for k = 1, #src do
                    chars[k] = src:sub(k, k)
                end
                local edits = rand(MUT_MAX_EDITS)
                for _ = 1, edits do
                    local pos = rand(#chars)
                    local bi = rand(#mut_bytes)
                    local byte = mut_bytes:sub(bi, bi)
                    local op = rand(4)
                    if op == 1 then
                        table.remove(chars, pos)
                    elseif op == 2 then
                        table.insert(chars, pos, byte)
                    elseif op == 3 then
                        if pos < #chars then
                            chars[pos], chars[pos + 1] = chars[pos + 1], chars[pos]
                        end
                    else
                        chars[pos] = byte
                    end
                    if #chars == 0 then
                        chars[1] = " "
                    end
                end
                check_source(table.concat(chars),
                    path .. ":mut#" .. i, gnuG)
            end
        end
    end)
end
