-- build.lua — user-modifiable build script (P6 demo).
-- Canonical wiring lives here; heavy lifting belongs in compiler/init.lua
-- and compiler/buildkit.lua. See AGENTS.md section 9.
-- Usage: luajit build.lua <task> [--flag ...]   (try `luajit build.lua --help`)
-- CxCompiler is single-app oriented: multi-binary builds loop one instance
-- per app, as `build` below demonstrates.

local Cx = require("compiler.init")
local buildkit = require("compiler.buildkit")

local argv = rawget(_G, "arg") or {}

--- Print CLI help to stdout.
local function usage()
    io.stdout:write([[
Cx build script (P6 demo)

Usage:
  luajit build.lua <task> [--flag ...]

Tasks:
  help            print this help (default when no task is given)
  test            run the test suite (forwards extra flags to tests/run.lua)
  emit            emit samples/programs/01_hello_args.cx to out/01.c
  build           emit+compile+link the strict samples (01-06) to out/<stem>
  run <stem>      build (if needed) and execute one sample, forwarding args
  clean           remove the out/ tree

Flags:
  --help, -h      print this help
  --std <std>     C standard, default "c23"
  --cc <cc>       C toolchain, default "clang"
  --force         rebuild everything, skipping no outputs

Examples:
  luajit build.lua --help
  luajit build.lua test
  luajit build.lua build --cc gcc
  luajit build.lua run 01_hello_args -- foo bar
  luajit build.lua clean
]])
end

--- Shift `--key value` / `--key=value` flags out of argv.
--- @param list string[]
--- @return table opts parsed flags
--- @return string[] rest positional args
local function parse_flags(list)
    local opts = { std = Cx.DEFAULT_STD, cc = Cx.DEFAULT_CC, force = false }
    local rest = {}
    local i = 1
    while i <= #list do
        local a = list[i]
        if a == "--help" or a == "-h" then
            opts.help = true
        elseif a == "--force" then
            opts.force = true
        elseif a == "--std" then
            i = i + 1
            opts.std = list[i]
            assert(opts.std, "--std requires a value")
        elseif a == "--cc" then
            i = i + 1
            opts.cc = list[i]
            assert(opts.cc, "--cc requires a value")
        elseif a == "--" then
            for j = i + 1, #list do
                rest[#rest + 1] = list[j]
            end
            break
        else
            rest[#rest + 1] = a
        end
        i = i + 1
    end
    return opts, rest
end

--- Binary path for a sample stem under out/ (.exe on Windows targets).
--- @param b CxCompiler
--- @param stem string e.g. "01_hello_args"
--- @return string
local function sample_bin(b, stem)
    if b.target.os == "windows" then
        return "out/" .. stem .. ".exe"
    end
    return "out/" .. stem
end

--- Strict sample inputs for the demo (07 needs dialect.gnu + gnu std;
--- see the golden harness instead).
--- @return string[] .cx paths 01-06 in order
local function strict_samples()
    local out = {}
    for _, f in ipairs(buildkit.glob("samples/programs", ".cx")) do
        if f:match("/0[1-6]_") ~= nil then
            out[#out + 1] = f
        end
    end
    return out
end

--- Emit + compile + link one sample; skips work already up to date.
--- @param flags table parsed flags
--- @param src string .cx path
--- @return string binary path
local function build_one(flags, src)
    local stem = (src:match("([^/]*)$") or src):gsub("%.cx$", "")
    local b = Cx.new({ std = flags.std, cc = flags.cc })
    local bin = sample_bin(b, stem)
    if not flags.force and not buildkit.needs_rebuild(bin, { src }) then
        io.stdout:write("up to date: " .. bin .. "\n")
        return bin
    end
    b:file(src)
    b:cc({ force = flags.force })
    b:link({ out = bin, force = flags.force })
    io.stdout:write("built: " .. bin .. "\n")
    return bin
end

local flags, rest = parse_flags(argv)
local task = rest[1]

if flags.help or task == nil or task == "help" then
    usage()
    return
end

if task == "test" then
    local extra = {}
    for i = 2, #rest do
        extra[#extra + 1] = rest[i]
    end
    local cmd = "luajit tests/run.lua"
    if #extra > 0 then
        cmd = cmd .. " " .. table.concat(extra, " ")
    end
    local ok = os.execute(cmd)
    if ok ~= true and ok ~= 0 then
        error("build.lua: test task failed", 0)
    end
    return
end

if task == "emit" then
    -- Canonical shape: instantiate, register extensions, compile, emit.
    local b = Cx.new({ std = flags.std, cc = flags.cc })
    -- b:extension("gnu", require("compiler.extensions.gnu"))
    b:file("samples/programs/01_hello_args.cx"):emit("out/01.c")
    io.stdout:write("emitted: out/01.c\n")
    return
end

if task == "build" then
    for _, src in ipairs(strict_samples()) do
        build_one(flags, src)
    end
    return
end

if task == "run" then
    local want = rest[2]
    assert(want ~= nil, "build.lua run needs a sample stem (try `run 01`)")
    local found = nil
    for _, src in ipairs(strict_samples()) do
        local stem = (src:match("([^/]*)$") or src):gsub("%.cx$", "")
        if stem == want or stem:sub(1, #want) == want then
            found = src
            break
        end
    end
    assert(found ~= nil, "build.lua: no sample matches '" .. want .. "'")
    local bin = build_one(flags, found)
    local pargs = { bin }
    for i = 3, #rest do
        pargs[#pargs + 1] = rest[i]
    end
    local _, code = buildkit.exec(pargs)
    os.exit(code or 0)
end

if task == "clean" then
    buildkit.rm_rf("out")
    io.stdout:write("cleaned: out/\n")
    return
end

io.stderr:write("build.lua: unknown task '" .. tostring(task) .. "' (try --help)\n")
os.exit(2)
