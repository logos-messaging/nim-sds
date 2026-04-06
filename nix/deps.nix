{ pkgs, stdenv, src, version, revision }:

stdenv.mkDerivation {
  pname = "nim-sds-nimble-deps";
  version = "${version}-${revision}";

  inherit src;

  nativeBuildInputs = with pkgs; [
    jq rsync git cacert moreutils
  ];

  configurePhase = ''
    export XDG_CACHE_HOME=$TMPDIR
    export NIMBLE_DIR=$NIX_BUILD_TOP/nimbledir
    export HOME=$TMPDIR
    git config --global user.email "nix@build"
    git config --global user.name "Nix Build"
    git config --global init.defaultBranch main
  '';

  buildPhase = ''
    mkdir -p $NIMBLE_DIR/pkgs2

    # Read nimble.lock and clone each package at the pinned revision.
    # This bypasses nimble entirely, avoiding its segfault when it tries
    # to build binary targets (e.g. testutils/ntu) in the Nix sandbox.
    for pkg in $(jq -r '.packages | keys[]' nimble.lock); do
      url=$(jq -r ".packages.\"$pkg\".url" nimble.lock)
      rev=$(jq -r ".packages.\"$pkg\".vcsRevision" nimble.lock)
      ver=$(jq -r ".packages.\"$pkg\".version" nimble.lock)
      sha1=$(jq -r ".packages.\"$pkg\".checksums.sha1" nimble.lock)

      dest="$NIMBLE_DIR/pkgs2/$pkg-$ver-$sha1"
      echo "Fetching $pkg@$ver ($rev) from $url"
      git clone --quiet "$url" "$TMPDIR/clone_$pkg"
      (cd "$TMPDIR/clone_$pkg" && git checkout --quiet "$rev")

      mkdir -p "$dest"
      rsync -a --exclude='.git' "$TMPDIR/clone_$pkg/" "$dest/"

      # Create nimblemeta.json (nimble needs this to recognise installed packages)
      files=$(cd "$dest" && find . -type f | sed 's|^\./|/|' | sort | jq -R . | jq -s .)
      cat > "$dest/nimblemeta.json" <<METAEOF
    {
      "version": 1,
      "metaData": {
        "url": "$url",
        "downloadMethod": "git",
        "vcsRevision": "$rev",
        "files": $files,
        "binaries": [],
        "specialVersions": ["$ver"]
      }
    }
METAEOF

      rm -rf "$TMPDIR/clone_$pkg"
    done

    # Generate nimble.paths from installed packages
    : > nimble.paths
    for pkg in $NIMBLE_DIR/pkgs2/*/; do
      echo "--path:\"$pkg\"" >> nimble.paths
    done
  '';

  installPhase = ''
    mkdir -p $out/nimbledeps

    cp nimble.paths $out/nimble.paths

    rsync -ra \
      --prune-empty-dirs \
      --include='*/' \
      --include='*.json' \
      --include='*.nim' \
      --include='*.nimble' \
      --exclude='*' \
      $NIMBLE_DIR/pkgs2 $out/nimbledeps
  '';

  fixupPhase = ''
    # Replace build path with deterministic $out.
    sed "s|$NIMBLE_DIR|./nimbledeps|g" $out/nimble.paths \
      | sort | sponge $out/nimble.paths

    # Nimble does not maintain order of files list.
    for META_FILE in $(find $out -name nimblemeta.json); do
      jq '.metaData.files |= sort' $META_FILE | sponge $META_FILE
    done
  '';

  # Make this a fixed-output derivation to allows internet access for git clones.
  outputHash = "sha256-KTiUrarS6MmPksi3asJX7UQFLaNKB+a11RB6aHHPZgc=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}
