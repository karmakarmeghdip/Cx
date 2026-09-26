use zed_extension_api as zed;

/// Cx language extension: launches `luajit build.lua lsp` (the Cx language
/// server over stdio) with the opened worktree root as the project dir.
///
/// The server reads that directory's `build.lua` as its config source of
/// truth (targets, extensions/dialects per file), so open the Cx project
/// root itself as the worktree for per-file dialect accuracy.
struct CxExtension;

impl zed::Extension for CxExtension {
    fn new() -> Self {
        CxExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> zed::Result<zed::Command> {
        let build_lua = worktree.root_path() + "/build.lua";
        Ok(zed::Command {
            command: "luajit".to_string(),
            args: vec![build_lua, "lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(CxExtension);
