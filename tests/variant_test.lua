-- Tests for the Variant / Tagged Union syntax extension (P5).
-- Validates parsing, AST expansion, tag enum generation, anonymous union layout,
-- type aliases, constructor helpers, error cases, and end-to-end C23 execution.

---@param ctx TestCtx
return function(ctx)
    local Cx = require("compiler.init")
    local variantmod = require("compiler.extensions.variant")
    local extension = require("compiler.extension")

    --- Helper: compile a source string to C using compiler with variant extension.
    --- @param src string
    --- @param opts table|nil
    --- @return string
    local function emit_c(src, opts)
        opts = opts or {}
        local b = Cx.new({ cc = opts.cc or "clang", std = opts.std or "c23" })
        b:extension("variant", variantmod)
        local tmp_cx = "out/test_variant_tmp.cx"
        local tmp_c = "out/test_variant_tmp.c"
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
        local c_file = "out/test_variant_run.c"
        local bin_file = "out/test_variant_bin"
        local f = assert(io.open(c_file, "w"))
        f:write(c_code)
        f:close()
        os.remove(bin_file)
        local cmd = cc .. " -std=c23 -Wall -Wextra -o " .. bin_file .. " " .. c_file .. " 2>&1"
        local compile_handle = assert(io.popen(cmd), "failed to run " .. cc)
        local compile_log = compile_handle:read("*a") or ""
        local ok = compile_handle:close()
        assert(ok, cc .. " compilation failed:\n" .. compile_log .. "\nSource:\n" .. c_code)

        local run_handle = assert(io.popen(bin_file .. " </dev/null 2>&1; echo \"CX_EXIT:$?\""),
            "failed to run " .. bin_file)
        local out = run_handle:read("*a") or ""
        run_handle:close()

        local code_str = out:match("CX_EXIT:(%d+)")
        local exit_code = tonumber(code_str) or -1
        local clean_out = out:gsub("CX_EXIT:%d+\n?", "")
        return clean_out, exit_code
    end

    ctx.check("variant: registry validation", function()
        extension.validate("variant", variantmod)
        assert(variantmod.name == "Variant")
        assert(type(variantmod.extend_grammar) == "function")
        assert(type(variantmod.expanders["Ext:Variant:EnumDecl"]) == "function")
    end)

    ctx.check("variant: opt-in dialect guard", function()
        -- Without variant extension, variant payload syntax fails
        local b = Cx.new({ cc = "clang", std = "c23" })
        local src = "enum Shape { Circle(double), Point };\n"
        local tmp_cx = "out/test_variant_guard.cx"
        os.execute("mkdir -p out")
        local f = assert(io.open(tmp_cx, "w"))
        f:write(src)
        f:close()
        local ok = pcall(function()
            b:file(tmp_cx):emit("out/test_variant_guard.c")
        end)
        assert(not ok, "unextended Cx must reject variant payload syntax")
    end)

    ctx.check("variant: standard enum without payloads remains plain C enum", function()
        local src = [[
enum Color {
    Red,
    Green,
    Blue,
};
function main(): int {
    let c: enum Color = Green;
    return c == Green ? 0 : 1;
}
]]
        local c = emit_c(src)
        assert(c:find("enum Color {"), "expected plain enum Color, got:\n" .. c)
        assert(not c:find("enum Color_Tag"), "plain enum must not generate Color_Tag")
    end)

    ctx.check("variant: AST expansion emits tag enum, struct union, aliases, constructors", function()
        local src = [[
enum Shape {
    Circle(double),
    Point,
};
]]
        local c = emit_c(src)
        assert(c:find("enum Shape_Tag {"), "expected enum Shape_Tag in:\n" .. c)
        assert(c:find("Shape_Tag_Circle,"), "expected Shape_Tag_Circle enumerator")
        assert(c:find("Shape_Tag_Point,"), "expected Shape_Tag_Point enumerator")
        assert(c:find("typedef enum Shape_Tag Shape_Tag;"), "expected typedef Shape_Tag")
        assert(c:find("struct Shape {"), "expected struct Shape")
        assert(c:find("enum Shape_Tag tag;"), "expected tag field")
        assert(c:find("union {"), "expected union in struct Shape")
        assert(c:find("double Circle;"), "expected double Circle in union")
        assert(c:find("typedef struct Shape Shape;"), "expected typedef Shape")
        assert(c:find("Shape_Circle%(double _0%)"), "expected Shape_Circle constructor")
        assert(c:find("Shape_Point%(void%)"), "expected Shape_Point constructor")
    end)

    ctx.check("variant: duplicate variant names are rejected", function()
        local src = [[
enum Foo {
    Bar(int),
    Bar(double),
};
]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok, "duplicate variant name must fail")
        assert(tostring(err):find("duplicate variant 'Bar'"), "expected duplicate variant error, got: " .. tostring(err))
    end)

    ctx.check("variant: block scope declaration is rejected", function()
        local src = [[
function test(): void {
    enum Local {
        Val(int),
    };
}
]]
        local ok, err = pcall(function() emit_c(src) end)
        assert(not ok, "block scope variant enum must fail")
        assert(tostring(err):find("file scope"), "expected file scope error, got: " .. tostring(err))
    end)

    ctx.check("variant: sample program compiles with gcc and clang and runs end-to-end", function()
        local src = [[
#include <stdio.h>

enum Shape {
    Circle(double),
    Point,
};

function describe_shape(s: Shape): double {
    switch (s.tag) {
        case Shape_Tag_Circle:
            return s.Circle;
        case Shape_Tag_Point:
            return -1.0;
    }
    return 0.0;
}

function main(): int {
    let c: Shape = Shape_Circle(42.5);
    let p: Shape = Shape_Point();

    if (c.tag != Shape_Tag_Circle) return 1;
    if (describe_shape(c) != 42.5) return 2;

    if (p.tag != Shape_Tag_Point) return 3;
    if (describe_shape(p) != -1.0) return 4;

    return 0;
}
]]
        local c_code = emit_c(src)

        local compilers = {}
        if have_tool("gcc") then compilers[#compilers + 1] = "gcc" end
        if have_tool("clang") then compilers[#compilers + 1] = "clang" end

        for _, cc in ipairs(compilers) do
            local _, exit_code = compile_and_run(c_code, cc)
            assert(exit_code == 0, cc .. " execution failed with code " .. exit_code)
        end
    end)

    ctx.check("variant: multiple payload types with pointers and ints", function()
        local src = [[
#include <string.h>

enum Value {
    IntVal(int),
    StrVal(const char*),
    None,
};

function main(): int {
    let v1: Value = Value_IntVal(123);
    let v2: Value = Value_StrVal("hello");
    let v3: Value = Value_None();

    if (v1.tag != Value_Tag_IntVal || v1.IntVal != 123) return 1;
    if (v2.tag != Value_Tag_StrVal || strcmp(v2.StrVal, "hello") != 0) return 2;
    if (v3.tag != Value_Tag_None) return 3;

    return 0;
}
]]
        local c_code = emit_c(src)

        if have_tool("clang") then
            local _, exit_code = compile_and_run(c_code, "clang")
            assert(exit_code == 0, "clang execution failed with code " .. exit_code)
        end
    end)

    ctx.check("variant: explicit discriminant values survive", function()
        local src = [[
enum Code {
    Success(int) = 0,
    NotFound = 404,
    ServerError(const char*) = 500,
};

function main(): int {
    let s: Code = Code_Success(1);
    let n: Code = Code_NotFound();
    let e: Code = Code_ServerError("fail");

    if (s.tag != 0 || s.Success != 1) return 1;
    if (n.tag != 404) return 2;
    if (e.tag != 500) return 3;

    return 0;
}
]]
        local c_code = emit_c(src)
        assert(c_code:find("Code_Tag_Success = 0,"), "expected Code_Tag_Success = 0")
        assert(c_code:find("Code_Tag_NotFound = 404,"), "expected Code_Tag_NotFound = 404")
        assert(c_code:find("Code_Tag_ServerError = 500,"), "expected Code_Tag_ServerError = 500")

        if have_tool("gcc") then
            local _, exit_code = compile_and_run(c_code, "gcc")
            assert(exit_code == 0, "gcc execution failed with code " .. exit_code)
        end
    end)

    ctx.check("variant: multiple variant enums in one file do not collide", function()
        local src = [[
enum OptionInt {
    Some(int),
    None,
};

enum OptionFloat {
    Some(float),
    None,
};

function main(): int {
    let a: OptionInt = OptionInt_Some(10);
    let b: OptionFloat = OptionFloat_Some(3.5f);

    if (a.tag != OptionInt_Tag_Some || a.Some != 10) return 1;
    if (b.tag != OptionFloat_Tag_Some || b.Some != 3.5f) return 2;

    return 0;
}
]]
        local c_code = emit_c(src)
        if have_tool("clang") then
            local _, exit_code = compile_and_run(c_code, "clang")
            assert(exit_code == 0, "clang execution failed with code " .. exit_code)
        end
    end)
end
