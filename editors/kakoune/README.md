# Kakoune Editor Support for Cx

This directory provides first-class support for the **Cx** programming language in [Kakoune](https://kakoune.org/) with [kak-lsp](https://github.com/kakoune-lsp/kakoune-lsp).

---

## Features

- **Syntax Highlighting (`cx.kak`)**:
  - Full grammar highlighting for core keywords (`function`, `let`, `type`, `struct`, `union`, `enum`, `sizeof`, `typeof`, etc.).
  - Builtin primitive types (`int`, `size_t`, `int64_t`, `_BitInt`, `_Complex`, etc.).
  - Extension keywords (`defer`, `|>`, `__auto_type`, `__asm__`, `__label__`, etc.).
  - Comments (`//` and `/* ... */`), raw strings (`R"(...)"`), character and numeric literals.
  - C preprocessor directives (`#include`, `#define`, `#if`, etc.).
  - Smart indentation hooks on `{`, `}`, `:`, and newlines.
- **LSP Integration (`cx-lsp.kak` & `kak-lsp.toml`)**:
  - **Semantic Tokens**: AST-fused semantic token highlighting via `kak-lsp`.
  - **Inlay Hints**: Parameter names (`param:`) and inferred `let` types (`: type`).
  - **Autocomplete & Snippets**: Context-aware completion with tabstops (`defer`, functions, struct members).
  - **Signature Help**: Active parameter tracking as you type function arguments.
  - **Hover**: Formatted signatures and dialect/extension explanations.
  - **Go-to Definition**: Direct jumping to declarations in the current file or across imported modules.
  - **Document Symbols**: Hierarchical file outline.

---

## Directory Structure

| File | Description |
| :--- | :--- |
| [`cx.kak`](file:///home/meghdip/Projects/Cx/editors/kakoune/cx.kak) | Kakoune language module: filetype detection, highlighters, indentation, comment settings |
| [`cx-lsp.kak`](file:///home/meghdip/Projects/Cx/editors/kakoune/cx-lsp.kak) | `kak-lsp` bridge: server registration, auto-enable hooks, user mode shortcuts |
| [`kak-lsp.toml`](file:///home/meghdip/Projects/Cx/editors/kakoune/kak-lsp.toml) | Drop-in configuration snippet for `kak-lsp` |
| [`kakrc`](file:///home/meghdip/Projects/Cx/editors/kakoune/kakrc) | Minimal standalone rc for testing Cx and `kak-lsp` in a test session |
| [`test_session.sh`](file:///home/meghdip/Projects/Cx/editors/kakoune/test_session.sh) | Automated test script verifying Kakoune, kak-lsp, and `cx-lsp` integration |

---

## Quick Test (Zero Installation)

You can test Cx editing with Kakoune and `kak-lsp` directly from this repository without modifying your personal configuration:

```bash
# 1. Add Cx LSP launcher to PATH for the current session
export PATH="$(pwd)/bin:$PATH"

# 2. Run the automated integration test
./editors/kakoune/test_session.sh

# 3. Launch Kakoune with the test config on a sample Cx file
kak -e 'source editors/kakoune/kakrc' samples/programs/01_hello_args.cx
```

---

## Permanent Installation

### 1. Install Kakoune Language Files

Symlink or copy `cx.kak` and `cx-lsp.kak` into your Kakoune autoload directory:

```bash
mkdir -p ~/.config/kak/autoload/filetype/
ln -sf "$(pwd)/editors/kakoune/cx.kak" ~/.config/kak/autoload/filetype/cx.kak
ln -sf "$(pwd)/editors/kakoune/cx-lsp.kak" ~/.config/kak/autoload/filetype/cx-lsp.kak
```

### 2. Put `cx-lsp` on your `PATH`

Link the language server binary into `~/.local/bin` (or `/usr/local/bin`):

```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/bin/cx-lsp" ~/.local/bin/cx-lsp
```

### 3. Ensure `kak-lsp` is Enabled

If you already use `kak-lsp` in your `kakrc`, `cx-lsp.kak` will configure it automatically whenever a `.cx` file is opened.

Alternatively, if you prefer configuring servers in `~/.config/kak-lsp/kak-lsp.toml`, append:

```toml
[language_server.cx]
filetypes = ["cx"]
roots = ["build.lua", ".git"]
command = "cx-lsp"
```

---

## Keybindings (`user` mode)

In Kakoune, press `<space>` (or your custom `user` mode leader) to access these shortcuts:

| Shortcut | Command | Action |
| :--- | :--- | :--- |
| `<space>k` | `:lsp-hover` | Show hover signature and doc info |
| `<space>d` | `:lsp-definition` | Go to symbol definition |
| `<space>s` | `:lsp-signature-help` | Show signature help & active parameter |
| `<space>y` | `:lsp-document-symbol`| Browse document symbol outline |
| `<space>i` | `:lsp-inlay-hints-enable window` | Enable inlay hints |
| `<space>I` | `:lsp-inlay-hints-disable window`| Disable inlay hints |
| `<space>l` | `:enter-user-mode lsp` | Open full `kak-lsp` command menu |
