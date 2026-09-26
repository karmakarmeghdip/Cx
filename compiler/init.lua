-- Cx compiler public API.
-- Pipeline: .cx -> lexer -> parser-core + grammar-table -> AST
-- -> (P5: expand loop) -> codegen -> .c -> (P6: cc/link).
-- See AGENTS.md sections 7, 9, 10.

local extension = require("compiler.extension")
local target_mod = require("compiler.target")

local M = {}

M.VERSION = "0.0.0-p4"
M.DEFAULT_STD = "c23"
M.DEFAULT_CC = "clang"

---@class CxOptions
---@field std string|nil C standard, e.g. "c23" (default "c23")
---@field cc string|nil C toolchain, e.g. "clang" (default "clang")
---@field triple string|nil target triple override (default: host)
---@field target table|nil prebuilt CxTarget (skips detection)

---@class CxCompiler
---@field opts CxOptions resolved options ({std, cc, triple?, target?})
---@field target table CxTarget, built once via target.detect
---@field sources string[] queued .cx input paths
---@field extensions table<string, any> registered extensions by name
---@field ext_order string[] registration order (deterministic assembly)
---@field program_units table<string, table>|nil linked modules by path (program only)
---@field program_order string[]|nil module paths in dependency order (program only)
local CxCompiler = {}
CxCompiler.__index = CxCompiler

--- Read + lex + parse one .cx file. Shared by parse_file (AST only) and
--- the emit path (which also needs the source text for cinit slices).
--- The full CxTarget threads into ParseEnv (read-only proxy).
--- @param path string input .cx path
--- @param self CxCompiler
--- @param entries table[] {{name: string, mod: table}} in order
--- @return table root Cx:TranslationUnit (possibly holding Ext:* nodes)
--- @return string src file text
local function compile_source(path, self, entries)
    assert(type(path) == "string", "compile_source: path must be a string")
    local f = assert(io.open(path, "r"), "Cx: cannot open " .. path)
    local src = f:read("*a") or ""
    f:close()
    local lexer = require("compiler.lexer")
    local core = require("compiler.parser_core")
    local target = self.target
    local dialect = {}
    for _, e in ipairs(entries) do
        dialect[e.mod.name:lower()] = true
    end
    local G = require("compiler.grammar_cx")
    if #entries > 0 then
        G = extension.assemble(G, entries, { target = target, dialect = dialect })
    end
    local toks = lexer.lex(src, path)
    local env = core.new_env({
        file = path,
        src = src,
        target = target,
        dialect = dialect,
        grammar = G,
    })
    local p = core.new(toks, env)
    local root = core.parse_unit(p, G.rules.parseTranslationUnit, "translation unit")
    return root, src
end

--- Ordered extension entries for deterministic assembly.
--- @param self CxCompiler
--- @return table[] {{name: string, mod: table}}
local function ext_entries(self)
    local list = {}
    for _, name in ipairs(self.ext_order) do
        list[#list + 1] = { name = name, mod = self.extensions[name] }
    end
    return list
end

--- Object path for an emitted C file (sibling .o, or .obj for msvc).
--- @param cfile string emitted .c path
--- @param target CxTarget # CxTarget
--- @return string
local function obj_of(cfile, target)
    if target.cc == "msvc" then
        return cfile:gsub("%.c$", "") .. ".obj"
    end
    return cfile:gsub("%.c$", "") .. ".o"
end

--- Default link output for a target (out/app, out/app.exe on Windows).
--- @param target CxTarget # CxTarget
--- @return string
local function default_bin(target)
    if target.os == "windows" then
        return "out/app.exe"
    end
    return "out/app"
end

--- Emit one linked AST to a .c path (mkdir -p for the output directory).
--- Runs the expansion fixpoint when extensions are registered.
--- @param self CxCompiler
--- @param root table Cx:TranslationUnit (possibly holding Ext:* nodes)
--- @param src string file text (cinit slices)
--- @param entries table[] {{name: string, mod: table}} in order
--- @param out string output .c path
local function emit_root(self, root, src, entries, out)
    if #entries > 0 then
        local expand = require("compiler.expand")
        local expanders = extension.collect_expanders(entries)
        local dialect = {}
        for _, e in ipairs(entries) do
            dialect[e.mod.name:lower()] = true
        end
        root = expand.expand(root, expanders,
            { target = self.target, dialect = dialect })
    end
    local codegen = require("compiler.codegen")
    local text = codegen.emit(root, {
        cc = self.opts.cc, std = self.opts.std, src = src, target = self.target,
    })
    local dir = out:match("^(.*)/[^/]*$")
    if dir ~= nil then
        local ok = os.execute('mkdir -p "' .. dir .. '"')
        assert(ok == true or ok == 0, "emit: cannot create directory " .. dir)
    end
    local f = assert(io.open(out, "w"), "emit: cannot write " .. out)
    f:write(text)
    f:close()
end

--- Emit one source to a .c path (mkdir -p for the output directory).
--- Runs the expansion fixpoint when extensions are registered.
--- @param self CxCompiler
--- @param srcpath string input .cx path
--- @param out string output .c path
local function do_emit(self, srcpath, out)
    local entries = ext_entries(self)
    local root, src = compile_source(srcpath, self, entries)
    emit_root(self, root, src, entries, out)
end

--- Create a new compiler instance.
--- P0 default (per project setup choice): `{ std = "c23", cc = "clang" }`.
--- @param opts CxOptions|nil
--- @return CxCompiler
function M.new(opts)
    opts = opts or {}
    local resolved = {
        std = opts.std or M.DEFAULT_STD,
        cc = opts.cc or M.DEFAULT_CC,
        triple = opts.triple,
        target = opts.target,
    }
    local self = setmetatable({
        opts = resolved,
        target = opts.target or target_mod.detect({
            triple = opts.triple, cc = resolved.cc, std = resolved.std,
        }),
        sources = {},
        extensions = {},
        ext_order = {},
        program_units = nil,
        program_order = nil,
    }, CxCompiler)
    return self
end

--- Queue a single .cx input file.
--- @param path string input .cx path
--- @return CxFileJob job handle supporting `:emit(out)`
function CxCompiler:file(path)
    assert(type(path) == "string", "CxCompiler:file(path: string) required")
    self.sources[#self.sources + 1] = path
    ---@class CxFileJob
    local job = {
        _compiler = self,
        _src = path,
    }
    --- Emit the queued file to a .c output path.
    --- @param out string output .c path
    --- @return CxFileJob
    function job:emit(out)
        assert(type(out) == "string", "file job :emit(out: string) required")
        do_emit(job._compiler, job._src, out)
        return job
    end
    return job
end

--- Queue several .cx input files at once.
--- @param paths string[]
--- @return CxCompiler self (chainable)
function CxCompiler:files(paths)
    assert(type(paths) == "table", "CxCompiler:files(paths: string[]) required")
    for _, p in ipairs(paths) do
        self:file(p)
    end
    return self
end

--- Register a dialect/extension module (shape-validated now; P5).
--- Re-registering a name replaces the module in place (order kept).
--- @param name string extension name, e.g. "gnu"
--- @param mod CxExtension
--- @return CxCompiler self (chainable)
function CxCompiler:extension(name, mod)
    extension.validate(name, mod)
    self.extensions[name] = mod
    local found = false
    for _, n in ipairs(self.ext_order) do
        if n == name then
            found = true
            break
        end
    end
    if not found then
        self.ext_order[#self.ext_order + 1] = name
    end
    return self
end

--- Parse a .cx file into a RAW AST (lex + grammar, no expansion).
--- With extensions registered the tree may hold Ext:* nodes; the emit
--- path expands them. Parse errors raise with file:line:col + snippet.
--- @param path string input .cx path
--- @return table CxNode AST root (Cx:TranslationUnit)
function CxCompiler:parse_file(path)
    assert(type(path) == "string", "CxCompiler:parse_file(path: string) required")
    local root, _ = compile_source(path, self, ext_entries(self))
    return root
end

--- Emit all queued sources to outdir (one `<stem>.c` each; P6 adds
--- incremental skip on top of this plain loop). Sources that came from
--- program() re-emit their linked ASTs instead of re-parsing.
--- @param outdir string|nil output directory (default "out")
--- @return CxCompiler self (chainable)
function CxCompiler:emit_all(outdir)
    assert(outdir == nil or type(outdir) == "string", "emit_all(outdir: string?) required")
    outdir = outdir or "out"
    local entries = ext_entries(self)
    for _, src in ipairs(self.sources) do
        local base = src:match("([^/]*)$") or src
        local stem = base:gsub("%.cx$", "")
        local out = outdir .. "/" .. stem .. ".c"
        local unit = self.program_units ~= nil and self.program_units[src] or nil
        if unit ~= nil then
            emit_root(self, unit.root, unit.src, entries, out)
        else
            do_emit(self, src, out)
        end
    end
    return self
end

--- Compile a multi-file program: resolve the import graph reachable from
--- `entry`, link prototypes across TUs (compiler/modules.lua), and emit
--- one .c per module. Works with any registered graph extension (one that
--- provides graph_api, e.g. modules); exactly one must be registered.
--- v1 needs unique basenames across the program. Queues every module so
--- cc()/link() work unchanged; replaces any previously queued sources.
--- @param entry string entry .cx path
--- @param outdir string|nil output directory (default "out")
--- @return CxCompiler self (chainable)
function CxCompiler:program(entry, outdir)
    assert(type(entry) == "string", "CxCompiler:program(entry: string) required")
    assert(outdir == nil or type(outdir) == "string", "program(outdir: string?) required")
    local api = nil
    for _, name in ipairs(self.ext_order) do
        local mod = self.extensions[name]
        if mod.graph_api ~= nil then
            assert(api == nil,
                "program: multiple graph extensions registered"
                .. " (register exactly one, e.g. modules)")
            api = mod.graph_api
        end
    end
    assert(api ~= nil,
        "program: needs a registered graph extension"
        .. " (b:extension(\"modules\", require(\"compiler.extensions.modules\")))")
    outdir = outdir or "out"
    local modules = require("compiler.modules")
    local entries = ext_entries(self)
    local function parse_fn(path)
        return compile_source(path, self, entries)
    end
    local graph = modules.build_graph(entry, parse_fn, api)
    modules.link_graph(graph, api)
    local seen = {}
    local units = {}
    local order = {}
    for _, path in ipairs(graph.order) do
        local base = path:match("([^/]*)$") or path
        local stem = base:gsub("%.cx$", "")
        assert(seen[stem] == nil,
            "program: basename collision on '" .. stem
            .. "' (v1 needs unique basenames; rename a module)")
        seen[stem] = true
        local unit = graph.units[path]
        local cfile = outdir .. "/" .. stem .. ".c"
        emit_root(self, unit.root, unit.src, entries, cfile)
        units[path] = { root = unit.root, src = unit.src, cfile = cfile }
        order[#order + 1] = path
    end
    self.sources = order
    self.program_units = units
    self.program_order = order
    return self
end

---@class CcOpts
---@field flags string[]|nil extra compiler flags appended verbatim
---@field force boolean|nil rebuild everything, skipping no outputs

--- Compile every queued source: emit to out/<stem>.c, then to objects.
--- Up-to-date objects are skipped unless opts.force (mtime-based).
--- @param opts CcOpts|nil
--- @return CxCompiler self (chainable)
function CxCompiler:cc(opts)
    opts = opts or {}
    assert(type(opts) == "table", "cc(opts: table?) required")
    local buildkit = require("compiler.buildkit")
    self:emit_all("out")
    for _, src in ipairs(self.sources) do
        local base = src:match("([^/]*)$") or src
        local stem = base:gsub("%.cx$", "")
        local cfile = "out/" .. stem .. ".c"
        local obj = obj_of(cfile, self.target)
        if buildkit.needs_rebuild(obj, { cfile }, opts.force) then
            local argv = target_mod.cc_compile_argv(
                self.target, cfile, obj, opts.flags)
            local ok, code = buildkit.exec(argv)
            if not ok then
                error("cc: failed (code " .. tostring(code) .. ") "
                    .. "(is '" .. self.target.cc .. "' installed?): "
                    .. buildkit.join(argv), 0)
            end
        end
    end
    return self
end

---@class LinkOpts
---@field out string|nil output binary (default out/app[.exe])
---@field flags string[]|nil extra linker flags appended verbatim
---@field force boolean|nil rebuild everything, skipping no outputs

--- Link all queued sources' objects into one binary (single-app oriented;
--- multi-binary builds loop one CxCompiler per app, see build.lua).
--- @param opts LinkOpts|nil
--- @return CxCompiler self (chainable)
function CxCompiler:link(opts)
    opts = opts or {}
    assert(type(opts) == "table", "link(opts: table?) required")
    assert(#self.sources > 0, "link: nothing queued (nothing to link)")
    local buildkit = require("compiler.buildkit")
    local objs = {}
    for _, src in ipairs(self.sources) do
        local base = src:match("([^/]*)$") or src
        local stem = base:gsub("%.cx$", "")
        objs[#objs + 1] = obj_of("out/" .. stem .. ".c", self.target)
    end
    local out = opts.out or default_bin(self.target)
    if buildkit.needs_rebuild(out, objs, opts.force) then
        local dir = out:match("^(.*)/[^/]*$")
        if dir ~= nil then
            buildkit.mkdir_p(dir)
        end
        local argv = target_mod.cc_link_argv(self.target, objs, out, opts.flags)
        local ok, code = buildkit.exec(argv)
        if not ok then
            error("link: failed (code " .. tostring(code) .. "): "
                .. buildkit.join(argv), 0)
        end
    end
    return self
end

---@class RunOpts
---@field out string|nil output binary (default out/app[.exe])
---@field args string[]|nil argv forwarded to the binary
---@field flags string[]|nil extra compiler/linker flags
---@field force boolean|nil rebuild everything

--- Emit + compile + link, then execute the binary forwarding opts.args.
--- @param opts RunOpts|nil
--- @return integer exit code of the binary
function CxCompiler:run(opts)
    opts = opts or {}
    assert(type(opts) == "table", "run(opts: table?) required")
    local buildkit = require("compiler.buildkit")
    self:cc({ flags = opts.flags, force = opts.force })
    self:link({ out = opts.out, flags = opts.flags, force = opts.force })
    local bin = opts.out or default_bin(self.target)
    local argv = { bin }
    for _, a in ipairs(opts.args or {}) do
        argv[#argv + 1] = a
    end
    local _, code = buildkit.exec(argv)
    if code == nil then
        return 0
    end
    return code
end

M.CxCompiler = CxCompiler

return M
