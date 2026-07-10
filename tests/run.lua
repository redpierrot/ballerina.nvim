-- Zero-dependency test runner, executed with:  nvim -l tests/run.lua
-- (from the repository root; the Makefile `test` target does this).

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    print("ok    " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end

local function eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected %s, got %s"):format(
        msg and (msg .. ": ") or "",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

------------------------------------------------------------------- config --

local config = require("ballerina.config")

test("config: defaults", function()
  eq(true, config.options.format_on_save)
  eq(true, config.options.indent)
  eq(true, config.options.lsp.enabled)
  eq({ "Ballerina.toml" }, config.options.lsp.root_markers)
  eq(nil, config.options.bal_cmd)
end)

test("config: user options deep-merge without clobbering siblings", function()
  config.setup({ lsp = { enabled = false } })
  eq(false, config.options.lsp.enabled)
  eq({ "Ballerina.toml" }, config.options.lsp.root_markers, "sibling key survives")
  config.setup({})
  eq(true, config.options.lsp.enabled, "setup() resets from defaults")
end)

test("config: rejects wrong option types", function()
  local ok = pcall(config.setup, { format_on_save = "yes" })
  assert(not ok, "expected a validation error for format_on_save = 'yes'")
  ok = pcall(config.setup, { bal_cmd = 42 })
  assert(not ok, "expected a validation error for bal_cmd = 42")
  config.setup({})
end)

--------------------------------------------------------------------- util --

test("util: bal_cmd honors the config override", function()
  config.setup({ bal_cmd = "/opt/custom/bal" })
  eq("/opt/custom/bal", require("ballerina.util").bal_cmd())
  config.setup({})
end)

test("util: bal_cmd falls back to $BALLERINA_HOME/bin/bal", function()
  package.loaded["ballerina.util"] = nil -- drop the module-level cache
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. "/bin", "p")
  local fake = home .. "/bin/bal"
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, fake)
  vim.uv.fs_chmod(fake, 493) -- 0755
  local saved_path, saved_home = vim.env.PATH, vim.env.BALLERINA_HOME
  vim.env.PATH = home -- no `bal` directly on PATH (bin/ is not included)
  vim.env.BALLERINA_HOME = home
  local found = require("ballerina.util").bal_cmd()
  vim.env.PATH = saved_path
  vim.env.BALLERINA_HOME = saved_home
  eq(fake, found)
end)

test("util: bal_cmd finds an executable on PATH", function()
  package.loaded["ballerina.util"] = nil -- drop the module-level cache
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local fake = dir .. "/bal"
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, fake)
  vim.uv.fs_chmod(fake, 493) -- 0755
  local saved_path = vim.env.PATH
  vim.env.PATH = dir
  local found = require("ballerina.util").bal_cmd()
  vim.env.PATH = saved_path
  eq(fake, found)
end)

---------------------------------------------------------------------- cli --

local cli = require("ballerina.cli")

test("cli: build_cmd with no args", function()
  eq({ "bal", "build" }, cli.build_cmd("bal", "build", nil, {}))
  eq({ "bal", "run", "main.bal" }, cli.build_cmd("bal", "run", "main.bal", nil))
end)

test("cli: build_cmd puts options before the target", function()
  eq(
    { "bal", "test", "--tests", "fooTest", "main.bal" },
    cli.build_cmd("bal", "test", "main.bal", { "--tests", "fooTest" })
  )
end)

test("cli: build_cmd puts `--` program args after the target", function()
  eq(
    { "bal", "run", "main.bal", "--", "8080", "debug" },
    cli.build_cmd("bal", "run", "main.bal", { "--", "8080", "debug" })
  )
  eq(
    { "bal", "run", "--observability-included", "main.bal", "--", "8080" },
    cli.build_cmd("bal", "run", "main.bal", { "--observability-included", "--", "8080" })
  )
end)

test("cli: errorformat parses ERROR and WARNING diagnostics with ranges", function()
  local parsed = vim.fn.getqflist({
    lines = {
      "Compiling source",
      "\tdemo/e2epkg:0.1.0",
      "ERROR [/pkg/main.bal:(4:5,4:18)] undefined symbol 'foo'",
      "WARNING [/pkg/util.bal:(2:1,3:10)] unused variable 'x'",
      "error: compilation contains errors",
    },
    efm = cli.errorformat,
  })
  local items = vim.tbl_filter(function(item)
    return item.valid == 1
  end, parsed.items)
  eq(2, #items, "two valid diagnostics")
  eq("E", items[1].type)
  eq(4, items[1].lnum)
  eq(5, items[1].col)
  eq(4, items[1].end_lnum)
  eq(18, items[1].end_col)
  eq("undefined symbol 'foo'", items[1].text)
  eq("W", items[2].type)
  eq(3, items[2].end_lnum)
end)

test("cli: compiler/ballerina.vim stays in sync with cli.errorformat", function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("compiler ballerina")
    eq("bal build", vim.o.makeprg:gsub("\\ ", " "))
    eq(cli.errorformat, vim.opt_local.errorformat:get() and vim.bo.errorformat or "")
  end)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

---------------------------------------------------------------------- dap --

test("dap: registers adapter and configurations when nvim-dap is present", function()
  package.loaded["dap"] = { adapters = {}, configurations = {} }
  local fake_dap = package.loaded["dap"]

  assert(require("ballerina.dap").setup(), "setup() should report success")
  assert(type(fake_dap.adapters.ballerina) == "function", "adapter registered")
  eq(4, #fake_dap.configurations.ballerina, "launch x3 + attach")

  config.setup({ bal_cmd = "/opt/custom/bal" })
  local adapter
  fake_dap.adapters.ballerina(function(a)
    adapter = a
  end, {})
  config.setup({})

  eq("server", adapter.type)
  eq("/opt/custom/bal", adapter.executable.command)
  eq("start-debugger-adapter", adapter.executable.args[1])
  local port = tonumber(adapter.executable.args[2])
  assert(port and port > 0, "adapter spawned with a real port")
  eq(port, adapter.port, "connects to the same port it spawned on")

  local attach = fake_dap.configurations.ballerina[4]
  eq("attach", attach.request)
  eq("127.0.0.1", attach.debuggeeHost)
  package.loaded["dap"] = nil
end)

------------------------------------------------------------------- indent --

local indent = require("ballerina.indent")

local function indent_for(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].shiftwidth = 4
  local result
  vim.api.nvim_buf_call(bufnr, function()
    result = indent.indentexpr(#lines)
  end)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return result
end

local indent_cases = {
  { name = "first line gets 0", lines = { "x" }, want = 0 },
  {
    name = "indents after an opening brace",
    lines = { "function main() {", "x" },
    want = 4,
  },
  {
    name = "dedents a closing brace",
    lines = { "function main() {", "    int a = 5;", "}" },
    want = 0,
  },
  {
    name = "keeps the previous line's indent",
    lines = { "function main() {", "    int a = 5;", "x" },
    want = 4,
  },
  {
    name = "indents after an opening paren",
    lines = { "io:println(", "x" },
    want = 4,
  },
  {
    name = "ignores a brace inside a line comment",
    lines = { "int a = 5; // {", "x" },
    want = 0,
  },
  {
    name = "quoted identifier does not hide a trailing comment",
    lines = { "int 'from = 5; // {", "x" },
    want = 0,
  },
  {
    name = "ignores // inside a template string",
    lines = { "handle(`http://a`, {", "y" },
    want = 4,
  },
  {
    name = "ignores braces inside a plain string",
    lines = { 'string s = "{";', "x" },
    want = 0,
  },
  {
    name = "never returns a negative indent",
    lines = { "int a = 5;", "}" },
    want = 0,
  },
}

for _, case in ipairs(indent_cases) do
  test("indent: " .. case.name, function()
    eq(case.want, indent_for(case.lines))
  end)
end

---------------------------------------------------------------------------

if failed > 0 then
  print(("\n%d test(s) failed"):format(failed))
  os.exit(1)
end
print("\nall tests passed")
