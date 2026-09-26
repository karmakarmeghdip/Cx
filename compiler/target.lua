-- Build targets: triples, host detection, toolchain flag maps (P6).
-- This is the ONLY module that may read host globals (jit.os/jit.arch)
-- or name toolchain binaries. Everything else receives an already-built
-- CxTarget and branches on its fields (AGENTS.md section 10).

local M = {}

---@class CxTarget
---@field triple string e.g. "x86_64-unknown-linux-gnu"
---@field os string "linux"|"windows"|"macos"|...
---@field arch string "x86_64"|"aarch64"|...
---@field abi string "gnu"|"musl"|"msvc"|"darwin"|...
---@field cc string "gcc"|"clang"|"msvc"|"tcc" (the C toolchain, not the host)
---@field std string "c23"|"gnu23"|"c17" (passed as -std= or /std:)

---@class TargetOpts
---@field triple string|nil full triple (overrides os/arch/abi detection)
---@field os string|nil operating system override
---@field arch string|nil architecture override
---@field abi string|nil ABI override
---@field cc string|nil C toolchain (default "clang")
---@field std string|nil C standard (default "c23")

M.DEFAULT_CC = "clang"
M.DEFAULT_STD = "c23"

-- Host mappings (jit.os/jit.arch vocabularies -> CxTarget spellings).
local JIT_OS = {
    Linux = "linux",
    OSX = "macos",
    Windows = "windows",
    BSD = "bsd",
    POSIX = "posix",
}
local JIT_ARCH = {
    x64 = "x86_64",
    x86 = "x86",
    arm64 = "aarch64",
    arm = "arm",
    mips = "mips",
    ppc = "ppc",
}

-- Default ABI per OS (overridable).
local OS_ABI = {
    linux = "gnu",
    windows = "msvc",
    macos = "darwin",
    bsd = "bsd",
    posix = "posix",
}

-- Vendor filler per OS for canonical triples.
local OS_VENDOR = {
    linux = "unknown",
    windows = "pc",
    macos = "apple",
    bsd = "unknown",
    posix = "unknown",
}

--- Split "arch-vendor-os-abi" (4 parts) or "arch-os-abi" (3 parts).
--- @param triple string
--- @return table|nil {arch, vendor, os, abi}
--- @return string|nil err
local function split_triple(triple)
    local parts = {}
    for p in triple:gmatch("[^-]+") do
        parts[#parts + 1] = p
    end
    if #parts == 4 then
        return { arch = parts[1], vendor = parts[2], os = parts[3], abi = parts[4] }
    end
    if #parts == 3 then
        return { arch = parts[1], vendor = nil, os = parts[2], abi = parts[3] }
    end
    return nil, "triple must be arch-vendor-os-abi or arch-os-abi, got '" .. triple .. "'"
end

--- Normalize an arch spelling to canonical form.
--- @param arch string
--- @return string canonical arch
local function norm_arch(arch)
    if arch == "x64" then
        return "x86_64"
    end
    if arch == "arm64" then
        return "aarch64"
    end
    if arch == "amd64" then
        return "x86_64"
    end
    return arch
end

--- Normalize an OS spelling to canonical form.
--- @param os string
--- @return string canonical os
local function norm_os(os)
    if os == "darwin" or os == "macosx" or os == "apple" then
        return "macos"
    end
    if os == "win32" or os == "win64" or os == "mingw32" then
        return "windows"
    end
    return os
end

-- Supported (arch, os, abi) combinations for normalize().
local KNOWN = {
    x86_64 = {
        linux = { gnu = true, musl = true },
        windows = { msvc = true, gnu = true },
        macos = { darwin = true },
    },
    aarch64 = {
        linux = { gnu = true, musl = true },
        windows = { msvc = true, gnu = true },
        macos = { darwin = true },
    },
    x86 = {
        linux = { gnu = true },
        windows = { msvc = true, gnu = true },
    },
}

--- Canonicalize a triple string into CxTarget os/arch/abi fields.
--- Unknown combinations are hard errors listing the supported set.
--- @param triple string
--- @return table {os, arch, abi}
function M.normalize(triple)
    assert(type(triple) == "string", "normalize: triple must be a string")
    local parts, err = split_triple(triple)
    if parts == nil then
        error("target.normalize: " .. err, 0)
    end
    local arch = norm_arch(parts.arch)
    local os = norm_os(parts.os)
    local abi = parts.abi
    -- Accept common aliases: "macos" triples may spell abi "darwin" or "macos".
    if os == "macos" and abi == "macos" then
        abi = "darwin"
    end
    local arches = KNOWN[arch]
    if arches == nil or arches[os] == nil or arches[os][abi] == nil then
        error("target.normalize: unsupported target '" .. triple
            .. "' (want arch x86_64/aarch64/x86 with a matching os/abi)", 0)
    end
    return { os = os, arch = arch, abi = abi }
end

--- Canonical triple string for os/arch/abi fields.
--- @param os string
--- @param arch string
--- @param abi string
--- @return string triple
local function make_triple(os, arch, abi)
    return arch .. "-" .. (OS_VENDOR[os] or "unknown") .. "-" .. os .. "-" .. abi
end

--- Detect (or accept overrides for) the build target. Only this function
--- reads jit.os/jit.arch. Unknown host values are hard errors.
--- @param opts TargetOpts|nil
--- @return CxTarget
function M.detect(opts)
    opts = opts or {}
    assert(opts.cc == nil or type(opts.cc) == "string", "detect: cc must be a string")
    assert(opts.std == nil or type(opts.std) == "string", "detect: std must be a string")
    local os = nil
    local arch = nil
    local abi = opts.abi
    if opts.triple ~= nil then
        local parts = M.normalize(opts.triple)
        os = parts.os
        arch = parts.arch
        abi = abi or parts.abi
    end
    if opts.os ~= nil then
        os = norm_os(opts.os)
    end
    if opts.arch ~= nil then
        arch = norm_arch(opts.arch)
    end
    if os == nil or arch == nil then
        local josh, hos = pcall(function() return jit.os end)
        local jarch, harch = pcall(function() return jit.arch end)
        assert(josh and hos ~= nil, "target.detect: cannot read jit.os (need os override)")
        assert(jarch and harch ~= nil, "target.detect: cannot read jit.arch (need arch override)")
        if os == nil then
            os = JIT_OS[hos]
            assert(os ~= nil, "target.detect: unsupported host os '" .. tostring(hos) .. "'")
        end
        if arch == nil then
            arch = JIT_ARCH[harch]
            assert(arch ~= nil, "target.detect: unsupported host arch '" .. tostring(harch) .. "'")
        end
    end
    if abi == nil then
        abi = OS_ABI[os] or "unknown"
    end
    ---@type CxTarget
    local target = {
        triple = opts.triple or make_triple(os, arch, abi),
        os = os,
        arch = arch,
        abi = abi,
        cc = opts.cc or M.DEFAULT_CC,
        std = opts.std or M.DEFAULT_STD,
    }
    return target
end

--- Quote one shell word when it contains whitespace or quotes.
--- @param w string
--- @return string
local function quote(w)
    if w:find("[%s\"]") == nil then
        return w
    end
    return '"' .. w:gsub('"', '\\"') .. '"'
end

--- Command line (argv array) to compile one C file to one object file.
--- @param target CxTarget
--- @param src string input .c path
--- @param obj string output object path
--- @param flags string[]|nil extra flags appended verbatim
--- @return string[] argv
function M.cc_compile_argv(target, src, obj, flags)
    assert(type(target) == "table", "cc_compile_argv: target required")
    assert(type(src) == "string" and type(obj) == "string", "cc_compile_argv: src/obj required")
    local argv = {}
    if target.cc == "msvc" then
        argv = { "cl", "/nologo", "/std:clatest", "/c", src, "/Fo:" .. obj }
    elseif target.cc == "tcc" then
        argv = { "tcc", "-std=c23", "-c", src, "-o", obj }
    elseif target.cc == "gcc" or target.cc == "clang" then
        argv = { target.cc, "-std=" .. target.std, "-c", src, "-o", obj }
        -- Cross-compiling clang needs an explicit --target (native omits it).
        if target.cc == "clang" then
            local host = M.detect({ cc = target.cc, std = target.std })
            if host.triple ~= target.triple then
                table.insert(argv, 2, "--target=" .. target.triple)
            end
        end
    else
        error("target: unsupported cc '" .. tostring(target.cc)
            .. "' (want gcc|clang|msvc|tcc)", 0)
    end
    if flags ~= nil then
        assert(type(flags) == "table", "cc_compile_argv: flags must be an array")
        for _, f in ipairs(flags) do
            argv[#argv + 1] = f
        end
    end
    return argv
end

--- Command line (argv array) to link objects into a binary.
--- @param target CxTarget
--- @param objs string[] object paths in link order
--- @param out string output binary path
--- @param flags string[]|nil extra flags appended verbatim
--- @return string[] argv
function M.cc_link_argv(target, objs, out, flags)
    assert(type(target) == "table", "cc_link_argv: target required")
    assert(type(objs) == "table" and #objs > 0, "cc_link_argv: objs must be non-empty")
    assert(type(out) == "string", "cc_link_argv: out required")
    local argv = {}
    if target.cc == "msvc" then
        argv = { "link", "/nologo" }
        for _, o in ipairs(objs) do
            argv[#argv + 1] = o
        end
        argv[#argv + 1] = "/OUT:" .. out
    elseif target.cc == "tcc" then
        argv = { "tcc", "-std=c23" }
        for _, o in ipairs(objs) do
            argv[#argv + 1] = o
        end
        argv[#argv + 1] = "-o"
        argv[#argv + 1] = out
    elseif target.cc == "gcc" or target.cc == "clang" then
        argv = { target.cc }
        for _, o in ipairs(objs) do
            argv[#argv + 1] = o
        end
        argv[#argv + 1] = "-o"
        argv[#argv + 1] = out
    else
        error("target: unsupported cc '" .. tostring(target.cc)
            .. "' (want gcc|clang|msvc|tcc)", 0)
    end
    if flags ~= nil then
        assert(type(flags) == "table", "cc_link_argv: flags must be an array")
        for _, f in ipairs(flags) do
            argv[#argv + 1] = f
        end
    end
    return argv
end

--- Join an argv array into a shell command line (quoting as needed).
--- @param argv string[]
--- @return string
function M.join(argv)
    assert(type(argv) == "table", "join: argv must be an array")
    local parts = {}
    for _, w in ipairs(argv) do
        parts[#parts + 1] = quote(w)
    end
    return table.concat(parts, " ")
end

return M
