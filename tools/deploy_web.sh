#!/usr/bin/env bash
# Met en ligne la version web d'une version déjà produite par tools/release.sh, sur
# GitHub Pages (branche gh-pages du dépôt public AMealPlanner).
#
#   tools/deploy_web.sh           # version courante de project.godot
#   tools/deploy_web.sh 2.2.0     # version explicite
#
# Adresse : https://alaine1.github.io/AMealPlanner/
#
# La branche gh-pages ne porte QUE la version web compilée, jamais le code source : le
# dépôt est public, et tools/ contient l'export des données personnelles. Elle est
# remplacée d'un bloc à chaque envoi (commit orphelin, push forcé) : l'historique des
# compilations ne sert à rien, et le garder ajouterait ~50 Mo au dépôt à chaque version.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="https://github.com/aLaine1/AMealPlanner.git"
URL="https://alaine1.github.io/AMealPlanner/"
GH="${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}"

VERSION="${1:-$(grep -oP '(?<=^config/version=")[^"]+' "$PROJECT/project.godot")}"
SRC="$PROJECT/build/release/$VERSION/web"
[ -f "$SRC/index.html" ] || {
    echo "✗ $SRC introuvable — lancer d'abord tools/release.sh $VERSION" >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || {
    echo "✗ gh n'est pas connecté : $GH auth login --web --git-protocol https" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$SRC/." "$WORK/"
# Sans lui, Pages fait passer le site par Jekyll, inutile ici.
touch "$WORK/.nojekyll"

cd "$WORK"
git init -q
git checkout -q -b gh-pages
git add -A
git -c user.name="$(git -C "$PROJECT" config user.name)" \
    -c user.email="$(git -C "$PROJECT" config user.email)" \
    commit -q -m "Version web $VERSION"
# Identifiants fournis par gh pour cette seule commande : rien n'est écrit dans ~/.gitconfig.
git -c credential.helper= -c "credential.helper=!$GH auth git-credential" \
    push -q --force "$REPO" gh-pages

echo "✓ Version web $VERSION envoyée — en ligne d'ici une à deux minutes :"
echo "  $URL"
