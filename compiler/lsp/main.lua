#!/usr/bin/env luajit
-- compiler/lsp/main.lua — Entry point for Cx Language Server

-- Ensure compiler module is loadable from working directory or script location
local script_dir = debug.getinfo(1, "S").source:match("@?(.*)/") or "."
local repo_root = script_dir:match("(.-)/compiler/lsp$") or "."
package.path = repo_root .. "/?.lua;" .. repo_root .. "/?/init.lua;" .. package.path

require("compiler.lsp.server").run()
