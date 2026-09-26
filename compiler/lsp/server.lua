-- Cx LSP server over stdio (P0-P4, editor-agnostic).
-- Transport: JSON-RPC 2.0 with Content-Length framing on stdin/stdout;
-- logs go to stderr. Full-sync only (TextDocumentSyncKind.Full).
-- Position encoding: "utf-8" preferred, "utf-16" fallback.
-- Per-file compiler config (target/extensions/dialect) comes from
-- buildinfo.resolve("build.lua"); missing entries fall back to host
-- defaults so unknown files still parse as strict Cx.

local json = require("compiler.lsp.json")
local positions = require("compiler.lsp.positions")
local docs = require("compiler.lsp.docs")
local buildinfo = require("compiler.lsp.buildinfo")
local tokens = require("compiler.lsp.tokens")
local query = require("compiler.lsp.query")
local graph = require("compiler.lsp.graph")

local M = {}

---@class LspServer
---@field store table doc store (see docs.lua)
---@field build_map table<string, table> norm path -> file config
---@field build_warn string|nil resolver warning
---@field build_mtime integer|nil mtime of build.lua at resolve time
---@field encoding string "utf-8"|"utf-16"
---@field shutdown_requested boolean
---@field next_version table<string, integer> fallback versions
---@field graph_cache table<string, table> entry path -> {extkey, entry_version, stamps, index}
---@field dep_cache table<string, table> disk-parse cache (see graph.build)
---@field handle fun(self: LspServer, msg: table): table[] dispatch one message

--- Create a server with a fresh doc store and resolved build map.
--- @return LspServer
function M.new()
    local self = {
        store = docs.new(),
        build_map = {},
        build_warn = nil,
        build_mtime = nil,
        encoding = "utf-8",
        shutdown_requested = false,
        next_version = {},
        graph_cache = {},
        dep_cache = {},
    }
    M.refresh_build(self)
    return setmetatable(self, { __index = M })
end

--- (Re)resolve build.lua when it changed or was never loaded.
--- @param self LspServer
function M.refresh_build(self)
    local buildkit = require("compiler.buildkit")
    local mt = buildkit.mtime("build.lua")
    if mt ~= nil and mt == self.build_mtime and next(self.build_map) ~= nil then
        return
    end
    local map, warn = buildinfo.resolve("build.lua", ".")
    self.build_map = map or {}
    self.build_warn = warn
    self.build_mtime = mt
end

--- Config for a document URI (refreshes the build map first).
--- @param self LspServer
--- @param uri string
--- @return table config (see docs.parse_text) + entries
function M.config_for_uri(self, uri)
    M.refresh_build(self)
    local path = buildinfo.uri_to_path(uri)
    return buildinfo.config_for(self.build_map, path)
end

--- Extension key for graph-cache validation (registered graph
--- extensions + target select the grammar, hence the index).
--- @param cfg table file config
--- @return string
local function ext_key(cfg)
    local names = {}
    for _, e in ipairs(cfg.entries or {}) do
        names[#names + 1] = e.name
    end
    local tgt = cfg.target or {}
    return table.concat(names, ",") .. "|" .. tostring(tgt.triple or "?")
        .. "|" .. tostring(cfg.cc) .. "|" .. tostring(cfg.std)
end

--- Workspace graph index for an open document, cached by entry version +
--- dep stamps + extension key. Returns an empty index when no graph
--- extension is registered or the entry has no parse tree.
--- @param self LspServer
--- @param uri string
--- @param doc table LspDoc
--- @param cfg table file config
--- @return table index LspGraphIndex
function M.graph_for(self, uri, doc, cfg)
    ---@type table
    local empty = { entry = buildinfo.uri_to_path(uri), order = {},
        units = {}, exports = {}, errors = {}, stamps = {}, api = nil }
    if graph.find_graph_api(cfg.entries) == nil or doc.root == nil then
        return empty
    end
    local entry_path = buildinfo.uri_to_path(uri)
    local key = ext_key(cfg)
    local c = self.graph_cache[entry_path]
    if c ~= nil and c.extkey == key and c.entry_version == doc.version then
        local fresh = true
        for path, stamp in pairs(c.stamps) do
            local u = c.index.units[path]
            if graph.stamp(self.store, (u ~= nil) and u.uri or nil, path) ~= stamp then
                fresh = false
                break
            end
        end
        if fresh then
            return c.index
        end
    end
    local n = 0
    for _ in pairs(self.dep_cache) do
        n = n + 1
    end
    if n > 128 then
        self.dep_cache = {}
    end
    local index = graph.build(entry_path,
        { root = doc.root, src = doc.text }, self.store, cfg, self.dep_cache)
    self.graph_cache[entry_path] = {
        extkey = key, entry_version = doc.version,
        stamps = index.stamps, index = index,
    }
    return index
end

--- Completion items at a byte position: local scope first, then
--- workspace imports (not shadowing locals), tagged with their origin.
--- @param self LspServer
--- @param uri string
--- @param doc table LspDoc
--- @param cfg table file config
--- @param line integer 1-based
--- @param col integer 1-based byte column
--- @return table[] items
function M.complete_items(self, uri, doc, cfg, line, col)
    local items = query.complete(doc, line, col, cfg.entries)
    local index = M.graph_for(self, uri, doc, cfg)
    if index.api == nil then
        return items
    end
    local have = {}
    for _, it in ipairs(items) do
        have[it.label] = true
    end
    local kinds = {
        ["Cx:FunctionDecl"] = 3, ["Cx:BindingDecl"] = 6,
        ["Cx:TypeAlias"] = 8, ["Cx:RecordDecl"] = 22,
        ["Cx:EnumDecl"] = 13,
    }
    for _, w in ipairs(graph.workspace_of(index,
        buildinfo.uri_to_path(uri))) do
        if not have[w.name] then
            have[w.name] = true
            local base = (w.path or "?"):match("([^/]*)$") or w.path
            items[#items + 1] = {
                label = w.name,
                kind = kinds[w.decl_kind] or 6,
                detail = "from " .. base,
            }
        end
    end
    return items
end

--- Definition Location at a byte position (same-file or cross-file),
--- or nil when nothing matches.
--- @param self LspServer
--- @param uri string
--- @param doc table LspDoc
--- @param cfg table file config
--- @param line integer 1-based
--- @param col integer 1-based byte column
--- @return table|nil location {uri, range}
function M.definition_at(self, uri, doc, cfg, line, col)
    local index = M.graph_for(self, uri, doc, cfg)
    local ws = {}
    if index.api ~= nil then
        ws = graph.workspace_of(index, buildinfo.uri_to_path(uri))
    end
    local loc, target_uri = query.definition(doc, line, col, ws)
    if loc == nil then
        return nil
    end
    target_uri = target_uri or uri
    local text = M.text_for(self, index, target_uri, loc)
    return {
        uri = target_uri,
        range = positions.loc_to_range(loc, text, nil, self.encoding),
    }
end

--- Source text backing a (possibly cross-file) location: open doc text
--- when available, else the graph unit's snapshot, else "".
--- @param self LspServer
--- @param index table LspGraphIndex
--- @param uri string location URI
--- @param loc table compiler Loc (loc.file names the path)
--- @return string text
function M.text_for(self, index, uri, loc)
    local open_doc = docs.get(self.store, uri)
    if open_doc ~= nil then
        return open_doc.text or ""
    end
    local path = (loc ~= nil and loc.file) or buildinfo.uri_to_path(uri)
    local unit = index.units[path]
    if unit == nil and path ~= nil then
        -- Open docs parse with the URI-derived path (possibly "./"-prefixed)
        -- while index keys are normalized: retry stripped.
        unit = index.units[(path:gsub("^%./+", ""))]
    end
    if unit ~= nil then
        return unit.src or ""
    end
    return ""
end

--- Publish diagnostics for a doc; returns the notification (caller sends).
--- @param self LspServer
--- @param uri string
--- @param doc table LspDoc
--- @param extra table[]|nil extra normalized errors (e.g. graph errors)
--- @return table notification
function M.diagnostics_notif(self, uri, doc, extra)
    local diags = {}
    for _, e in ipairs(doc.errors or {}) do
        diags[#diags + 1] = {
            range = positions.loc_to_range(e.loc, doc.text,
                doc.starts, self.encoding),
            severity = 1,
            source = "cx",
            message = e.message,
        }
    end
    for _, e in ipairs(extra or {}) do
        diags[#diags + 1] = {
            range = positions.loc_to_range(e.loc, doc.text,
                doc.starts, self.encoding),
            severity = 1,
            source = "cx",
            message = e.message,
        }
    end
    return {
        jsonrpc = "2.0",
        method = "textDocument/publishDiagnostics",
        params = { uri = uri, diagnostics = diags },
    }
end

--- Parse (or reparse) an open URI with its build config.
--- @param self LspServer
--- @param uri string
--- @param text string
--- @param version integer|nil
--- @return table doc
--- @return table config
function M.parse_uri(self, uri, text, version)
    local cfg = M.config_for_uri(self, uri)
    local path = buildinfo.uri_to_path(uri)
    cfg.file = path
    local doc = docs.open(self.store, uri, text, version or 0, cfg)
    return doc, cfg
end

--- Dispatch one decoded JSON-RPC message. Returns a list of reply
--- messages to send (responses + publishDiagnostics pushes).
--- @param self LspServer
--- @param msg table decoded message
--- @return table[] replies
function M.handle(self, msg)
    local method = msg.method
    local id = msg.id
    if id == json.null then
        id = nil
    end
    local function result(value)
        if id == nil then
            return {}
        end
        return { { jsonrpc = "2.0", id = id, result = value } }
    end
    local function err(code, message)
        if id == nil then
            return {}
        end
        return { { jsonrpc = "2.0", id = id,
            error = { code = code, message = message } } }
    end
    if method == "initialize" then
        local params = msg.params or {}
        local encs = params.capabilities ~= nil
            and params.capabilities.general ~= nil
            and params.capabilities.general.positionEncodings or nil
        self.encoding = "utf-16"
        if type(encs) == "table" then
            for _, e in ipairs(encs) do
                if e == "utf-8" then
                    self.encoding = "utf-8"
                    break
                end
            end
        else
            self.encoding = "utf-8"
        end
        return result({
            capabilities = {
                textDocumentSync = 1,
                positionEncoding = self.encoding,
                semanticTokensProvider = {
                    legend = tokens.legend,
                    full = true,
                    range = true,
                },
                completionProvider = { triggerCharacters = { ".", ":", ">" } },
                hoverProvider = true,
                definitionProvider = true,
            },
            serverInfo = { name = "cx-lsp", version = "0.0.0-p0" },
        })
    end
    if method == "initialized" then
        return {}
    end
    if method == "shutdown" then
        self.shutdown_requested = true
        return result(json.null)
    end
    if method == "exit" then
        return {}
    end
    if method == "textDocument/didOpen" then
        local td = (msg.params or {}).textDocument or {}
        local uri = td.uri
        if type(uri) ~= "string" then
            return err(-32602, "didOpen: textDocument.uri required")
        end
        local doc, cfg = M.parse_uri(self, uri,
            td.text or "", td.version or 0)
        local index = M.graph_for(self, uri, doc, cfg)
        return { M.diagnostics_notif(self, uri, doc, index.errors) }
    end
    if method == "textDocument/didChange" then
        local params = msg.params or {}
        local td = params.textDocument or {}
        local uri = td.uri
        if type(uri) ~= "string" then
            return err(-32602, "didChange: textDocument.uri required")
        end
        local changes = params.contentChanges or {}
        local text = nil
        for _, ch in ipairs(changes) do
            if type(ch.text) == "string" then
                text = ch.text
            end
        end
        if text == nil then
            local cur = docs.get(self.store, uri)
            text = (cur ~= nil) and cur.text or ""
        end
        local doc, cfg = M.parse_uri(self, uri, text, td.version or 0)
        local index = M.graph_for(self, uri, doc, cfg)
        return { M.diagnostics_notif(self, uri, doc, index.errors) }
    end
    if method == "textDocument/didClose" then
        local uri = ((msg.params or {}).textDocument or {}).uri
        if type(uri) == "string" then
            docs.close(self.store, uri)
        end
        return {}
    end
    if method == "textDocument/didSave" then
        local td = (msg.params or {}).textDocument or {}
        local uri = td.uri
        if type(uri) == "string" then
            local cur = docs.get(self.store, uri)
            local text = (msg.params or {}).text
            if type(text) ~= "string" then
                text = (cur ~= nil) and cur.text or ""
            end
            local doc, cfg = M.parse_uri(self, uri, text,
                (cur ~= nil and cur.version or 0))
            local index = M.graph_for(self, uri, doc, cfg)
            return { M.diagnostics_notif(self, uri, doc, index.errors) }
        end
        return {}
    end
    if method == "textDocument/semanticTokens/full"
        or method == "textDocument/semanticTokens/full/delta" then
        local uri = ((msg.params or {}).textDocument or {}).uri
        local doc = (type(uri) == "string") and docs.get(self.store, uri) or nil
        if doc == nil then
            return err(-32602, "semanticTokens: unknown document")
        end
        local cfg = M.config_for_uri(self, uri)
        return result({ data = tokens.full(doc, cfg.entries, self.encoding) })
    end
    if method == "textDocument/semanticTokens/range" then
        local uri = ((msg.params or {}).textDocument or {}).uri
        local doc = (type(uri) == "string") and docs.get(self.store, uri) or nil
        if doc == nil then
            return err(-32602, "semanticTokens: unknown document")
        end
        local cfg = M.config_for_uri(self, uri)
        return result({ data = tokens.full(doc, cfg.entries, self.encoding) })
    end
    if method == "textDocument/completion" then
        local params = msg.params or {}
        local uri = (params.textDocument or {}).uri
        local doc = (type(uri) == "string") and docs.get(self.store, uri) or nil
        if doc == nil then
            return err(-32602, "completion: unknown document")
        end
        local cfg = M.config_for_uri(self, uri)
        local pos = params.position or { line = 0, character = 0 }
        local line, col = positions.position_to_loc(
            doc.text, doc.starts, pos, self.encoding)
        return result({ isIncomplete = false,
            items = M.complete_items(self, uri, doc, cfg, line, col) })
    end
    if method == "textDocument/hover" then
        local params = msg.params or {}
        local uri = (params.textDocument or {}).uri
        local doc = (type(uri) == "string") and docs.get(self.store, uri) or nil
        if doc == nil then
            return err(-32602, "hover: unknown document")
        end
        local pos = params.position or { line = 0, character = 0 }
        local line, col = positions.position_to_loc(
            doc.text, doc.starts, pos, self.encoding)
        local text = query.hover(doc, line, col)
        if text == nil then
            return result(json.null)
        end
        return result({ contents = { kind = "markdown", value = text } })
    end
    if method == "textDocument/definition" then
        local params = msg.params or {}
        local uri = (params.textDocument or {}).uri
        local doc = (type(uri) == "string") and docs.get(self.store, uri) or nil
        if doc == nil then
            return err(-32602, "definition: unknown document")
        end
        local pos = params.position or { line = 0, character = 0 }
        local line, col = positions.position_to_loc(
            doc.text, doc.starts, pos, self.encoding)
        local cfg = M.config_for_uri(self, uri)
        local found = M.definition_at(self, uri, doc, cfg, line, col)
        if found == nil then
            return result(json.null)
        end
        return result(found)
    end
    if method ~= nil and method:sub(1, 2) == "$/" then
        return {}
    end
    return err(-32601, "method not found: " .. tostring(method))
end

--- Read exactly n bytes from stdin (looping on short reads).
--- @param n integer
--- @return string|nil data (nil on EOF)
local function read_bytes(n)
    local parts = {}
    local got = 0
    while got < n do
        local chunk = io.stdin:read(n - got)
        if chunk == nil then
            return nil
        end
        parts[#parts + 1] = chunk
        got = got + #chunk
    end
    return table.concat(parts)
end

--- Encode + write one message with Content-Length framing.
--- @param msg table
local function write_msg(msg)
    local body = json.encode(msg)
    io.stdout:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
    io.stdout:flush()
end

--- Log a line to stderr (never stdout: stdout is the protocol).
--- @param s string
local function log(s)
    io.stderr:write("[cx-lsp] " .. s .. "\n")
end

--- Run the stdio loop until `exit` (after `shutdown`) or EOF.
function M.run()
    local self = M.new()
    if io.stdout.setvbuf ~= nil then
        pcall(function() io.stdout:setvbuf("no") end)
    end
    log("listening on stdio (encoding=" .. self.encoding .. ")")
    if self.build_warn ~= nil then
        log("buildinfo: " .. self.build_warn)
    end
    while true do
        -- Header block: lines until the blank line.
        local headers = {}
        while true do
            local line = io.stdin:read("*l")
            if line == nil then
                return
            end
            line = line:gsub("\r$", "")
            if line == "" then
                break
            end
            headers[#headers + 1] = line
        end
        local length = nil
        for _, h in ipairs(headers) do
            local v = h:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
            if v ~= nil then
                length = tonumber(v)
            end
        end
        if length == nil then
            log("missing Content-Length; skipping block")
        else
            local body = read_bytes(length)
            if body == nil then
                return
            end
            local ok, msg = pcall(json.decode, body)
            if not ok then
                log("bad JSON: " .. tostring(msg))
            else
                local replies_ok, replies = pcall(M.handle, self, msg)
                if not replies_ok then
                    log("handler error: " .. tostring(replies))
                    if type(msg.id) == "number" then
                        write_msg({ jsonrpc = "2.0", id = msg.id,
                            error = { code = -32603,
                                message = "internal error: " .. tostring(replies) } })
                    end
                else
                    for _, r in ipairs(replies) do
                        write_msg(r)
                    end
                end
                if msg.method == "exit" then
                    return
                end
            end
        end
    end
end

return M
