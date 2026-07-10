" Vim syntax file
" Language:    Ballerina
" Maintainer:  ballerina.nvim contributors
" Source:      Keyword/type lists ported from ballerina-platform/ballerina-grammar
"              (syntaxes/ballerina.YAML-tmLanguage), which are themselves
"              generated from the Ballerina compiler's LexerTerminals.java.

if exists("b:current_syntax")
  finish
endif

syntax case match

" Control flow
syntax keyword balConditional if else match
syntax keyword balRepeat foreach while
syntax keyword balStatement break check checkpanic continue fail panic return returns trap wait

" Type-defining constructs
syntax keyword balStructure class enum object record service
syntax keyword balTypedef type

" Modifiers / storage qualifiers
syntax keyword balStorageClass abstract annotation client configurable const external final isolated listener private public remote resource worker

" import
syntax keyword balInclude import

" Everything else, including query-expression keywords (from/select/where/...).
" `group` and `collect` are contextual keywords (promoted by the parser, not
" LexerTerminals.java) but highlight-worthy all the same. `version` was
" dropped from the language along with import versioning.
syntax keyword balKeyword as ascending base16 base64 by collect commit conflict
syntax keyword balKeyword default descending do equals field flush fork from function
syntax keyword balKeyword group in is join key let limit lock module natural new on
syntax keyword balKeyword order outer parameter retry rollback select source start
syntax keyword balKeyword table transaction transactional typeof variable where
syntax keyword balKeyword xmlns

" `re` is only a keyword directly before a regexp template: re `...`
syntax match balKeyword "\<re\ze\s*`"

" Types
syntax keyword balType any distinct error future handle map never readonly stream typedesc var
syntax keyword balPrimitiveType anydata boolean byte decimal float int json string xml

syntax keyword balBoolean true false
syntax keyword balNull null
syntax keyword balSelf self

" Annotations: @foo, @foo:bar
syntax match balAnnotation "@[a-zA-Z_][a-zA-Z0-9_]*\(:[a-zA-Z_][a-zA-Z0-9_]*\)\?"

" Comments: `//` line comments, `#` markdown-style doc comments
syntax match balComment "//.*$" contains=@Spell
syntax match balDocComment "#.*$" contains=@Spell

" Numbers: hex, binary, octal, decimal, float (with optional exponent and
" f/F/d/D float/decimal type suffix, e.g. 1.0f, 2d)
syntax match balNumber "\<0[xX][0-9a-fA-F][0-9a-fA-F_]*\>"
syntax match balNumber "\<0[bB][01][01_]*\>"
syntax match balNumber "\<0[oO][0-7][0-7_]*\>"
syntax match balNumber "\<[0-9][0-9_]*\(\.[0-9][0-9_]*\)\?\([eE][+-]\?[0-9]\+\)\?[fFdD]\?\>"

" Strings: double-quoted with backslash escapes
syntax region balString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=balStringEscape,@Spell
syntax match balStringEscape "\\." contained

" String templates: `...`, string`...`, xml`...`, re`...`, with ${...} substitutions
syntax region balStringTemplate matchgroup=balTemplateDelim start=+`+ end=+`+ contains=balTemplateSubst
syntax region balTemplateSubst matchgroup=balTemplateDelim start=+\${+ end=+}+ contained contains=TOP

" Operators / punctuation (kept minimal on purpose)
syntax match balOperator "=>"

highlight default link balConditional     Conditional
highlight default link balRepeat          Repeat
highlight default link balStatement       Statement
highlight default link balStructure       Structure
highlight default link balTypedef         Typedef
highlight default link balStorageClass    StorageClass
highlight default link balInclude         Include
highlight default link balKeyword         Keyword
highlight default link balType            Type
highlight default link balPrimitiveType   Type
highlight default link balBoolean         Boolean
highlight default link balNull            Constant
highlight default link balSelf            Constant
highlight default link balAnnotation      PreProc
highlight default link balComment         Comment
highlight default link balDocComment      SpecialComment
highlight default link balNumber          Number
highlight default link balString          String
highlight default link balStringEscape    SpecialChar
highlight default link balStringTemplate  String
highlight default link balTemplateDelim   Delimiter
highlight default link balOperator        Operator

let b:current_syntax = "ballerina"
