{
  pkgs,
  src ? ../.,
  # Outputs to build: libsds, libsdsIOS or libsdsAndroid<Arch>.
  targets ? ["libsdsAndroidArm64"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" "x86_64-windows"],
}:

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) any match substring optionals optionalString;

  # Check if build is for android platform.
  containsAndroid = s: (match ".*[Aa]ndroid.*" s) != null;
  isAndroidBuild = any containsAndroid targets;

  tools = callPackage ./tools.nix {};

  ndkClang = triple: "${pkgs.androidPkgs.ndk}/toolchains/llvm/prebuilt/"
    + (if stdenv.isDarwin then "darwin" else "linux") + "-x86_64/bin/${triple}30-clang";
  androidParams = cpu: triple:
    "--os:android --cpu:${cpu} --cc:clang --clang.exe:${ndkClang triple}"
    + " --clang.linkerexe:${ndkClang triple} -d:chronicles_log_level=ERROR";

  # sds.nimble's task and the target flags for each output.
  buildCommand = target: {
    libsds = {
      task = "libsds";
      params = "-d:chronicles_line_numbers -d:chronicles_log_level=TRACE";
    };
    libsdsIOS = {
      task = "libsdsStatic";
      params = "--passC:\"-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)\"";
    };
    libsdsAndroidArm64 = { task = "libsds"; params = androidParams "arm64" "aarch64-linux-android"; };
    libsdsAndroidAmd64 = { task = "libsds"; params = androidParams "amd64" "x86_64-linux-android"; };
    libsdsAndroidX86 = { task = "libsds"; params = androidParams "i386" "i686-linux-android"; };
    libsdsAndroidArm = { task = "libsds"; params = androidParams "arm" "armv7a-linux-androideabi"; };
  }.${target};

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

  # The generated C helpers in libsds.h call TinyCBOR.
  propagatedBuildInputs = optionals (!isAndroidBuild) [ pkgs.tinycbor ];

  configurePhase = ''
    export NIMBLE_DIR=$NIX_BUILD_TOP/nimbledeps
    mkdir -p $NIMBLE_DIR/pkgs2

    # Populate pkgs2 with writable copies so nimble considers deps installed
    # and does not attempt to download them (which fails in the Nix sandbox).
    ${pkgs2SetupCmds}

    # Write nimble.paths so config.nims passes --path: flags to the Nim compiler.
    cp ${nimblePaths} ./nimble.paths
  '';

  # --useSystemNim: the sandbox has no network, so nimble must not try to fetch
  # the Nim pinned in nimble.lock. Nix supplies the compiler instead.
  buildPhase = lib.concatMapStringsSep "\n" (target: let
    command = buildCommand target;
  in ''
    NIM_PARAMS="--mm:refc --opt:size ${command.params}" nimble --useSystemNim --verbose ${command.task}
  '') targets;

  installPhase = let
    androidManifest = ''
      <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"org.waku.nim-sds\" />
    '';
  in if isAndroidBuild then ''
    mkdir -p $out/jni
    cp build/libsds.so build/libsds.h $out/jni/
    cp -r build/generated $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out
    zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/lib -p $out/include
    cp build/libsds.* $out/lib/
    rm $out/lib/libsds.h
    cp build/libsds.h $out/include/
    cp -r build/generated $out/include/
  '';

  meta = with pkgs.lib; {
    description = "Nim implementation of the e2e reliability protocol";
    homepage = "https://github.com/status-im/nim-sds";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
