#!/usr/bin/env bash
# Capture l'app à une résolution donnée, sous Xvfb, pour vérifier les mises en page
# responsive sans appareil Android.
#
#   tools/shoot.sh <nom> <largeur>x<hauteur> [titre-onglet]
#
# Exemples :
#   tools/shoot.sh courses-tel 412x915 "Liste de course"   # gabarit téléphone courant
#   tools/shoot.sh courses-pc  1280x800 "Liste de course"
#
# L'autoload Screenshotter est ajouté puis retiré à la volée : il ne doit jamais
# rester dans project.godot.
set -euo pipefail

NAME="${1:?usage: shoot.sh <nom> <LxH> [onglet]}"
RES="${2:?usage: shoot.sh <nom> <LxH> [onglet]}"
TAB="${3:-}"

GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
USERDATA="$HOME/.local/share/godot/app_userdata/AMeal Planner"
AUTOLOAD='Screenshotter="*res://tools/Screenshotter.gd"'

cleanup() {
    grep -v "^Screenshotter=" "$PROJECT/project.godot" > "$PROJECT/project.godot.tmp"
    mv "$PROJECT/project.godot.tmp" "$PROJECT/project.godot"
}
trap cleanup EXIT

# Insère l'autoload en fin de section [autoload], juste avant [display]. Sans ligne
# vide ajoutée : le nettoyage ne retire que la ligne de l'autoload, et chaque capture
# laissait donc une ligne vide de plus dans project.godot.
awk -v line="$AUTOLOAD" '
    /^\[display\]/ && !done { print line; done = 1 }
    { print }
' "$PROJECT/project.godot" > "$PROJECT/project.godot.tmp"
mv "$PROJECT/project.godot.tmp" "$PROJECT/project.godot"

SHOT_NAME="$NAME" SHOT_TAB="$TAB" \
    xvfb-run -a "$GODOT" --path "$PROJECT" --resolution "$RES" 2>&1 \
    | grep -E "^SHOT|SCRIPT ERROR|ERROR" || true

echo "→ $USERDATA/$NAME.png"
