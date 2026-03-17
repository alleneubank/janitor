{
  description = "Zig project template";

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
      in {
        formatter = pkgs.alejandra;

        packages.ziglint = ziglint;

        devShells.default = pkgs.mkShell {
          name = "zig-dev";
          nativeBuildInputs = [
            pkgs.zigpkgs.master
            pkgs.zls
            pkgs.lefthook
            pkgs.jq
            pkgs.ripgrep
            ziglint
          ];

          shellHook =
            ''
              echo "zig $(zig version)"
            ''
            + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
              unset SDKROOT
              unset DEVELOPER_DIR
              export PATH=/usr/bin:$PATH
            '');
        };

        devShell = self.devShells.${system}.default;
      }
    );
}
