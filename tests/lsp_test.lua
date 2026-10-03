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
    ctx.check("lsp: semantic tokens fine-grained classification", function()
        local cfg = buildinfo.default_config("fine.cx")
        local src = "// comment line\nlet count: int = 100;\nfunction test(val: int): int {\nreturn val + 1;\n}\n"
        local doc = docs.parse_text(src, cfg)
        local data = tokens.full(doc, {}, "utf-8")
        assert(#data >= 25, "insufficient tokens emitted")
        -- Legended types: "comment" is idx 10, "keyword" is 0, "variable" is 5, "type" is 1, "number" is 12, "function" is 4
        -- Verify that tokens exist for comment (idx 10) and number (idx 12)
        local has_comment, has_number, has_function = false, false, false
        for i = 1, #data, 5 do
            local tok_type = data[i + 3]
            if tok_type == 10 then has_comment = true end
            if tok_type == 12 then has_number = true end
            if tok_type == 4 then has_function = true end
        end
        assert(has_comment, "missing comment token")
        assert(has_number, "missing number token")
        assert(has_function, "missing function token")
    end)

    ctx.check("lsp: extension completions and snippets", function()
        local defer_mod = require("compiler.extensions.defer")
        local cfg = {
            file = "defer_test.cx",
            entries = { { name = "defer", mod = defer_mod } },
            dialect = { defer = true },
        }
        local src = "function main(): int {\nlet x: int = 0;\n\nreturn x;\n}\n"
        local doc = docs.parse_text(src, cfg)
        local items = query.complete(doc, 3, 1, cfg.entries, { snippet_support = true })
        local found_defer = nil
        for _, it in ipairs(items) do
            if it.label == "defer" then
                found_defer = it
                break
            end
        end
        assert(found_defer ~= nil, "defer completion missing")
        assert(found_defer.insertTextFormat == 2, "defer should use snippet format")
        assert(found_defer.insertText:find("${1:", 1, true) ~= nil, "defer snippet placeholder missing")
    end)

    ctx.check("lsp: extension hover documentation", function()
        local defer_mod = require("compiler.extensions.defer")
        local pipe_mod = require("compiler.extensions.pipe")
        local gnu_mod = require("compiler.extensions.gnu")
        local entries = {
            { name = "defer", mod = defer_mod },
            { name = "pipe", mod = pipe_mod },
            { name = "gnu", mod = gnu_mod },
        }
        -- Test defer hover
        local dnode = { kind = "Cx:Defer:Item", loc = { file = "t.cx", line = 1, col = 1 } }
        local dhover = defer_mod.lsp_hover(dnode, {})
        assert(dhover ~= nil and dhover:find("Defer Statement", 1, true) ~= nil, "defer hover failed")

        -- Test pipe hover
        local pnode = { kind = "Ext:Pipe:Infix", loc = { file = "t.cx", line = 1, col = 1 } }
        local phover = pipe_mod.lsp_hover(pnode, {})
        assert(phover ~= nil and phover:find("Pipeline Operator", 1, true) ~= nil, "pipe hover failed")

        -- Test gnu stmt expr hover
        local gnode = { kind = "Cx:Gnu:StmtExpr", loc = { file = "t.cx", line = 1, col = 1 } }
        local ghover = gnu_mod.lsp_hover(gnode, {})
        assert(ghover ~= nil and ghover:find("GNU Statement Expression", 1, true) ~= nil, "gnu hover failed")
    end)

    ctx.check("lsp: signature help tracks active parameter", function()
        local cfg = buildinfo.default_config("sig.cx")
        local src = "function compute(a: int, b: int, c: int): int { return a + b + c; }\nfunction run(): void {\ncompute(10, \n}\n"
        local doc = docs.parse_text(src, cfg)
        local sig = query.signature_help(doc, 3, 13, {})
        assert(sig ~= nil, "signature help returned nil")
        assert(sig.activeParameter == 1, "activeParameter should be 1 (second param) but got " .. tostring(sig.activeParameter))
        assert(#sig.signatures == 1, "expected 1 signature")
        assert(#sig.signatures[1].parameters == 3, "expected 3 parameters")
        assert(sig.signatures[1].label:find("compute", 1, true) ~= nil, "signature label mismatch")
    end)

    ctx.check("lsp: inlay hints infer types and parameter names", function()
        local cfg = buildinfo.default_config("inlay.cx")
        local src = "function add(x: int, y: int): int { return x + y; }\nlet answer = 42;\nlet total: int = add(1, 2);\n"
        local doc = docs.parse_text(src, cfg)
        local hints = query.inlay_hints(doc, nil, {}, "utf-8")
        assert(#hints >= 2, "expected at least 2 inlay hints, got " .. #hints)
        local found_type_hint = false
        local found_param_hint = false
        for _, h in ipairs(hints) do
            if h.kind == 1 and h.label == ": int" then
                found_type_hint = true
            elseif h.kind == 2 and (h.label == "x:" or h.label == "y:") then
                found_param_hint = true
            end
        end
        assert(found_type_hint, "inferred type inlay hint missing")
        assert(found_param_hint, "parameter name inlay hint missing")
    end)

    ctx.check("lsp: document symbols outline functions and structs", function()
        local cfg = buildinfo.default_config("outline.cx")
        local src = "struct Point { x: int; y: int; };\nfunction draw(p: Point): void {}\n"
        local doc = docs.parse_text(src, cfg)
        local syms = query.document_symbols(doc, "utf-8")
        assert(#syms == 2, "expected 2 top-level symbols, got " .. #syms)
        local struct_sym, func_sym = nil, nil
        for _, s in ipairs(syms) do
            if s.name == "Point" then struct_sym = s end
            if s.name == "draw" then func_sym = s end
        end
        assert(struct_sym ~= nil and struct_sym.kind == 23, "struct symbol missing or wrong kind")
        assert(struct_sym.children ~= nil and #struct_sym.children == 2, "struct fields missing")
        assert(func_sym ~= nil and func_sym.kind == 12, "function symbol missing or wrong kind")
    end)

    ctx.check("lsp: protocol handles signatureHelp, inlayHint, and documentSymbol", function()
        local s = server.new()
        local init = s:handle({ jsonrpc = "2.0", id = 1,
            method = "initialize",
            params = {
                capabilities = {
                    textDocument = {
                        completion = { completionItem = { snippetSupport = true } },
                    },
                },
            }
        })[1]
        assert(init.result.capabilities.signatureHelpProvider ~= nil, "signatureHelpProvider capability missing")
        assert(init.result.capabilities.inlayHintProvider ~= nil, "inlayHintProvider capability missing")
        assert(init.result.capabilities.documentSymbolProvider ~= nil, "documentSymbolProvider capability missing")
        assert(s.snippet_support == true, "server should acknowledge snippetSupport")

        local uri = "file:///api.cx"
        local src = "function add(a: int, b: int): int { return a + b; }\nlet res = add(10, 20);\n"
        s:handle({ jsonrpc = "2.0", method = "textDocument/didOpen",
            params = { textDocument = { uri = uri, text = src, version = 1 } } })

        -- Test signatureHelp over protocol
        local sig_res = s:handle({ jsonrpc = "2.0", id = 2,
            method = "textDocument/signatureHelp",
            params = { textDocument = { uri = uri }, position = { line = 1, character = 18 } } })[1]
        assert(sig_res.result ~= nil and sig_res.result.signatures ~= nil, "protocol signatureHelp failed")

        -- Test inlayHint over protocol
        local hint_res = s:handle({ jsonrpc = "2.0", id = 3,
            method = "textDocument/inlayHint",
            params = { textDocument = { uri = uri }, range = { start = { line = 0, character = 0 }, ["end"] = { line = 2, character = 0 } } } })[1]
        assert(hint_res.result ~= nil and #hint_res.result > 0, "protocol inlayHint failed")

        -- Test documentSymbol over protocol
        local sym_res = s:handle({ jsonrpc = "2.0", id = 4,
            method = "textDocument/documentSymbol",
            params = { textDocument = { uri = uri } } })[1]
        assert(sym_res.result ~= nil and #sym_res.result >= 1, "protocol documentSymbol failed")
    end)
end
