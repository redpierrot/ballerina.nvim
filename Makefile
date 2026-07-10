LUA_DIRS := lua ftplugin ftdetect lsp tests

.PHONY: test lint fmt fmt-check

test:
	nvim -l tests/run.lua

lint:
	luacheck $(LUA_DIRS)

fmt:
	stylua $(LUA_DIRS)

fmt-check:
	stylua --check $(LUA_DIRS)
