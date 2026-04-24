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

      pkgsFor = forAllSystems (
        system: import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays =  [
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })

            (final: prev: {
              nimble = prev.nimble.overrideAttrs (old: {
                src = prev.fetchFromGitHub {
                  version = "0.22.0";
                  owner = "nim-lang";
                  repo = "nimble";
                  rev = "802e158ddce88c93367ebd9b3c66714b215a7928";
                  hash = "sha256-m0i6JOwdxvp33XAr9XJ1Daly+4DOLPTUDNXKCHJj3I8=";
                  fetchSubmodules = true;
                };
              });
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

        # All potential targets — must match nimble task names in sds.nimble.
        allTargets = [
          "libsds"
          "libsdsAndroidArm64"
          "libsdsAndroidAmd64"
          "libsdsAndroidX86"
          "libsdsAndroidArm"
          "libsdsIOS"
        ];

        # Create a package for each target
        allPackages = builtins.listToAttrs (map (t: {
          name = t;
          value = buildTargets.override { targets = [ t ]; };
        }) allTargets);
      in
        allPackages // {
          default = allPackages.libsds;
          # Convenience aliases matching old hyphenated names.
          libsds-android-arm64 = allPackages.libsdsAndroidArm64;
          libsds-android-amd64 = allPackages.libsdsAndroidAmd64;
          libsds-android-x86   = allPackages.libsdsAndroidX86;
          libsds-android-arm   = allPackages.libsdsAndroidArm;
          libsds-ios           = allPackages.libsdsIOS;
        }
      );

      devShells = forAllSystems (system:
        let pkgs = pkgsFor.${system}; in {
          default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              nim-2_2
              nimble
            ];
          };
        }
      );
    };

}
