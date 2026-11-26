; Adapted from tree-sitter-grammars/tree-sitter-xml queries/xml/highlights.scm (MIT): attributes as in HTML, element text uncoloured.
"xml" @keyword
[ "version" "encoding" "standalone" ] @attribute
(EncName) @string
(VersionNum) @number
[ "yes" "no" ] @boolean
(PI (PITarget) @keyword)

(elementdecl "ELEMENT" @keyword (Name) @tag)
(GEDecl "ENTITY" @keyword (Name) @constant)
(GEDecl (EntityValue) @string)
(PEDecl "ENTITY" @keyword (Name) @constant)
(PEDecl (EntityValue) @string)
(NotationDecl "NOTATION" @keyword (Name) @constant)
(AttlistDecl "ATTLIST" @keyword (Name) @tag)
(AttDef (Name) @attribute)
(DefaultDecl (AttValue) @string)
[ "#REQUIRED" "#IMPLIED" "#FIXED" "#PCDATA" ] @keyword
[ "PUBLIC" "SYSTEM" ] @keyword
(PubidLiteral) @string
(SystemLiteral) @string
(doctypedecl "DOCTYPE" @keyword (Name) @type)
(XmlModelPI "xml-model" @keyword)
(StyleSheetPI "xml-stylesheet" @keyword)
(PseudoAtt (Name) @attribute)
(PseudoAtt (PseudoAttValue) @string)

(EntityRef) @string.escape
(CharRef) @string.escape
(PEReference) @constant

(STag (Name) @tag)
(ETag (Name) @tag)
(EmptyElemTag (Name) @tag)
(Attribute (Name) @attribute)
(Attribute (AttValue) @string)

[ "<?" "?>" "<!" "<" ">" "</" "/>" ] @punctuation.bracket

(CDSect (CDStart) @punctuation.bracket (CData) @string "]]>" @punctuation.bracket)
(Comment) @comment
