-- P0 scaffold smoke tests: modules load, defaults match the project
-- setup choice (cc=clang, std=c23), and unimplemented P0 methods fail
-- loudly instead of silently succeeding.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    ctx.check("scaffold: compiler.init loads", function()
        local Cx = require("compiler.init")
        assert(type(Cx) == "table", "compiler.init must return a table")
        assert(type(Cx.new) == "function", "Cx.new missing")
        assert(Cx.DEFAULT_STD == "c23", "DEFAULT_STD must be c23")
        assert(Cx.DEFAULT_CC == "clang", "DEFAULT_CC must be clang (setup choice)")
    end)

    ctx.check("scaffold: Cx.new defaults (std=c23, cc=clang)", function()
        local Cx = require("compiler.init")
        local b = Cx.new()
        assert(b.opts.std == "c23", "default std must be c23, got " .. tostring(b.opts.std))
        assert(b.opts.cc == "clang", "default cc must be clang, got " .. tostring(b.opts.cc))
    end)

    ctx.check("scaffold: Cx.new honors explicit opts", function()
        local Cx = require("compiler.init")
        local b = Cx.new({ std = "c23", cc = "clang" })
        assert(b.opts.std == "c23" and b.opts.cc == "clang", "explicit opts not kept")
    end)

    ctx.check("scaffold: file() queues + emit() writes C", function()
        local Cx = require("compiler.init")
        local b = Cx.new()
        local job = b:file("samples/programs/01_hello_args.cx")
        assert(#b.sources == 1, "file() must queue the source")
        os.execute("mkdir -p out 2>/dev/null")
        job:emit("out/.scaffold_probe.c")
        local f = assert(io.open("out/.scaffold_probe.c", "r"), "emit must write output")
        local body = f:read("*a")
        f:close()
        os.remove("out/.scaffold_probe.c")
        assert(body:find("int main", 1, true) ~= nil, "emitted C must contain main")
    end)

    ctx.check("scaffold: extension() registers", function()
        local Cx = require("compiler.init")
        local b = Cx.new()
        b:extension("gnu", { name = "Gnu",
            extend_grammar = function() end, expanders = {} })
        assert(b.extensions["gnu"] ~= nil, "extension gnu not registered")
        assert(b.ext_order[1] == "gnu", "registration order lost")
    end)

    ctx.check("scaffold: emit_all writes one .c per source", function()
        local Cx = require("compiler.init")
        local b = Cx.new()
        b:file("samples/programs/01_hello_args.cx")
        b:emit_all("out")
        local f = assert(io.open("out/01_hello_args.c", "r"), "emit_all must write output")
        f:close()
        os.remove("out/01_hello_args.c")
    end)

    ctx.check("scaffold: cc/link/run build and execute (or SKIP)", function()
        local cc = nil
        for _, c in ipairs({ "gcc", "clang" }) do
            local ok = os.execute("command -v " .. c .. " >/dev/null 2>&1")
            if ok == true or ok == 0 then
                cc = c
                break
            end
        end
        if cc == nil then
            io.stdout:write("  SKIP no C toolchain on PATH\n")
            return
        end
        local Cx = require("compiler.init")
        local b = Cx.new({ cc = cc })
        b:file("samples/programs/01_hello_args.cx")
        b:cc()
        local obj = io.open("out/01_hello_args.o", "r")
        assert(obj ~= nil, "cc must produce an object file")
        obj:close()
        b:link({ out = "out/.probe_app" })
        local bin = io.open("out/.probe_app", "r")
        assert(bin ~= nil, "link must produce a binary")
        bin:close()
        local code = b:run({ out = "out/.probe_app" })
        assert(code == 0, "run must exit 0, got " .. tostring(code))
        os.remove("out/01_hello_args.c")
        os.remove("out/01_hello_args.o")
        os.remove("out/.probe_app")
    end)

    ctx.check("scaffold: .luarc.json selects LuaJIT", function()
        local f = io.open(".luarc.json", "r")
        assert(f, ".luarc.json missing")
        local body = f:read("*a")
        f:close()
        assert(string.find(body, "LuaJIT", 1, true) ~= nil, ".luarc.json must mention LuaJIT")
    end)

    ctx.check("scaffold: build.lua exposes --help", function()
        local f = io.open("build.lua", "r")
        assert(f, "build.lua missing")
        local body = f:read("*a")
        f:close()
        assert(string.find(body, "%-%-help", 1) ~= nil, "build.lua must mention --help")
    end)
end
