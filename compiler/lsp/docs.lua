-- Open-document store + tolerant per-file pipeline (P0-P2).
-- Full-sync only: the client sends the whole text on every change.
-- Parsing is tolerant by construction: parseTranslationUnit is invoked
-- directly (not via parse_unit), so recovered errors in env.errors do NOT
-- discard the partial root (see tests/recovery_test.lua pattern).
-- Expansion and codegen-check errors are collected as diagnostics too.

local positions = require("compiler.lsp.positions")

local M = {}

---@class LspDoc
---@field uri string document URI
---@field text string current full text
---@field version integer last seen version
---@field root table|nil partial (or full) Cx:TranslationUnit
---@field expanded table|nil post-expansion root (may equal root)
---@field errors table[] normalized {loc={line,col,end_line,end_col,file}, message}
---@field starts integer[] line starts for text

---@class LspStore
---@field docs table<string, LspDoc>

--- Create an empty store.
--- @return LspStore
function M.new()
    return { docs = {} }
end

--- Split a "file:line:col: message" string into parts.
--- @param s string
--- @param default_file string|nil
--- @return table loc {file,line,col,end_line,end_col}
--- @return string message
local function split_string_error(s, default_file)
    local f, l, c, msg = s:match("^([^:\n]+):(%d+):(%d+):%s*(.-)%s*$")
    if f == nil then
        return { file = default_file or "?", line = 1, col = 1,
            end_line = 1, end_col = 1 }, s
    end
    local line = tonumber(l) or 1
    local col = tonumber(c) or 1
    return { file = f, line = line, col = col,
        end_line = line, end_col = col }, (msg or s)
end

--- Normalize one error (ParseError table, aggregate, or string) into a
--- flat list of {loc, message}.
--- @param e any
--- @param default_file string|nil
--- @return table[] list
function M.normalize_error(e, default_file)
    local out = {}
    if type(e) == "table" and e.is_parse_error == true then
        if e.errors ~= nil then
            for _, sub in ipairs(e.errors) do
                local list = M.normalize_error(sub, default_file)
                for _, item in ipairs(list) do
                    out[#out + 1] = item
                end
            end
            return out
        end
        out[1] = {
            loc = {
                file = e.file or default_file or "?",
                line = e.line or 1, col = e.col or 1,
                end_line = e.line or 1, end_col = (e.col or 1),
            },
            message = e.message or tostring(e),
        }
        return out
    end
    local loc, msg = split_string_error(tostring(e), default_file)
    out[1] = { loc = loc, message = msg }
    return out
end

--- Tolerant parse of `text` with a resolved file config.
--- config = {file:string, target:table, std:string, cc:string,
---           entries:table[] {{name,mod}}, dialect:table}.
--- Never raises on Cx errors; they land in doc.errors. Real Lua bugs
--- propagate (they are compiler bugs, not diagnostics).
--- @param text string
--- @param config table
--- @return LspDoc doc (uri set to config.file)
function M.parse_text(text, config)
    assert(type(text) == "string", "docs.parse_text: text must be a string")
    assert(type(config) == "table", "docs.parse_text: config required")
    local file = config.file or "<input>"
    local target = config.target or {}
    local dialect = config.dialect or {}
    local entries = config.entries or {}
    ---@type LspDoc
    local doc = {
        uri = file, text = text, version = 0,
        root = nil, expanded = nil, errors = {},
        starts = positions.line_starts(text),
    }
    local lexer = require("compiler.lexer")
    local core = require("compiler.parser_core")
    local extension = require("compiler.extension")
    local toks
    do
        local ok, v = pcall(lexer.lex, text, file)
        if not ok then
            local list = M.normalize_error(v, file)
            for _, item in ipairs(list) do
                doc.errors[#doc.errors + 1] = item
            end
            return doc
        end
        toks = v
    end
    local G = require("compiler.grammar_cx")
    if #entries > 0 then
        G = extension.assemble(G, entries, { target = target, dialect = dialect })
    end
    local env = core.new_env({
        file = file, src = text, target = target,
        dialect = dialect, grammar = G,
    })
    local p = core.new(toks, env)
    do
        local ok, v = pcall(G.rules.parseTranslationUnit, p)
        if ok and v ~= nil then
            doc.root = v
        elseif core.is_parse_error(v) then
            -- Cap-path aggregates abort the rule: keep whatever env saw?
            -- The rule builds `body` incrementally but only returns at the
            -- end, so on abort there is no partial root; diagnostics remain.
            local list = M.normalize_error(v, file)
            for _, item in ipairs(list) do
                doc.errors[#doc.errors + 1] = item
            end
        else
            error(v, 0)
        end
    end
    for _, e in ipairs(env.errors) do
        local list = M.normalize_error(e, file)
        for _, item in ipairs(list) do
            doc.errors[#doc.errors + 1] = item
        end
    end
    if doc.root == nil then
        return doc
    end
    -- Graph extensions (modules-style) resolve their Ext markers in a
    -- whole-program driver pass (modules.link_graph), not per-node
    -- expansion: expanding a single file would spuriously flag markers
    -- the driver owns. Skip expansion then; graph.lua validates instead.
    local has_graph = false
    for _, e in ipairs(entries) do
        if e.mod ~= nil and e.mod.graph_api ~= nil then
            has_graph = true
            break
        end
    end
    if #entries > 0 and not has_graph then
        local expand = require("compiler.expand")
        local expanders = extension.collect_expanders(entries)
        local ok, v = pcall(expand.expand, doc.root, expanders,
            { target = target, dialect = dialect })
        if ok then
            doc.expanded = v
        else
            local list = M.normalize_error(v, file)
            for _, item in ipairs(list) do
                doc.errors[#doc.errors + 1] = item
            end
            doc.expanded = doc.root
        end
    else
        doc.expanded = doc.root
    end
    -- Target-reject dry run: unsupported constructs for the selected
    -- cc/std become diagnostics, not crashes. Skipped while any Ext
    -- nodes remain (expansion already diagnosed those; graph markers
    -- belong to the driver, not codegen).
    do
        local ast = require("compiler.ast")
        if #ast.collect_ext(doc.expanded) == 0 then
            local codegen = require("compiler.codegen")
            local ok, v = pcall(codegen.emit, doc.expanded, {
                cc = config.cc, std = config.std, src = text, target = target,
            })
            if not ok then
                local list = M.normalize_error(v, file)
                for _, item in ipairs(list) do
                    doc.errors[#doc.errors + 1] = item
                end
            end
        end
    end
    return doc
end

--- Open (or replace) a document and parse it.
--- @param store LspStore
--- @param uri string
--- @param text string
--- @param version integer|nil
--- @param config table parse config (see parse_text)
--- @return LspDoc
function M.open(store, uri, text, version, config)
    assert(type(uri) == "string", "docs.open: uri required")
    local doc = M.parse_text(text, config or { file = uri })
    doc.uri = uri
    doc.version = version or 0
    store.docs[uri] = doc
    return doc
end

--- Full-sync change: replace text and reparse.
--- @param store LspStore
--- @param uri string
--- @param text string
--- @param version integer|nil
--- @param config table|nil
--- @return LspDoc
function M.change(store, uri, text, version, config)
    return M.open(store, uri, text, version, config or { file = uri })
end

--- Close a document.
--- @param store LspStore
--- @param uri string
function M.close(store, uri)
    store.docs[uri] = nil
end

--- Get an open document (or nil).
--- @param store LspStore
--- @param uri string
--- @return LspDoc|nil
function M.get(store, uri)
    return store.docs[uri]
end

return M
