/// Minimal total-parse Tree-sitter grammar for Cx (the C23-dialect layer).
///
/// Deliberately shallow: every token class Cx needs for baseline Zed
/// behavior (comments, strings, numbers, `#` directives, `[[...]]`
/// attributes, keywords, builtin types, brackets, operators) lexes as a
/// flat item list, so Cx-specific declaration syntax (`let x: int`,
/// `function f(): T`, `{x: 1}`, `cinit {...}`) never produces error nodes.
/// Deep highlighting, diagnostics, and navigation come from the Cx LSP
/// via semantic tokens — this grammar only provides token scopes,
/// bracket matching, and string/comment regions.
module.exports = grammar({
  name: 'cx',

  extras: $ => [/\s/, $.comment],

  word: $ => $.identifier,

  rules: {
    translation_unit: $ => repeat($._item),

    _item: $ => choice(
      $.preprocessor_directive,
      $.attribute,
      $.string_literal,
      $.char_literal,
      $.number_literal,
      $.boolean_literal,
      $.keyword,
      $.builtin_type,
      $.raw_identifier,
      $.identifier,
      $.operator,
      $.punctuation,
    ),

    comment: $ => token(choice(
      seq('//', /.*/),
      seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/'),
    )),

    // One opaque logical line starting with `#` (matches the Cx lexer,
    // which preserves directives verbatim).
    preprocessor_directive: $ => token(seq('#', /.*/)),

    attribute: $ => token(seq('[[', /([^\]]|\][^\]])*/, ']]')),

    string_literal: $ => token(seq(
      /(u8|u|U|L)?/,
      '"',
      /([^"\\\n]|\\.)*/,
      '"',
    )),

    char_literal: $ => token(seq(
      /(u|U|L)?/,
      "'",
      /([^'\\\n]|\\.)*/,
      "'",
    )),

    // C23 integers (hex/oct/bin, `'` separators, wb/uwb) and floats.
    // Approximate: close enough for highlight scopes.
    number_literal: $ => token(choice(
      /0[bB][01']+(wb|uwb|WB|UWB)?/,
      /0[xX][0-9a-fA-F']+([uU]*[lL]{0,2})?/,
      /0[0-7']*([uU]*[lL]{0,2})?/,
      /[0-9][\d']*(\.[\d']*)?([eE][+-]?[\d']+)?[fFlL]?[uU]*[lL]{0,2}/,
      /[0-9][\d']*(wb|uwb|WB|UWB)/,
    )),

    boolean_literal: $ => choice('true', 'false', 'nullptr', 'NULL'),

    // Cx introducers + C control/statements + module/dialect words that
    // read better as keywords inside raw C regions (cinit, K&R lines).
    keyword: $ => choice(
      'let', 'function', 'type', 'as', 'cinit',
      'const', 'constexpr', 'static', 'extern', 'thread_local', 'inline',
      'sizeof', 'alignof', '_Generic', 'static_assert',
      'struct', 'union', 'enum', 'typedef',
      'if', 'else', 'while', 'do', 'for', 'switch', 'case', 'default',
      'goto', 'continue', 'break', 'return',
      'import', 'export', 'from',
      'alignas', '_Alignas', '_Atomic', '_Noreturn', '_Thread_local',
      'typeof', 'typeof_unqual',
    ),

    builtin_type: $ => choice(
      'void', 'char', 'short', 'int', 'long', 'float', 'double',
      'signed', 'unsigned', 'bool',
      'char8_t', 'char16_t', 'char32_t', 'wchar_t',
      'size_t', 'ptrdiff_t', 'intptr_t', 'uintptr_t',
      'va_list', 'nullptr_t',
      '_BitInt', '_Complex', '_Imaginary',
      '_Decimal32', '_Decimal64', '_Decimal128',
    ),

    // `@ident` raw escape (the `@` drops at Cx codegen; one token).
    // Both accept `\uXXXX` / `\UXXXXXXXX` escapes like the Cx lexer.
    raw_identifier: $ => token(seq(
      '@',
      /([a-zA-Z_\u00a0-\uFFFF]|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})([a-zA-Z0-9_\u00a0-\uFFFF]|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*/,
    )),

    identifier: $ => /([a-zA-Z_\u00a0-\uFFFF]|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})([a-zA-Z0-9_\u00a0-\uFFFF]|\\u[0-9a-fA-F]{4}|\\U[0-9a-fA-F]{8})*/,

    operator: $ => choice(
      '=>', '==', '!=', '<=', '>=', '&&', '||', '++', '--', '->',
      '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=',
      '<<', '>>', '##', '...',
      '+', '-', '*', '/', '%', '&', '|', '^', '~', '!',
      '<', '>', '=', '?',
    ),

    punctuation: $ => choice(
      '(', ')', '{', '}', '[', ']', ';', ',', '.', ':',
    ),
  },
});
