{
  description = "janitor process-group supervisor";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    ...
  } @ inputs: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              zigpkgs = inputs.zig-overlay.packages.${prev.system};
            })
          ];
        };

        ziglintVersion = "0.5.2";

        ziglintSources = {
          "x86_64-linux" = {
            url = "https://github.com/rockorager/ziglint/releases/download/v${ziglintVersion}/ziglint-x86_64-linux.tar.gz";
            sha256 = "sha256-XqxsF1/0iDCg4Nl4SpY8wvNfLVOkZSEsyVNSXo9d9rs=";
          };
          "aarch64-linux" = {
            url = "https://github.com/rockorager/ziglint/releases/download/v${ziglintVersion}/ziglint-aarch64-linux.tar.gz";
            sha256 = "sha256-Dtjzaah/lji/0OETdGrXkiUu2gaoKsa8P1hIeGQhw0A=";
          };
          "aarch64-darwin" = {
            url = "https://github.com/rockorager/ziglint/releases/download/v${ziglintVersion}/ziglint-aarch64-macos.tar.gz";
            sha256 = "sha256-7F7Wk4p+iFGdiTtwd6c3O3dRWeTnCNYxSHtZ8FWyM1Y=";
          };
        };

        ziglint = let
          source =
            ziglintSources.${system}
              or (throw "ziglint: unsupported system ${system}");
        in
          pkgs.stdenv.mkDerivation {
            pname = "ziglint";
            version = ziglintVersion;

            src = pkgs.fetchurl {
              inherit (source) url sha256;
            };

            sourceRoot = ".";

            unpackPhase = ''
              mkdir -p unpacked
              tar xzf $src -C unpacked
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp unpacked/ziglint $out/bin/ziglint
              chmod +x $out/bin/ziglint
            '';

            meta = with pkgs.lib; {
              description = "Opinionated linter for Zig";
              homepage = "https://github.com/rockorager/ziglint";
              platforms = builtins.attrNames ziglintSources;
            };
          };
        # nixpkgs still ships lefthook <= 2.1.5 (2.1.9 bump pending in
        # NixOS/nixpkgs#514847). Hooks need >= 2.1.6 for the pty/setsid fix
        # (evilmartians/lefthook#1392): older versions allocate a pty via
        # setsid() for every `run:` command, which sandboxed environments such
        # as Claude Code sessions forbid, failing all hooks with EPERM.
        # 2.1.8 (not 2.1.9) because 2.1.9's go.mod needs Go >= 1.26.3 while
        # the pinned nixpkgs has 1.26.1; 2.1.8 also silences the spurious
        # core.hooksPath warning (lefthook#1421). Drop this override once the
        # nixpkgs bump lands.
        lefthook = pkgs.lefthook.overrideAttrs (finalAttrs: prevAttrs: {
          version = "2.1.8";
          src = pkgs.fetchFromGitHub {
            owner = "evilmartians";
            repo = "lefthook";
            rev = "v${finalAttrs.version}";
            hash = "sha256-ZCdDRJw59M/Uy0/z2fsNc/KRQx0ZXANOe1UFJZE7ffQ=";
          };
          vendorHash = "sha256-jVjdGnNRRFTjd2/DjKHZmLWkbtb3eEQ+R/yw1LBa3bE=";
        });
      in {
        formatter = pkgs.alejandra;

        packages.ziglint = ziglint;

        devShells.default = pkgs.mkShell {
          name = "zig-dev";
          nativeBuildInputs = [
            pkgs.zigpkgs."0.15.2"
            pkgs.zls
            lefthook
            pkgs.jq
            pkgs.ripgrep
            ziglint
          ];

          shellHook =
            ''
              echo "zig $(zig version)"
              if [ -e .git ]; then
                lefthook install >/dev/null 2>&1 || true
              fi
            ''
            + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
              unset SDKROOT
              unset DEVELOPER_DIR
              export PATH=/usr/bin:$PATH
            '');
        };
      }
    );
}
