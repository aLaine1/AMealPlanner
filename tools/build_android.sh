#!/usr/bin/env bash
# Construit l'APK Android et, si un appareil est branché, l'installe.
#
#   tools/build_android.sh            # build debug + installe si un appareil est vu
#   tools/build_android.sh release    # build release (exige un keystore de release)
#   tools/build_android.sh --no-install
#
# Prérequis, déjà en place sur cette machine :
#   - templates d'export Godot 4.7 dans ~/.local/share/godot/export_templates/4.7.stable
#     (seuls android_debug.apk et android_release.apk ont été extraits : le reste de
#     l'archive, dont android_source.zip de 214 Mo, ne sert qu'aux builds gradle)
#   - SDK Android dans ~/Android/Sdk (platform-tools + build-tools 35.0.0)
#   - keystore de debug dans ~/.local/share/godot/keystores/debug.keystore
#   - chemins renseignés dans ~/.config/godot/editor_settings-4.7.tres
set -euo pipefail

GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
ADB="$SDK/platform-tools/adb"
APK="$PROJECT/build/AMealPlanner.apk"

MODE="debug"
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        release) MODE="release" ;;
        --no-install) INSTALL=0 ;;
    esac
done

mkdir -p "$PROJECT/build"

echo "→ Export $MODE"
if [ "$MODE" = "release" ]; then
    "$GODOT" --headless --path "$PROJECT" --export-release "Android" "$APK"
else
    "$GODOT" --headless --path "$PROJECT" --export-debug "Android" "$APK"
fi

if [ ! -f "$APK" ]; then
    echo "✗ L'APK n'a pas été produit." >&2
    exit 1
fi
# LC_NUMERIC=C : en locale française, awk produit « 29,3 » que printf %f rejette.
LC_NUMERIC=C printf "✓ %s  (%.1f Mo)\n" "$APK" "$(stat -c%s "$APK" | LC_NUMERIC=C awk '{print $1/1048576}')"

# Listing capturé une seule fois. À NE PAS remplacer par « unzip -l | grep -q » :
# grep -q sort à la première correspondance, unzip prend un SIGPIPE, et sous
# `set -o pipefail` le pipeline remonte un échec — le contrôle échouerait donc
# précisément quand le fichier est présent.
CONTENTS="$(unzip -l "$APK")"

# Sans le .so arm64, godot-sqlite ne se chargerait pas sur l'appareil et l'app
# démarrerait sur une base vide sans le dire clairement.
if ! grep -q "libgdsqlite.*arm64.so" <<<"$CONTENTS"; then
    echo "✗ libgdsqlite arm64 absente de l'APK — la base de données ne fonctionnera pas." >&2
    exit 1
fi
echo "✓ godot-sqlite (arm64) embarquée"

# Et l'inverse : l'export des données personnelles ne doit jamais partir dans l'APK.
if grep -q "recettes_export_personnel" <<<"$CONTENTS"; then
    echo "✗ L'export de données personnelles est présent dans l'APK." >&2
    exit 1
fi
echo "✓ aucune donnée personnelle embarquée"

if [ "$INSTALL" -eq 0 ]; then
    exit 0
fi

if [ ! -x "$ADB" ]; then
    echo "adb introuvable ($ADB) — installation ignorée."
    exit 0
fi

DEVICES=$("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l)
if [ "$DEVICES" -eq 0 ]; then
    echo
    echo "Aucun appareil détecté. Sur le téléphone :"
    echo "  1. Paramètres > À propos > toucher 7 fois « Numéro de build »"
    echo "  2. Paramètres > Options pour les développeurs > activer « Débogage USB »"
    echo "  3. brancher en USB, puis accepter l'empreinte affichée"
    echo "Puis : $ADB devices     (doit lister l'appareil en « device »)"
    echo "Installer ensuite :  $ADB install -r \"$APK\""
    exit 0
fi

echo "→ Installation sur l'appareil"
"$ADB" install -r "$APK"
echo "✓ Installé. Journal en direct :"
echo "  $ADB logcat -s godot:V GodotSQLite:V"
