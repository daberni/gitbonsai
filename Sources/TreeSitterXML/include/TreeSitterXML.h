// The XML grammar (tree-sitter-grammars/tree-sitter-xml v0.7.0, MIT), vendored because its Swift package depends on a second copy of SwiftTreeSitter.
#ifndef TREE_SITTER_XML_H_
#define TREE_SITTER_XML_H_

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_xml(void);

#endif
