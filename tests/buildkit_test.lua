-- P6 buildkit tests: glob, mkdir-p, mtime queries, incremental skip,
-- and command execution. No compiler state involved.
-- Each file must return `function run(ctx)`.

---@param ctx TestCtx
return function(ctx)
    local buildkit = require("compiler.buildkit")

    ctx.check("buildkit: glob lists and sorts one level", function()
        local files = buildkit.glob("samples/programs", ".cx")
        assert(#files == 9, "nine .cx samples expected, got " .. #files)
        assert(files[1] == "samples/programs/01_hello_args.cx", "sorted first wrong")
        assert(files[#files] == "samples/programs/08_modules_vec.cx",
            "sorted last wrong")
        local none = buildkit.glob("samples/programs", ".zzz")
        assert(#none == 0, "no-match must be empty")
        local missing = buildkit.glob("no/such/dir", ".cx")
        assert(#missing == 0, "missing dir must be empty, not an error")
    end)

    ctx.check("buildkit: mkdir_p is idempotent", function()
        buildkit.mkdir_p("out/.probe/nested")
        buildkit.mkdir_p("out/.probe/nested")
        local f = assert(io.open("out/.probe/nested/marker", "w"))
        f:write("x")
        f:close()
        buildkit.rm_rf("out/.probe")
        assert(io.open("out/.probe/nested/marker", "r") == nil, "rm_rf must clean")
    end)

    ctx.check("buildkit: mtime reads and misses", function()
        local f = assert(io.open("out/.probe_mtime", "w"))
        f:write("x")
        f:close()
        local t = buildkit.mtime("out/.probe_mtime")
        assert(type(t) == "number" and t > 0, "mtime must be a positive number")
        assert(buildkit.mtime("out/.probe_definitely_missing") == nil,
            "missing file must yield nil")
        os.remove("out/.probe_mtime")
    end)

    ctx.check("buildkit: needs_rebuild matrix", function()
        assert(buildkit.needs_rebuild("out/.missing", { "build.lua" }, false) == true,
            "missing output rebuilds")
        assert(buildkit.needs_rebuild("build.lua", { "build.lua" }, true) == true,
            "force rebuilds")
        assert(buildkit.needs_rebuild("build.lua", { "build.lua" }, false) == false,
            "same file is up to date")
        -- Older output than its input rebuilds (input = this file, output probe).
        local f = assert(io.open("out/.probe_old", "w"))
        f:write("x")
        f:close()
        os.execute("sleep 1")
        local g = assert(io.open("out/.probe_new", "w"))
        g:write("x")
        g:close()
        assert(buildkit.needs_rebuild("out/.probe_old", { "out/.probe_new" }, false) == true,
            "older output rebuilds")
        assert(buildkit.needs_rebuild("out/.probe_new", { "out/.probe_old" }, false) == false,
            "newer output skips")
        assert(buildkit.needs_rebuild("out/.probe_new", { "out/.probe_gone" }, false) == true,
            "missing input rebuilds")
        os.remove("out/.probe_old")
        os.remove("out/.probe_new")
    end)

    ctx.check("buildkit: exec codes and quoting", function()
        local ok, code = buildkit.exec({ "true" })
        assert(ok and code == 0, "true must succeed")
        local ok2, code2 = buildkit.exec({ "false" })
        assert(not ok2 and code2 ~= 0, "false must fail")
        local ok3 = buildkit.exec("true")
        assert(ok3, "string form must work")
        assert(buildkit.join({ "echo", "a b" }) == 'echo "a b"', "join must quote")
    end)
end
