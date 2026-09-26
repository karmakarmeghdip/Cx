-- Single test entry point for the Cx compiler (P0 scaffold).
-- Discovers `tests/*_test.lua`; each file must return
-- `function run(ctx) ... end` and use plain `assert` + `ctx.check(name, fn)`.
-- Usage:
--   luajit tests/run.lua [--bless] [--filter <substr>] [--help]
-- `--bless` is forwarded to tests via `ctx.bless` (goldens refresh with review).
-- Exit code is 0 on success, 1 on any failure. No network, no luarocks.

---@class TestCtx
---@field bless boolean true when `--bless` was passed
---@field filter string|nil substring filter for check names
---@field fuzz_seed integer PRNG seed for the fuzzer (default 1)
---@field check fun(name: string, fn: fun()) run one named check

local M = {}

--- Print usage to stdout.
local function usage()
    io.stdout:write([[
Usage: luajit tests/run.lua [options]

Options:
  --bless            allow golden snapshots under tests/goldens/ to be (re)generated
  --filter <substr>  run only checks whose "file: name" contains <substr>
  --fuzz-seed <n>    PRNG seed for the fuzzer (default 1)
  --help, -h         print this help
]])
end

--- Parse CLI args.
--- @param args string[]
--- @return table { bless: boolean, filter: string|nil, help: boolean, fuzz_seed: integer }
local function parse_args(args)
    local opts = { bless = false, filter = nil, help = false, fuzz_seed = 1 }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--bless" then
            opts.bless = true
        elseif a == "--fuzz-seed" then
            i = i + 1
            opts.fuzz_seed = tonumber(args[i])
            assert(opts.fuzz_seed ~= nil, "--fuzz-seed requires a numeric value")
        elseif a == "--filter" then
            i = i + 1
            opts.filter = args[i]
            assert(opts.filter, "--filter requires a value")
        elseif a == "--help" or a == "-h" then
            opts.help = true
        else
            error("tests/run.lua: unknown argument '" .. tostring(a) .. "' (try --help)", 0)
        end
        i = i + 1
    end
    return opts
end

--- Discover test files matching tests/*_test.lua, sorted.
--- Uses `ls` via popen (runner-only; compiler itself stays dep-free).
--- @return string[]
local function discover()
    local files = {}
    local handle = io.popen("ls tests/*_test.lua 2>/dev/null | sort")
    if handle then
        for line in handle:lines() do
            line = line:gsub("%s+$", "")
            if line ~= "" then
                files[#files + 1] = line
            end
        end
        handle:close()
    end
    return files
end

--- Main entry: run all discovered test files.
--- @param args string[] CLI args (typically global `arg`)
--- @return integer exit code (0 ok, 1 failures)
function M.main(args)
    local opts = parse_args(args or {})
    if opts.help then
        usage()
        return 0
    end

    local files = discover()
    if #files == 0 then
        io.stderr:write("tests/run.lua: no tests/*_test.lua files found\n")
        return 1
    end

    local passed = 0
    local failed = 0
    local failures = {}

    --- Run one named check, honouring the --filter substring.
    --- @param name string check name
    --- @param fn fun() check body (plain asserts)
    local function do_check(name, fn)
        if opts.filter and not string.find(name, opts.filter, 1, true) then
            return
        end
        local ok, err = pcall(fn)
        if ok then
            passed = passed + 1
            io.stdout:write("  PASS " .. name .. "\n")
        else
            failed = failed + 1
            failures[#failures + 1] = name .. ": " .. tostring(err)
            io.stdout:write("  FAIL " .. name .. "\n         " .. tostring(err) .. "\n")
        end
    end

    ---@type TestCtx
    local ctx = {
        bless = opts.bless,
        filter = opts.filter,
        fuzz_seed = opts.fuzz_seed,
        check = do_check,
    }

    for _, f in ipairs(files) do
        io.stdout:write("== " .. f .. "\n")
        local chunk, load_err = loadfile(f)
        if not chunk then
            failed = failed + 1
            failures[#failures + 1] = f .. ": load error: " .. tostring(load_err)
            io.stdout:write("  FAIL load: " .. tostring(load_err) .. "\n")
        else
            local ok, run_or_err = pcall(chunk)
            if not ok then
                failed = failed + 1
                failures[#failures + 1] = f .. ": " .. tostring(run_or_err)
                io.stdout:write("  FAIL load: " .. tostring(run_or_err) .. "\n")
            elseif type(run_or_err) ~= "function" then
                failed = failed + 1
                failures[#failures + 1] = f .. ": must return function run(ctx)"
                io.stdout:write("  FAIL invalid: must return function run(ctx)\n")
            else
                local ok_run, run_err = pcall(run_or_err, ctx)
                if not ok_run then
                    failed = failed + 1
                    failures[#failures + 1] = f .. ": " .. tostring(run_err)
                    io.stdout:write("  FAIL run: " .. tostring(run_err) .. "\n")
                end
            end
        end
    end

    io.stdout:write(string.format("\n%d passed, %d failed (%d test files)\n", passed, failed, #files))
    if opts.bless then
        io.stdout:write("(note: --bless was on; snapshots may have been refreshed — review the diff)\n")
    end
    if failed > 0 then
        io.stderr:write("Failures:\n")
        for _, e in ipairs(failures) do
            io.stderr:write(" - " .. e .. "\n")
        end
        return 1
    end
    return 0
end

-- When invoked as `luajit tests/run.lua ...`, the global `arg` table holds
-- the CLI args (arg[0] is the script name, arg[1..] are the flags).
-- Detect direct execution (vs. require) via arg[0] so `--bless`/`--filter`
-- flags in `...` cannot suppress the entry point.
local cli_args = rawget(_G, "arg") or {}
if type(cli_args[0]) == "string" and cli_args[0]:match("run%.lua$") then
    local forwarded = {}
    for i = 1, #cli_args do
        forwarded[#forwarded + 1] = cli_args[i]
    end
    local code = M.main(forwarded)
    os.exit(code)
end

return M
