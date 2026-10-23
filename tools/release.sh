#!/usr/bin/env bash
# Produit une version de production : APK Android signé + exécutable Windows + version web.
#
#   tools/release.sh patch            # 0.1.0 -> 0.1.1
#   tools/release.sh minor            # 0.1.0 -> 0.2.0
#   tools/release.sh major            # 0.1.0 -> 1.0.0
#   tools/release.sh 1.4.2            # version explicite
#   tools/release.sh patch --dry-run  # calcule et affiche, ne construit rien
#   tools/release.sh patch --skip-tests
#
# La procédure complète est décrite dans release_prod.md.
set -euo pipefail

GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

DRY_RUN=0
SKIP_TESTS=0
BUMP=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-tests) SKIP_TESTS=1 ;;
        *) BUMP="$arg" ;;
    esac
done
[ -z "$BUMP" ] && { echo "usage: release.sh <major|minor|patch|X.Y.Z> [--dry-run] [--skip-tests]" >&2; exit 2; }

# ---------------------------------------------------------------- version

CURRENT="$(grep -oP '(?<=^config/version=")[^"]+' "$PROJECT/project.godot")"
IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *)
        [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version invalide : $BUMP" >&2; exit 2; }
        IFS=. read -r MAJOR MINOR PATCH <<<"$BUMP"
        ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"

# Android refuse d'installer par-dessus une version dont le code est inférieur ou
# égal. Le dériver de la version garantit qu'il croît strictement, sans compteur
# séparé à tenir. Plafond assumé : minor et patch doivent rester sous 100.
if [ "$MINOR" -ge 100 ] || [ "$PATCH" -ge 100 ]; then
    echo "✗ minor et patch doivent rester sous 100 (version/code dériverait mal)." >&2
    exit 1
fi
VERSION_CODE=$((MAJOR * 10000 + MINOR * 100 + PATCH))

echo "Version : $CURRENT → $VERSION   (version/code $VERSION_CODE)"
[ "$DRY_RUN" -eq 1 ] && exit 0

# ---------------------------------------------------------------- garde-fous

if [ "$SKIP_TESTS" -eq 0 ]; then
    echo
    echo "→ Suites de tests"
    "$PROJECT/tools/run_tests.sh" || { echo "✗ Publication interrompue : des tests échouent." >&2; exit 1; }
fi

for var in GODOT_ANDROID_KEYSTORE_RELEASE_PATH GODOT_ANDROID_KEYSTORE_RELEASE_USER \
           GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "✗ $var non définie — voir release_prod.md, section « Keystore de release »." >&2
        exit 1
    fi
done
[ -f "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ] || {
    echo "✗ Keystore introuvable : $GODOT_ANDROID_KEYSTORE_RELEASE_PATH" >&2; exit 1; }

# ---------------------------------------------------------------- propagation

# project.godot est la source unique de vérité ; les presets ne font que la refléter.
sed -i "s/^config\/version=\".*\"/config\/version=\"$VERSION\"/" "$PROJECT/project.godot"
sed -i "s/^version\/code=.*/version\/code=$VERSION_CODE/" "$PROJECT/export_presets.cfg"
sed -i "s/^version\/name=\".*\"/version\/name=\"$VERSION\"/" "$PROJECT/export_presets.cfg"
# Windows attend quatre composantes.
sed -i "s/^application\/file_version=\".*\"/application\/file_version=\"$VERSION.0\"/" "$PROJECT/export_presets.cfg"
sed -i "s/^application\/product_version=\".*\"/application\/product_version=\"$VERSION.0\"/" "$PROJECT/export_presets.cfg"

OUT="$PROJECT/build/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT/windows"

# ---------------------------------------------------------------- Android

echo
echo "→ APK Android (release, signé)"
APK="$OUT/AMealPlanner-$VERSION.apk"
"$GODOT" --headless --path "$PROJECT" --export-release "Android" "$APK" 2>&1 \
    | grep -viE "^\[|ADDING|^\s*$|DONE|Could not find version of build tools" || true
[ -f "$APK" ] || { echo "✗ APK non produit." >&2; exit 1; }

CONTENTS="$(unzip -l "$APK")"
grep -q "libgdsqlite.*arm64.so" <<<"$CONTENTS" || {
    echo "✗ libgdsqlite arm64 absente de l'APK." >&2; exit 1; }
grep -q "recettes_export_personnel" <<<"$CONTENTS" && {
    echo "✗ Données personnelles présentes dans l'APK." >&2; exit 1; }

# Signature de RELEASE et non de debug : un APK signé avec la clé de debug ne peut pas
# être publié, et surtout ne pourra jamais être mis à jour par la vraie clé.
SIGNER="$($HOME/Android/Sdk/build-tools/35.0.0/apksigner verify --print-certs "$APK" 2>/dev/null \
    | grep -m1 "certificate DN" || true)"
grep -q "CN=Android Debug" <<<"$SIGNER" && {
    echo "✗ APK signé avec la clé de DEBUG : $SIGNER" >&2; exit 1; }
echo "✓ $APK"
echo "  signé par : ${SIGNER#*: }"

# ---------------------------------------------------------------- Windows

echo
echo "→ Exécutable Windows (release)"
"$GODOT" --headless --path "$PROJECT" --export-release "Windows" "$OUT/windows/AMealPlanner.exe" 2>&1 \
    | grep -viE "^\[|ADDING|^\s*$|DONE|Could not find version of build tools" || true
[ -f "$OUT/windows/AMealPlanner.exe" ] || { echo "✗ Exécutable non produit." >&2; exit 1; }

# La DLL du GDExtension SQLite doit voyager à côté de l'exécutable : sans elle,
# l'application démarre puis échoue à ouvrir sa base.
ls "$OUT/windows/"*.dll >/dev/null 2>&1 || {
    echo "✗ libgdsqlite.dll absente du dossier Windows." >&2; exit 1; }
echo "✓ $OUT/windows/"

(cd "$OUT" && zip -qr "AMealPlanner-$VERSION-windows.zip" windows)
echo "✓ $OUT/AMealPlanner-$VERSION-windows.zip"

# ---------------------------------------------------------------- installeur
#
# Le zip reste livré à côté : il sert à qui préfère une version portable, ou n'a
# pas le droit d'installer quoi que ce soit. L'installeur, lui, remplace la version
# en place au lieu d'obliger à supprimer puis redécompresser, et garantit que la DLL
# ne se sépare jamais de l'exécutable.
#
# Absence de makensis = avertissement, pas échec : l'APK et le zip sont déjà produits
# et valides, et refuser toute la publication pour l'outil manquant serait absurde.
echo
echo "→ Installeur Windows"
if command -v makensis >/dev/null 2>&1; then
    SETUP="$OUT/AMealPlanner-$VERSION-setup.exe"
    makensis -V2 \
        "-DVERSION=$VERSION" \
        "-DSRC=$OUT/windows" \
        "-DTOOLS=$PROJECT/tools" \
        "-DOUT=$SETUP" \
        "$PROJECT/tools/installer.nsi" 2>&1 | sed 's/^/  /'
    [ -f "$SETUP" ] || { echo "✗ Installeur non produit." >&2; exit 1; }
    echo "✓ $SETUP"
else
    echo "  ⚠ makensis introuvable — installeur non produit (apt install nsis)."
fi

# ---------------------------------------------------------------- Web
#
# Version d'appoint pour un ordinateur d'emprunt : connexion obligatoire, rien de stocké
# sur le poste (cf. `LocalDatabase.ephemeral()`). Un dossier de fichiers statiques, à
# déposer chez n'importe quel hébergeur ; le zip est la forme à transporter.
echo
echo "→ Version web (release)"
mkdir -p "$OUT/web"
"$GODOT" --headless --path "$PROJECT" --export-release "Web" "$OUT/web/index.html" 2>&1 \
    | grep -viE "^\[|ADDING|^\s*$|DONE|Could not find version of build tools|tcp:5037" || true
[ -f "$OUT/web/index.html" ] || { echo "✗ Version web non produite." >&2; exit 1; }

# Le binaire SQLite sans fils d'exécution : sans lui la page charge le moteur, puis refuse
# de lier le GDExtension et reste blanche.
ls "$OUT/web/"libgdsqlite.web.*nothreads.wasm >/dev/null 2>&1 || {
    echo "✗ libgdsqlite web (sans fils) absente." >&2; exit 1; }
grep -aq "recettes_export_personnel" "$OUT/web/index.pck" && {
    echo "✗ Données personnelles présentes dans la version web." >&2; exit 1; }
# Les exports précédents vivent dans build/, DANS le projet : sans build/.gdignore, Godot
# importe leurs images et les embarque dans le paquet suivant.
grep -aq "res://build/" "$OUT/web/index.pck" && {
    echo "✗ Le paquet web embarque des fichiers de build/ (build/.gdignore manquant ?)." >&2; exit 1; }
echo "✓ $OUT/web/"

(cd "$OUT" && zip -qr "AMealPlanner-$VERSION-web.zip" web)
echo "✓ $OUT/AMealPlanner-$VERSION-web.zip"

# ---------------------------------------------------------------- récapitulatif

echo
echo "Version $VERSION prête dans $OUT :"
ls -la "$OUT" | awk 'NR>3 && $9 != "windows" && $9 != "web" {printf "  %-42s %6.1f Mo\n", $9, $5/1048576}'
echo
echo "Étape suivante : marquer la version dans git"
echo "  git commit -am \"Version $VERSION\" && git tag v$VERSION"
echo "puis publier : tools/deploy_web.sh (version web) et tools/publish_github.sh (code + release)"
