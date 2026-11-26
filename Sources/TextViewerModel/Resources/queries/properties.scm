; Adapted from tree-sitter-grammars/tree-sitter-properties queries/highlights.scm (MIT).
(comment) @comment
(key) @property
(value) @string
(value (escape) @string.escape)
(substitution (key) @constant)
(property [ "=" ":" ] @operator)
[ "${" "}" ] @punctuation.special
