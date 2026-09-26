; Baseline highlights for Cx (tree-sitter grammar `cx`).
; The Cx LSP paints full semantic tokens over this ("full" mode replaces
; these entirely); this layer only matters before the server attaches.
(comment) @comment
(preprocessor_directive) @preproc
(attribute) @attribute
(string_literal) @string
(char_literal) @string
(number_literal) @number
(boolean_literal) @boolean
(keyword) @keyword
(builtin_type) @type.builtin
(raw_identifier) @variable.special
(operator) @operator
(punctuation) @punctuation
