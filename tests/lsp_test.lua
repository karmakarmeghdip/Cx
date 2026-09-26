-- LSP tests: json framing codec, positions, buildinfo resolver, tolerant
-- docs pipeline, semantic tokens (strict vs gnu), and in-process protocol
-- dispatch. Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local json = require("compiler.lsp.json")
    local positions = require("compiler.lsp.positions")
    local docs = require("compiler.lsp.docs")
    local buildinfo = require("compiler.lsp.buildinfo")
    local tokens = require("compiler.lsp.tokens")
    local query = require("compiler.lsp.query")
    local server = require("compiler.lsp.server")

    ctx.check("lsp: json round-trips messages", function()
        local msg = {
            jsonrpc = "2.0", id = 1, method = "initialize",
            params = { capabilities = {}, text = "a\nb\"\\\u{1}q" },
        }
        local back = json.decode(json.encode(msg))
        assert(back.id == 1, "id lost")
        assert(back.method == "initialize", "method lost")
        assert(back.params.text:find("a\nb", 1, true) ~= nil, "escapes lost")
        assert(json.decode('{"a":null}')["a"] == json.null, "null sentinel lost")
        assert(json.encode({ 1, 2, 3 }) == "[1,2,3]", "array shape wrong")
    end)

    ctx.check("lsp: positions map byte locs (utf-8 + utf-16)", function()
        local src = "let x: int = 1;\nlet y: int = 2;\n"
        local starts = positions.line_starts(src)
        local r = positions.loc_to_range(
            { line = 2, col = 5, end_line = 2, end_col = 6 }, src, starts, "utf-8")
        assert(r.start.line == 1 and r.start.character == 4, "utf-8 start wrong")
        assert(r["end"].character == 5, "utf-8 end wrong")
        local u = "let caf\u{c3}\u{a9}: int = 1;\n"
        local ustarts = positions.line_starts(u)
        local line_text = positions.line_text(u, ustarts, 1)
        local c8 = positions.byte_col_to_char(line_text, 8, "utf-8")
        local c16 = positions.byte_col_to_char(line_text, 8, "utf-16")
        assert(c8 == 7, "utf-8 multibyte col wrong: " .. c8)
        assert(c16 == 7, "utf-16 BMP col wrong: " .. c16)
        local l, c = positions.position_to_loc(u, ustarts,
            { line = 0, character = 7 }, "utf-16")
        assert(l == 1 and c == 8, "utf-16 inverse wrong")
    end)

    ctx.check("lsp: buildinfo resolves repo build.lua", function()
        local map, _ = buildinfo.resolve("build.lua", ".")
        local cfg = buildinfo.config_for(map, "samples/programs/01_hello_args.cx")
        assert(cfg ~= nil and cfg.target ~= nil, "no config resolved")
        assert(cfg.target.cc ~= nil, "target missing cc")
        assert(type(cfg.entries) == "table", "entries missing")
    end)

    ctx.check("lsp: buildinfo falls back without build.lua", function()
        local map, warn = buildinfo.resolve("no-such-build.lua", ".")
        assert(warn ~= nil, "expected fallback warning")
        local cfg = buildinfo.config_for(map, "x.cx")
        assert(cfg.target ~= nil and #cfg.entries == 0, "default config wrong")
    end)

    ctx.check("lsp: docs parse valid file with no errors", function()
        local f = assert(io.open("samples/programs/01_hello_args.cx", "r"))
        local src = f:read("*a") or ""
        f:close()
        local map, _ = buildinfo.resolve("build.lua", ".")
        local cfg = buildinfo.config_for(map, "samples/programs/01_hello_args.cx")
        local doc = docs.parse_text(src, cfg)
        assert(doc.root ~= nil, "no root for valid file")
        assert(#doc.errors == 0, "unexpected errors: " .. tostring(
            (doc.errors[1] ~= nil) and doc.errors[1].message or ""))
    end)

    ctx.check("lsp: docs keep partial root around failures", function()
        local cfg = buildinfo.default_config("t.cx")
        local doc = docs.parse_text(
            "let a: int = 1;\nlet broken !!!;\nlet b: int = 2;\n", cfg)
        assert(doc.root ~= nil, "partial root lost")
        assert(#doc.errors >= 1, "expected diagnostics")
        assert(#doc.root.body >= 2, "valid decls should survive")
    end)

    ctx.check("lsp: tokens differ strict vs gnu on ({", function()
        local src = "function f(): int {\nlet x: int = ({ 1; });\nreturn x;\n}\n"
        local strict = docs.parse_text(src, buildinfo.default_config("s.cx"))
        local gnu_mod = require("compiler.extensions.gnu")
        local target_mod = require("compiler.target")
        local target = target_mod.detect({ cc = "gcc", std = "gnu23" })
        local cfg = {
            file = "g.cx", target = target, cc = "gcc", std = "gnu23",
            entries = { { name = "gnu", mod = gnu_mod } },
            dialect = { gnu = true },
        }
        local gnu_doc = docs.parse_text(src, cfg)
        assert(#strict.errors >= 1, "strict should reject ({")
        assert(#gnu_doc.errors == 0, "gnu should accept ({: " .. tostring(
            (gnu_doc.errors[1] ~= nil) and gnu_doc.errors[1].message or ""))
        local s_data = tokens.full(strict, {}, "utf-8")
        local g_data = tokens.full(gnu_doc, cfg.entries, "utf-8")
        assert(#s_data > 0 and #g_data > 0, "empty token streams")
        assert(#g_data ~= #s_data, "gnu tree should tokenize differently")
    end)

    ctx.check("lsp: query completes, hovers, defines", function()
        local cfg = buildinfo.default_config("q.cx")
        local src = "type Handle = int;\nfunction add(a: int, b: int): int {\n"
            .. "let total: int = a;\nreturn total;\n}\n"
        local doc = docs.parse_text(src, cfg)
        doc.uri = "file:///q.cx"
        assert(#doc.errors == 0, "fixture should parse")
        local items = query.complete(doc, 3, 18, {})
        local seen_fn, seen_ty = false, false
        for _, it in ipairs(items) do
            if it.label == "add" then seen_fn = true end
            if it.label == "Handle" then seen_ty = true end
        end
        assert(seen_fn, "function missing from completion")
        assert(seen_ty, "type alias missing from completion")
        local h = query.hover(doc, 2, 10)
        assert(h ~= nil and h:find("add", 1, true) ~= nil, "hover wrong")
        local loc = query.definition(doc, 4, 8)
        assert(loc ~= nil and loc.line == 3, "definition should hit let total")
    end)

    ctx.check("lsp: protocol initialize->open->tokens->completion", function()
        local s = server.new()
        local init = s:handle({ jsonrpc = "2.0", id = 1,
            method = "initialize", params = { capabilities = {} } })[1]
        assert(init.result ~= nil, "no initialize result")
        assert(init.result.capabilities.semanticTokensProvider ~= nil,
            "tokens capability missing")
        local f = assert(io.open("samples/programs/01_hello_args.cx", "r"))
        local src = f:read("*a") or ""
        f:close()
        local uri = "file://samples/programs/01_hello_args.cx"
        local reps = s:handle({ jsonrpc = "2.0", method = "textDocument/didOpen",
            params = { textDocument = { uri = uri, text = src, version = 1 } } })
        assert(#reps == 1 and reps[1].method == "textDocument/publishDiagnostics",
            "didOpen must push diagnostics")
        local tok = s:handle({ jsonrpc = "2.0", id = 2,
            method = "textDocument/semanticTokens/full",
            params = { textDocument = { uri = uri } } })[1]
        assert(tok.result ~= nil and #(tok.result.data or {}) > 0,
            "empty semantic tokens")
        local comp = s:handle({ jsonrpc = "2.0", id = 3,
            method = "textDocument/completion",
            params = { textDocument = { uri = uri },
                position = { line = 0, character = 0 } } })[1]
        assert(comp.result ~= nil and comp.result.items ~= nil,
            "no completion result")
    end)

    ctx.check("lsp: protocol reports broken-file diagnostics, keeps tokens", function()
        local s = server.new()
        s:handle({ jsonrpc = "2.0", id = 1,
            method = "initialize", params = { capabilities = {} } })
        local uri = "file:///broken.cx"
        local reps = s:handle({ jsonrpc = "2.0",
            method = "textDocument/didOpen",
            params = { textDocument = { uri = uri,
                text = "let a: int = 1;\nlet broken !!!;\n", version = 1 } } })
        local diags = reps[1].params.diagnostics
        assert(#diags >= 1, "expected diagnostics")
        assert(diags[1].range ~= nil and diags[1].message ~= nil,
            "diagnostic shape wrong")
        local tok = s:handle({ jsonrpc = "2.0", id = 2,
            method = "textDocument/semanticTokens/full",
            params = { textDocument = { uri = uri } } })[1]
        assert(tok.result ~= nil, "tokens should still work on broken files")
    end)
end
