#!/bin/sh
# Installs the pendenz command on an agent's machine (macOS on Apple silicon, Linux on x86_64 or
# arm64) from the latest GitHub release, checks it against the release's SHA256SUMS, and puts
# it in ~/.local/bin, or in PENDENZ_INSTALL_DIR. Set PENDENZ_VERSION=0.5.0 for a given release.
#
#   curl -fsSL https://github.com/unveroleone/pendenz/releases/latest/download/install.sh | sh
set -eu

repo="unveroleone/pendenz"
dir="${PENDENZ_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset="pendenz-macos-arm64.tar.gz" ;;
  Linux-x86_64) asset="pendenz-linux-x86_64.tar.gz" ;;
  Linux-aarch64 | Linux-arm64) asset="pendenz-linux-arm64.tar.gz" ;;
  *) echo "There is no pendenz build for $(uname -s) $(uname -m). Build it with: cargo install --path server" >&2; exit 1 ;;
esac

if [ -n "${PENDENZ_DOWNLOAD_URL:-}" ]; then
  # Another place with the same files, for a mirror or a test.
  base="$PENDENZ_DOWNLOAD_URL"
elif [ -n "${PENDENZ_VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/v$PENDENZ_VERSION"
else
  base="https://github.com/$repo/releases/latest/download"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/$asset" "$base/$asset"
curl -fsSL -o "$work/SHA256SUMS" "$base/SHA256SUMS"

expected=$(grep " $asset\$" "$work/SHA256SUMS" | cut -d ' ' -f 1)
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work/$asset" | cut -d ' ' -f 1)
else
  actual=$(shasum -a 256 "$work/$asset" | cut -d ' ' -f 1)
fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "The download does not match SHA256SUMS. Nothing was installed." >&2
  exit 1
fi

tar -xzf "$work/$asset" -C "$work"
mkdir -p "$dir"
install -m 755 "$work/pendenz" "$dir/pendenz"
echo "Installed $("$dir/pendenz" --version 2>/dev/null || echo pendenz) in $dir."
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH, or run it as $dir/pendenz." ;;
esac
