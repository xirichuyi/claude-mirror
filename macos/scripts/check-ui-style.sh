#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive \
  Sources/RemoteCC/DesignSystem Sources/RemoteCC/Features \
  Sources/RemoteCC/Persistence Sources/RemoteCC/Workspace
