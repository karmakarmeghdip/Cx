-- Grammar-agnostic recursive-descent + Pratt core (P2).
-- Knows NOTHING about Cx: it threads tokens and a ParseEnv, and lets the
-- caller (grammar table, P3+) build whatever values it wants.
-- Failure model: rules return nil on SOFT failure (backtrackable via marks);
-- committed mistakes RAISE a string error `file:line:col: ...` + snippet.
-- No left recursion, no memoization: keep `choice` to 1-token lookahead and
-- commit early with `expect` (see AGENTS.md section 6a).

local M = {}

---@class LexToken
---@field kind string token kind (ident, keyword, int, punct, ...)
---@field value string semantic text
---@field raw string|nil verbatim spelling (nil only for synthesized tokens)
---@field raw_ident boolean|nil true for @-escaped identifiers
---@field leading table|nil trivia before the token
---@field trailing table|nil same-line trivia after the token
---@field loc Loc source location

---@class EnvOpts
---@field file string|nil source name for diagnostics (default "<input>")
---@field src string|nil full source text for snippets (default "")
---@field target table|nil CxTarget (stored behind a read-only proxy)
---@field dialect table|nil dialect flags (default {})
---@field grammar table|nil assembled grammar (rules/prefix/infix resolution)
---@field max_errors integer|nil recovery cap (default MAX_ERRORS)

---@class ParseEnv
---@field file string source name for diagnostics
---@field src string full source text (snippet lookups only)
---@field dialect table dialect flags (grammar-owned, e.g. {gnu=true})
---@field target table read-only CxTarget proxy (writes raise)
---@field errors table[] collected parse errors (P7 recovery)
---@field max_errors integer recovery cap (default MAX_ERRORS)
---@field scopes table[] scope stack; scopes[1] is global (internal)
---@field line_starts integer[] byte index where each 1-based line starts (internal)
---@field grammar table|nil assembled grammar (set by the driver; rules resolve through it)
---@field push_scope fun(self: ParseEnv) push a block scope
---@field pop_scope fun(self: ParseEnv) pop the innermost scope (never global)
---@field define_typedef fun(self: ParseEnv, name: string) define alias in innermost scope
---@field is_typename fun(self: ParseEnv, name: string): boolean visible alias?
---@field define_tag fun(self: ParseEnv, tagkind: string, name: string) define struct/union/enum tag
---@field lookup_tag fun(self: ParseEnv, tagkind: string, name: string): boolean visible tag?
---@field line_text fun(self: ParseEnv, n: integer): string|nil source of 1-based line n
---@field snippet fun(self: ParseEnv, loc: table): string|nil "line\n  ^" for a loc
---@field push_scope fun(self: ParseEnv) push a block scope
---@field pop_scope fun(self: ParseEnv) pop the innermost scope (never global)
---@field define_typedef fun(self: ParseEnv, name: string) define alias in innermost scope
---@field is_typename fun(self: ParseEnv, name: string): boolean visible alias?
---@field define_tag fun(self: ParseEnv, tagkind: string, name: string) define struct/union/enum tag
---@field lookup_tag fun(self: ParseEnv, tagkind: string, name: string): boolean visible tag?
---@field line_text fun(self: ParseEnv, n: integer): string|nil source of 1-based line n
---@field snippet fun(self: ParseEnv, loc: table): string|nil "line\n  ^" for a loc

---@class InfixSpec
---@field prec number precedence level (higher binds tighter)
---@field assoc string "left" | "right"
---@field parse fun(p: Parser, left: any, tok: LexToken, next_min: number): any

---@class Parser
---@field env ParseEnv
---@field peek fun(self: Parser, n?: integer): LexToken
---@field next fun(self: Parser): LexToken
---@field eof fun(self: Parser): boolean
---@field mark fun(self: Parser): integer
---@field reset fun(self: Parser, m: integer)
---@field try fun(self: Parser, rule: Rule): any
---@field unget fun(self: Parser, tok: LexToken)
---@field fail fun(self: Parser, what: string)
---@field fail_at fun(self: Parser, tok: LexToken, what: string)

---@alias Rule fun(p: Parser): any

-- C prelude: standard typedef names visible without any header parsing.
-- Headers stay opaque (AGENTS.md); the parser only needs to RECOGNIZE these.
local PRELUDE = {
    "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
    "va_list", "wchar_t", "char16_t", "char32_t",
}

--- Wrap t so reads pass through and any write raises. env.target must be
--- branchable but never mutable outside target.lua (AGENTS.md section 10).
--- @param t table|nil
--- @return table read-only proxy
local function readonly(t, what)
    assert(t == nil or type(t) == "table", "readonly: table or nil required")
    local inner = t or {}
    return setmetatable({}, {
        __index = inner,
        __newindex = function(_, k)
            error(what .. " is read-only (attempt to write '" .. tostring(k) .. "')", 2)
        end,
    })
end

--- Byte indices where each 1-based line starts.
--- @param src string
--- @return integer[]
local function compute_starts(src)
    local starts = { 1 }
    for k = 1, #src do
        if src:sub(k, k) == "\n" then
            starts[#starts + 1] = k + 1
        end
    end
    return starts
end

--- Create a ParseEnv. The C prelude is defined in the global scope.
--- @param opts EnvOpts|nil
--- @return ParseEnv
function M.new_env(opts)
    opts = opts or {}
    assert(opts.file == nil or type(opts.file) == "string", "new_env: file must be a string")
    assert(opts.src == nil or type(opts.src) == "string", "new_env: src must be a string")
    assert(opts.dialect == nil or type(opts.dialect) == "table", "new_env: dialect must be a table")
    assert(opts.grammar == nil or type(opts.grammar) == "table", "new_env: grammar must be a table")
    assert(opts.max_errors == nil or type(opts.max_errors) == "number",
        "new_env: max_errors must be a number")
    local src = opts.src or ""
    local env = {
        file = opts.file or "<input>",
        src = src,
        dialect = opts.dialect or {},
        target = readonly(opts.target, "env.target"),
        errors = {},
        max_errors = opts.max_errors or M.MAX_ERRORS,
        scopes = { { typedefs = {}, tags = {} } },
        line_starts = compute_starts(src),
        grammar = opts.grammar,
    }
    for _, name in ipairs(PRELUDE) do
        env.scopes[1].typedefs[name] = true
    end
    local out = setmetatable(env, { __index = M.env })
    ---@cast out ParseEnv
    return out
end

-- ParseEnv methods (resolved through the env metatable; field types live on
-- the ParseEnv class above).
M.env = {}

--- Push a block scope (typedefs/tags inside die with it).
--- @param env ParseEnv
function M.env.push_scope(env)
    env.scopes[#env.scopes + 1] = { typedefs = {}, tags = {} }
end

--- Pop the innermost scope. The global scope is never popped.
--- @param env ParseEnv
function M.env.pop_scope(env)
    assert(#env.scopes > 1, "parser_core: cannot pop the global scope")
    table.remove(env.scopes)
end

--- Define a typedef alias in the innermost scope.
--- @param env ParseEnv
--- @param name string
function M.env.define_typedef(env, name)
    assert(type(name) == "string", "define_typedef: name must be a string")
    env.scopes[#env.scopes].typedefs[name] = true
end

--- Semantic predicate: is `name` a visible typedef alias (incl. prelude)?
--- This is the lookup a pure CFG cannot do (sizeof(T) vs sizeof(expr), ...).
--- @param env ParseEnv
--- @param name string
--- @return boolean
function M.env.is_typename(env, name)
    for i = #env.scopes, 1, -1 do
        if env.scopes[i].typedefs[name] then
            return true
        end
    end
    return false
end

--- Define a struct/union/enum tag in the innermost scope. Tags live apart
--- from typedefs: `struct Point` never implies a bare `Point` type.
--- @param env ParseEnv
--- @param tagkind string "struct" | "union" | "enum"
--- @param name string
function M.env.define_tag(env, tagkind, name)
    assert(tagkind == "struct" or tagkind == "union" or tagkind == "enum",
        "define_tag: kind must be struct|union|enum")
    assert(type(name) == "string", "define_tag: name must be a string")
    env.scopes[#env.scopes].tags[tagkind .. " " .. name] = true
end

--- Look up a tag from the innermost scope outward.
--- @param env ParseEnv
--- @param tagkind string "struct" | "union" | "enum"
--- @param name string
--- @return boolean
function M.env.lookup_tag(env, tagkind, name)
    local key = tagkind .. " " .. name
    for i = #env.scopes, 1, -1 do
        if env.scopes[i].tags[key] then
            return true
        end
    end
    return false
end

--- Source text of 1-based line n (no trailing newline), or nil if unknown.
--- @param env ParseEnv
--- @param n integer
--- @return string|nil
function M.env.line_text(env, n)
    local starts = env.line_starts
    local s = starts[n]
    if s == nil then
        return nil
    end
    local e = (starts[n + 1] or (#env.src + 2)) - 2
    if e < s then
        return ""
    end
    return env.src:sub(s, e)
end

--- "line text\n  ^" snippet for a loc, or nil when the line is unknown.
--- @param env ParseEnv
--- @param loc table {line, col}
--- @return string|nil
function M.env.snippet(env, loc)
    local text = M.env.line_text(env, loc.line)
    if text == nil then
        return nil
    end
    return text .. "\n" .. string.rep(" ", math.max(loc.col - 1, 0)) .. "^"
end

--- Parse errors are TABLES (not strings), so recovery loops can collect
--- them and re-raise aggregates. __tostring renders the classic
--- `file:line:col: msg` + snippet shape, keeping every existing
--- tostring-based assertion byte-identical. The marker field tells real
--- Lua bugs (re-raised untouched) apart from parse failures.
---@class ParseError
---@field is_parse_error boolean always true (marker)
---@field file string
---@field line integer
---@field col integer
---@field message string
---@field snippet string|nil "line\n  ^" context
---@field errors table|nil aggregate members (aggregate errors only)

local PARSE_MT = {}
--- @param e table ParseError
--- @return string
function PARSE_MT.__tostring(e)
    if e.errors ~= nil then
        local parts = { string.format("%d parse errors:", #e.errors) }
        for _, sub in ipairs(e.errors) do
            parts[#parts + 1] = tostring(sub)
        end
        return table.concat(parts, "\n")
    end
    local s = string.format("%s:%d:%d: %s", e.file, e.line, e.col, e.message)
    if e.snippet ~= nil then
        s = s .. "\n" .. e.snippet
    end
    return s
end

--- Cap on collected errors per parse (panic-mode gives up past this).
M.MAX_ERRORS = 10

--- Build (not raise) a located parse error.
--- @param env ParseEnv
--- @param loc table {line, col}
--- @param msg string
--- @return table ParseError
function M.parse_error(env, loc, msg)
    local e = {
        is_parse_error = true,
        file = env.file,
        line = loc.line,
        col = loc.col,
        message = msg,
        snippet = M.env.snippet(env, loc),
    }
    return setmetatable(e, PARSE_MT)
end

--- True for ParseError tables (single or aggregate); false for Lua bugs.
--- @param e any pcall result
--- @return boolean
function M.is_parse_error(e)
    return type(e) == "table" and e.is_parse_error == true
end

--- Raise the collected errors (plus one optional extra) as an aggregate.
--- A lone error raises unwrapped, preserving the classic single shape.
--- @param env ParseEnv
--- @param extra table|nil one more ParseError
function M.raise_aggregate(env, extra)
    local list = {}
    for _, e in ipairs(env.errors) do
        list[#list + 1] = e
    end
    if extra ~= nil then
        list[#list + 1] = extra
    end
    if #list == 1 then
        error(list[1], 0)
    end
    error(setmetatable({ is_parse_error = true, errors = list }, PARSE_MT), 0)
end

--- Record a recovered error and panic-skip to the next boundary: past a
--- `;` (consumed, continue), or stop (break the loop) at `}`, directives,
--- declaration starters, or eof. Declaration starters and directives are
--- NOT consumed, so following valid code still parses. Every path consumes
--- input or stops (starter failures always consume the starter itself), so
--- item loops always terminate. At the error cap the aggregate raises
--- immediately (no silent flood).
--- @param p Parser cursor to advance
--- @param err any the caught ParseError (callers filter Lua bugs first)
--- @param consume_close boolean TU level consumes stray `}` and continues
--- @return boolean continue the item loop
function M.record_error(p, err, consume_close)
    local env = p.env
    env.errors[#env.errors + 1] = err
    if #env.errors >= (env.max_errors or M.MAX_ERRORS) then
        M.raise_aggregate(env, nil)
    end
    while not p:eof() do
        local t = p:peek()
        if t.kind == "punct" and t.value == ";" then
            p:next()
            return true
        end
        if t.kind == "punct" and t.value == "}" then
            if consume_close then
                p:next()
                return true
            end
            return false
        end
        if t.kind == "directive" or M.is_decl_start(t) then
            return true
        end
        p:next()
    end
    return false
end

--- Declaration-starter words (recovery resume points, never consumed).
--- @param t LexToken
--- @return boolean
function M.is_decl_start(t)
    if t.kind == "keyword" then
        return t.value == "let" or t.value == "const" or t.value == "constexpr"
            or t.value == "type" or t.value == "function"
    end
    if t.kind == "ident" then
        return t.value == "struct" or t.value == "union" or t.value == "enum"
            or t.value == "static_assert"
    end
    return false
end

--- How a token reads inside "expected X, found Y".
--- @param t LexToken
--- @return string
local function found_desc(t)
    if t.kind == "eof" then
        return "end of input"
    end
    return "'" .. t.value .. "'"
end

--- Create a cursor over tokens (which must end with one `eof` token, as
--- produced by lexer.lex). Methods are plain closures: no metatables.
--- @param tokens LexToken[]
--- @param env ParseEnv
--- @return Parser
function M.new(tokens, env)
    assert(type(tokens) == "table" and #tokens > 0, "parser_core.new: tokens must be a non-empty array")
    assert(tokens[#tokens].kind == "eof", "parser_core.new: tokens must end with one eof token")
    assert(type(env) == "table" and type(env.file) == "string", "parser_core.new: env must be a ParseEnv")
    local pos = 1
    local count = #tokens
    -- Unget stack for bracket splitting (U.open_bracket/close_bracket):
    -- consumed immediately after pushing, so it is always empty across
    -- any mark/reset boundary (asserted below).
    local pending = {}
    local P = { env = env }

    --- 1-based lookahead (peek() is the next token). Never returns nil:
    --- past the end it reports at the final (eof) token.
    --- @param n integer|nil
    --- @return LexToken
    function P:peek(n)
        n = n or 1
        assert(type(n) == "number" and n >= 1, "peek: n must be >= 1")
        if n <= #pending then
            return pending[#pending - n + 1]
        end
        local t = tokens[pos + n - #pending - 1]
        if t == nil then
            t = tokens[count]
        end
        return t
    end

    --- Consume and return the next token. Past the end is a hard error.
    --- @return LexToken
    function P:next()
        if #pending > 0 then
            return table.remove(pending)
        end
        local t = tokens[pos]
        if t == nil then
            error(M.parse_error(env, tokens[count].loc, "unexpected end of input"), 0)
        end
        pos = pos + 1
        return t
    end

    --- True when the cursor sits on the eof token with nothing pushed back.
    --- @return boolean
    function P:eof()
        if #pending > 0 then
            return false
        end
        return tokens[pos] ~= nil and tokens[pos].kind == "eof"
    end

    --- Save the cursor for backtracking.
    --- @return integer mark
    function P:mark()
        assert(#pending == 0,
            "parser_core.mark: unget token pending (consume it before marking)")
        return pos
    end

    --- Restore a mark from mark().
    --- @param m integer
    function P:reset(m)
        assert(#pending == 0,
            "parser_core.reset: unget token pending (consume it before resetting)")
        assert(type(m) == "number" and m >= 1 and m <= count + 1, "reset: bad mark")
        pos = m
    end

    --- Run rule; on soft (nil) failure rewind and yield nil.
    --- Hard errors propagate without rewinding.
    --- @param rule Rule
    --- @return any
    function P:try(rule)
        assert(type(rule) == "function", "try: rule must be a function")
        local m = self:mark()
        local v = rule(self)
        if v == nil then
            self:reset(m)
        end
        return v
    end

    --- Push one token back to be consumed next (single-purpose: splitting
    --- merged `[[` / `]]` tokens; see U.open_bracket/U.close_bracket).
    --- @param tok LexToken
    function P:unget(tok)
        assert(type(tok) == "table" and tok.kind ~= nil, "unget: token required")
        pending[#pending + 1] = tok
    end

    --- Raise "expected <what>, found <tok>" at the cursor (committed).
    --- @param what string
    --- @noreturn
    function P:fail(what)
        assert(type(what) == "string", "fail: what must be a string")
        local t = self:peek()
        error(M.parse_error(env, t.loc, "expected " .. what .. ", found " .. found_desc(t)), 0)
    end

    --- Raise like fail() but at an explicit token (e.g. already consumed).
    --- @param tok LexToken
    --- @param what string
    --- @noreturn
    function P:fail_at(tok, what)
        assert(type(tok) == "table" and tok.loc ~= nil, "fail_at: tok must be a token")
        assert(type(what) == "string", "fail_at: what must be a string")
        error(M.parse_error(env, tok.loc, "expected " .. what .. ", found " .. found_desc(tok)), 0)
    end

    ---@cast P Parser
    return P
end

--- Match one token by kind, optionally by exact value. Soft (nil) on mismatch.
--- @param p Parser
--- @param kind string
--- @param value string|nil
--- @return LexToken|nil
function M.token(p, kind, value)
    assert(type(kind) == "string", "token: kind must be a string")
    local t = p:peek()
    if t.kind == kind and (value == nil or t.value == value) then
        p:next()
        return t
    end
    return nil
end

--- Match a Cx keyword token. Soft (nil) on mismatch.
--- @param p Parser
--- @param word string
--- @return LexToken|nil
function M.keyword(p, word)
    assert(type(word) == "string", "keyword: word must be a string")
    return M.token(p, "keyword", word)
end

--- Committed match: like token() but raises naming `what` on mismatch.
--- Call only after the rule is committed (distinguishing keyword consumed).
--- @param p Parser
--- @param kind string
--- @param value string|nil
--- @param what string|nil expectation name (default: kind/value spelling)
--- @return LexToken
function M.expect(p, kind, value, what)
    assert(type(kind) == "string", "expect: kind must be a string")
    local t = M.token(p, kind, value)
    if t == nil then
        if what == nil then
            what = (value ~= nil) and (kind .. " '" .. value .. "'") or kind
        end
        p:fail(what)
    end
    assert(t ~= nil, "parser_core.expect: unreachable (fail always raises)")
    return t
end

--- Try rules in order; first non-nil result wins. Rewinds between attempts.
--- Soft (nil) when every rule fails. Hard errors propagate immediately.
--- @param ... Rule
--- @return Rule
function M.choice(...)
    local n = select("#", ...)
    assert(n > 0, "choice: at least one rule required")
    local rules = { ... }
    for i = 1, n do
        assert(type(rules[i]) == "function", "choice: rule " .. i .. " must be a function")
    end
    return function(p)
        for i = 1, n do
            local m = p:mark()
            local v = rules[i](p)
            if v ~= nil then
                return v
            end
            p:reset(m)
        end
        return nil
    end
end

--- Run rules in order, collecting values. Any soft failure rewinds all.
--- @param ... Rule
--- @return Rule
function M.seq(...)
    local n = select("#", ...)
    assert(n > 0, "seq: at least one rule required")
    local rules = { ... }
    for i = 1, n do
        assert(type(rules[i]) == "function", "seq: rule " .. i .. " must be a function")
    end
    return function(p)
        local m = p:mark()
        local out = {}
        for i = 1, n do
            local v = rules[i](p)
            if v == nil then
                p:reset(m)
                return nil
            end
            out[i] = v
        end
        return out
    end
end

--- Zero or more repetitions. Never soft-fails. A match that consumes no
--- input is a HARD error (grammar bug: it would loop forever).
--- @param rule Rule
--- @return Rule
function M.many(rule)
    assert(type(rule) == "function", "many: rule must be a function")
    return function(p)
        local out = {}
        while true do
            local m = p:mark()
            local v = rule(p)
            if v == nil then
                p:reset(m)
                return out
            end
            if p:mark() == m then
                error("parser_core.many: rule matched empty without consuming input", 2)
            end
            out[#out + 1] = v
        end
    end
end

--- One or more repetitions. Soft (nil, rewound) when the first fails.
--- @param rule Rule
--- @return Rule
function M.many1(rule)
    assert(type(rule) == "function", "many1: rule must be a function")
    local rep = M.many(rule)
    return function(p)
        local m = p:mark()
        local out = rep(p)
        if #out == 0 then
            p:reset(m)
            return nil
        end
        return out
    end
end

--- item (sep item)*. Strict: a trailing separator backtracks (no empty tail).
--- Soft (nil, rewound) when the first item fails.
--- @param item Rule
--- @param sep Rule
--- @return Rule
function M.sepBy(item, sep)
    assert(type(item) == "function", "sepBy: item must be a function")
    assert(type(sep) == "function", "sepBy: sep must be a function")
    return function(p)
        local m = p:mark()
        local first = item(p)
        if first == nil then
            p:reset(m)
            return nil
        end
        local out = { first }
        while true do
            local s = p:mark()
            if sep(p) == nil then
                p:reset(s)
                return out
            end
            local v = item(p)
            if v == nil then
                p:reset(s)
                return out
            end
            out[#out + 1] = v
        end
    end
end

--- Optional rule: yields the rule value, or false when absent (nil is
--- reserved for soft failure, so seq() members stay distinguishable).
--- Never fails; rewinds when absent.
--- @param rule Rule
--- @return Rule
function M.opt(rule)
    assert(type(rule) == "function", "opt: rule must be a function")
    return function(p)
        local m = p:mark()
        local v = rule(p)
        if v == nil then
            p:reset(m)
            return false
        end
        return v
    end
end

--- open body close. Missing open is soft (nil, rewound); once open matched,
--- body/close failures are HARD (the rule is committed).
--- @param open_rule Rule
--- @param body_rule Rule
--- @param close_rule Rule
--- @param what string|nil construct name for error messages
--- @return Rule
function M.delimited(open_rule, body_rule, close_rule, what)
    assert(type(open_rule) == "function", "delimited: open must be a function")
    assert(type(body_rule) == "function", "delimited: body must be a function")
    assert(type(close_rule) == "function", "delimited: close must be a function")
    what = what or "delimited construct"
    assert(type(what) == "string", "delimited: what must be a string")
    return function(p)
        local m = p:mark()
        if open_rule(p) == nil then
            p:reset(m)
            return nil
        end
        local v = body_rule(p)
        if v == nil then
            p:fail(what)
        end
        if close_rule(p) == nil then
            p:fail("closing part of " .. what)
        end
        return v
    end
end

--- Opaque balanced region: the opening value must be next (else soft nil);
--- then tokens through its match, nesting included, are returned WITH the
--- delimiters. Unterminated regions are HARD errors. (P3's cinit vehicle.)
--- @param p Parser
--- @param open_val string opening spelling, e.g. "{"
--- @param close_val string closing spelling, e.g. "}"
--- @return LexToken[]|nil
function M.balanced(p, open_val, close_val)
    assert(type(open_val) == "string" and type(close_val) == "string",
        "balanced: delimiter spellings must be strings")
    assert(open_val ~= close_val, "balanced: delimiters must differ")
    if p:peek().value ~= open_val then
        return nil
    end
    local out = {}
    local depth = 0
    while true do
        if p:eof() then
            p:fail("'" .. close_val .. "' to close '" .. open_val .. "'")
        end
        local tok = p:next()
        out[#out + 1] = tok
        if tok.value == open_val then
            depth = depth + 1
        elseif tok.value == close_val then
            depth = depth - 1
            if depth == 0 then
                return out
            end
        end
    end
end

--- Try rule without consuming (always rewinds). Yields its value or nil.
--- @param rule Rule
--- @return Rule
function M.lookahead(rule)
    assert(type(rule) == "function", "lookahead: rule must be a function")
    return function(p)
        local m = p:mark()
        local v = rule(p)
        p:reset(m)
        return v
    end
end

--- Operator lookup key: spelling for punct/keyword tokens, kind otherwise.
--- @param t LexToken
--- @return string
local function op_key(t)
    if t.kind == "punct" or t.kind == "keyword" then
        return t.value
    end
    return t.kind
end

--- Pratt expression driver. prefix maps keys to fun(p, tok); infix maps keys
--- to InfixSpec ({prec, assoc, parse}). Precedence numbers live in the
--- caller's tables, never here. parse() receives next_min so custom forms
--- (ternary, assignment) can drive nested expr() calls themselves.
--- @param p Parser
--- @param prefix table<string, fun(p: Parser, tok: LexToken): any>
--- @param infix table<string, InfixSpec>
--- @param min_prec number|nil
--- @return any
function M.expr(p, prefix, infix, min_prec)
    assert(type(prefix) == "table", "expr: prefix table required")
    assert(type(infix) == "table", "expr: infix table required")
    min_prec = min_prec or 0
    assert(type(min_prec) == "number", "expr: min_prec must be a number")
    local t = p:peek()
    local pre = prefix[op_key(t)]
    if pre == nil then
        p:fail_at(t, "expression")
    end
    assert(pre ~= nil, "parser_core.expr: unreachable (fail_at always raises)")
    p:next()
    local left = pre(p, t)
    while true do
        local op = p:peek()
        local spec = infix[op_key(op)]
        if spec == nil or spec.prec < min_prec then
            return left
        end
        if spec.assoc ~= "left" and spec.assoc ~= "right" then
            error("parser_core.expr: assoc must be 'left' or 'right'", 2)
        end
        p:next()
        local next_min = spec.prec + (spec.assoc == "left" and 1 or 0)
        left = spec.parse(p, left, op, next_min)
    end
end

--- Ordered suffix loop: try each parser in order, append hits, repeat until
--- all miss. Soft failures rewind (defensively). Order is significant and
--- belongs to the caller: P3 configures `*` then `[...]` array forms here.
--- @param p Parser
--- @param parsers (fun(p: Parser): any)[] tried in order per round
--- @return any[]
function M.suffix_loop(p, parsers)
    assert(type(parsers) == "table" and #parsers > 0, "suffix_loop: parsers array required")
    for i, sp in ipairs(parsers) do
        assert(type(sp) == "function", "suffix_loop: parser " .. i .. " must be a function")
    end
    local out = {}
    while true do
        local matched = false
        for _, sp in ipairs(parsers) do
            local m = p:mark()
            local s = sp(p)
            if s ~= nil then
                out[#out + 1] = s
                matched = true
                break
            end
            p:reset(m)
        end
        if not matched then
            return out
        end
    end
end

--- Run a top-level rule and demand eof after it. Soft rule failure and
--- trailing garbage are HARD errors; anything collected by recovery loops
--- joins the aggregate.
--- @param p Parser
--- @param rule Rule
--- @param what string|nil expectation name (default "input")
--- @return any
function M.parse_unit(p, rule, what)
    assert(type(rule) == "function", "parse_unit: rule must be a function")
    what = what or "input"
    assert(type(what) == "string", "parse_unit: what must be a string")
    local ok, v = pcall(rule, p)
    if not ok then
        if M.is_parse_error(v) then
            if v.errors ~= nil then
                error(v, 0) -- already aggregate (cap path): re-raise whole
            end
            M.raise_aggregate(p.env, v)
        end
        error(v, 0) -- Lua bug: propagate untouched
    end
    if v == nil then
        M.raise_aggregate(p.env, M.parse_error(p.env, p:peek().loc, "expected " .. what))
    end
    if not p:eof() then
        local t = p:peek()
        M.raise_aggregate(p.env,
            M.parse_error(p.env, t.loc, "expected end of input, found " .. found_desc(t)))
    end
    if #p.env.errors > 0 then
        M.raise_aggregate(p.env, nil)
    end
    return v
end

--- Byte offset just past a loc's end position, for opaque source slices
--- (cinit regions). Complements loc.offset (start) from the lexer.
--- @param env ParseEnv
--- @param loc table {end_line: integer, end_col: integer}
--- @return integer
function M.loc_end_offset(env, loc)
    assert(type(env.line_starts) == "table", "loc_end_offset: env needs line_starts")
    local s = env.line_starts[loc.end_line]
    assert(s ~= nil, "loc_end_offset: end_line out of range")
    return s + loc.end_col - 1
end

return M
