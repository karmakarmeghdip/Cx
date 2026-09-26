-- P6 target tests: host detection, triple normalization, and toolchain
-- flag maps (argv shapes only; no toolchain is executed here).
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local target = require("compiler.target")

    ctx.check("target: detects this host sanely", function()
        local t = target.detect()
        assert(t.os ~= nil and t.arch ~= nil, "os/arch required")
        assert(t.cc == "clang" and t.std == "c23", "project defaults must hold")
        assert(t.triple:find(t.arch, 1, true) ~= nil, "triple must carry arch")
        assert(t.triple:find(t.os, 1, true) ~= nil, "triple must carry os")
        local t2 = target.detect({ cc = "gcc", std = "gnu23" })
        assert(t2.cc == "gcc" and t2.std == "gnu23", "overrides must win")
        assert(t2.triple == t.triple, "triple unaffected by cc/std")
    end)

    ctx.check("target: overrides skip host introspection", function()
        local t = target.detect({ os = "windows", arch = "aarch64", abi = "msvc" })
        assert(t.os == "windows" and t.arch == "aarch64" and t.abi == "msvc",
            "explicit fields must win")
        assert(t.triple == "aarch64-pc-windows-msvc", "triple wrong: " .. t.triple)
    end)

    ctx.check("target: normalize accepts the common matrix", function()
        local cases = {
            { "x86_64-unknown-linux-gnu", "linux", "x86_64", "gnu" },
            { "x86_64-unknown-linux-musl", "linux", "x86_64", "musl" },
            { "aarch64-apple-darwin", "macos", "aarch64", "darwin" },
            { "x86_64-pc-windows-msvc", "windows", "x86_64", "msvc" },
            { "aarch64-windows-gnu", "windows", "aarch64", "gnu" },
            { "x86_64-linux-gnu", "linux", "x86_64", "gnu" },
        }
        for _, c in ipairs(cases) do
            local got = target.normalize(c[1])
            assert(got.os == c[2] and got.arch == c[3] and got.abi == c[4],
                c[1] .. " normalized wrong")
        end
        local ok = pcall(target.normalize, "mips-unknown-plan9-x")
        assert(not ok, "unknown triple must fail")
        local ok2 = pcall(target.normalize, "just-a-name")
        assert(not ok2, "short triple must fail")
    end)

    ctx.check("target: triple option feeds normalize", function()
        local t = target.detect({ triple = "aarch64-apple-darwin", cc = "clang" })
        assert(t.os == "macos" and t.arch == "aarch64" and t.abi == "darwin",
            "triple fields wrong")
        assert(t.triple == "aarch64-apple-darwin", "triple must round-trip")
    end)

    ctx.check("target: gcc/clang argv shapes", function()
        local t = target.detect({ triple = "x86_64-unknown-linux-gnu",
            cc = "gcc", std = "c23" })
        local c = target.cc_compile_argv(t, "out/a.c", "out/a.o", { "-Wall" })
        assert(c[1] == "gcc" and c[2] == "-std=c23", "compile head wrong")
        assert(c[#c - 1] == "-o" or c[#c] == "-Wall", "flags must append")
        local found_target = false
        for _, w in ipairs(c) do
            if w:find("--target", 1, true) then
                found_target = true
            end
        end
        assert(not found_target, "native gcc must omit --target")
        local l = target.cc_link_argv(t, { "out/a.o", "out/b.o" }, "out/app", nil)
        assert(l[1] == "gcc" and l[#l - 1] == "-o" and l[#l] == "out/app",
            "link shape wrong: " .. table.concat(l, " "))
    end)

    ctx.check("target: clang --target appears only when cross", function()
        local native = target.detect({ cc = "clang" })
        local c = target.cc_compile_argv(native, "a.c", "a.o", nil)
        for _, w in ipairs(c) do
            assert(w:find("--target", 1, true) == nil, "native clang omits --target")
        end
        -- Flip the host arch so the triple is foreign on any machine.
        local other = (native.arch == "x86_64") and "aarch64" or "x86_64"
        local foreign = target.detect({
            triple = other .. "-unknown-linux-gnu", cc = "clang" })
        local c2 = target.cc_compile_argv(foreign, "a.c", "a.o", nil)
        local seen = false
        for _, w in ipairs(c2) do
            if w == "--target=" .. foreign.triple then
                seen = true
            end
        end
        assert(seen, "cross clang needs --target")
    end)

    ctx.check("target: msvc argv shapes", function()
        local t = target.detect({ triple = "x86_64-pc-windows-msvc",
            cc = "msvc", std = "c23" })
        local c = target.cc_compile_argv(t, "a.c", "a.obj", nil)
        assert(c[1] == "cl", "msvc compile driver wrong")
        local fo, cflag = false, false
        for _, w in ipairs(c) do
            if w == "/Fo:a.obj" then
                fo = true
            end
            if w == "/c" then
                cflag = true
            end
        end
        assert(fo and cflag, "msvc compile needs /c + /Fo:")
        local l = target.cc_link_argv(t, { "a.obj" }, "out/app.exe", nil)
        assert(l[1] == "link" and l[#l] == "/OUT:out/app.exe", "msvc link wrong")
    end)

    ctx.check("target: unknown cc is a hard error", function()
        local t = target.detect({ cc = "frobnicate" })
        local ok = pcall(target.cc_compile_argv, t, "a.c", "a.o", nil)
        assert(not ok, "unknown cc must fail compile argv")
        local ok2 = pcall(target.cc_link_argv, t, { "a.o" }, "app", nil)
        assert(not ok2, "unknown cc must fail link argv")
    end)

    ctx.check("target: tcc maps best-effort", function()
        local t = target.detect({ cc = "tcc" })
        local c = target.cc_compile_argv(t, "a.c", "a.o", nil)
        assert(c[1] == "tcc" and c[2] == "-std=c23", "tcc compile wrong")
    end)

    ctx.check("target: join quotes only when needed", function()
        assert(target.join({ "gcc", "-o", "a b" }) == 'gcc -o "a b"',
            "quoting wrong")
        assert(target.join({ "gcc", "-c" }) == "gcc -c", "plain join wrong")
    end)
end
