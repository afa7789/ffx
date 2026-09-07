#!/bin/sh
# Install the ffx binary from a GitHub release.
set -eu

repo="${FFX_REPOSITORY:-afa7789/ffx}"
version="${FFX_VERSION:-latest}"
install_dir="${FFX_INSTALL_DIR:-}"

usage() {
    cat <<USAGE
Usage: setup.sh [--help]

Install ffx from https://github.com/${repo}/releases.

Environment:
  FFX_REPOSITORY  GitHub repository (default: afa7789/ffx)
  FFX_VERSION     Release tag, without v (default: latest)
  FFX_INSTALL_DIR Destination directory (default: ~/.ffx/bin)
USAGE
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "setup.sh: unknown argument: $1" >&2
    usage >&2
    exit 2
fi

case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) platform="linux-x86_64" ;;
    Linux:aarch64|Linux:arm64) platform="linux-aarch64" ;;
    Darwin:x86_64|Darwin:amd64) platform="macos-x86_64" ;;
    Darwin:arm64|Darwin:aarch64) platform="macos-arm64" ;;
    *)
        echo "setup.sh: unsupported platform $(uname -s)/$(uname -m)" >&2
        exit 1
        ;;
esac

if [ -z "$install_dir" ]; then
    if command -v ffx >/dev/null 2>&1; then
        current_bin=$(command -v ffx)
        case "$current_bin" in
            /*) install_dir=${current_bin%/*} ;;
        esac
    fi
    install_dir=${install_dir:-"$HOME/.ffx/bin"}
fi

if [ "$version" = "latest" ]; then
    release_url="https://github.com/${repo}/releases/latest/download/ffx-${platform}.tar.gz"
    checksum_url="${release_url}.sha256"
else
    release_url="https://github.com/${repo}/releases/download/v${version}/ffx-${platform}.tar.gz"
    checksum_url="${release_url}.sha256"
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ffx-install.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
archive="$tmp_dir/ffx.tar.gz"
checksum="$tmp_dir/ffx.tar.gz.sha256"

curl -fsSL --proto '=https' --tlsv1.2 "$release_url" -o "$archive"
curl -fsSL --proto '=https' --tlsv1.2 "$checksum_url" -o "$checksum"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp_dir" && sha256sum -c "$(basename "$checksum")")
elif command -v shasum >/dev/null 2>&1; then
    expected=$(awk 'NR == 1 { print $1 }' "$checksum")
    actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
    [ "$expected" = "$actual" ] || { echo "setup.sh: checksum verification failed" >&2; exit 1; }
else
    echo "setup.sh: sha256sum or shasum is required" >&2
    exit 1
fi

mkdir -p "$install_dir"
tar -xzf "$archive" -C "$tmp_dir"
[ -f "$tmp_dir/ffx" ] || { echo "setup.sh: release archive has no ffx binary" >&2; exit 1; }
install -m 755 "$tmp_dir/ffx" "$install_dir/ffx"

echo "Installed ffx ${version} (${platform}) at ${install_dir}/ffx"
case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *) echo "Add ${install_dir} to PATH if ffx is not found." ;;
esac
