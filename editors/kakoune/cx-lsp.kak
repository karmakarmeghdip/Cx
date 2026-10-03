# cx-lsp.kak — Kakoune-lsp integration for Cx
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾

# Register Cx language ID with kak-lsp
hook -group lsp-language-id global BufSetOption filetype=cx %{
    set-option buffer lsp_language_id cx
}

# Register cx-lsp server configuration
hook -group lsp-filetype-cx global BufSetOption filetype=cx %{
    set-option buffer lsp_language_id cx
    set-option buffer lsp_servers %sh{
        if command -v cx-lsp >/dev/null 2>&1; then
            cat <<'EOF'
[cx-lsp]
root_globs = ["build.lua", ".git"]
command = "cx-lsp"
EOF
        else
            cat <<'EOF'
[cx-lsp]
root_globs = ["build.lua", ".git"]
command = "luajit"
args = ["compiler/lsp/main.lua"]
EOF
        fi
    }
}

# Auto-enable LSP and inlay hints when opening Cx files
hook -group lsp-enable-cx global WinSetOption filetype=cx %{
    set-option buffer lsp_language_id cx
    try %{
        lsp-enable-window
        lsp-inlay-hints-enable window
    } catch %{
        echo -debug "cx-lsp: kak-lsp not available or failed to initialize window"
    }
}

# Retroactively configure already open buffers
evaluate-commands -buffer * %{
    evaluate-commands %sh{
        if [ "$kak_opt_filetype" = "cx" ] || [ "${kak_buffile%.cx}" != "$kak_buffile" ]; then
            printf 'set-option buffer filetype cx\n'
            printf 'set-option buffer lsp_language_id cx\n'
            if command -v cx-lsp >/dev/null 2>&1; then
                printf 'set-option buffer lsp_servers %%{\n[cx-lsp]\nroot_globs = ["build.lua", ".git"]\ncommand = "cx-lsp"\n}\n'
            else
                printf 'set-option buffer lsp_servers %%{\n[cx-lsp]\nroot_globs = ["build.lua", ".git"]\ncommand = "luajit"\nargs = ["compiler/lsp/main.lua"]\n}\n'
            fi
        fi
    }
}

# Retroactively enable LSP in current window if editing a .cx file
evaluate-commands %sh{
    case "$kak_buffile" in
        *.cx)
            printf 'try %%{ lsp-enable-window; lsp-inlay-hints-enable window } catch %%{}\n'
            ;;
    esac
}

# Useful shortcuts in Kakoune 'user' mode (<space> in default kakoune)
map global user l ': enter-user-mode lsp<ret>'             -docstring 'LSP menu'
map global user k ': lsp-hover<ret>'                      -docstring 'LSP hover'
map global user d ': lsp-definition<ret>'                 -docstring 'LSP definition'
map global user s ': lsp-signature-help<ret>'             -docstring 'LSP signature help'
map global user y ': lsp-document-symbol<ret>'            -docstring 'LSP document symbols'
map global user i ': lsp-inlay-hints-enable window<ret>'  -docstring 'Enable inlay hints'
map global user I ': lsp-inlay-hints-disable window<ret>' -docstring 'Disable inlay hints'
