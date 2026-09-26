-- Lexer: .cx source text -> token array (P1, extended P3).
-- Contract (see AGENTS.md section 4):
--   * line-splicing (`\` + newline) is consumed token-by-token (never as a
--     pre-pass), so Loc stays PHYSICAL while logical lines join exactly as
--     C phase 2 specifies -- even inside comments, strings and directives.
--     Splices between tokens surface as "splice" trivia (verbatim kept).
--   * token `value` is the phase-4 view (splices stripped); `raw` keeps
--     file bytes. The two differ only when a splice hides inside a token.
--   * C23 literals (ints with hex/oct/bin, `'` separators, wb/uwb; floats;
--     chars; strings with u8/char8_t prefixes) carried as RAW text;
--   * `[[` / `]]` are single tokens; operators are `punct` (precedence
--     lives in the P3 grammar table, not here); Cx-only `=>` is one punct;
--   * identifiers accept UTF-8 bytes and `\uXXXX`/`\UXXXXXXXX` escapes
--     (columns stay byte-based);
--   * trivia (whitespace, // and non-nesting /* */ comments) attaches as
--     leading/trailing lists; directives (logical line starting with `#`
--     after splicing) are ONE opaque token, preserved verbatim;
--   * Cx keywords match whole tokens only; `@ident` lexes as ONE ident
--     token with raw_ident=true;
--   * every token carries Loc; first error aborts as `file:line:col` + snippet.
-- Columns and offsets count BYTES, not code points.

local M = {}

--- Cx keywords: whole-token match only (`letter` stays an identifier).
--- Introducers/operators reserved from C: they can never be plain names.
--- `__alignof__` is GNU-only (gated by dialect.gnu in the grammar).
M.KEYWORDS = {
    ["let"] = true,
    ["function"] = true,
    ["type"] = true,
    ["as"] = true,
    ["cinit"] = true,
    ["const"] = true,
    ["constexpr"] = true,
    ["sizeof"] = true,
    ["alignof"] = true,
    ["_Generic"] = true,
    ["__alignof__"] = true,
}

---@class LexLoc
---@field file string source file name
---@field line integer 1-based start line
---@field col integer 1-based start column (bytes)
---@field end_line integer 1-based end line (exclusive end position)
---@field end_col integer 1-based end column (bytes, exclusive)
---@field offset integer 1-based byte index of the start in the spliced source

---@class Trivia
---@field kind string "ws" | "comment" | "splice" (splice = `\<newline>` between tokens)
---@field value string verbatim text (comments keep their delimiters)
---@field loc LexLoc

---@class Token
---@field kind string ident|keyword|int|float|char|string|attr_open|attr_close|punct|directive|eof
---@field value string semantic text (@-sigil dropped for idents)
---@field raw string verbatim spelling (keeps @-sigil, prefixes, quotes)
---@field loc LexLoc
---@field leading Trivia[] trivia before the token (since the previous token)
---@field trailing Trivia[] same-line trivia after the token (spaces/comments only)
---@field raw_ident boolean|nil true when the source used the @ escape

-- Two-character punctuation (checked after the three-character forms).
-- Includes Cx-only `=>` (arrow function types).
local PUNCT2 = {
    ["=="] = true, ["!="] = true, ["<="] = true, [">="] = true,
    ["&&"] = true, ["||"] = true, ["++"] = true, ["--"] = true,
    ["->"] = true, ["=>"] = true, ["+="] = true, ["-="] = true,
    ["*="] = true, ["/="] = true, ["%="] = true, ["&="] = true,
    ["|="] = true, ["^="] = true, ["<<"] = true, [">>"] = true,
    ["##"] = true,
}

-- Single-character punctuation.
local PUNCT1 = {
    ["("] = true, [")"] = true, ["{"] = true, ["}"] = true,
    ["["] = true, ["]"] = true, [";"] = true, [","] = true,
    ["."] = true, [":"] = true, ["?"] = true, ["&"] = true,
    ["*"] = true, ["+"] = true, ["-"] = true, ["~"] = true,
    ["!"] = true, ["%"] = true, ["^"] = true, ["="] = true,
    ["<"] = true, [">"] = true, ["|"] = true, ["/"] = true,
}

--- Lex source text into a token array (always ends with one `eof` token).
--- Raises `filename:line:col: message` + snippet line + caret on first error.
--- @param src string source text
--- @param filename string|nil file name for diagnostics (default "<input>")
--- @return Token[]
function M.lex(src, filename)
    assert(type(src) == "string", "lexer.lex: src must be a string")
    filename = filename or "<input>"
    assert(type(filename) == "string", "lexer.lex: filename must be a string")

    -- Phase 1: line endings only. Splices are consumed while scanning so
    -- Loc stays physical; token `value` strips them, `raw` keeps them.
    src = src:gsub("\r\n", "\n"):gsub("\r", "\n")

    local n = #src
    local i = 1
    local line = 1
    local col = 1
    -- True once a token or comment appeared since the last newline.
    -- Only whitespace so far  =>  a `#` starts a directive line.
    local line_has_token = false
    local tokens = {}
    local pending = {}

    --- C phase-2 view of a slice: drop backslash-newline splices.
    --- @param s string
    --- @return string
    local function strip(s)
        return (s:gsub("\\\n", ""))
    end

    --- Byte at absolute position p, or "" past the end.
    --- @param p integer
    --- @return string
    local function at(p)
        if p > n then
            return ""
        end
        return src:sub(p, p)
    end

    --- Current byte or "" at end of input.
    --- @return string
    local function cur()
        return at(i)
    end

    --- Byte k positions ahead (k=1 is the next byte) or "".
    --- @param k integer
    --- @return string
    local function peek(k)
        return at(i + k)
    end

    --- Advance k bytes, tracking line/col.
    --- @param k integer|nil
    local function advance(k)
        k = k or 1
        for _ = 1, k do
            if i > n then
                return
            end
            if src:sub(i, i) == "\n" then
                line = line + 1
                col = 1
            else
                col = col + 1
            end
            i = i + 1
        end
    end

    --- Source text of the line containing absolute position pos (no newline).
    --- @param pos integer
    --- @return string
    local function line_text(pos)
        local s = pos
        while s > 1 and src:sub(s - 1, s - 1) ~= "\n" do
            s = s - 1
        end
        local e = pos
        while e <= n and src:sub(e, e) ~= "\n" do
            e = e + 1
        end
        return src:sub(s, e - 1)
    end

    --- Abort with file:line:col + snippet + caret (level 0: message is final).
    --- @param msg string
    local function fail(msg)
        error(string.format("%s:%d:%d: %s\n%s\n%s^",
            filename, line, col, msg, line_text(i), string.rep(" ", col - 1)), 0)
    end

    --- Push trivia consumed from absolute span [s, i).
    --- Comment values strip splices (phase-4 view); raw reconstruction
    --- uses `raw` on tokens plus verbatim trivia (P4).
    --- @param kind string "ws" | "comment" | "splice"
    --- @param s integer start index
    --- @param sl integer start line
    --- @param sc integer start col
    --- @return Trivia
    local function trivia(kind, s, sl, sc)
        local text = src:sub(s, i - 1)
        return {
            kind = kind,
            value = (kind == "comment") and strip(text) or text,
            loc = { file = filename, line = sl, col = sc,
                end_line = line, end_col = col, offset = s },
        }
    end

    -- Forward declaration: trailing trivia needs the comment scanner.
    local scan_comment

    --- Consume same-line spaces/tabs and comments (no newlines) as trailing trivia.
    --- @return Trivia[]
    local function take_trailing()
        local out = {}
        while i <= n do
            local c = cur()
            if c == " " or c == "\t" or c == "\v" or c == "\f" then
                local s, sl, sc = i, line, col
                while i <= n and (cur() == " " or cur() == "\t" or cur() == "\v" or cur() == "\f") do
                    advance()
                end
                out[#out + 1] = trivia("ws", s, sl, sc)
            elseif c == "/" and peek(1) == "/" then
                out[#out + 1] = scan_comment()
            elseif c == "/" and peek(1) == "*" then
                -- A block comment holding a newline belongs to the next
                -- token's leading trivia instead; leave it unconsumed.
                local close = src:find("*/", i + 2, true)
                if close == nil then
                    fail("unterminated block comment")
                end
                if src:sub(i, close + 1):find("\n", 1, true) ~= nil then
                    break
                end
                out[#out + 1] = scan_comment()
            else
                break
            end
        end
        return out
    end

    --- Emit one real token; pending trivia becomes its leading list.
    --- End position is captured before trailing trivia is consumed.
    --- @param kind string
    --- @param value string
    --- @param raw string|nil verbatim spelling (defaults to value)
    --- @param s integer start index
    --- @param sl integer start line
    --- @param sc integer start column
    --- @param extra table|nil additional fields (e.g. {raw_ident=true})
    --- @return Token
    local function emit(kind, value, raw, s, sl, sc, extra)
        ---@type Token
        local t = {
            kind = kind,
            value = value,
            raw = raw or value,
            loc = { file = filename, line = sl, col = sc,
                end_line = line, end_col = col, offset = s },
            leading = pending,
            trailing = {},
        }
        if extra ~= nil then
            for k, v in pairs(extra) do
                t[k] = v
            end
        end
        pending = {}
        t.trailing = take_trailing()
        tokens[#tokens + 1] = t
        line_has_token = true
        return t
    end

    --- Scan a // or /* */ comment at the current position (must start with /).
    --- Marks the line as token-bearing (comments are not whitespace). A
    --- spliced // comment continues onto the next physical line, like C.
    --- @return Trivia
    function scan_comment()
        local s, sl, sc = i, line, col
        if peek(1) == "/" then
            advance(2)
            while i <= n do
                if cur() == "\n" then
                    break
                elseif cur() == "\\" and peek(1) == "\n" then
                    advance(2)
                else
                    advance()
                end
            end
            line_has_token = true
            return trivia("comment", s, sl, sc)
        end
        assert(peek(1) == "*", "lexer: scan_comment called without comment start")
        advance(2)
        while true do
            if i > n then
                fail("unterminated block comment")
            end
            if cur() == "*" and peek(1) == "/" then
                advance(2)
                line_has_token = true
                return trivia("comment", s, sl, sc)
            end
            advance()
        end
    end

    --- Consume a run of charset chars, bridging splices (raw keeps them).
    --- @param set string Lua pattern class, e.g. "[0-9']"
    local function take_set(set)
        while i <= n do
            local d = src:match("^" .. set .. "+", i)
            if d ~= nil then
                advance(#d)
            elseif cur() == "\\" and peek(1) == "\n" then
                advance(2)
            else
                break
            end
        end
    end

    --- Consume a decimal digit/quote run: [0-9']+.
    local function take_digits()
        take_set("[0-9']")
    end

    --- Consume a literal suffix: letters/digits/underscores (wb, uwb, u, f, ...).
    local function take_suffix()
        take_set("[A-Za-z0-9_]")
    end

    --- Scan a number starting at a digit (current char is [0-9]).
    --- @return string kind "int" | "float"
    --- @return string value phase-4 spelling (splices stripped)
    --- @return string raw file spelling (splices kept)
    local function scan_number()
        local s = i
        local is_float = false
        if cur() == "0" and (peek(1) == "x" or peek(1) == "X") then
            advance(2)
            take_set("[0-9a-fA-F']")
            if cur() == "." and peek(1):match("[0-9a-fA-F]") ~= nil then
                is_float = true
                advance()
                take_set("[0-9a-fA-F']")
            end
            if (cur() == "p" or cur() == "P")
                and (peek(1):match("%d") ~= nil
                    or ((peek(1) == "+" or peek(1) == "-") and peek(2):match("%d") ~= nil)) then
                is_float = true
                advance()
                if cur() == "+" or cur() == "-" then
                    advance()
                end
                take_digits()
            end
            take_suffix()
        elseif cur() == "0" and (peek(1) == "b" or peek(1) == "B") then
            advance(2)
            take_set("[01']")
            take_suffix()
        else
            take_digits()
            if cur() == "." and peek(1):match("%d") ~= nil then
                is_float = true
                advance()
                take_digits()
            end
            if (cur() == "e" or cur() == "E")
                and (peek(1):match("%d") ~= nil
                    or ((peek(1) == "+" or peek(1) == "-") and peek(2):match("%d") ~= nil)) then
                is_float = true
                advance()
                if cur() == "+" or cur() == "-" then
                    advance()
                end
                take_digits()
            end
            take_suffix()
        end
        local raw = src:sub(s, i - 1)
        return (is_float and "float" or "int"), strip(raw), raw
    end

    --- Scan a number starting with `.` (next char is a digit; float by shape).
    --- @return string kind (always "float")
    --- @return string value phase-4 spelling
    --- @return string raw file spelling
    local function scan_dot_number()
        local s = i
        advance() -- the dot
        take_digits()
        if (cur() == "e" or cur() == "E")
            and (peek(1):match("%d") ~= nil
                or ((peek(1) == "+" or peek(1) == "-") and peek(2):match("%d") ~= nil)) then
            advance()
            if cur() == "+" or cur() == "-" then
                advance()
            end
            take_digits()
        end
        take_suffix()
        local raw = src:sub(s, i - 1)
        return "float", strip(raw), raw
    end

    --- Scan a string or char literal. The opening quote is at i; prefix
    --- (u8/u/U/L) was already consumed when present. Backslash-newline
    --- splices vanish from the value (phase-4 view) but stay in raw.
    --- @param quote string '"' | "'"
    --- @param what string "string" | "char" (for error messages)
    --- @param s integer start index (includes any prefix)
    --- @return string value phase-4 spelling
    --- @return string raw file spelling
    local function scan_quoted(quote, what, s)
        advance() -- opening quote
        while true do
            local c = cur()
            if c == "" or c == "\n" then
                fail("unterminated " .. what .. " literal")
            elseif c == "\\" then
                advance(2)
                if i > n + 1 then
                    fail("unterminated " .. what .. " literal")
                end
            elseif c == quote then
                advance()
                local raw = src:sub(s, i - 1)
                return strip(raw), raw
            else
                advance()
            end
        end
    end

    --- Identifier start (letters/underscore)? The @ escape is handled separately.
    --- High bytes (>= 0x80) continue UTF-8 sequences: C23 extended
    --- identifiers (e.g. `Ångstrom`) lex as one ident, columns stay byte-based.
    --- @param c string
    --- @return boolean
    local function is_word_start(c)
        if c == "" then
            return false
        end
        if c:match("[A-Za-z_]") ~= nil then
            return true
        end
        local b = c:byte(1)
        return b ~= nil and b >= 128
    end

    --- Consume one identifier (word chars, high bytes, `\uXXXX`/`\UXXXXXXXX`
    --- escapes which may also START the identifier). Splices bridge through
    --- (stripped from the value by the caller, kept in raw).
    --- @return string raw spelling
    local function take_word()
        local s = i
        while true do
            local w = src:match("[A-Za-z0-9_\128-\255]*", i)
            assert(w ~= nil, "lexer: unreachable word state")
            advance(#w)
            if cur() == "\\" and peek(1) == "\n" then
                advance(2)
            elseif cur() == "\\" and (peek(1) == "u" or peek(1) == "U") then
                local digits = (peek(1) == "u") and 4 or 8
                local esc = src:sub(i, i + 1 + digits)
                if #esc ~= 2 + digits or esc:match("^\\[uU][0-9a-fA-F]+$") == nil then
                    fail("bad universal character name in identifier")
                end
                advance(2 + digits)
            else
                break
            end
        end
        return src:sub(s, i - 1)
    end

    while i <= n do
        local c = cur()
        if c == " " or c == "\t" or c == "\v" or c == "\f" then
            local s, sl, sc = i, line, col
            while i <= n and (cur() == " " or cur() == "\t" or cur() == "\v" or cur() == "\f") do
                advance()
            end
            pending[#pending + 1] = trivia("ws", s, sl, sc)
        elseif c == "\n" then
            local s, sl, sc = i, line, col
            advance()
            pending[#pending + 1] = trivia("ws", s, sl, sc)
            line_has_token = false
        elseif c == "/" and (peek(1) == "/" or peek(1) == "*") then
            pending[#pending + 1] = scan_comment()
        elseif c == "#" then
            if line_has_token then
                fail("unexpected '#' (a directive must start the line)")
            end
            local s, sl, sc = i, line, col
            while i <= n do
                if cur() == "\n" then
                    break
                elseif cur() == "\\" and peek(1) == "\n" then
                    advance(2)
                else
                    advance()
                end
            end
            local text = src:sub(s, i - 1)
            emit("directive", strip(text), text, s, sl, sc)
        elseif c == "@" then
            local s, sl, sc = i, line, col
            advance() -- the @
            local w0 = i
            local name = take_word()
            if i == w0 then
                fail("stray '@' (must be followed by an identifier)")
            end
            emit("ident", strip(name), "@" .. name, s, sl, sc, { raw_ident = true })
        elseif is_word_start(c) or (c == "\\" and (peek(1) == "u" or peek(1) == "U")) then
            -- Prefixed literals (u8"..", u'..', L"..") win over identifiers.
            local pre = src:match("^u8", i) or src:match("^[uUL]", i)
            local after = (pre ~= nil) and at(i + #pre) or ""
            if pre ~= nil and (after == '"' or after == "'") then
                local s, sl, sc = i, line, col
                advance(#pre)
                local kind = (after == '"') and "string" or "char"
                local value, raw = scan_quoted(after, kind, s)
                emit(kind, value, raw, s, sl, sc)
            else
                local s, sl, sc = i, line, col
                local word = take_word()
                local norm = strip(word)
                if M.KEYWORDS[norm] then
                    emit("keyword", norm, word, s, sl, sc)
                else
                    emit("ident", norm, word, s, sl, sc)
                end
            end
        elseif c:match("%d") ~= nil then
            local s, sl, sc = i, line, col
            local kind, value, raw = scan_number()
            emit(kind, value, raw, s, sl, sc)
        elseif c == "." then
            if peek(1):match("%d") ~= nil then
                local s, sl, sc = i, line, col
                local kind, value, raw = scan_dot_number()
                emit(kind, value, raw, s, sl, sc)
            else
                local s, sl, sc = i, line, col
                if src:sub(i, i + 2) == "..." then
                    advance(3)
                    emit("punct", "...", nil, s, sl, sc)
                elseif c == "." then
                    advance()
                    emit("punct", ".", nil, s, sl, sc)
                end
            end
        elseif c == '"' or c == "'" then
            local s, sl, sc = i, line, col
            local kind = (c == '"') and "string" or "char"
            local value, raw = scan_quoted(c, kind, s)
            emit(kind, value, raw, s, sl, sc)
        elseif c == "[" and peek(1) == "[" then
            local s, sl, sc = i, line, col
            advance(2)
            emit("attr_open", "[[", nil, s, sl, sc)
        elseif c == "]" and peek(1) == "]" then
            local s, sl, sc = i, line, col
            advance(2)
            emit("attr_close", "]]", nil, s, sl, sc)
        elseif c == "\\" and peek(1) == "\n" then
            -- Spliced newline between tokens: logical line continues
            -- (line_has_token untouched), trivia preserved for P4.
            local s, sl, sc = i, line, col
            advance(2)
            pending[#pending + 1] = trivia("splice", s, sl, sc)
        elseif c == "\\" then
            fail("stray backslash")
        else
            local three = src:sub(i, i + 2)
            local two = src:sub(i, i + 1)
            local s, sl, sc = i, line, col
            if three == "<<=" or three == ">>=" then
                advance(3)
                emit("punct", three, nil, s, sl, sc)
            elseif PUNCT2[two] then
                advance(2)
                emit("punct", two, nil, s, sl, sc)
            elseif PUNCT1[c] then
                advance()
                emit("punct", c, nil, s, sl, sc)
            else
                fail("unexpected character '" .. c .. "'")
            end
        end
    end

    ---@type Token
    local eof = {
        kind = "eof",
        value = "",
        raw = "",
        loc = { file = filename, line = line, col = col,
            end_line = line, end_col = col, offset = n + 1 },
        leading = pending,
        trailing = {},
    }
    tokens[#tokens + 1] = eof
    return tokens
end

return M
