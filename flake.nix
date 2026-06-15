{
  description = "Development environment for `haskell-ts-mode`";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        {
          pkgs,
          ...
        }:
        let
          hpkgs = pkgs.haskellPackages;

          # This mode targets @tek's tree-sitter-haskell grammar
          # (https://github.com/tek/tree-sitter-haskell), which is more
          # actively developed than the official one and whose node types
          # the font-lock and indentation queries are written against.
          # Override the nixpkgs grammar to that revision; its `src/' is
          # not pre-generated, so regenerate it with `tree-sitter generate'
          # before building.
          overrideTreeSitterHaskell =
            tree-sitter-haskell:
            tree-sitter-haskell.overrideAttrs (old: {
              version = "2026-03-03";
              src = pkgs.fetchFromGitHub {
                owner = "tek";
                repo = "tree-sitter-haskell";
                rev = "064b41807b2af4a9a23716c4987597ed7e21947a";
                hash = "sha256-EJw8AHpfpfzAOwa6RKASm4C+Dt2JAgCodHXxSBO7WzA=";
              };
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                pkgs.nodejs
                pkgs.tree-sitter
              ];
              preBuild = ''
                tree-sitter generate
              '';
            });

          # A directory holding `libtree-sitter-haskell.so' built from the
          # tek grammar.  The nixpkgs emacs wrapper does not wire grammars
          # into `treesit-extra-load-path', so we expose this path via the
          # HASKELL_TS_GRAMMAR_PATH environment variable and the test
          # harness adds it itself (see tests/haskell-ts-mode-tests.el).
          haskellGrammar =
            (pkgs.emacs.pkgs.treesit-grammars.with-grammars (
              ps: [ (overrideTreeSitterHaskell ps.tree-sitter-haskell) ]
            ))
            + "/lib";

          # Emacs with `inheritenv', a hard dependency of haskell-ts-mode.
          # The grammar is provided separately, via HASKELL_TS_GRAMMAR_PATH.
          emacsForTests = pkgs.emacs.pkgs.withPackages (epkgs: [ epkgs.inheritenv ]);
        in
        {
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              emacsForTests
              hpkgs.cabal-install
              hpkgs.ghc
              hpkgs.haskell-language-server
            ];
            # So `make test' under `nix develop' / direnv runs the
            # grammar-dependent integration tests instead of skipping them.
            HASKELL_TS_GRAMMAR_PATH = haskellGrammar;
          };

          # `nix flake check' runs the byte-compile + ERT suite headlessly
          # against the tek grammar.
          checks.default =
            pkgs.runCommand "haskell-ts-mode-check"
              {
                nativeBuildInputs = [ emacsForTests ];
                HASKELL_TS_GRAMMAR_PATH = haskellGrammar;
              }
              ''
                cp -r ${./.} src
                chmod -R +w src
                cd src
                make check EMACS=${emacsForTests}/bin/emacs
                touch $out
              '';

          packages.emacs = emacsForTests;
        };
      flake = { };
    };
}
