-- build.lua as LSP config source of truth (P1).
-- Replays the user build script with stubbed side effects and records,
-- per .cx file, the compiler config that owns it: {std, cc, triple,
-- target:CxTarget, ext_order, ext_mods, dialect}.
-- Multi-app builds (one Cx.new per binary loop) are supported: the last
-- recording for a file wins. program() graphs expand to every module.
-- Failures (missing build.lua, load/run error) yield a host-default
-- config so the server still works.

local M = {}

---@class LspFileConfig
---@field file string|nil source path the config was resolved for
---@field std string
---@field cc string
---@field triple string|nil
---@field target table CxTarget
---@field entries table[] {{name:string, mod:table}}
---@field dialect table

--- Normalize a path to an absolute-ish key for map lookups.
--- @param p string
--- @return string
local function norm(p)
    if p:sub(1, 1) == "/" then
        return p
    end
    return (M.cwd or ".") .. "/" .. p
end

--- File URI (file://...) to a path.
--- @param uri string
--- @return string path
function M.uri_to_path(uri)
    local p = uri:gsub("^file://", "")
    return p
end

--- Path to file:// URI.
--- @param path string
--- @return string
function M.path_to_uri(path)
    if path:sub(1, 1) == "/" then
        return "file://" .. path
    end
    return "file://" .. (M.cwd or ".") .. "/" .. path
end

--- Default config: host target, strict C23, no extensions.
--- @param file string|nil
--- @return LspFileConfig
function M.default_config(file)
    local target_mod = require("compiler.target")
    local target = target_mod.detect({ cc = "clang", std = "c23" })
    return {
        file = file, std = "c23", cc = "clang", triple = nil,
        target = target, entries = {}, dialect = {},
    }
end

--- Replay build.lua, recording per-file compiler configs.
--- @param build_path string|nil path to build script (default "build.lua")
--- @param cwd string|nil working directory for relative paths
--- @return table<string, LspFileConfig> map norm path -> config
--- @return string|nil warning when falling back to defaults
function M.resolve(build_path, cwd)
    build_path = build_path or "build.lua"
    M.cwd = cwd or "."
    local map = {}
    local f = io.open(build_path, "r")
    if f == nil then
        return map, "build.lua not found; using host defaults"
    end
    f:close()
    local chunk, load_err = loadfile(build_path)
    if chunk == nil then
        return map, "build.lua load error: " .. tostring(load_err)
    end
    local recordings = {}
    local target_mod = require("compiler.target")
    local extension_mod = require("compiler.extension")

    local function snapshot(compiler, paths)
        local entries = {}
        local dialect = {}
        for _, name in ipairs(compiler.ext_order or {}) do
            local mod = (compiler.extensions or {})[name]
            if mod ~= nil then
                entries[#entries + 1] = { name = name, mod = mod }
                dialect[mod.name:lower()] = true
            end
        end
        return {
            std = (compiler.opts and compiler.opts.std) or "c23",
            cc = (compiler.opts and compiler.opts.cc) or "clang",
            triple = compiler.opts and compiler.opts.triple or nil,
            target = compiler.target,
            entries = entries,
            dialect = dialect,
            paths = paths,
        }
    end

    local function record(compiler, paths)
        local snap = snapshot(compiler, paths)
        for _, p in ipairs(paths) do
            recordings[norm(p)] = snap
        end
    end

    -- Stub compiler object mirroring compiler.init's chainable surface.
    local function stub_compiler(opts)
        opts = opts or {}
        local target = opts.target or target_mod.detect({
            triple = opts.triple, cc = opts.cc or "clang", std = opts.std or "c23",
        })
        local self = {
            opts = {
                std = opts.std or "c23", cc = opts.cc or "clang",
                triple = opts.triple, target = opts.target,
            },
            target = target, extensions = {}, ext_order = {},
            sources = {},
        }
        function self:extension(name, mod)
            extension_mod.validate(name, mod)
            self.extensions[name] = mod
            local found = false
            for _, n in ipairs(self.ext_order) do
                if n == name then found = true break end
            end
            if not found then self.ext_order[#self.ext_order + 1] = name end
            return self
        end
        function self:file(path)
            self.sources[#self.sources + 1] = path
            record(self, { path })
            local job = { _c = self, _src = path }
            function job:emit(_)
                return job
            end
            return job
        end
        function self:files(paths)
            for _, p in ipairs(paths) do
                self.sources[#self.sources + 1] = p
            end
            record(self, paths)
            return self
        end
        function self:program(entry, _)
            self.sources[#self.sources + 1] = entry
            record(self, { entry })
            -- Best effort: include graph modules if a graph extension
            -- is registered and entries parse. Failures keep entry only.
            local ok = pcall(function()
                local api = nil
                for _, name in ipairs(self.ext_order) do
                    local mod = self.extensions[name]
                    if mod.graph_api ~= nil then api = mod.graph_api end
                end
                if api == nil then return end
                local modules = require("compiler.modules")
                local G_entries = {}
                for _, name in ipairs(self.ext_order) do
                    G_entries[#G_entries + 1] = { name = name, mod = self.extensions[name] }
                end
                local G = require("compiler.grammar_cx")
                if #G_entries > 0 then
                    G = extension_mod.assemble(G, G_entries,
                        { target = self.target, dialect = snapshot(self, {}).dialect })
                end
                local function parse_fn(path)
                    local fh = assert(io.open(path, "r"))
                    local src = fh:read("*a") or ""
                    fh:close()
                    local lexer = require("compiler.lexer")
                    local core = require("compiler.parser_core")
                    local toks = lexer.lex(src, path)
                    local env = core.new_env({ file = path, src = src,
                        target = self.target, dialect = snapshot(self, {}).dialect, grammar = G })
                    local pp = core.new(toks, env)
                    return pp and G.rules.parseTranslationUnit(pp), src
                end
                local graph = modules.build_graph(entry, parse_fn, api)
                local paths = {}
                for _, pth in ipairs(graph.order or {}) do
                    paths[#paths + 1] = pth
                end
                if #paths > 0 then record(self, paths) end
            end)
            if not ok then
                -- entry-only recording already stored; ignore graph errors
            end
            return self
        end
        function self:emit_all(_)
            record(self, self.sources)
            return self
        end
        function self:cc(_)
            return self
        end
        function self:link(_)
            return self
        end
        function self:run(_)
            return 0
        end
        function self:parse_file(_)
            return nil
        end
        return self
    end

    local stub_init = {
        DEFAULT_STD = "c23", DEFAULT_CC = "clang",
        new = function(opts) return stub_compiler(opts) end,
    }
    local stub_buildkit = setmetatable({}, {
        __index = function(_, k)
            if k == "glob" then
                local real = require("compiler.buildkit")
                return function(dir, suffix) return real.glob(dir, suffix) end
            end
            if k == "exec" then
                return function(_) return true, 0 end
            end
            return function() return nil end
        end,
    })
    local function stub_require(name)
        if name == "compiler.init" then
            return stub_init
        end
        if name == "compiler.buildkit" then
            return stub_buildkit
        end
        return require(name)
    end
    -- NOTE: build.lua reads `rawget(_G, "arg")` directly and calls
    -- `os.exit` on unknown tasks, so the sandbox must shadow _G.arg,
    -- neuter os.exit, and silence usage prints for the replay lifetime.
    local sandbox_os = setmetatable({}, {
        __index = function(_, k)
            if k == "execute" or k == "remove" or k == "rename" then
                return function() return true end
            end
            if k == "exit" then
                return function() error("buildinfo: os.exit blocked", 0) end
            end
            local real_os = os
            return real_os[k]
        end,
    })
    -- Run with a constrained environment: stubs for side effects,
    -- everything else inherited so user logic (loops, globs) still works.
    local env = setmetatable({
        require = stub_require,
        os = sandbox_os,
        arg = {},
    }, { __index = _G })
    if setfenv ~= nil then
        -- LuaJIT path: setfenv exists; PUC-Lua 5.2+ _ENV path not needed.
        setfenv(chunk, env)
    end
    -- Shadow process state the replay must not see or kill.
    local saved_arg = rawget(_G, "arg")
    local saved_stdout = io.stdout
    local saved_stderr = io.stderr
    ---@type table
    local mute
    mute = setmetatable({}, {
        __index = function(_, k)
            if k == "write" or k == "flush" then
                return function() return mute end
            end
            return saved_stdout[k]
        end,
    })
    rawset(_G, "arg", {})
    io.stdout = mute
    io.stderr = mute
    local ok, run_err = pcall(chunk)
    rawset(_G, "arg", saved_arg)
    io.stdout = saved_stdout
    io.stderr = saved_stderr
    if not ok then
        return map, "build.lua error: " .. tostring(run_err)
    end
    for path, snap in pairs(recordings) do
        map[path] = {
            file = path, std = snap.std, cc = snap.cc, triple = snap.triple,
            target = snap.target, entries = snap.entries, dialect = snap.dialect,
        }
    end
    return map, nil
end

--- Config for one file path (falls back to host defaults).
--- @param map table<string, LspFileConfig>
--- @param path string
--- @return LspFileConfig
function M.config_for(map, path)
    local hit = map[norm(path)] or map[path]
    if hit ~= nil then
        hit.file = path
        return hit
    end
    -- Suffix match: build.lua may record relative paths while the
    -- editor sends absolute ones (or vice versa).
    for k, v in pairs(map) do
        if k == path or k:sub(-#path) == path or path:sub(-#k) == k then
            v.file = path
            return v
        end
    end
    return M.default_config(path)
end

return M
