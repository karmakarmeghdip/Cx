# Cx Language Server Protocol (LSP) Roadmap & Pending Tasks

This document tracks completed features and pending roadmap items for the Cx LSP server (`compiler/lsp/`).

---

## Completed Features

- [x] **Lexer + AST Semantic Token Fusion (`textDocument/semanticTokens/full`, `/range`)**
  - Fine-grained base coverage for comments, numbers, strings, keywords, operators, directives.
  - Multi-line trivia token splitting for strict LSP compliance.
  - AST semantic refinement for declarations, functions, types, parameters, variables, labels, and enums.
  - Composite extension token subsumption (e.g. GNU statement expressions `({ ... })`, `defer`).
- [x] **Extension LSP Protocol**
  - `mod.lsp_token(node)`: Custom token mapping for dialect/extension AST nodes.
  - `mod.lsp_complete(ctx)`: Dialect-provided completions, snippets, and keywords.
  - `mod.lsp_hover(node, ctx)`: Lowered C explanations and documentation for extension constructs.
  - `mod.lsp_inlay_hints(doc, ctx)`: Dialect-provided custom hints.
- [x] **Context- & Type-Aware Autocomplete (`textDocument/completion`)**
  - Snippet support (`insertTextFormat = 2`) with parameter tabstops (`${1:arg}`).
  - Type-aware struct member completion: resolves receiver types across `.` and `->` to suggest matching fields.
- [x] **Rust-Analyzer Ergonomics**
  - **Inlay Hints (`textDocument/inlayHint`)**: Inferred types for `let` bindings (`: Type`) and parameter name hints for call arguments (`param:`).
  - **Signature Help (`textDocument/signatureHelp`)**: Active parameter tracking across arguments triggered on `(` and `,`.
  - **Document Symbols (`textDocument/documentSymbol`)**: Hierarchical file outline for functions, structs with fields, enums with enumerators, type aliases, and variables.
  - **Go-to Definition (`textDocument/definition`)**: Local file and workspace-wide cross-module definitions.

---

## Pending Roadmap Tasks

### 1. Hover on Usages & Inferred Types (`textDocument/hover`)
- **Resolve `Cx:Ident` Usages**:
  When hovering on an identifier use (e.g. `add(1, 2)` or `return total;`), resolve it to its declaration and render the full signature, type, and source location instead of falling back to a raw AST node label.
- **Inferred Type Display**:
  Display inferred types for untyped `let` bindings (e.g. `let count = 42;` -> `let count: int`).
- **Cross-Module Hover**:
  When hovering over a symbol imported from another module via `import { ... }`, resolve across the workspace graph to show the foreign declaration signature and location.

### 2. Documentation Comment Extraction
- **Doc Comments (`///` and `/** ... */`)**:
  Associate leading doc-comment trivia with top-level functions, records, fields, and type aliases.
  Render doc-comments as markdown in hover cards, completion documentation, and signature help.

### 3. Find References & Rename (`textDocument/references`, `textDocument/rename`)
- **Find References**:
  Walk current file and workspace graph to locate all usages of a symbol.
- **Symbol Rename**:
  Implement `textDocument/prepareRename` and `textDocument/rename` to safely rename variables, functions, and types across all files in the workspace.

### 4. Code Actions & Desugared C Inspection (`textDocument/codeAction`)
- **View Lowered C**:
  Provide an LSP command or code action to view what an AST node, function, or extension expands to in standard C.
- **Quick Fixes**:
  Offer automatic imports for unknown identifiers matching workspace symbols.

### 5. Go-to Type Definition (`textDocument/typeDefinition`)
- Jump directly from a variable or parameter declaration to the declaration of its underlying `struct`, `union`, or `type` alias.

### 6. Workspace Symbol Search (`workspace/symbol`)
- Implement project-wide fuzzy symbol lookup across all indexed translation units.

### 7. Document Formatting (`textDocument/formatting`)
- Implement code formatting based on AST pretty-printing or canonical indentation.
