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

  # The library and target flags for each output.
  shared = { app = "lib"; out = "libsds.${if stdenv.isDarwin then "dylib" else "so"}"; };
  buildCommand = target: {
    libsds = shared // {
      params = "-d:chronicles_line_numbers -d:chronicles_log_level=TRACE";
    };
    libsdsIOS = {
      app = "staticlib"; out = "libsds.a";
      params = "--os:ios --cpu:arm64 --cc:clang --passC:\"-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)\"";
    };
    libsdsAndroidArm64 = shared // { out = "libsds.so"; params = androidParams "arm64" "aarch64-linux-android"; };
    libsdsAndroidAmd64 = shared // { out = "libsds.so"; params = androidParams "amd64" "x86_64-linux-android"; };
    libsdsAndroidX86 = shared // { out = "libsds.so"; params = androidParams "i386" "i686-linux-android"; };
    libsdsAndroidArm = shared // { out = "libsds.so"; params = androidParams "arm" "armv7a-linux-androideabi"; };
  }.${target};

  revision = substring 0 8 (src.rev or src.dirtyRev or "00000000");
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../sds.nimble;

  # Fetched dep sources, keyed by package name.
  deps = import ./deps.nix { inherit pkgs; };

  # nimble.paths for the Nim compiler (read by config.nims).
  # Paths must be double-quoted so that NimScript can parse the include correctly.
  nimblePaths = pkgs.writeText "nimble.paths" (
    builtins.concatStringsSep "\n" (
      [ "--noNimblePath" ] ++
      builtins.concatMap (p: [ "--path:\"${p}\"" "--path:\"${p}/src\"" ])
        (builtins.attrValues deps)
    )
  );

in stdenv.mkDerivation {
  pname = "nim-sds";
  inherit src;
  version = "${version}-${revision}";

  env = {
    ANDROID_SDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.sdk;
    ANDROID_NDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.ndk;
  };

  buildInputs = with pkgs; [
    openssl gmp zip nim-2_2 git
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = with pkgs; [
    nim-2_2 cmake which patchelf
  ] ++ optionals stdenv.isLinux [
    pkgs.lsb-release
  ];

  # The generated C helpers in libsds.h call TinyCBOR.
  propagatedBuildInputs = optionals (!isAndroidBuild) [ pkgs.tinycbor ];

  configurePhase = ''
    # Write nimble.paths so config.nims passes --path: flags to the Nim compiler.
    cp ${nimblePaths} ./nimble.paths
  '';

  # Nix supplies the compiler; config.nims reads nimble.paths.
  buildPhase = lib.concatMapStringsSep "\n" (target: let
    command = buildCommand target;
  in ''
    nim c -d:ffiOutputDir=$PWD/build/generated --nimcache:$PWD/build/nimcache \
      --app:${command.app} --out:build/${command.out} \
      --mm:refc --opt:size ${command.params} library/libsds.nim
    cp library/libsds.h build/
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
