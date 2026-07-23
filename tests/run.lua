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
  eq(true, config.options.lsp.file_watch)
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

---------------------------------------------------------------------- lsp --

test("lsp: file_watch on by default enables dynamicRegistration", function()
  config.setup({})
  require("ballerina.lsp").setup()
  eq(
    true,
    vim.lsp.config.ballerina.capabilities.workspace.didChangeWatchedFiles.dynamicRegistration
  )
end)

test("lsp: file_watch = false disables dynamicRegistration, even after a true run", function()
  config.setup({ lsp = { file_watch = false } })
  require("ballerina.lsp").setup()
  eq(
    false,
    vim.lsp.config.ballerina.capabilities.workspace.didChangeWatchedFiles.dynamicRegistration
  )
  config.setup({})
  require("ballerina.lsp").setup()
end)

------------------------------------------------------------------ lsp_watch --

local lsp_watch = require("ballerina.lsp_watch")

-- The exact registration captured from Ballerina LS 2201.13.4 (Swan Lake
-- Update 13) — see docs/proposals/scoped-lsp-file-watch.md.
local captured_watchers = {
  { globPattern = "/**/*.bal", kind = 7 },
  { globPattern = "/**/modules/*", kind = 5 },
  { globPattern = "/**/modules", kind = 4 },
  { globPattern = "/**/generated", kind = 4 },
  { globPattern = "/**/Ballerina.toml", kind = 5 },
  { globPattern = "/**/Cloud.toml", kind = 5 },
  { globPattern = "/**/Dependencies.toml", kind = 5 },
}

test("lsp_watch: classifies the captured 7-pattern payload with no unknowns", function()
  local routed = lsp_watch.classify(captured_watchers)
  eq({}, routed.unknown, "every captured pattern is recognized")

  eq({
    { match = "*.bal", kind = 7 },
    { match = "Ballerina.toml", kind = 5 },
    { match = "Cloud.toml", kind = 5 },
    { match = "Dependencies.toml", kind = 5 },
  }, routed.root_direct)

  eq({
    { name = "modules", kind = 4 },
    { name = "generated", kind = 4 },
  }, routed.root_dir_events)

  eq({
    { pattern = "**/*.bal", kind = 7 },
    { pattern = "*", kind = 5 },
    { pattern = "**/generated", kind = 4 },
  }, routed.modules)

  eq({
    { pattern = "**/*.bal", kind = 7 },
  }, routed.generated)
end)

test("lsp_watch: unrecognized pattern falls back loudly instead of silently dropping", function()
  local routed = lsp_watch.classify({
    { globPattern = "/**/*.bal", kind = 7 },
    { globPattern = "/**/some-new-pattern", kind = 7 },
  })
  eq({ { globPattern = "/**/some-new-pattern", kind = 7 } }, routed.unknown)
  eq(1, #routed.root_direct, "known patterns are still routed alongside the unknown one")
end)

test("lsp_watch: a RelativePattern (table globPattern) is treated as unknown", function()
  local routed = lsp_watch.classify({
    { globPattern = { baseUri = "file:///tmp", pattern = "**/*.bal" }, kind = 7 },
  })
  eq(1, #routed.unknown)
end)

test("lsp_watch: defaults kind to Create+Change+Delete when the server omits it", function()
  local routed = lsp_watch.classify({ { globPattern = "/**/*.bal" } })
  eq(7, routed.root_direct[1].kind)
end)

test("lsp_watch: classify_rename treats ENOENT as Deleted", function()
  eq(vim._watch.FileChangeType.Deleted, lsp_watch.classify_rename("ENOENT"))
end)

test("lsp_watch: classify_rename treats a successful stat as Created", function()
  eq(vim._watch.FileChangeType.Created, lsp_watch.classify_rename(nil))
end)

test(
  "lsp_watch: classify_rename skips (rather than crashing on) a non-ENOENT stat error",
  function()
    -- e.g. ENAMETOOLONG from a pathologically long JaCoCo/coverage path
    -- under target/ — core's vim._watch.watch asserts and crashes here
    -- instead; this is the fix for that (see lsp_watch.lua's top comment).
    eq(nil, lsp_watch.classify_rename("ENAMETOOLONG"))
  end
)

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

test("cli: parse_test_failures resolves a failure to its own test frame", function()
  -- Real `bal test` output for an assertEquals failure (captured verbatim,
  -- tabs and all) -- the stack walks through ballerina/test internals
  -- (assert.bal), the user's test function, then compiler-generated
  -- harness glue (test_execute-generated_1.bal) and more internals.
  local lines = {
    "\t\tqfcheck",
    "",
    "\t\t[pass] testAddOk",
    "",
    "\t\t[fail] testAddWrong:",
    "",
    '\t\t    error {ballerina/test:0}TestError ("Assertion Failed!',
    "\t\t\t ",
    "\t\t\texpected: '999'",
    "\t\t\tactual\t: '5'\")",
    "\t\t\t\tcallableName: createBallerinaError moduleName: ballerina.test.0 fileName: assert.bal lineNumber: 41",
    "\t\t\t\tcallableName: assertEquals moduleName: ballerina.test.0 fileName: assert.bal lineNumber: 109",
    "\t\t\t\tcallableName: testAddWrong moduleName: demo.qfcheck$test.0.tests.main_test "
      .. "fileName: tests/main_test.bal lineNumber: 10",
    "\t\t\t\tcallableName: testAddWrong$lambda1$ "
      .. "moduleName: demo.qfcheck$test.0.tests.test_execute-generated_1 "
      .. "fileName: tests/test_execute-generated_1.bal lineNumber: 5",
    "\t\t\t\tcallableName: call moduleName: ballerina.lang.function.0 fileName: function.bal lineNumber: 37",
    "",
    "",
    "\t\t1 passing",
    "\t\t1 failing",
    "\t\t0 skipped",
  }
  local items = cli.parse_test_failures(lines, "/pkg")
  eq(1, #items, "one failure, [pass] produces no item")
  eq("/pkg/tests/main_test.bal", items[1].filename, "lands on the user's test file, not assert.bal")
  eq(10, items[1].lnum)
  eq("E", items[1].type)
  assert(items[1].text:match("testAddWrong"), "text mentions the test name")
  assert(items[1].text:match("Assertion Failed"), "text mentions the failure reason")
end)

test("cli: parse_test_failures ignores passing tests", function()
  local items = cli.parse_test_failures({ "\t\t[pass] testAddOk", "", "\t\t1 passing" }, "/pkg")
  eq(0, #items)
end)

test("cli: parse_test_failures handles multiple failures independently", function()
  local lines = {
    "\t\t[fail] testA:",
    '\t\t    error {ballerina/test:0}TestError ("boom")',
    "\t\t\t\tcallableName: a moduleName: demo.pkg$test.0.tests.a_test fileName: tests/a_test.bal lineNumber: 3",
    "",
    "\t\t[fail] testB:",
    '\t\t    error {ballerina/test:0}TestError ("bang")',
    "\t\t\t\tcallableName: b moduleName: demo.pkg$test.0.tests.b_test fileName: tests/b_test.bal lineNumber: 7",
    "",
    "\t\t1 passing",
  }
  local items = cli.parse_test_failures(lines, "/pkg")
  eq(2, #items)
  eq("/pkg/tests/a_test.bal", items[1].filename)
  eq(3, items[1].lnum)
  eq("/pkg/tests/b_test.bal", items[2].filename)
  eq(7, items[2].lnum)
end)

test("cli: parse_test_failures resolves an already-absolute test path as-is", function()
  local lines = {
    "\t\t[fail] testAbs:",
    '\t\t    error {ballerina/test:0}TestError ("boom")',
    "\t\t\t\tcallableName: a moduleName: demo.pkg$test.0.tests.a_test fileName: /abs/tests/a_test.bal lineNumber: 3",
  }
  local items = cli.parse_test_failures(lines, "/pkg")
  eq(1, #items)
  eq("/abs/tests/a_test.bal", items[1].filename)
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
