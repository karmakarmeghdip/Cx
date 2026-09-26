-- Build-script helpers: glob, mkdir-p, mtime queries, incremental skip,
-- and command execution (P6). Pure helpers over compiler state; build.lua
-- composes these instead of reimplementing parsing or shell logic.

local M = {}

--- List files in `dir` ending with `suffix`, sorted. Returns paths joined
--- as dir/name. Missing directories yield an empty list (not an error).
--- @param dir string directory, e.g. "samples/programs"
--- @param suffix string e.g. ".cx"
--- @return string[]
function M.glob(dir, suffix)
    assert(type(dir) == "string" and type(suffix) == "string",
        "glob: dir and suffix must be strings")
    local out = {}
    local handle = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if handle == nil then
        return out
    end
    for name in handle:lines() do
        name = name:gsub("%s+$", "")
        if #name >= #suffix and name:sub(-#suffix) == suffix then
            out[#out + 1] = dir .. "/" .. name
        end
    end
    handle:close()
    table.sort(out)
    return out
end

--- mkdir -p (idempotent). Raises on failure.
--- @param dir string
function M.mkdir_p(dir)
    assert(type(dir) == "string", "mkdir_p: dir must be a string")
    local ok = os.execute('mkdir -p "' .. dir .. '"')
    assert(ok == true or ok == 0, "buildkit: cannot create directory " .. dir)
end

--- Modification time (seconds since epoch), or nil when missing.
--- Branches on `os_hint` ("linux"|"macos"|...) for the stat spelling;
--- defaults to the host via jit when available.
--- @param path string
--- @param os_hint string|nil
--- @return integer|nil
function M.mtime(path, os_hint)
    assert(type(path) == "string", "mtime: path must be a string")
    local probe = io.open(path, "r")
    if probe == nil then
        return nil
    end
    probe:close()
    local os_name = os_hint
    if os_name == nil then
        local ok, hos = pcall(function() return jit.os end)
        if ok and hos == "OSX" then
            os_name = "macos"
        elseif ok and hos == "Windows" then
            os_name = "windows"
        else
            os_name = "linux"
        end
    end
    local cmd = nil
    if os_name == "macos" or os_name == "bsd" then
        cmd = 'stat -f %m "' .. path .. '" 2>/dev/null'
    else
        cmd = 'stat -c %Y "' .. path .. '" 2>/dev/null'
    end
    local handle = io.popen(cmd)
    if handle == nil then
        return nil
    end
    local text = handle:read("*a") or ""
    handle:close()
    return tonumber(text:match("%d+"))
end

--- True when `out` must be rebuilt: missing, forced, or any input newer.
--- @param out string output path
--- @param ins string[] input paths
--- @param force boolean|nil rebuild unconditionally
--- @return boolean
function M.needs_rebuild(out, ins, force)
    assert(type(out) == "string", "needs_rebuild: out must be a string")
    assert(type(ins) == "table", "needs_rebuild: ins must be an array")
    if force then
        return true
    end
    local out_t = M.mtime(out)
    if out_t == nil then
        return true
    end
    for _, input in ipairs(ins) do
        local in_t = M.mtime(input)
        if in_t == nil or in_t > out_t then
            return true
        end
    end
    return false
end

--- Join an argv array into a shell command (quoting words as needed).
--- @param argv string[]
--- @return string
function M.join(argv)
    assert(type(argv) == "table", "join: argv must be an array")
    local parts = {}
    for _, w in ipairs(argv) do
        assert(type(w) == "string", "join: argv words must be strings")
        if w:find('[%s"]') == nil then
            parts[#parts + 1] = w
        else
            parts[#parts + 1] = '"' .. w:gsub('"', '\\"') .. '"'
        end
    end
    return table.concat(parts, " ")
end

--- Run a command (argv array or pre-joined string). Returns true + exit
--- code 0 convention: ok is true exactly when the exit status is zero.
--- @param cmd string[]|string
--- @return boolean ok
--- @return integer|nil code best-effort exit code
function M.exec(cmd)
    local line = nil
    if type(cmd) == "table" then
        line = M.join(cmd)
    else
        assert(type(cmd) == "string", "exec: cmd must be argv or string")
        line = cmd
    end
    local ok, _, code = os.execute(line)
    if ok == true or ok == 0 then
        return true, 0
    end
    if type(code) == "number" then
        return false, code
    end
    if type(ok) == "number" then
        return ok == 0, ok
    end
    return false, nil
end

--- Remove a file or directory tree (rm -rf). Raises on failure.
--- Used by `clean` tasks; prefer it over ad-hoc os.execute in build scripts.
--- @param path string
function M.rm_rf(path)
    assert(type(path) == "string", "rm_rf: path must be a string")
    local ok = os.execute('rm -rf "' .. path .. '"')
    assert(ok == true or ok == 0, "buildkit: cannot remove " .. path)
end

return M
