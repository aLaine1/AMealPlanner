#!/usr/bin/env bash
# Revérifie l'encodeur QR contre la bibliothèque de référence `qrcode` (Python).
#
#   python3.11 -m pip install --user qrcode
#   tools/verify_qr.sh
#
# À relancer après toute modification de services/QrCode.gd ou QrTables.gd, puis
# régénérer les témoins de tools/QrGolden.gd si la sortie a légitimement changé.
set -euo pipefail
GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$(mktemp)"
trap 'rm -f "$DUMP"' EXIT
QR_OUT="$DUMP" "$GODOT" --headless --path "$PROJECT" --script res://tools/dump_qr.gd >/dev/null 2>&1
python3.11 "$PROJECT/tools/compare_qr.py" "$DUMP"
