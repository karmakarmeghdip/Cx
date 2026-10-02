-- Tests for the Pipe operator syntax extension (P5).
-- Validates parsing, Pratt operator precedence, placeholder '_' substitution,
-- error reporting, AST rewrites, and end-to-end execution.

---@param ctx TestCtx
return function(ctx)
    local Cx = require("compiler.init")
    local pipemod = require("compiler.extensions.pipe")
    local extension = require("compiler.extension")

    --- Helper: compile a source string to C using compiler with pipe extension.
    --- @param src string
    --- @param opts table|nil
    --- @return string
    local function emit_c(src, opts)
        opts = opts or {}
        local b = Cx.new({ cc = opts.cc or "clang", std = opts.std or "c23" })
        b:extension("pipe", pipemod)
        local tmp_cx = "out/test_pipe_tmp.cx"
        local tmp_c = "out/test_pipe_tmp.c"
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
        local c_file = "out/test_pipe_run.c"
        local bin_file = "out/test_pipe_bin"
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

        local exit_str = out:match("CX_EXIT:(%d+)")
        local stdout = out:gsub("CX_EXIT:%d+\n?", "")
        return stdout, tonumber(exit_str) or -1
    end

    ctx.check("pipe: registry validation", function()
        assert(pipemod.name == "Pipe")
        extension.validate("pipe", pipemod)
    end)

    ctx.check("pipe: opt-in dialect guard", function()
        local b = Cx.new({ cc = "clang", std = "c23" })
        local src = "function main(): int { let x: int = 1 |> inc(); return x; }\n"
        local tmp_cx = "out/test_pipe_guard.cx"
        local tmp_c = "out/test_pipe_guard.c"
        os.execute("mkdir -p out")
        local f = assert(io.open(tmp_cx, "w"))
        f:write(src)
        f:close()
        local ok, err = pcall(function()
            b:file(tmp_cx):emit(tmp_c)
        end)
        assert(not ok, "strict mode should reject '|>'")
        assert(tostring(err):find("found '|>'"),
            "expected parse/syntax error without pipe extension, got: " .. tostring(err))
    end)

    ctx.check("pipe: basic thread-first call f()", function()
        local src = [[
function double_it(n: int): int { return n * 2; }
function main(): int {
    let x: int = 10 |> double_it();
    return x;
}
]]
        local c = emit_c(src)
        assert(c:find("double_it%(10%)"), "expected double_it(10), got:\n" .. c)
    end)

    ctx.check("pipe: thread-first with existing arguments f(a, b)", function()
        local src = [[
function add(a: int, b: int): int { return a + b; }
function main(): int {
    let x: int = 10 |> add(20);
    return x;
}
]]
        local c = emit_c(src)
        assert(c:find("add%(10, 20%)"), "expected add(10, 20), got:\n" .. c)
    end)

    ctx.check("pipe: bare identifier callee f", function()
        local src = [[
function inc(n: int): int { return n + 1; }
function main(): int {
    let x: int = 41 |> inc;
    return x;
}
]]
        local c = emit_c(src)
        assert(c:find("inc%(41%)"), "expected inc(41), got:\n" .. c)
    end)

    ctx.check("pipe: struct function pointer vs pipe (no collision)", function()
        local src = [[
struct Task {
    run: ((int) => int)*;
};
function helper(t: struct Task, n: int): int { return n; }
function main(): int {
    let t: struct Task;
    // Standard struct member function pointer call must stay untouched
    let a: int = t.run(42);
    // Piping struct into free function (thread-first)
    let b: int = t |> helper(100);
    // Piping struct into member function pointer via placeholder
    let c: int = t |> _.run(99);
    return a + b + c;
}
]]
        local c = emit_c(src)
        assert(c:find("t%.run%(42%)"), "t.run(42) must remain untouched, got:\n" .. c)
        assert(c:find("helper%(t, 100%)"), "helper(t, 100) expected, got:\n" .. c)
        assert(c:find("t%.run%(99%)"), "t.run(99) expected, got:\n" .. c)
    end)

    ctx.check("pipe: slot placeholder in arguments f(1, _, 2)", function()
        local src = [[
function div(a: int, b: int): int { return a / b; }
function tri(a: int, b: int, c: int): int { return a + b + c; }
function main(): int {
    let x: int = 2 |> div(10, _);
    let y: int = 10 |> div(_, 2);
    let z: int = 5 |> tri(1, _, 10);
    return x + y + z;
}
]]
        local c = emit_c(src)
        assert(c:find("div%(10, 2%)"), "expected div(10, 2), got:\n" .. c)
        assert(c:find("div%(10, 2%)"), "expected div(10, 2), got:\n" .. c)
        assert(c:find("tri%(1, 5, 10%)"), "expected tri(1, 5, 10), got:\n" .. c)
    end)

    ctx.check("pipe: slot placeholder in expressions", function()
        local src = [[
function main(): int {
    let a: int = 10 |> _ * 2;
    let b: int = 10 |> _ + 1 |> _ * 2;
    let c: int = 10 |> _ * 2 |> _ + 1;
    let d: int = 42 |> _;
    return a + b + c + d;
}
]]
        local c = emit_c(src)
        assert(c:find("10 %* 2"), "expected 10 * 2, got:\n" .. c)
        assert(c:find("%(10 %+ 1%) %* 2"), "expected (10 + 1) * 2, got:\n" .. c)
        assert(c:find("10 %* 2 %+ 1"), "expected 10 * 2 + 1, got:\n" .. c)
        assert(c:find("int d = 42;"), "expected 42, got:\n" .. c)
    end)

    ctx.check("pipe: multi-stage chaining", function()
        local src = [[
function add(a: int, b: int): int { return a + b; }
function mul(a: int, b: int): int { return a * b; }
function sub(a: int, b: int): int { return a - b; }
function main(): int {
    let res: int = 5
        |> add(10)
        |> mul(2)
        |> sub(_, 1);
    return res;
}
]]
        local c = emit_c(src)
        assert(c:find("sub%(mul%(add%(5, 10%), 2%), 1%)"), "expected sub(mul(add(5, 10), 2), 1), got:\n" .. c)
    end)

    ctx.check("pipe: reject multiple placeholders", function()
        local src = [[
function bad(a: int, b: int): int { return a + b; }
function main(): int {
    let x: int = 10 |> bad(_, _);
    return x;
}
]]
        local ok, err = pcall(function()
            emit_c(src)
        end)
        assert(not ok, "multiple '_' should be rejected")
        assert(tostring(err):find("pipe placeholder '_' may only appear once"),
            "expected placeholder error, got: " .. tostring(err))
    end)

    ctx.check("pipe: reject invalid target without placeholder", function()
        local src = [[
function main(): int {
    let x: int = 10 |> 20;
    return x;
}
]]
        local ok, err = pcall(function()
            emit_c(src)
        end)
        assert(not ok, "literal without placeholder should be rejected")
        assert(tostring(err):find("requires a function call or '_' placeholder"),
            "expected target error, got: " .. tostring(err))
    end)

    ctx.check("pipe: raw ident @_ is not a placeholder", function()
        local src = [[
function wrap(a: int, b: int): int { return a + b; }
function main(): int {
    let @_: int = 99;
    let x: int = 10 |> wrap(@_);
    return x;
}
]]
        local c = emit_c(src)
        assert(c:find("wrap%(10, _%)"), "expected wrap(10, _), got:\n" .. c)
    end)

    ctx.check("pipe: sample program compiles and runs end-to-end", function()
        local cc = have_tool("gcc") and "gcc" or (have_tool("clang") and "clang" or nil)
        if not cc then
            return
        end

        local src = [[
#include <stdio.h>

function add(a: int, b: int): int { return a + b; }
function mul(a: int, b: int): int { return a * b; }
function square(x: int): int { return x * x; }

function main(): int {
    let val: int = 3
        |> add(2)        // 3 + 2 = 5
        |> square        // 5 * 5 = 25
        |> mul(2)        // 25 * 2 = 50
        |> _ - 8         // 50 - 8 = 42
        |> _ / 2;        // 42 / 2 = 21

    printf("RESULT:%d\n", val);
    return 0;
}
]]
        local c = emit_c(src, { cc = cc })
        local stdout, code = compile_and_run(c, cc)
        assert(code == 0, "expected exit code 0, got " .. code)
        assert(stdout:find("RESULT:21"), "expected RESULT:21, got: " .. stdout)
    end)
end
