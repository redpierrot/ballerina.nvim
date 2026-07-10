" Vim compiler file
" Compiler:  Ballerina (bal build)
" Usage:     :compiler ballerina | :make

if exists("current_compiler")
  finish
endif
let current_compiler = "ballerina"

let s:cpo_save = &cpo
set cpo&vim

CompilerSet makeprg=bal\ build

" The errorformat is owned by lua/ballerina/cli.lua so the :Ballerina*
" commands and :make can never drift apart (tests/run.lua asserts this).
execute 'CompilerSet errorformat=' . escape(luaeval("require'ballerina.cli'.errorformat"), ' \,')

let &cpo = s:cpo_save
unlet s:cpo_save
