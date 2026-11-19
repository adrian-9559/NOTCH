#!/bin/sh
# Replica del install.sh de Lumio: descarga el zip del release y lo pone en /Applications.
set -eu
REPO="${REPO:-tu-usuario/NOTCH}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Descargando NOTCH…"
curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/${REPO}/releases/latest/download/NOTCH.zip" -o "$tmp/NOTCH.zip"
ditto -x -k "$tmp/NOTCH.zip" "$tmp"
open "$tmp/NOTCH.app" 2>/dev/null || true
echo "NOTCH extraído en $tmp/NOTCH.app — muévelo a /Applications."
