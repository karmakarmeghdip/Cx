-- Defer extension tests: LIFO order, early return value capture,
-- loop scoping (continue/break), nested blocks, and error diagnostics.

---@param ctx TestCtx
return function(ctx)
    local Cx = require("compiler.init")
    local extension = require("compiler.extension")
    local defmod = require("compiler.extensions.defer")

    --- Helper: compile a source string to C using compiler with defer extension.
    --- @param src string
    --- @param opts table|nil
    --- @return string
    local function emit_c(src, opts)
        opts = opts or {}
        local b = Cx.new({ cc = opts.cc or "clang", std = opts.std or "c23" })
        b:extension("defer", defmod)
        local tmp_cx = "out/test_defer_tmp.cx"
        local tmp_c = "out/test_defer_tmp.c"
        os.execute("mkdir -p out")
        local f = assert(io.open(tmp_cx, "w"))
        f:write(src)
        f:close()
        b:file(tmp_cx):emit(tmp_c)
        local fc = assert(io.open(tmp_c, "r"))
        local c_code = fc:read("*a")
        fc:close()
        return c_code
    end

    --- True when an executable exists on PATH.
    --- @param name string
    --- @return boolean
    local function have_tool(name)
        local ok = os.execute("command -v " .. name .. " >/dev/null 2>&1")
        return ok == true or ok == 0
    end

    --- Compile C source and run it, returning stdout and exit code.
    --- @param c_code string
    --- @param cc string
    --- @return string stdout
    --- @return integer exit_code
    local function compile_and_run(c_code, cc)
        local c_file = "out/test_defer_run.c"
        local bin_file = "out/test_defer_bin"
        local f = assert(io.open(c_file, "w"))
        f:write(c_code)
        f:close()
        os.remove(bin_file)
        local cmd = cc .. " -std=c23 -o " .. bin_file .. " " .. c_file .. " 2>&1"
        local compile_handle = assert(io.popen(cmd), "failed to run " .. cc)
        local compile_log = compile_handle:read("*a") or ""
        local ok = compile_handle:close()
        assert(ok, cc .. " compilation failed:\n" .. compile_log .. "\nSource:\n" .. c_code)

        local run_handle = assert(io.popen(bin_file .. " </dev/null 2>&1; echo \"CX_EXIT:$?\""),
            "failed to run " .. bin_file)
        local out = run_handle:read("*a") or ""
        run_handle:close()

        local code_str = out:match("CX_EXIT:(%d+)%s*$")
        local clean_out = out:gsub("CX_EXIT:%d+%s*$", "")
        return clean_out, tonumber(code_str) or -1
    end

    ctx.check("defer: registry validation", function()
        extension.validate("defer", defmod)
        assert(defmod.name == "Defer")
        assert(type(defmod.extend_grammar) == "function")
        assert(type(defmod.expanders) == "table")
        assert(type(defmod.expanders["Ext:Defer:Func"]) == "function")
    end)

    ctx.check("defer: opt-in dialect guard", function()
        -- Without the extension registered, `defer` is not recognized as a keyword
        local b = Cx.new()
        local tmp_cx = "out/test_no_defer.cx"
        local f = assert(io.open(tmp_cx, "w"))
        f:write([[
            function test(): void {
                defer return;
            }
        ]])
        f:close()
        local ok, _ = pcall(function()
            b:file(tmp_cx):emit("out/test_no_defer.c")
        end)
        assert(not ok, "unregistered defer should fail parsing")
    end)

    ctx.check("defer: LIFO execution order on normal exit", function()
        local src = [[
            #include <stdio.h>

            function main(): int {
                defer printf("1\n");
                defer printf("2\n");
                defer printf("3\n");
                return 0;
            }
        ]]
        local c = emit_c(src)
        local p3 = c:find('printf%("3\\n"%)')
        local p2 = c:find('printf%("2\\n"%)')
        local p1 = c:find('printf%("1\\n"%)')
        assert(p3 ~= nil and p2 ~= nil and p1 ~= nil)
        assert(p3 < p2 and p2 < p1, "LIFO order violated: expected 3, then 2, then 1")

        if have_tool("clang") then
            local out, code = compile_and_run(c, "clang")
            assert(code == 0)
            assert(out == "3\n2\n1\n", "unexpected stdout:\n" .. out)
        end
    end)

    ctx.check("defer: return value evaluated before cleanup", function()
        local src = [[
            #include <stdio.h>

            function compute(state: int*): int {
                let x = 42;
                defer *state = 99;
                return x;
            }

            function main(): int {
                let s = 0;
                let res = compute(&s);
                if (res == 42 && s == 99) {
                    printf("OK\n");
                    return 0;
                }
                return 1;
            }
        ]]
        local c = emit_c(src)
        if have_tool("gcc") then
            local out, code = compile_and_run(c, "gcc")
            assert(code == 0)
            assert(out == "OK\n", "unexpected stdout:\n" .. out)
        end
    end)

    ctx.check("defer: early return with nested blocks", function()
        local src = [[
            #include <stdio.h>

            function test(flag: int): int {
                defer printf("outer\n");
                if (flag > 0) {
                    defer printf("inner\n");
                    if (flag == 1) {
                        return 10;
                    }
                    printf("inner-fallthrough\n");
                }
                printf("outer-fallthrough\n");
                return 20;
            }

            function main(): int {
                printf("--- call 1 ---\n");
                let r1 = test(1);
                printf("ret=%d\n", r1);

                printf("--- call 2 ---\n");
                let r2 = test(2);
                printf("ret=%d\n", r2);
                return 0;
            }
        ]]
        local c = emit_c(src)
        if have_tool("clang") then
            local out, code = compile_and_run(c, "clang")
            assert(code == 0)
            local expected = "--- call 1 ---\ninner\nouter\nret=10\n"
                .. "--- call 2 ---\ninner-fallthrough\ninner\nouter-fallthrough\nouter\nret=20\n"
            assert(out == expected, "got:\n" .. out .. "\nexpected:\n" .. expected)
        end
    end)

    ctx.check("defer: loop scope with continue and break", function()
        local src = [[
            #include <stdio.h>

            function main(): int {
                for (let i = 0; i < 4; i = i + 1) {
                    defer printf("defer-loop %d\n", i);
                    if (i == 1) {
                        printf("continue %d\n", i);
                        continue;
                    }
                    if (i == 2) {
                        printf("break %d\n", i);
                        break;
                    }
                    printf("body %d\n", i);
                }
                return 0;
            }
        ]]
        local c = emit_c(src)
        if have_tool("gcc") then
            local out, code = compile_and_run(c, "gcc")
            assert(code == 0)
            local expected = "body 0\n"
                .. "defer-loop 0\n"
                .. "continue 1\n"
                .. "defer-loop 1\n"
                .. "break 2\n"
                .. "defer-loop 2\n"
            assert(out == expected, "got:\n" .. out .. "\nexpected:\n" .. expected)
        end
    end)

    ctx.check("defer: compound statement body defer { ... }", function()
        local src = [[
            #include <stdio.h>

            function main(): int {
                let a = 1;
                let b = 2;
                defer {
                    a = 10;
                    b = 20;
                    printf("a=%d b=%d\n", a, b);
                }
                printf("running\n");
                return 0;
            }
        ]]
        local c = emit_c(src)
        if have_tool("clang") then
            local out, code = compile_and_run(c, "clang")
            assert(code == 0)
            assert(out == "running\na=10 b=20\n")
        end
    end)

    ctx.check("defer: switch break cleanup", function()
        local src = [[
            #include <stdio.h>

            function test_switch(x: int): void {
                switch (x) {
                    case 1: {
                        defer printf("case 1 cleanup\n");
                        printf("case 1 body\n");
                        break;
                    }
                    default: {
                        printf("default body\n");
                        break;
                    }
                }
            }

            function main(): int {
                test_switch(1);
                test_switch(2);
                return 0;
            }
        ]]
        local c = emit_c(src)
        if have_tool("gcc") then
            local out, code = compile_and_run(c, "gcc")
            assert(code == 0)
            assert(out == "case 1 body\ncase 1 cleanup\ndefault body\n")
        end
    end)

    ctx.check("defer: reject escaping return from defer body", function()
        local src = [[
            function test(): int {
                defer return 1;
                return 0;
            }
        ]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok)
        assert(tostring(err):find("cannot 'return' from inside a defer body"),
            "expected return rejection, got: " .. tostring(err))
    end)

    ctx.check("defer: reject escaping break from defer body", function()
        local src = [[
            function test(): void {
                while (1) {
                    defer break;
                }
            }
        ]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok)
        assert(tostring(err):find("cannot 'break' from inside a defer body"),
            "expected break rejection, got: " .. tostring(err))
    end)

    ctx.check("defer: reject escaping continue from defer body", function()
        local src = [[
            function test(): void {
                while (1) {
                    defer continue;
                }
            }
        ]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok)
        assert(tostring(err):find("cannot 'continue' from inside a defer body"),
            "expected continue rejection, got: " .. tostring(err))
    end)

    ctx.check("defer: reject nested defer statement", function()
        local src = [[
            function test(): void {
                defer {
                    defer printf("no\n");
                }
            }
        ]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok)
        assert(tostring(err):find("nested 'defer' statements are not allowed"),
            "expected nested defer rejection, got: " .. tostring(err))
    end)

    ctx.check("defer: reject goto across active defer scope", function()
        local src = [[
            function test(): void {
                defer printf("cleanup\n");
                goto done;
            done:
                return;
            }
        ]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok)
        assert(tostring(err):find("'goto' across active defer scopes is not supported"),
            "expected goto rejection, got: " .. tostring(err))
    end)

    ctx.check("defer: portable standard C emitted for MSVC target", function()
        local src = [[
            function compute(n: int): int {
                defer n = n + 1;
                if (n < 0) {
                    return -1;
                }
                return n * 2;
            }
        ]]
        local c = emit_c(src, { cc = "msvc" })
        -- Verify no compiler-specific keywords or attributes were emitted
        assert(not c:find("__attribute__"), "msvc code must not contain __attribute__")
        assert(not c:find("__cleanup"), "msvc code must not contain __cleanup")
        assert(not c:find("__try"), "msvc code must not contain SEH __try")
        assert(c:find("int compute%(int n%)"), "function signature intact")
        assert(c:find("int __cx_ret_"), "standard return variable emitted")
    end)

    ctx.check("defer: sample program compiles and runs end-to-end", function()
        local b = Cx.new({ cc = "clang", std = "c23" })
        b:extension("defer", defmod)
        local out_c = "out/test_10_defer.c"
        b:file("samples/defer/10_defer.cx"):emit(out_c)
        local fc = assert(io.open(out_c, "r"))
        local c_code = fc:read("*a")
        fc:close()

        if have_tool("gcc") then
            local out, code = compile_and_run(c_code, "gcc")
            assert(code == 0)
            assert(out:find("returned value = 105"), "sample ran successfully with gcc")
        end
        if have_tool("clang") then
            local out, code = compile_and_run(c_code, "clang")
            assert(code == 0)
            assert(out:find("returned value = 105"), "sample ran successfully with clang")
        end
    end)
end
