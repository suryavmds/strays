#!/bin/bash
# Fills in the Homebrew cask template.
#   scripts/render-cask.sh <version> <sha256> <owner/repo> [bundle-id] > strays.rb
set -euo pipefail
version="${1:?version}"
sha256="${2:?sha256}"
repository="${3:?owner/repo}"
bundle_id="${4:-com.suryavmds.strays}"
sed -e "s|__VERSION__|${version}|g" \
    -e "s|__SHA256__|${sha256}|g" \
    -e "s|__REPOSITORY__|${repository}|g" \
    -e "s|__BUNDLE_ID__|${bundle_id}|g" \
    "$(dirname "$0")/../packaging/homebrew/strays.rb.template"
