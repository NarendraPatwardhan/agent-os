# AgentOS grammar language

`mc-grammar-gen` compiles AgentOS-owned `.grammar` files into normalized Grammar IR and then into
Tree-sitter's generated C parser format. The authoring language is a small EBNF language: it does not
embed JavaScript, Rust, or Tree-sitter's `grammar.js` combinator API.

## A small grammar

```grammar
grammar example "1.0.0"
start document

skip whitespace | comment

token whitespace = /\s+/
token comment = "--" /[^\n]*/
token identifier = /[A-Za-z_][A-Za-z0-9_]*/

document = body:statement*
  => module(body)
     derives scope

statement = "local" name:identifier "=" value:expression
  => declaration(name)
     derives declaration

open expression = identifier | number | parenthesized
token number = /[0-9]+/
parenthesized = "(" expression ")"
```

Adjacent expressions form a sequence. `|` forms a choice, and `?`, `*`, and `+` mean optional,
zero-or-more, and one-or-more. Parentheses group an expression. Quoted strings are literal tokens;
`/.../imsu` is a regex token with optional flags. A field is written `name:expression`.

Precedence is an expression prefix:

```grammar
index_expression = left 14: receiver:expression "[" index:expression "]"
```

`left`, `right`, and `plain` select left-associative, right-associative, and non-associative
precedence. Production, field, and fragment names are C identifiers so the backend never has to
repair source names.

## Reuse and dialects

A family owns common productions and explicit composition points:

```grammar
family lua.core "1.0.0"

fragment separated(item, separator) = (item (separator item)*)?

open expression = identifier | number
slot type_annotation

parameter = name:identifier type_annotation?
arguments = "(" separated(expression, ",") ")"
```

Fragment application has no whitespace before `(`. A space means ordinary EBNF adjacency, so
`separated(...)` is a fragment call while `identifier ("." identifier)*` is a sequence.

The root grammar declares every family explicitly; Bazel must provide the same module IDs:

```grammar
grammar luau "0.725.0"
use lua.core
start source_file

extend expression = if_expression | type_cast_expression
fill type_annotation = ":" type:type_expression
```

Only an `open` production can be extended. A slot can be filled once. An unfilled slot disappears
inside `?`, `*`, or a choice; using one in a required sequence is an error. Families cannot choose
their own dependency order: the root grammar and its `use` declarations are the single composition
authority.

## Operators

Operator tables express the repetitive recursive shape once and generate stable `operator`, `left`,
`right`, and `argument` fields:

```grammar
prefix unary_expression over expression
  => operator(right=argument)
  right 12: "not" | "-"

infix binary_expression over expression
  => operator(left, right)
  left   1: "or"
  left   9: "+" | "-"
  right 13: "^"
```

## Shared semantics

`=> kind(...)` maps a concrete production onto the vocabulary in
`memcontainers/contracts/syntax.kdl`. Arguments name canonical roles; `role=field` maps a canonical
role to a differently named concrete field. `derives` adds vocabulary traits. The compiler rejects
unknown kinds, roles, and traits; roles or traits not admitted by a kind; missing required roles; and
roles that do not name a concrete field in the production.

External scanner tokens can be mapped separately:

```grammar
external long_comment
map long_comment => comment
```

The lossless concrete tree remains language-specific. Semantic mappings provide common vocabulary
without pretending different languages have identical syntax trees.

## Compiler boundary and diagnostics

The implementation has four deliberate stages:

```text
.grammar -> spanned surface AST -> module elaboration -> normalized Grammar IR
         -> isolated Tree-sitter grammar.json backend -> generated parser.c
```

The AST owns author intent and source spans. Elaboration owns fragments, `open`/`extend`, slots,
operator tables, name resolution, semantic validation, and nullable-repetition checks. Grammar IR is
versioned and backend-neutral. Only `tree_sitter_backend.rs` knows Tree-sitter's JSON schema.

Tokens are deliberately lexical: after fragment expansion they may contain literals, regexes,
choices, sequences, repetition, and precedence, but no production references or syntax fields.
Failures are reported at the originating `.grammar` span whenever that information is available.

## Formatting

The checked-in grammars use the canonical formatter:

```bash
bazel run //bazel/tools/mc-grammar-gen:mc-grammar-fmt -- path/to/file.grammar
bazel run //bazel/tools/mc-grammar-gen:mc-grammar-fmt -- --check path/to/file.grammar
```

Formatting is idempotent and preserves `//` and `#` comments. The stage-zero parser and formatter
are handwritten so bootstrapping the parser stack never requires an already-generated parser.
