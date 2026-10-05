# Proposal: text objects for Ballerina (mini.ai)

Status: accepted, implemented in `lua/ballerina/textobjects.lua`.

## Problem

Ballerina has no tree-sitter grammar, so the usual tree-sitter-backed
mini.ai text objects (`f`/`c`/`o` in LazyVim-style configs, via
`ai.gen_spec.treesitter({ a = "@function.outer", ... })`) raise `E5108` in
Ballerina buffers, and `daf`, `cif`, `vao`, ... do nothing useful.

mini.ai also accepts a plain Lua function as a spec, returning regions. That
needs no grammar, only a way to find constructs in the buffer text reliably
enough. The workaround lives today in one user's dotfiles; it belongs in the
plugin so every Ballerina user gets it.

## Non-goals

- A real parser. A proper `tree-sitter-ballerina` is the long-term answer
  and, once it exists, would replace this module. Minor misses on exotic
  code are acceptable; wrong results on ordinary code are not.
- Supporting text-object plugins other than mini.ai. The scanner is pure
  (text in, byte offsets out), so a different front-end can be added later.

## Objects

Three kinds, each with an `a` (outer) and `i` (inner) form. Default keys
follow the common mini.ai/LazyVim convention and are configurable.

| Key | Kind  | `a…` (outer)                                                 | `i…` (inner)         |
| --- | ----- | ------------------------------------------------------------ | -------------------- |
| `f` | func  | qualifiers + `function` … closing `}`                        | body between braces  |
| `o` | block | whole statement, including `else`/`on fail` chain            | each body in a chain |
| `c` | class | `class`/`service`/`record`/`object`/`enum` declaration       | body between braces  |

Details:

- **func**: every `function` keyword that has a `{` body: top-level, methods,
  `remote`/`resource` functions, anonymous functions. Leading qualifiers
  (`public isolated`, `resource`, `remote`, ...) are part of the outer
  region. Skipped: function *type* descriptors (`function (int) returns int`
  with no body), `external` functions, abstract/interface methods ending in
  `;`.
- **block**: `if`/`else if`/`else`, `while`, `foreach`, `match`, `do`, `lock`,
  `transaction`, `retry`, `fork`, `worker`, plus `=> { ... }` match clause
  bodies. A trailing chain belongs to the statement: `else`/`else if` for
  `if`, and `on fail` for the others. `ao` selects the whole chain; `io`
  selects the body the cursor is in (each body of a chain is its own region,
  so `dio` in the `else` branch deletes the `else` body, not the `if` body).
- **class**: `class`, `service`, `enum`, and `record`/`object` type
  descriptors. For a `type Foo record {| ... |};`, the outer region starts at
  `type` (and its `public` qualifier) and takes the trailing `;`.

Inner regions skip the whitespace hugging the braces, so `cif` on a
multi-line body leaves `{` and `}` on their own lines. Empty/whitespace-only
bodies produce no inner region.

Nesting needs no special handling: mini.ai picks the smallest region around
the cursor and `a`/`i` repeated (or counts) walk outwards.

## Approach

Plain brace counting is what the first version did and it is the main source
of wrong results: braces inside strings, comments and templates. So:

1. **Mask** the buffer text: replace comments (`// ...`), string literals,
   backtick templates (`` `...${x}...` ``, including `xml`/`string`/`re`
   prefixed ones) and quoted identifiers (`'function`) with spaces. Length
   and newlines are preserved, so byte offsets still line up with the
   original text.
2. **Pair braces** once on the masked text (single stack pass), giving
   `open -> close` in O(n). No `%b{}` rescans.
3. **Find keywords** in the masked text with frontier patterns
   (`%f[%w_]kw%f[^%w_]`), so comments/strings/identifiers like
   `functional` never match.
4. **Locate the body brace** by walking from the keyword at bracket depth 0:
   skip `( )`, `[ ]`, `< >` groups; skip a `{` that opens a mapping
   constructor or a record/object type (preceded by an operator, `in`,
   `record`, `object`, ...); stop at `;`, `=` or an unmatched closer, which
   mean "no body".
5. **Extend chains** (`else`, `on fail`) after the closing brace.
6. Convert byte offsets to `{ line, col }` regions for mini.ai. Results are
   cached per buffer keyed on `changedtick`, since mini.ai calls the spec
   several times per keypress.

## Wiring

`ftplugin/ballerina.lua` sets the buffer-local `vim.b.miniai_config`
(mini.ai merges it over the global config), only touching the keys this
plugin owns and never overwriting a spec the user already set buffer-locally.
mini.ai is not required: without it the config is simply unused.

```lua
require("ballerina").setup({
  textobjects = {
    enabled = true, -- default
    keys = { func = "f", block = "o", class = "c" }, -- false disables one
  },
})
```

The spec functions are also exported
(`require("ballerina.textobjects").func` / `.block` / `.class`), for users who
want different keys or to register them themselves.

## Known limitations

- A `{` that is a mapping constructor in a statement header and is not
  preceded by an obvious operator can be taken for the body. Rare.
- Template `${ ... }` interpolations are masked together with the template.
  Text objects therefore never match inside an interpolation.
- Statements without braces are not objects (Ballerina requires braces for
  all of these, so this only affects `match` arms with expression bodies).
