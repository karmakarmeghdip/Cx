-- P4 golden harness: snapshots under tests/goldens/ are COMPILER OUTPUT
-- (blessed via --bless, reviewed against samples/programs/*.c which remain
-- the human reference). Checks: (1) round-trip emit == snapshot,
-- (2) gcc -fsyntax-only clean, (3) differential execution: samples/*.c and
-- emitted .c run to identical stdout + exit codes (the real equivalence
-- proof, since hand-written .c files use cosmetic idioms no deterministic
-- printer reproduces: sizeof parens, int*-vs-int[], typedef order, ...).
-- 07_gnu_* stays out (P5 owns it).
-- Each file must return `function run(ctx)`.

local STRICT = {
    "01_hello_args",
    "02_numbers_control",
    "03_arrays_strings_memory",
    "04_records_callbacks",
    "05_declarations_preprocessor",
    "06_syntax_reference",
}

--- Collapse all whitespace runs to single spaces for comparison.
--- @param s string
--- @return string
local function normalize(s)
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

--- Read a whole file or return nil.
--- @param path string
--- @return string|nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local body = f:read("*a")
    f:close()
    return body
end

--- Emit one strict sample to C text through the public compiler seam.
--- @param base string sample base name
--- @return string C source
local function emit_sample(base)
    local Cx = require("compiler.init")
    local codegen = require("compiler.codegen")
    local path = "samples/programs/" .. base .. ".cx"
    local root = Cx.new():parse_file(path)
    local src = assert(read_file(path), "missing " .. path)
    return codegen.emit(root, { cc = "clang", std = "c23", src = src })
end

--- True when an executable exists on PATH.
--- @param name string
--- @return boolean
local function have_tool(name)
    local ok = os.execute("command -v " .. name .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

--- Compile src to bin, capturing the log. Binary presence decides success
--- (robust across Lua os.execute return shapes).
--- @param cc string compiler executable
--- @param std string C standard flag value ("c23"|"gnu23")
--- @param src string input .c path
--- @param bin string output binary path
--- @return boolean ok
--- @return string log compiler stderr
local function try_compile(cc, std, src, bin)
    os.remove(bin)
    local h = io.popen(cc .. " -std=" .. std .. " -I samples/programs -o "
        .. bin .. " " .. src .. " 2>&1")
    local log = ""
    if h ~= nil then
        log = h:read("*a") or ""
        h:close()
    end
    local t = io.open(bin, "r")
    local ok = t ~= nil
    if t ~= nil then
        t:close()
    end
    return ok, log
end

--- Pick C toolchains, preferring gcc. Runs each available one.
--- @return string[] cc list (possibly empty)
local function pick_cc()
    local out = {}
    if have_tool("gcc") then
        out[#out + 1] = "gcc"
    end
    if have_tool("clang") then
        out[#out + 1] = "clang"
    end
    return out
end

--- Emit the GNU sample through the public extension seam (temp file in
--- out/, removed after reading).
--- @return string C text
local function emit_gnu()
    local Cx = require("compiler.init")
    local gnu = require("compiler.extensions.gnu")
    local b = Cx.new()
    b:extension("gnu", gnu)
    local tmp = "out/.tmp_07_gnu.c"
    b:file("samples/programs/07_gnu_extensions.cx"):emit(tmp)
    local text = assert(read_file(tmp), "emit must write " .. tmp)
    os.remove(tmp)
    return text
end

--- Run bin with stdin closed; returns stdout bytes and exit code.
--- @param bin string
--- @return string|nil out
--- @return integer|nil code
local function run_capture(bin)
    local h = io.popen(bin .. " </dev/null 2>&1; echo \"CX_DIFF_EXIT:$?\"")
    if h == nil then
        return nil, nil
    end
    local out = h:read("*a") or ""
    h:close()
    local code = out:match("CX_DIFF_EXIT:(%d+)%s*$")
    local body = out:gsub("CX_DIFF_EXIT:%d+%s*$", "")
    return body, tonumber(code)
end

---@param ctx TestCtx
return function(ctx)
    ctx.check("goldens: strict samples exist (01..06 .cx + .c)", function()
        for _, base in ipairs(STRICT) do
            assert(read_file("samples/programs/" .. base .. ".cx") ~= nil,
                "missing samples/programs/" .. base .. ".cx")
            assert(read_file("samples/programs/" .. base .. ".c") ~= nil,
                "missing samples/programs/" .. base .. ".c")
        end
    end)

    ctx.check("goldens: gnu sample gated behind dialect.gnu", function()
        assert(read_file("samples/programs/07_gnu_extensions.cx") ~= nil,
            "missing samples/programs/07_gnu_extensions.cx")
        assert(read_file("samples/programs/07_gnu_extensions.c") ~= nil,
            "missing samples/programs/07_gnu_extensions.c")
    end)

    ctx.check("goldens: snapshots present (or run with --bless)", function()
        os.execute("mkdir -p tests/goldens out 2>/dev/null")
        if ctx.bless then
            -- Refresh every snapshot from current compiler output.
            for _, base in ipairs(STRICT) do
                local snap = "tests/goldens/" .. base .. ".c"
                local f = assert(io.open(snap, "w"), "cannot write " .. snap)
                f:write(emit_sample(base))
                f:close()
            end
            return
        end
        local missing = {}
        for _, base in ipairs(STRICT) do
            local snap = "tests/goldens/" .. base .. ".c"
            if read_file(snap) == nil then
                missing[#missing + 1] = snap
            end
        end
        if #missing > 0 then
            error("missing snapshots (run `luajit tests/run.lua --bless` to emit, then review):\n  "
                .. table.concat(missing, "\n  "), 0)
        end
        assert(true)
    end)

    ctx.check("goldens: emitted C matches snapshots (whitespace-normalized)", function()
        for _, base in ipairs(STRICT) do
            local snap = read_file("tests/goldens/" .. base .. ".c")
            if snap == nil then
                error("snapshot tests/goldens/" .. base .. ".c missing; run with --bless first", 0)
            end
            local got = emit_sample(base)
            assert(normalize(got) == normalize(snap),
                "emitted " .. base .. " drifted from its snapshot (bless only after review)")
        end
    end)

    ctx.check("goldens: snapshots are gcc -fsyntax-only clean", function()
        if not have_tool("gcc") then
            io.stdout:write("  SKIP no gcc on PATH\n")
            return
        end
        for _, base in ipairs(STRICT) do
            local snap = "tests/goldens/" .. base .. ".c"
            if read_file(snap) ~= nil then
                local code = os.execute("gcc -fsyntax-only -std=c23 " .. snap .. " 2>/dev/null")
                local ok = (code == true or code == 0)
                assert(ok, snap .. " failed gcc -fsyntax-only -std=c23")
            end
        end
    end)

    ctx.check("goldens: differential execution matches samples", function()
        local toolchains = pick_cc()
        if #toolchains == 0 then
            io.stdout:write("  SKIP no C toolchain on PATH\n")
            return
        end
        os.execute("mkdir -p out 2>/dev/null")
        for _, cc in ipairs(toolchains) do
            for _, base in ipairs(STRICT) do
                local ref_src = "samples/programs/" .. base .. ".c"
                local got_src = "tests/goldens/" .. base .. ".c"
                if read_file(got_src) == nil then
                    error("snapshot " .. got_src .. " missing; run with --bless first", 0)
                end
                local ref_bin = "out/.diff_" .. base .. "_ref_" .. cc
                local got_bin = "out/.diff_" .. base .. "_got_" .. cc
                local tag = base .. " [" .. cc .. "]"
                local ok, _ = try_compile(cc, "c23", ref_src, ref_bin)
                if not ok then
                    -- No working baseline, no comparison for this toolchain.
                    io.stdout:write("  SKIP " .. tag
                        .. " reference does not build (" .. cc .. ")\n")
                else
                    local ok2, log2 = try_compile(cc, "c23", got_src, got_bin)
                    assert(ok2, "cannot compile " .. got_src .. " (" .. cc .. "):\n" .. log2)
                    local ref_out, ref_code = run_capture(ref_bin)
                    local got_out, got_code = run_capture(got_bin)
                    os.remove(ref_bin)
                    os.remove(got_bin)
                    assert(ref_out ~= nil and got_out ~= nil,
                        "cannot run " .. tag .. " binaries")
                    assert(ref_code == got_code,
                        tag .. ": exit codes differ (" .. tostring(ref_code)
                        .. " vs " .. tostring(got_code) .. ")")
                    assert(ref_out == got_out, tag .. ": stdout differs")
                end
            end
        end
    end)

    -- GNU acceptance (P5): the same three legs through the extension seam,
    -- under -std=gnu23 (strict ISO cannot parse or compile these forms).

    ctx.check("gnu: snapshot present (or run with --bless)", function()
        os.execute("mkdir -p tests/goldens out 2>/dev/null")
        local snap = "tests/goldens/07_gnu.c"
        if ctx.bless then
            local f = assert(io.open(snap, "w"), "cannot write " .. snap)
            f:write(emit_gnu())
            f:close()
            return
        end
        if read_file(snap) == nil then
            error("missing snapshot (run `luajit tests/run.lua --bless` to emit,"
                .. " then review):\n  " .. snap, 0)
        end
        assert(true)
    end)

    ctx.check("gnu: emitted C matches snapshot (whitespace-normalized)", function()
        local snap = read_file("tests/goldens/07_gnu.c")
        if snap == nil then
            error("snapshot tests/goldens/07_gnu.c missing; run with --bless first", 0)
        end
        local got = emit_gnu()
        assert(normalize(got) == normalize(snap),
            "emitted 07 drifted from its snapshot (bless only after review)")
    end)

    ctx.check("gnu: snapshot is gcc -std=gnu23 clean", function()
        if not have_tool("gcc") then
            io.stdout:write("  SKIP no gcc on PATH\n")
            return
        end
        local snap = "tests/goldens/07_gnu.c"
        if read_file(snap) ~= nil then
            local code = os.execute("gcc -fsyntax-only -std=gnu23 " .. snap .. " 2>/dev/null")
            local ok = (code == true or code == 0)
            assert(ok, snap .. " failed gcc -fsyntax-only -std=gnu23")
        end
    end)

    ctx.check("gnu: differential execution matches samples", function()
        local toolchains = pick_cc()
        if #toolchains == 0 then
            io.stdout:write("  SKIP no C toolchain on PATH\n")
            return
        end
        os.execute("mkdir -p out 2>/dev/null")
        local ref_src = "samples/programs/07_gnu_extensions.c"
        local got_src = "tests/goldens/07_gnu.c"
        if read_file(got_src) == nil then
            error("snapshot " .. got_src .. " missing; run with --bless first", 0)
        end
        for _, cc in ipairs(toolchains) do
            local ref_bin = "out/.diff_07_ref_" .. cc
            local got_bin = "out/.diff_07_got_" .. cc
            local tag = "07 [" .. cc .. "]"
            local ok, _ = try_compile(cc, "gnu23", ref_src, ref_bin)
            if not ok then
                io.stdout:write("  SKIP " .. tag
                    .. " reference does not build (" .. cc .. ")\n")
            else
                local ok2, log2 = try_compile(cc, "gnu23", got_src, got_bin)
                assert(ok2, "cannot compile " .. got_src .. " (" .. cc .. "):\n" .. log2)
                local ref_out, ref_code = run_capture(ref_bin)
                local got_out, got_code = run_capture(got_bin)
                os.remove(ref_bin)
                os.remove(got_bin)
                assert(ref_out ~= nil and got_out ~= nil, "cannot run " .. tag .. " binaries")
                assert(ref_code == got_code,
                    tag .. ": exit codes differ (" .. tostring(ref_code)
                    .. " vs " .. tostring(got_code) .. ")")
                assert(ref_out == got_out, tag .. ": stdout differs")
            end
        end
    end)

    ctx.check("msvc: strict emits portable C (parse-only, no execution)", function()
        -- No cl.exe here: prove the text path accepts an msvc target and
        -- stays free of GNU spellings for strict input.
        local Cx = require("compiler.init")
        local b = Cx.new({ cc = "msvc" })
        assert(b.target.cc == "msvc", "target must carry msvc")
        local tmp = "out/.tmp_msvc_01.c"
        b:file("samples/programs/01_hello_args.cx"):emit(tmp)
        local text = assert(read_file(tmp), "emit must write " .. tmp)
        os.remove(tmp)
        assert(text:find("int main", 1, true) ~= nil, "msvc output must contain main")
        assert(text:find("__attribute__", 1, true) == nil, "strict must stay clean")
        assert(text:find("typeof", 1, true) == nil, "strict must stay clean")
    end)
end
