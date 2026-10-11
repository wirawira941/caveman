#!/data/data/com.termux/files/usr/bin/sh
# install-termux-pie.sh — install Caveman PIE binaries on Termux (Android 10+)
#
# Caveman's stock release binaries are non-PIE (ELF ET_EXEC). Android 10+
# refuses them with "unexpected e_type: 2", and `caveman setup --install` also
# rejects `android` in its platform table. This script sidesteps both: it drops
# the PIE binaries from the GitHub Actions artifact into ~/.caveman/bin, which
# cavemanBin() resolves WITHOUT any manifest or checksum gate (lookup order is
# env var -> PATH -> ~/.caveman/bin), and writes a manifest so `caveman setup`
# reports them honestly.
#
# Usage (from the artifact directory, or pass a path/tarball):
#   ./scripts/install-termux-pie.sh
#   ./scripts/install-termux-pie.sh /path/to/caveman-pie-arm64
#   ./scripts/install-termux-pie.sh /path/to/caveman-pie-arm64.zip
#
# The CLI resolves the following names from ~/.caveman/bin:
#   caveman-proxy  caveman-engine  caveman-mcp  cavemem
#   caveman-browse caveman-shrink

set -eu

CAVEMAN_HOME="${CAVEMAN_HOME:-$HOME/.caveman}"
BIN_DIR="$CAVEMAN_HOME/bin"
BINARY_RELEASE="${CAVEMAN_BINARY_RELEASE:-bin-v2.1.0}"

# RELEASE_BINARIES in scripts/build-release-binaries.mjs — name -> filename.
NAMES="caveman-proxy caveman-engine caveman-mcp cavemem caveman-browse caveman-shrink"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# Find the artifact contents: either a directory of *_linux_arm64 files, or a
# zip we unpack into a temp dir.
resolve_src() {
  src="${1:-.}"
  case "$src" in
    /*) ;;
    *) src="$PWD/$src" ;;
  esac
  [ -e "$src" ] || die "source not found: $src"

  case "$src" in
    *.zip)
      tmp="$(mktemp -d)"
      unzip -q "$src" -d "$tmp" || die "unzip failed: $src"
      src="$tmp"
      ;;
  esac

  # Flatten: the artifact may nest one or two directory levels
  # (artifacts unpack to binaries/ and recipes/ side by side).
  if [ -d "$src/binaries" ]; then src="$src/binaries"; fi
  if [ -d "$src/dist/binaries" ]; then src="$src/dist/binaries"; fi
  src="$src"
}

check_binary() {
  # The whole point: reject anything that isn't ET_DYN, because that is
  # exactly what Android kills with "unexpected e_type: 2".
  path="$1"
  # readelf prints e.g. "  Type:                              EXEC (Executable file)".
  # Pull the first token after the colon so "EXEC"/"DYN" is matched cleanly
  # regardless of the description text or surrounding whitespace.
  type_field="$(readelf -h "$path" 2>/dev/null | sed -n 's/^ *Type: *//p' | cut -d' ' -f1 | tr -d '[:space:]')"
  case "$type_field" in
    DYN) return 0 ;;
    EXEC) die "$path is non-PIE (ET_EXEC) — Android 10+ will refuse it with 'unexpected e_type: 2'. Rebuild with -buildmode=pie." ;;
    "") die "cannot read ELF type from $path (readelf missing or not an ELF)" ;;
    *) die "$path has unexpected ELF type '$type_field'" ;;
  esac
}

main() {
  resolve_src "$1"

  command -v readelf >/dev/null 2>&1 || die "readelf not found — install it: pkg install binutils"
  command -v caveman >/dev/null 2>&1 || info "note: caveman CLI not on PATH — install it first: npm i -g @caveman-ai/cli"

  mkdir -p "$BIN_DIR"
  chmod 700 "$CAVEMAN_HOME" 2>/dev/null || true
  chmod 700 "$BIN_DIR" 2>/dev/null || true

  installed=0
  manifest_entries=""
  for name in $NAMES; do
    artifact="$src/${name}_linux_arm64"
    [ -f "$artifact" ] || { info "skip  $name (not in artifact)"; continue; }

    check_binary "$artifact" || exit 1

    dest="$BIN_DIR/$name"
    cp "$artifact" "$dest"
    chmod 700 "$dest"

    sum="$(sha256sum "$dest" | cut -d' ' -f1)"
    # .bin-manifest.json is what verifiedLocalInstall() reads; writing it keeps
    # `caveman setup` from claiming the binaries are missing. The runtime
    # lookup in cavemanBin() never consults it, so a mismatch can't break runs.
    manifest_entries="${manifest_entries}$(printf '"%s":"%s",\n' "$name" "$sum")"
    info "ok    $name  -> $dest  (sha256 $sum, PIE)"
    installed=$((installed + 1))
  done

  [ "$installed" -gt 0 ] || die "no *_linux_arm64 binaries found in $src"

  # Write the manifest caveman setup --install looks for. Trim the trailing
  # comma so it stays valid JSON.
  entries="$(printf '%s' "$manifest_entries" | sed '$ s/,$//')"
  printf '{\n  "release": "%s",\n  "artifacts": {\n%s\n  }\n}\n' \
    "$BINARY_RELEASE" "$entries" > "$BIN_DIR/.bin-manifest.json"
  chmod 600 "$BIN_DIR/.bin-manifest.json"
  info "wrote $BIN_DIR/.bin-manifest.json (release $BINARY_RELEASE)"

  info ""
  info "Installed $installed PIE binaries to $BIN_DIR"
  info "Verify on device:"
  info "  caveman setup          # should now report the binaries present"
  info "  caveman compress <<< 'hello world'"
  info ""
  info "If caveman still can't find one, export the override for it, e.g.:"
  info "  export CAVEMAN_ENGINE_BIN=$BIN_DIR/caveman-engine"
}

main "$1"
