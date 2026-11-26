; Adapted from tree-sitter-grammars/tree-sitter-diff v0.2.0 queries/highlights.scm (MIT).
(comment) @comment
[ (addition) (new_file) ] @diff.plus
[ (deletion) (old_file) ] @diff.minus
(commit) @constant
(location) @attribute
(command "diff" @keyword (argument) @string)
(filename) @string
(mode) @number
(index "index" @keyword)
[ (binary_change) (similarity) (dissimilarity) (file_change) ] @property
(similarity (score) @number "%" @number)
(dissimilarity (score) @number "%" @number)
