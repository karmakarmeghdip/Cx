-- Codegen: Cx-only AST -> C23 text (P4).
-- Input must contain zero Ext:* nodes (asserted). Comments and whitespace
-- trivia are dropped (layout is regenerated); directives and cinit regions
-- pass through byte-verbatim. Target-aware via ctx.cc/ctx.target:
-- rejects msvc-unsupported constructs with loc (typeof/_BitInt/_Decimal,
-- alignof, wb literals, GNU nodes/attrs).
--
-- Layout: this file owns the public `emit` entry plus section wiring.
-- Printers live in compiler/codegen/: core (context/guards/emitter),
-- types (declarators), exprs (expressions/initializers), stmts
-- (statements), decls (declarations). Sections share one printer table P
-- so the former upvalue recursion keeps identical behavior.

local ast = require("compiler.ast")
local core = require("compiler.codegen.core")
local types = require("compiler.codegen.types")
local exprs = require("compiler.codegen.exprs")
local stmts = require("compiler.codegen.stmts")
local decls = require("compiler.codegen.decls")

local M = {}

--- Shared printer table (wired once; sections resolve peers at call time).
---@type table
local P = {}
types.define(P)
exprs.define(P)
stmts.define(P)
decls.define(P)

--- Compile a fully-expanded Cx-only AST to C text.
--- @param root table # Cx:TranslationUnit
--- @param ctx CodegenCtx
--- @return string C source (ends with a single newline)
function M.emit(root, ctx)
    assert(type(root) == "table" and root.kind == "Cx:TranslationUnit",
        "codegen.emit: root must be a Cx:TranslationUnit")
    local full = core.normalize_ctx(ctx)
    local ext = ast.collect_ext(root)
    if #ext > 0 then
        local loc = ext[1].loc or { file = "?", line = 0, col = 0 }
        error(string.format("%s:%d:%d: codegen: unexpanded extension node %s",
            loc.file, loc.line, loc.col, ext[1].kind), 0)
    end
    local E = core.new_emitter(full)
    for i, item in ipairs(root.body) do
        if i > 1 then
            E.lines[#E.lines + 1] = ""
        end
        P.emit_top(E, item)
    end
    if E.cur ~= "" then
        core.NL(E)
    end
    return table.concat(E.lines, "\n") .. "\n"
end

return M
