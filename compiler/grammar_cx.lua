-- The Cx core language as a Lua table: the ONLY place Cx syntax is defined.
-- Section modules below only extend this table (G.rules for rules,
-- G.prefix/G.infix for the Pratt driver); no syntax originates outside them.
-- Extensions may add keys/rules or wrap rule functions, but may not replace
-- the lexer or silently change C23 semantics of core rules.
-- Precedence numbers live HERE (and only here), per AGENTS.md section 6.

local types = require("compiler.grammar.types")
local exprs = require("compiler.grammar.exprs")
local inits = require("compiler.grammar.inits")
local decls = require("compiler.grammar.decls")
local stmts = require("compiler.grammar.stmts")

---@class CxGrammar
---@field keywords string[] Cx-only keywords (whole-token match; see lexer)
---@field prefix table<string, fun(p: table, tok: table): table> Pratt prefix parsers
---@field infix table<string, table> Pratt infix specs {prec, assoc, parse}
---@field rules table<string, fun(p: table, ...: any): any> named grammar rules

---@type CxGrammar
local G = {
    keywords = { "let", "function", "type", "as", "cinit",
        "const", "constexpr", "sizeof", "alignof", "_Generic" },
    prefix = {},
    infix = {},
    rules = {},
}

types.define(G)
exprs.define(G)
inits.define(G)
decls.define(G)
stmts.define(G)

return G
