#!/usr/bin/env bash
# Exécute toutes les suites headless sur une base JETABLE.
#
#   tools/run_tests.sh            # base temporaire, supprimée à la fin
#   tools/run_tests.sh --keep     # conserve la base pour inspection
#
# La variable MEALPLANNER_DB détourne LocalDatabase vers cette base. Sans elle, les
# tests écriraient dans la base réelle de l'utilisateur — ils y ont déjà laissé des
# doublons de catégories et fait perdre une liste de courses.
#
# MEALPLANNER_SESSION fait de même pour Session (user://session.json) : ce fichier n'est
# pas dans la base et lui échapperait sinon. Une connexion faite à la main pour essayer
# l'appli en laisse un jeton qui fait passer test_onboarding pour un compte déjà vu — un
# faux échec qui a fait perdre du temps à le prendre pour un vrai.
#
# Effet de bord bienvenu : partant d'une base vide, les tests sont semés avec le jeu
# d'exemple embarqué et deviennent donc déterministes, au lieu de dépendre d'un
# contenu qui change à chaque synchronisation.
set -uo pipefail

GODOT="${GODOT:-/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

SUITES=(
    test_sqlite test_generation test_crud test_regen test_breakfast
    test_autocomplete test_sync_schema test_state_diff test_sync_merge test_migration
    test_windows test_shopping_collapse test_reactivity test_aisles test_transport test_qr test_share
    test_palette test_photos test_touch_drag test_go_back test_keyboard test_tabs test_recipe_card test_plan_shape test_plan_weeks test_servings test_onboarding test_picker test_day_grouping
    test_motion test_account_chip test_recipe_keyboard test_web
)

WORKDIR="$(mktemp -d -t amealplanner-tests-XXXXXX)"
cleanup() { [ "$KEEP" -eq 1 ] && echo "bases conservées : $WORKDIR" || rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Bases de test : $WORKDIR"
echo

FAILED=0
for suite in "${SUITES[@]}"; do
    printf "  %-26s " "$suite"
    # Une base PAR suite : partager une seule base les rendait dépendantes de leur
    # ordre d'exécution — les tests de génération activant un réglage que la suite
    # suivante attendait à sa valeur par défaut.
    export MEALPLANNER_DB="$WORKDIR/$suite.db"
    export MEALPLANNER_SESSION="$WORKDIR/$suite.session.json"
    # Comportement de la version web (base et session en mémoire) : sa suite, et elle seule.
    if [ "$suite" = test_web ]; then export MEALPLANNER_EPHEMERAL=1; else unset MEALPLANNER_EPHEMERAL; fi
    OUTPUT="$(timeout 120 "$GODOT" --headless --path "$PROJECT" \
        --script "res://tools/$suite.gd" 2>&1)"
    STATUS=$?
    COUNT="$(grep -c "ÉCHEC" <<<"$OUTPUT")"
    # Une suite qui ne compile pas ne produit AUCUNE ligne « ÉCHEC » : à ne chercher
    # que ce mot, elle passait pour verte. On surveille donc aussi les erreurs de
    # compilation et le code de sortie.
    BROKEN="$(grep -cE "Parse Error|Compile Error|Failed to load script" <<<"$OUTPUT")"

    if [ "$BROKEN" -gt 0 ]; then
        echo "NE COMPILE PAS"
        grep -E "Parse Error|Compile Error|Failed to load script" <<<"$OUTPUT" | head -3 | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    elif [ "$STATUS" -ne 0 ]; then
        echo "SORTIE EN ERREUR (code $STATUS)"
        FAILED=$((FAILED + 1))
    elif [ "$COUNT" -eq 0 ]; then
        echo "OK"
    else
        echo "$COUNT ÉCHEC(S)"
        grep "ÉCHEC" <<<"$OUTPUT" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "✓ ${#SUITES[@]} suites, toutes vertes."
else
    echo "✗ $FAILED suite(s) en échec." >&2
fi
exit "$FAILED"
