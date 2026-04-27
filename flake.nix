{
  description = "Claude Code Neovim plugin development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Separate nixpkgs pin used only to build reviewfixer. The main pin is
    # held back to avoid CI/formatter churn, but reviewfixer requires
    # Go >= 1.26.2. Remove `nixpkgs-reviewfixer` (and `pkgsReviewfixer`
    # below) once the main pin includes Go >= 1.26.2
    # (check: `nix eval nixpkgs#go.version`).
    #
    # Note: `nix flake update` (no `--select`) bumps both inputs to the
    # same rev, silently collapsing this version gap. Use
    # `nix flake update nixpkgs-reviewfixer` to update this input alone.
    nixpkgs-reviewfixer.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = { self, nixpkgs, nixpkgs-reviewfixer, flake-utils, treefmt-nix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;

          config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [
            "claude-code"
          ];
        };

        pkgsReviewfixer = import nixpkgs-reviewfixer { inherit system; };

        reviewfixer = pkgsReviewfixer.buildGoModule rec {
          pname = "reviewfixer";
          version = "0.1.0-beta.0";

          src = pkgsReviewfixer.fetchFromGitHub {
            owner = "ThomasK33";
            repo = "reviewfixer";
            rev = "v${version}";
            hash = "sha256-hrnSm7ttpyUAtkre9micI2n9smKgzX5AmUcj3bJQjbU=";
          };

          vendorHash = "sha256-yIWbmHFxmOeXBm5TMRsupy33DC6VAUYvZNSz5wa1yxA=";

          # Upstream tests shell out to `git`, which isn't available in the
          # Nix build sandbox. Skip the test phase here.
          doCheck = false;

          meta = with pkgsReviewfixer.lib; {
            description = "Local harness for working through review feedback on Graphite-managed stacked PRs";
            homepage = "https://github.com/ThomasK33/reviewfixer";
            license = licenses.mit;
            mainProgram = "reviewfixer";
          };
        };

        treefmt = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs = {
            stylua.enable = true;
            nixpkgs-fmt.enable = true;
            prettier.enable = true;
            shfmt.enable = true;
            actionlint.enable = true;
            zizmor.enable = true;
            shellcheck.enable = true;
          };
          settings.formatter.shellcheck.options = [ "--exclude=SC1091,SC2016" ];
          settings.formatter.prettier.excludes = [
            # Exclude lazy.nvim lock files as they are auto-generated
            # and will be reformatted by lazy on each package update
            "fixtures/*/lazy-lock.json"
          ];
        };

        # CI-specific packages (minimal set for testing and linting)
        ciPackages = with pkgs; [
          lua5_1
          luajitPackages.luacheck
          luajitPackages.busted
          luajitPackages.luacov
          neovim
          treefmt.config.build.wrapper
          findutils
        ];

        # Development packages (additional tools for development)
        devPackages = with pkgs; [
          ast-grep
          luarocks
          gnumake
          websocat
          jq
          fzf
          reviewfixer
          # claude-code
        ];
      in
      {
        # Format the source tree
        formatter = treefmt.config.build.wrapper;

        # Check formatting
        checks.formatting = treefmt.config.build.check self;

        devShells = {
          # Minimal CI environment
          ci = pkgs.mkShell {
            buildInputs = ciPackages;
          };

          # Full development environment
          default = pkgs.mkShell {
            buildInputs = ciPackages ++ devPackages;
          };
        };
      }
    );
}
