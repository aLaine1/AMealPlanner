#!/usr/bin/env bash
# Lance le prototype comparant trois dispositions pour l'écran de réglages.
#
#   tools/prototype_settings.sh
#
# Travaille sur une COPIE de la base : on peut renommer un rayon, cocher un soir,
# supprimer un ingrédient — rien n'atteint les vraies données ni Supabase.
#
# L'autoload du prototype est ajouté puis retiré à la volée ; il ne doit jamais
# rester dans project.godot.
set -euo pipefail

GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
REAL="$HOME/.local/share/godot/app_userdata/AMeal Planner/mealplanner.db"
AUTOLOAD='SettingsPrototype="*res://tools/SettingsPrototype.gd"'

WORKDIR="$(mktemp -d -t amealplanner-proto-XXXXXX)"
cleanup() {
    grep -v "^SettingsPrototype=" "$PROJECT/project.godot" > "$PROJECT/project.godot.tmp"
    mv "$PROJECT/project.godot.tmp" "$PROJECT/project.godot"
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ -f "$REAL" ]; then
    cp "$REAL" "$WORKDIR/proto.db"
    echo "Copie de ta base : $WORKDIR/proto.db"
else
    echo "Base réelle introuvable — le prototype partira du jeu d'exemple."
fi
export MEALPLANNER_DB="$WORKDIR/proto.db"

# Aucune session : le prototype ne doit pas se synchroniser ni toucher au compte.
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH=""

awk -v line="$AUTOLOAD" '
    /^\[display\]/ && !done { print line; print ""; done = 1 }
    { print }
' "$PROJECT/project.godot" > "$PROJECT/project.godot.tmp"
mv "$PROJECT/project.godot.tmp" "$PROJECT/project.godot"

echo "Fenêtre en cours d'ouverture — ferme-la pour terminer."
"$GODOT" --path "$PROJECT" --resolution 1200x800 2>&1 \
    | grep -viE "^\[|ObjectDB|resources still|^Opened|^Closed|Godot Engine" || true
