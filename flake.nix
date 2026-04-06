{
  description = "Nim-SDS build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    # We are pinning the commit because ultimately we want to use same commit across different projects.
    # A commit from nixpkgs 25.11 release : https://github.com/NixOS/nixpkgs/tree/release-25.11
    nixpkgs.url = "github:NixOS/nixpkgs?rev=23d72dabcb3b12469f57b37170fcbc1789bd7457";
  };

  outputs = { self, nixpkgs }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);

      # Pin Nim to 2.2.8 to match the project's minimum requirement (nim >= 2.2.6).
      # nixpkgs ships Nim 2.2.4 whose nimble segfaults in sandboxed builds.
      # The extra-mangling patch is rebased for the 2.2.8 source tree.
      nimOverlay = final: prev: {
        nim-unwrapped-2_2 = prev.nim-unwrapped-2_2.overrideAttrs (old: rec {
          version = "2.2.8";
          src = prev.fetchurl {
            url = "https://nim-lang.org/download/nim-${version}.tar.xz";
            hash = "sha256-EUGRr6CDxQWdy+XOiNvk9CVCz/BOLDAXZo7kOLwLjPw=";
          };
          patches = builtins.filter (p:
            !prev.lib.hasSuffix "extra-mangling-2.patch" (toString p)
          ) old.patches ++ [
            ./nix/patches/nim-2.2.8-extra-mangling.patch
          ];
          # Nim 2.2.8 has a cstring-to-string type error in excpt.nim when
          # -d:nativeStacktrace is enabled. Drop it until upstream fixes it.
          kochArgs = prev.lib.remove "-d:nativeStacktrace" old.kochArgs;
        });
      };

      pkgsFor = forAllSystems (
        system: import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays =  [
            nimOverlay
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })
          ];
        }
      );

    in rec {
      packages = forAllSystems (system: let
        pkgs = pkgsFor.${system};

        buildTargets = pkgs.callPackage ./nix/default.nix {
          src = self;
        };

        # All potential targets
        allTargets = [
          "libsds"
          "libsds-android-arm64"
          "libsds-android-amd64"
          "libsds-android-x86"
          "libsds-android-arm"
          "libsds-ios"
        ];

        # Create a package for each target
        allPackages = builtins.listToAttrs (map (t: {
          name = t;
          value = buildTargets.override { targets = [ t ]; };
        }) allTargets);
      in
        allPackages // {
          default = allPackages.libsds;
        }
      );

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {
        };
      });
    };

}
