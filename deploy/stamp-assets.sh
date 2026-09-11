#!/usr/bin/env bash
# stamp-assets.sh — rewrite the ?v= cache-busters on the CSS and JS links in
# index.html from the current content hashes. Run by deploy.sh before the build.
#
# Why: /css/ and /js/ are served with a one-year immutable Cache-Control, so a
# changed stylesheet is invisible to returning visitors unless its URL changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC="${ROOT_DIR}/cmd/server/static"

hash8() {
  if command -v md5 >/dev/null 2>&1; then md5 -q "$1" | cut -c1-8
  else md5sum "$1" | cut -c1-8; fi
}

css_v="$(hash8 "${STATIC}/css/style.css")"
js_v="$(hash8 "${STATIC}/js/main.js")"

tmp="$(mktemp)"
sed -E \
  -e "s#(/css/style\.css)(\?v=[0-9a-f]+)?#\1?v=${css_v}#g" \
  -e "s#(/js/main\.js)(\?v=[0-9a-f]+)?#\1?v=${js_v}#g" \
  "${STATIC}/index.html" > "$tmp"
mv "$tmp" "${STATIC}/index.html"

echo "assets stamped: style.css?v=${css_v}  main.js?v=${js_v}"
