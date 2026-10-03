# Detection
# ‾‾‾‾‾‾‾‾‾

hook -group cx-filetype global BufCreate .*[.]cx$ %{
    set-option buffer filetype cx
}

hook -group cx-filetype global BufOpenFile .*[.]cx$ %{
    set-option buffer filetype cx
}

# Buffer options (comments)
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾

hook global BufSetOption filetype=cx %{
    try %{
        set-option buffer comment_line '//'
        set-option buffer comment_block_begin '/*'
        set-option buffer comment_block_end '*/'
    }
}

# Window options & hooks (indentation & highlighters)
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾

hook global WinSetOption filetype=cx %<
    require-module cx

    hook window ModeChange pop:insert:.* -group cx-trim-indent cx-trim-indent
    hook window InsertChar \n -group cx-indent cx-indent-on-new-line
    hook window InsertChar \{ -group cx-indent cx-indent-on-opening-curly-brace
    hook window InsertChar [)}\]] -group cx-indent cx-indent-on-closing
    hook -once -always window WinSetOption filetype=.* %{ remove-hooks window cx-.+ }
>

hook -group cx-highlight global WinSetOption filetype=cx %{
    add-highlighter window/cx ref cx
    hook -once -always window WinSetOption filetype=.* %{ remove-highlighter window/cx }
}

provide-module cx %§

# Highlighters
# ‾‾‾‾‾‾‾‾‾‾‾‾

add-highlighter shared/cx regions
add-highlighter shared/cx/code default-region group

# Strings and Character Literals
add-highlighter shared/cx/string     region %{(?<!')(?<!'\\)"} (?<!\\)(\\\\)*" fill string
add-highlighter shared/cx/character  region %{(?<!')'} (?<!\\)(\\\\)*'         fill value
add-highlighter shared/cx/raw_string region -match-capture %{R"([^(]*)\(} %{\)([^")]*)"} fill string

# Preprocessor Directives
add-highlighter shared/cx/directive  region ^\h*# (?<!\\)(\\\\)*$ fill meta

# Comments
add-highlighter shared/cx/line_comment region // $ group
add-highlighter shared/cx/line_comment/fill fill comment
add-highlighter shared/cx/line_comment/todo regex \b(TODO|NOTE|FIXME|BUG|XXX):? 0:meta

add-highlighter shared/cx/block_comment region -recurse /\* /\* \*/ group
add-highlighter shared/cx/block_comment/fill fill comment
add-highlighter shared/cx/block_comment/todo regex \b(TODO|NOTE|FIXME|BUG|XXX):? 0:meta

# Operators
add-highlighter shared/cx/code/operator_pipe regex \|> 0:operator
add-highlighter shared/cx/code/operator_arrow regex (->|=>) 0:operator
add-highlighter shared/cx/code/operators_arithmetic regex (\+|-|/|\*|=|\^|&|\||!|>|<|%)=? 0:operator
add-highlighter shared/cx/code/operators_logic regex (&&|\|\|) 0:operator
add-highlighter shared/cx/code/operators_compare regex (==|!=|<=|>=|<|>) 0:operator

# Numeric literals
add-highlighter shared/cx/code/numbers regex \b(?:0x[0-9a-fA-F](?:_?[0-9a-fA-F])*(?:\.[0-9a-fA-F](?:_?[0-9a-fA-F])*)?(?:[pP][+-]?[0-9]+)?|0b[01](?:_?[01])*|0o[0-7](?:_?[0-7])*|[0-9](?:_?[0-9])*(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9]+)?)(?:[uU]?[lL]{0,2}|[fFdD]|_?[iIuU](?:8|16|32|64))?\b 0:value

# Boolean and null literals
add-highlighter shared/cx/code/values regex \b(true|false|null|nullptr|nil)\b 0:value

# Core Declaration Keywords
add-highlighter shared/cx/code/decl_keywords regex \b(function|let|type|struct|union|enum|sizeof|alignof|typeof|as|import|export)\b 0:keyword

# Control Flow Keywords
add-highlighter shared/cx/code/control_keywords regex \b(if|else|while|for|do|switch|case|default|return|break|continue|goto)\b 0:keyword

# Extension Keywords
add-highlighter shared/cx/code/ext_keywords regex \b(defer|__auto_type|__asm__|__volatile__|__label__|__attribute__|__extension__|__alignof__|asm|volatile)\b 0:keyword

# Qualifiers and Storage Classes
add-highlighter shared/cx/code/storage regex \b(const|constexpr|static|extern|inline|atomic|restrict|_Atomic|_Thread_local)\b 0:attribute

# Builtin Types
add-highlighter shared/cx/code/builtin_types regex \b(void|bool|char|short|int|long|float|double|signed|unsigned|size_t|ssize_t|intptr_t|uintptr_t|ptrdiff_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|_BitInt|_Complex|_Decimal32|_Decimal64|_Decimal128)\b 0:type

# Function Declarations and Calls
add-highlighter shared/cx/code/func_decl regex (?:function\h+)([a-zA-Z_]\w*)\b 1:function
add-highlighter shared/cx/code/func_call regex \b([a-zA-Z_]\w*)\s*(?=\() 1:function

# Indentation and formatting commands
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾

define-command -hidden cx-trim-indent %{
    try %{ execute-keys -draft -itersel x s \h+$ <ret> d }
}

define-command -hidden cx-indent-on-new-line %<
    evaluate-commands -draft -itersel %<
        # Preserve comment prefix on newline
        try %<
            evaluate-commands -draft -save-regs "/\"" %<
                execute-keys -save-regs "" k x s ^\h*//[!/]{0,2}\h* <ret> y
                execute-keys j x <a-k> ^\h*// <ret> P
            >
        >
        # Indent after opening brace { or colon :
        try %<
            execute-keys -draft k x <a-k> [{(:]\h*(//.*)?$ <ret> j <a-gt>
        >
    >
>

define-command -hidden cx-indent-on-opening-curly-brace %<
    evaluate-commands -draft -itersel %<
        # align with opening line if preceded by whitespace only
        try %< execute-keys -draft <a-h> <a-k> ^\h+\{$ <ret> <a-lt> >
    >
>

define-command -hidden cx-indent-on-closing %<
    evaluate-commands -draft -itersel %<
        # de-indent when closing brace is typed alone
        try %< execute-keys -draft <a-h> <a-k> ^\h+[}\])]$ <ret> <a-lt> >
    >
>

§

# Retroactively apply filetype for any existing buffers matching *.cx
evaluate-commands -buffer * %{
    evaluate-commands %sh{
        case "$kak_buffile" in
            *.cx) printf 'set-option buffer filetype cx\n' ;;
        esac
    }
}
