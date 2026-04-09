{
  pkgs ? import <nixpkgs> { },
}:

let
  inherit (pkgs) lib stdenv;

in pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ];

  buildInputs = with pkgs; [
    nim-2_2
    nimble
    which
    git
    cmake
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.libiconv
  ];

  # Avoid compiling Nim itself.
  shellHook = ''
    export USE_SYSTEM_NIM=1
  '';
}
