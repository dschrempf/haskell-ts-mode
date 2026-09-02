<!-- Generated from README.org by `make readme'.  Do not edit. -->

[![img](https://github.com/dschrempf/haskell-ts-mode/actions/workflows/ci.yml/badge.svg)](https://github.com/dschrempf/haskell-ts-mode/actions/workflows/ci.yml)

**NOTICE:** This is a fork of [Pranshu's `haskell-ts-mode`](https://codeberg.org/pranshu/haskell-ts-mode) and under active
development. The API may change without notice.

An Emacs major mode for [Haskell](https://www.haskell.org/) built on [Tree-sitter](https://tree-sitter.github.io/tree-sitter/). Font lock, structural
and prose navigation, `imenu` and the REPL integration all work off the syntax
tree, which Emacs's built-in `treesit` keeps up to date.

The queries and the prose navigation are written against the node types of
[my fork of the `tree-sitter-haskell` grammar](https://github.com/dschrempf/tree-sitter-haskell), which this mode requires; the
official grammar does not work. Building it is a manual step, see
[Installing the grammar](#grammar).

![img](./ss.png "`haskell-ts-mode` with `prettify-symbols-mode` enabled")


<a id="features"></a>

# Features

-   Font lock at four levels of detail. Because it follows the syntax tree, only
    variables that are actually bound are highlighted &#x2013; not every occurrence of
    a name.
-   Structural navigation over declarations, bindings and expressions; see
    [Usage](#usage).
-   Comment-aware editing: sentence and paragraph motion inside comments and
    strings, paragraph text objects that stop at the comment/code boundary, and
    marker continuation on `RET`.
-   Imenu outline of functions, type signatures, data declarations and type
    aliases.
-   A GHCi REPL that uses `cabal repl` inside a cabal project; see [REPL](#repl).
-   `prettify-symbols-mode` support and an `M-x align` rule for `=` signs.

Deliberately out of scope:

-   **Indentation.** No indentation rules are installed, so `TAB` keeps Emacs's
    default behaviour (`indent-relative`). Earlier versions shipped Tree-sitter
    indentation rules; they proved unmaintainable and were removed, see
    [CHANGELOG.org](./CHANGELOG.org).
-   **Completion, diagnostics and cross references.** Use a language server, see
    [Language server](#language-server).
-   **Formatting.** Use a formatter such as Ormolu, for example through
    [Apheleia](https://github.com/radian-software/apheleia).


# Requirements

-   Emacs 30.1 or newer, built with Tree-sitter support (`treesit-available-p`
    returns non-nil).
-   [`inheritenv`](https://github.com/purcell/inheritenv), available from MELPA. The REPL needs it when
    `process-environment` / `exec-path` are set buffer-locally rather than
    globally, as a `direnv` integration like [`envrc`](https://github.com/purcell/envrc) does: neither the GHCi
    buffer nor the temporary buffer probing `cabal repl` inherits a buffer-local
    value.
-   A Haskell grammar built from [my fork](https://github.com/dschrempf/tree-sitter-haskell), see [Installing the grammar](#grammar).


# Installation

This fork is not on any package archive; install it from its repository. Add
this into your init.el:

```emacs-lisp
(use-package haskell-ts-mode
  :vc (:url "https://github.com/dschrempf/haskell-ts-mode" :rev :newest)
  :custom
  ;; Optional; both differ from the default.
  (haskell-ts-font-lock-level 3)
  (haskell-ts-prettify-symbols t))
```

An autoload puts `.hs` files into `haskell-ts-mode`, so nothing else is needed
to activate it.

Dropping `:rev :newest` installs the last release tag instead of the latest
commit. Note that `:ensure t` would install [Pranshu's `haskell-ts-mode`](https://codeberg.org/pranshu/haskell-ts-mode) from
MELPA, not this fork.


<a id="grammar"></a>

## Installing the grammar

The Haskell Tree-sitter grammar landscape is fragmented. There are several
versions:

-   the official [tree-sitter/tree-sitter-haskell](https://github.com/tree-sitter/tree-sitter-haskell) grammar (unmaintained);
-   a community fork (somewhat maintained);
-   a [fork by @tek](https://github.com/tek/tree-sitter-haskell) (well maintained);
-   [my fork of @tek's grammar](https://github.com/dschrempf/tree-sitter-haskell) (well maintained, with some features not in @tek's).

`haskell-ts-mode` requires my fork. @tek's grammar already fixes node type
names that the official grammar gets wrong (`type_synomym` → `type_synonym`,
for example), so the official grammar does **not** work with this mode. On top of
that, mine splits `comment` and `haddock` nodes into a `marker` child (`--`,
`-- |`, `-- ^`, `{-`, &#x2026;) and a `content` child holding the body, which prose
navigation reads directly instead of guessing the marker's shape with a
regexp.

The grammar has to be installed manually. `M-x
treesit-install-language-grammar` cannot do it: it defaults to the official
repository, and my repository ships neither a generated parser
(`src/parser.c`) nor a release branch, so the parser has to be produced with
`tree-sitter generate` before it can be compiled.

Either build the shared library yourself (clone the repository, run
`tree-sitter generate`, compile `src/parser.c` into a
`libtree-sitter-haskell` shared object and put it on
`treesit-extra-load-path`), or let a package manager build it. The
`flake.nix` in this repository builds the right grammar for development and
for the test suite.


<a id="usage"></a>

# Usage

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Command</th>
<th scope="col" class="org-left">Action</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>C-c C-r</code></td>
<td class="org-left"><code>haskell-ts-run</code></td>
<td class="org-left">Start a REPL (<code>C-u</code> to pick the cabal component)</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-c</code></td>
<td class="org-left"><code>haskell-ts-compile-region-and-go</code></td>
<td class="org-left">Send the region, or reload with <code>:r</code> when none is active</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-l</code></td>
<td class="org-left"><code>haskell-ts-load-file</code></td>
<td class="org-left">Save the buffer and <code>:load</code> its file</td>
</tr>

<tr>
<td class="org-left"><code>C-c C-e</code></td>
<td class="org-left"><code>haskell-ts-send-line</code></td>
<td class="org-left">Send the current line, verbatim</td>
</tr>

<tr>
<td class="org-left"><code>C-M-x</code></td>
<td class="org-left"><code>haskell-ts-send-defun</code></td>
<td class="org-left">Send the definition at point</td>
</tr>
</tbody>
</table>

Standard Emacs commands that become Haskell-aware in this mode:

-   `C-M-f` and `C-M-b` (`forward-sexp`, `backward-sexp`) move over
    declarations, bindings and expressions.
-   `M-e` and `M-a` (`forward-sentence`, `backward-sentence`) move by sentence
    inside comments and strings, and by equation in code.
-   `M-x imenu` jumps to a definition, `M-x align` lines up `=` signs.


## Structural navigation

```haskell
combs (x:xs) = map (x:) c ++ c
  where c = combs xs
```

With point right in front of the definition of `combs`, `C-M-f`
(`forward-sexp`) moves to the end of the second line: the equation and its
`where` clause are one sexp.


## Comments and prose

A `--` or Haddock comment spanning several lines is a single syntax node whose
continuation markers are ordinary text. Prose motion accounts for that:
sentence and paragraph boundaries are found as if the markers were not there,
and killing a sentence that spans a continuation line leaves that line's
marker in place, rather than merging two comment lines into one.

`RET` inside an own-line comment continues it with the same marker and
indentation. An inline comment &#x2013; one that follows code on the same line &#x2013;
is left alone.

With `evil` loaded, the paragraph text objects (`a p`, `i p`) and sentence
deletion (`d a s`) stay inside the comment instead of spilling into the
surrounding code, even when the comment is glued directly to it.


<a id="repl"></a>

# REPL

`C-c C-r` (`haskell-ts-run`) starts an inferior Haskell process. When the
current buffer is inside a cabal project (a `cabal.project` or `*.cabal` file
is found by walking up the directory tree), the process is started with `cabal
repl` in the project root, so the project's dependencies, default language
extensions and GHC options are available, and relative `import`'s and the
module search path resolve. Outside a cabal project it falls back to plain
`ghci`. This is controlled by `haskell-ts-use-cabal` (default `auto`; set it
to `nil` to always use `ghci`, or `t` to always use `cabal`).

The current file is passed as the cabal target, so the owning component is
opened. When the file belongs to several components, `haskell-ts-run` prompts
for one and remembers the choice per buffer; a prefix argument (`C-u C-c C-r`)
forces the prompt even for an unambiguous file.

`C-M-x` sends the definition at point &#x2013; the same definition
`treesit-defun-name-function` and imenu use, so it is either a top-level
binding or, from inside a `where` or `let` block, the enclosing local one.

The inferior buffer runs `haskell-ts-inferior-mode` (derived from
`comint-mode`): the prompt is read-only and input history is persisted across
sessions in `haskell-ts-inferior-history-file`. Filename completion and
history navigation (`TAB`, `M-p`, `M-n`) come from `comint`.


# Customization


## Font lock level

Set `haskell-ts-font-lock-level` to a value between 1 and 4. The default, 4,
fontifies the most; lower it for a quieter buffer.


## Prettify Symbols mode

With `haskell-ts-prettify-symbols` set, `prettify-symbols-mode` replaces
common operators with unicode alternatives, turning `->` into `→`:

```emacs-lisp
(setopt haskell-ts-prettify-symbols t)
(add-hook 'haskell-ts-mode-hook 'prettify-symbols-mode)
```

The variable defaults to nil, in which case `prettify-symbols-mode` has
nothing to substitute in a Haskell buffer. Setting `haskell-ts-prettify-words`
(nil by default as well) prettifies words too, turning `forall` into `∀` and
`elem` into `∈`.


## Aligning `=` signs

Calling `M-x align` on a region lines up the standalone `=` signs of the
bindings and equations it contains, for example:

    x   = 1
    foo = 2
    ab  = 3

Only an `=` surrounded by whitespace is aligned, so `==`, `=>`,
`<=`, `>=` and `/=` are left untouched. The rule lives in
`haskell-ts-align-rules-list`.


<a id="language-server"></a>

## Language server

`haskell-ts-mode` declares `haskell-mode` as a parent mode, so configuration
keyed on `haskell-mode` applies to it. `eglot` therefore picks up
`haskell-language-server-wrapper` without further setup, and `lsp-mode` works
as well.


## Other recommended packages

Unlike `haskell-mode`, this mode has limited scope. Other packages that help a
lot with development:

-   [consult-hoogle](https://codeberg.org/rahguzar/consult-hoogle) to consult Hoogle.
-   [Apheleia](https://github.com/radian-software/apheleia) to format code.


# Comparison with `haskell-mode`

`haskell-mode` is about 30 years old and has grown to nearly 30,000 lines
covering all things Haskell related. Much of what it once provided is now part
of standard Emacs. In 2018, [`haskell-tng-mode`](https://elpa.nongnu.org/nongnu/haskell-tng-mode.html) set out to solve some of
these problems, but because of Haskell's syntax it too became complex and
required a web of dependencies. Both end up approximating a Haskell parser in
order to highlight and indent code &#x2013; so why not use a real one? This mode
does, for everything it covers; indentation is the one thing it leaves out,
see [Features](#features).

Compared with `haskell-mode`, this mode:

-   highlights logically rather than approximately:
    -   only arguments that can be used in the function body are highlighted; in
        `f (_:(a:[]))` that is `a` alone, as it is the only captured variable;
    -   the return type of a function is highlighted;
    -   newly bound variables are highlighted wherever they appear, including
        generators and lambda arguments;
    -   the `=` of a guarded match is recognized as such, which would be
        stupidly hard with regular expressions;
-   is more performant, especially on long files;
-   is much, much smaller: it keeps to basic major mode functionality and leaves
    other tasks to external packages.


# Contributing

Issues and pull requests are welcome. In the flake's development shell (`nix
develop`), `make check` byte-compiles the sources and runs the formatting and
readme checks, `checkdoc`, `package-lint`, `relint` and the ERT suite; `nix
flake check` runs the same gate in a sandbox. Outside the development shell
the tests that need the Tree-sitter grammar are skipped rather than failed.

This file is the readme; `README.md` is generated from it by `make readme`
and committed, because GitHub renders Org with a converter that drops custom
ID anchors and leaves markup inside link descriptions unrendered. Edit
`README.org`, then run `make readme` &#x2013; `make check` fails when the two have
drifted apart.


# Changelog

See [CHANGELOG.org](./CHANGELOG.org) for the list of notable changes.


# License

GPL-3.0-or-later, see [LICENSE](./LICENSE).

