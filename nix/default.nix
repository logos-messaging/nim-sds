{
  pkgs,
  src ? ../.,
  # Options: 0,1,2
  verbosity ? 2,
  # Make targets
  targets ? ["libsds-android-arm64"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" "x86_64-windows"],
}:

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) any match substring optionals optionalString;

  # Check if build is for android platform.
  containsAndroid = s: (match ".*android.*" s) != null;
  isAndroidBuild = any containsAndroid targets;

  tools = callPackage ./tools.nix {};

  revision = substring 0 8 (src.rev or src.dirtyRev or "00000000");
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../sds.nimble;

  # Fetched dep sources, keyed by package name.
  deps = import ./deps.nix { inherit pkgs; };

  # nimble.lock metadata (version + checksums) for pkgs2 directory naming.
  lockFile = builtins.fromJSON (builtins.readFile ../nimble.lock);
  lockPkgs = lockFile.packages;

  # nimble.paths for the Nim compiler (read by config.nims).
  # Paths must be double-quoted so that NimScript can parse the include correctly.
  nimblePaths = pkgs.writeText "nimble.paths" (
    builtins.concatStringsSep "\n" (
      [ "--noNimblePath" ] ++
      builtins.concatMap (p: [ "--path:\"${p}\"" "--path:\"${p}/src\"" ])
        (builtins.attrValues deps)
    )
  );

  # Shell commands to populate pkgs2 with writable copies of only the Nim
  # source files nimble needs for dependency resolution. Full source for
  # compilation is provided via nimble.paths pointing to the Nix store.
  # Using rsync (same file filter as the old fixed-output deps derivation).
  # Each dir also gets a nimblemeta.json so nimble recognises it as installed
  # and does not attempt to re-download the package.
  pkgs2SetupCmds = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: dep:
      let
        meta = lockPkgs.${name};
        dirName = "${name}-${meta.version}-${meta.checksums.sha1}";
        nimbleMeta = pkgs.writeText "${name}-nimblemeta.json" (builtins.toJSON {
          version = 1;
          metaData = {
            url = meta.url;
            downloadMethod = "git";
            vcsRevision = meta.vcsRevision;
            files = [];
            binaries = [];
            specialVersions = [ meta.version ];
          };
        });
      in ''
        mkdir -p "$NIMBLE_DIR/pkgs2/${dirName}"
        rsync -a \
          --include='*/' \
          --include='*.nim' \
          --include='*.nims' \
          --include='*.nimble' \
          --include='*.json' \
          --exclude='*' \
          ${dep}/ "$NIMBLE_DIR/pkgs2/${dirName}/"
        chmod -R u+w "$NIMBLE_DIR/pkgs2/${dirName}"
        cp ${nimbleMeta} "$NIMBLE_DIR/pkgs2/${dirName}/nimblemeta.json"
      ''
    ) deps
  );

in stdenv.mkDerivation {
  pname = "nim-sds";
  inherit src;
  version = "${version}-${revision}";

  env = {
    NIMFLAGS = "-d:disableMarchNative";
    ANDROID_SDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.sdk;
    ANDROID_NDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.ndk;
  };

  buildInputs = with pkgs; [
    openssl gmp zip nim-2_2 git nimble
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = with pkgs; [
    nim-2_2 nimble rsync cmake which patchelf
  ] ++ optionals stdenv.isLinux [
    pkgs.lsb-release
  ];

  makeFlags = targets ++ [
    "V=${toString verbosity}"
  ];

  configurePhase = ''
    export NIMBLE_DIR=$NIX_BUILD_TOP/nimbledeps
    mkdir -p $NIMBLE_DIR/pkgs2

    # Populate pkgs2 with writable copies so nimble considers deps installed
    # and does not attempt to download them (which fails in the Nix sandbox).
    ${pkgs2SetupCmds}

    # Write nimble.paths so config.nims passes --path: flags to the Nim compiler.
    cp ${nimblePaths} ./nimble.paths
  '';

  installPhase = let
    androidManifest = ''
      <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"org.waku.nim-sds\" />
    '';
  in if isAndroidBuild then ''
    mkdir -p $out/jni
    cp -r build/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out
    zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/lib -p $out/include
    cp build/lib* $out/lib/
    cp library/libsds.h $out/include/
  '';

  meta = with pkgs.lib; {
    description = "Nim implementation of the e2e reliability protocol";
    homepage = "https://github.com/status-im/nim-sds";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
