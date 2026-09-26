-- Codegen core: shared context, guards, attributes, line emitter (P4).
-- No printer dependencies: expression/type/statement modules require this
-- file, never each other directly. Cross-printer recursion goes through
-- the P table wired in compiler/codegen.lua (same behavior as the former
-- upvalue recursion in the single-file printer).

local M = {}

---@class CodegenCtx
---@field cc string C toolchain name ("clang"|"gcc"|"msvc"|...)
---@field std string C standard ("c23"|...)
---@field src string original source text (cinit slices)
---@field line_markers boolean|nil opt-in #line emission (default off)
---@field target table|nil full CxTarget (cc/std fall back to the strings)

-- C precedence for minimal parentheses (mirrors the grammar numbers).
M.PREC = {
    [","] = 1,
    ["="] = 2, ["*="] = 2, ["/="] = 2, ["%="] = 2, ["+="] = 2,
    ["-="] = 2, ["<<="] = 2, [">>="] = 2, ["&="] = 2, ["^="] = 2, ["|="] = 2,
    ["?"] = 3,
    ["||"] = 4, ["&&"] = 5, ["|"] = 6, ["^"] = 7, ["&"] = 8,
    ["=="] = 9, ["!="] = 9,
    ["<"] = 10, [">"] = 10, ["<="] = 10, [">="] = 10,
    ["<<"] = 11, [">>"] = 11,
    ["+"] = 12, ["-"] = 12,
    ["*"] = 13, ["/"] = 13, ["%"] = 13,
}

--- Reject constructs the target toolchain cannot compile.
--- @param ctx CodegenCtx
--- @param loc Loc
--- @param what string construct description
function M.reject_if_msvc(ctx, loc, what)
    if ctx.cc == "msvc" then
        error(string.format("%s:%d:%d: %s is not supported for target cc",
            loc.file, loc.line, loc.col, what), 0)
    end
end

--- Reject GNU-only nodes on non-GNU toolchains (defense in depth; the
--- expander already gates on target, and strict never parses these).
--- @param ctx CodegenCtx
--- @param n table # Cx:Gnu:* node
function M.gnu_check(ctx, n)
    if ctx.cc == "msvc" then
        local loc = n.loc or {}
        error(string.format("%s:%d:%d: %s requires a GNU toolchain (target cc=msvc)",
            tostring(loc.file or "?"), loc.line or 0, loc.col or 0, n.kind), 0)
    end
end

--- Reject GNU-spelled attributes (`__...`) on non-GNU toolchains.
--- @param ctx CodegenCtx
--- @param loc Loc
--- @param attrs string[]
function M.check_gnu_attrs(ctx, loc, attrs)
    if ctx.cc ~= "msvc" then
        return
    end
    for _, a in ipairs(attrs) do
        if a:sub(1, 2) == "__" then
            M.reject_if_msvc(ctx, loc, "attribute '" .. a .. "'")
        end
    end
end

--- Precedence of an expression node, or nil for primaries/unary/postfix.
--- @param n table
--- @return number|nil
function M.prec_of(n)
    if n.kind == "Cx:Binary" then
        local p = M.PREC[n.op]
        assert(p ~= nil, "codegen: unknown binary op " .. tostring(n.op))
        return p
    end
    if n.kind == "Cx:Ternary" then
        return 3
    end
    if n.kind == "Cx:Assign" then
        return 2
    end
    if n.kind == "Cx:Comma" then
        return 1
    end
    if n.kind == "Cx:CastAs" then
        return 14
    end
    return nil
end

--- Render one `[[...]]` attribute (joins raw inners without spacing drift).
--- GNU spellings (`__attribute__((...))`, `__extension__`) pass through
--- verbatim; everything else is wrapped in `[[...]]`.
--- @param a string raw inner text
--- @return string
function M.attr_str(a)
    if a:sub(1, 2) == "__" then
        return a
    end
    local s = a:gsub("%( ", "("):gsub(" %)", ")"):gsub(" ,", ",")
    return "[[" .. s .. "]]"
end

--- Join a spec spelling with a declarator (no space before `[`).
--- @param spec string
--- @param decl string
--- @return string
function M.join_decl(spec, decl)
    if decl == "" then
        return spec
    end
    if decl:sub(1, 1) == "[" then
        return spec .. decl
    end
    return spec .. " " .. decl
end

---@class Emitter
---@field lines string[] finished lines
---@field cur string current line being built
---@field ind integer current indent level
---@field last_file string|nil #line tracker
---@field last_line integer|nil #line tracker
---@field ctx CodegenCtx

--- @param ctx CodegenCtx
--- @return table Emitter
function M.new_emitter(ctx)
    return { lines = {}, cur = "", ind = 0,
        last_file = nil, last_line = nil, ctx = ctx }
end

--- @param E Emitter # Emitter
--- @param s string
function M.W(E, s)
    if E.cur == "" then
        E.cur = string.rep("    ", E.ind)
    end
    E.cur = E.cur .. s
end

--- @param E Emitter # Emitter
function M.NL(E)
    local line = E.cur:gsub("%s+$", "")
    E.lines[#E.lines + 1] = line
    E.cur = ""
end

--- @param E Emitter # Emitter
--- @param s string full line at current indent
function M.LINE(E, s)
    M.W(E, s)
    M.NL(E)
end

--- #line marker before a located construct (opt-in only).
--- @param E Emitter # Emitter
--- @param loc table|nil
function M.MARK(E, loc)
    local ctx = E.ctx
    if not ctx.line_markers or loc == nil or loc.file == nil or loc.line == nil then
        return
    end
    if loc.file ~= E.last_file or loc.line ~= E.last_line then
        E.lines[#E.lines + 1] = "#line " .. loc.line .. ' "' .. loc.file .. '"'
        E.last_file = loc.file
        E.last_line = loc.line
    end
end

--- Verbatim output invalidates line tracking (user markers pass through).
--- @param E Emitter # Emitter
function M.UNMARK(E)
    E.last_file = nil
    E.last_line = nil
end

--- Resolve the full context: plain cc/std strings keep older callers
--- working; a full CxTarget overrides them when present (P6 threading).
--- @param ctx table|nil caller context
--- @return CodegenCtx
function M.normalize_ctx(ctx)
    ctx = ctx or {}
    local full = {
        cc = ctx.cc or "clang",
        std = ctx.std or "c23",
        src = ctx.src or "",
        line_markers = ctx.line_markers or false,
        target = ctx.target,
    }
    if full.target ~= nil then
        if full.target.cc ~= nil then
            full.cc = full.target.cc
        end
        if full.target.std ~= nil then
            full.std = full.target.std
        end
        full.target = nil
    end
    ---@cast full CodegenCtx
    return full
end

return M
