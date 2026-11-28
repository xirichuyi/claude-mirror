#!/bin/sh
# Builds static Linux (musl) tether-quic for arm64 and x64 into $1.
# Without cargo-zigbuild nothing is built and clients keep files on SSH.
set -eu
out=$1
mkdir -p "$out"
command -v cargo-zigbuild >/dev/null 2>&1 || { echo "cargo-zigbuild not found: building without QUIC" >&2; exit 0; }
root=$(cd "$(dirname "$0")/.." && pwd)
for pair in aarch64:arm64 x86_64:x64; do
  target="${pair%%:*}-unknown-linux-musl"
  rustup target add "$target" >/dev/null 2>&1 || true
  cargo zigbuild --release --locked --manifest-path "$root/quic/Cargo.toml" --target "$target"
  cp "$root/quic/target/$target/release/tether-quic" "$out/tether-quic-linux-${pair##*:}"
done
