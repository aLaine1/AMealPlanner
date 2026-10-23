#!/usr/bin/env bash
# Publie une version sur le dépôt public GitHub aLaine1/AMealPlanner : le code (branche
# main) puis la release et ses fichiers.
#
#   tools/publish_github.sh             # version courante, à la suite de main
#   tools/publish_github.sh --replace   # remplace main d'un bloc (commit orphelin, push forcé)
#   tools/publish_github.sh --dry-run   # construit et contrôle l'instantané, ne publie rien
#
# À lancer APRÈS tools/release.sh et le commit « Version X.Y.Z » : publie ce commit, jamais
# l'arbre de travail, et attend les fichiers dans build/release/X.Y.Z/.
#
# Le dépôt public ne reçoit qu'un INSTANTANÉ par version, jamais l'historique local : celui-ci
# contient une clé privée de compte de service Google et la base personnelle du foyer, du
# temps de la version Python (fichiers retirés depuis, mais toujours dans l'historique).
# Un commit public = une version publiée.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_SLUG="aLaine1/AMealPlanner"
REPO="https://github.com/$REPO_SLUG.git"
GH="${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}"

REPLACE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --replace) REPLACE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "usage: publish_github.sh [--replace] [--dry-run]" >&2; exit 2 ;;
    esac
done

# Fichiers suivis par le dépôt local mais qui n'ont rien à faire en public.
PRIVATE=(
    "tools/recettes_export_personnel.json"   # export des données personnelles du foyer
)

# Le projet vit dans un sous-dossier du dépôt local : les chemins de git partent de la racine.
TOP="$(git -C "$PROJECT" rev-parse --show-toplevel)"
PREFIX="$(git -C "$PROJECT" rev-parse --show-prefix)"
VERSION="$(git -C "$TOP" show "HEAD:${PREFIX}project.godot" \
    | grep -oP '(?<=^config/version=")[^"]+')"
OUT="$PROJECT/build/release/$VERSION"
[ -f "$OUT/AMealPlanner-$VERSION.apk" ] || {
    echo "✗ $OUT incomplet — lancer d'abord tools/release.sh $VERSION" >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || {
    echo "✗ gh n'est pas connecté : $GH auth login --web --git-protocol https" >&2; exit 1; }
if [ -n "$(git -C "$PROJECT" status --porcelain -- .)" ]; then
    echo "⚠ Modifications non commitées : elles ne partiront PAS (seul HEAD est publié)."
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- instantané

echo "→ Instantané de la version $VERSION"
mkdir "$WORK/snap"
# Depuis la racine : lancé dans le sous-dossier, `git archive` refuse un arbre désigné par
# « HEAD:<sous-dossier> » (« current working directory is untracked »).
git -C "$TOP" archive --format=tar "HEAD:$PREFIX" | tar -x -C "$WORK/snap"
for f in "${PRIVATE[@]}"; do rm -f "$WORK/snap/$f"; done

# Garde-fous : mieux vaut refuser une publication que la rattraper — un dépôt public est
# copié et indexé dès la première minute.
LEAKS="$(cd "$WORK/snap" && {
    grep -rlIE -- "-----BEGIN [A-Z ]*PRIVATE KEY|\"type\": *\"service_account\"" . || true
    find . -name "*.db" -o -name "*.db.bak" -o -name "supabase_config.json" \
        -o -name "recettes_export_personnel*" -o -name "*.keystore" -o -name "*.jks"
})"
[ -z "$LEAKS" ] || { echo "✗ Fichiers sensibles dans l'instantané :" >&2; echo "$LEAKS" >&2; exit 1; }
echo "✓ $(find "$WORK/snap" -type f | wc -l) fichiers, aucun fichier sensible"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (--dry-run : rien n'est publié)"
    (cd "$WORK/snap" && find . -maxdepth 1 | sort | sed 's#^\./#  #' | grep -v '^\.$')
    exit 0
fi

# ---------------------------------------------------------------- code (main)

# Titre et notes : ceux du commit « Version X.Y.Z » taggé, même si HEAD l'a dépassé depuis
# (README, outillage) — c'est la version qu'on annonce.
git -C "$PROJECT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || {
    echo "✗ Tag v$VERSION absent : faire d'abord le commit de version et git tag v$VERSION" >&2; exit 1; }
NOTES="$(git -C "$PROJECT" log -1 --format=%B "v$VERSION" | grep -v "^Co-Authored-By:")"
TITLE="$(head -1 <<<"$NOTES")"
AUTHOR=(-c user.name="$(git -C "$PROJECT" config user.name)" -c user.email="$(git -C "$PROJECT" config user.email)")
CRED=(-c credential.helper= -c "credential.helper=!$GH auth git-credential")

echo
echo "→ Code : branche main"
if [ "$REPLACE" -eq 1 ]; then
    mkdir "$WORK/repo" && cd "$WORK/repo"
    git init -q
    git checkout -q -b main
else
    git "${CRED[@]}" clone -q --depth 1 --branch main "$REPO" "$WORK/repo"
    cd "$WORK/repo"
    git rm -rq --ignore-unmatch .
fi
cp -r "$WORK/snap/." .
git add -A
if git diff --cached --quiet 2>/dev/null && [ "$REPLACE" -eq 0 ]; then
    echo "  main est déjà à jour"
else
    git "${AUTHOR[@]}" commit -q -m "$TITLE" -m "$(tail -n +3 <<<"$NOTES")"
    if [ "$REPLACE" -eq 1 ]; then
        git "${CRED[@]}" push -q --force "$REPO" main
    else
        git "${CRED[@]}" push -q "$REPO" main
    fi
    echo "✓ main → $(git rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------- release

echo
echo "→ Release v$VERSION"
if "$GH" release view "v$VERSION" -R "$REPO_SLUG" >/dev/null 2>&1; then
    echo "  existe déjà — fichiers non remplacés"
else
    ASSETS=("$OUT/AMealPlanner-$VERSION.apk" "$OUT/AMealPlanner-$VERSION-setup.exe"
            "$OUT/AMealPlanner-$VERSION-windows.zip" "$OUT/AMealPlanner-$VERSION-web.zip")
    for a in "${ASSETS[@]}"; do [ -f "$a" ] || { echo "✗ Fichier manquant : $a" >&2; exit 1; }; done
    "$GH" release create "v$VERSION" "${ASSETS[@]}" -R "$REPO_SLUG" --target main --latest \
        --title "AMeal Planner $VERSION" --notes "$NOTES" >/dev/null
    echo "✓ https://github.com/$REPO_SLUG/releases/tag/v$VERSION"
fi
