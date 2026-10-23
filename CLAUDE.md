# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Le projet

**AMeal Planner** — planificateur de repas familial, en GDScript sur **Godot 4.7**. Portage
d'une version Python/CustomTkinter. Application mono-foyer (pas de multi-tenant côté produit),
avec sync optionnelle entre appareils via Supabase. Le code et les commentaires sont en français ;
garder ce standard dans tout code ou commentaire ajouté.

## Commandes

Le binaire Godot n'est pas sur le PATH standard :
```bash
GODOT=/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64
```

**Lancer l'éditeur / l'app :**
```bash
$GODOT --editor --path .
$GODOT --path .
```

**Tests headless (obligatoires avant toute release, et à lancer après un changement dans
`services/`, `autoload/` ou `models/`) :**
```bash
tools/run_tests.sh            # base SQLite jetable, supprimée à la fin
tools/run_tests.sh --keep     # conserve les bases pour inspection
```
Chaque suite tourne sur sa PROPRE base (`$WORKDIR/<suite>.db` via `MEALPLANNER_DB`) — ne jamais
partager une base entre suites, l'ordre d'exécution romprait leur indépendance. Les suites sont
listées dans `tools/run_tests.sh` (tableau `SUITES`) ; chacune est un script headless
`tools/test_*.gd`. Lancer une suite seule :
```bash
$GODOT --headless --path . --script res://tools/test_generation.gd
```
Une suite qui ne compile pas ne produit aucune ligne `ÉCHEC` — le script vérifie donc aussi
`Parse Error` / `Compile Error` / le code de sortie, pas seulement le nombre d'échecs.

**Ne jamais lancer les tests sans `MEALPLANNER_DB`** en dehors de `run_tests.sh` : sans lui,
`LocalDatabase` écrit dans la vraie base utilisateur (`user://mealplanner.db`).

**Publication (APK Android signé + exécutable Windows + version web) :**
```bash
source ~/.amealplanner-release.env   # keystore, hors dépôt
tools/release.sh patch|minor|major|X.Y.Z [--dry-run] [--skip-tests]
```
`project.godot` (`config/version`) est la **source unique de vérité** pour la version ; le script
la propage vers `export_presets.cfg` et dérive le `version/code` Android
(`major*10000 + minor*100 + patch`, donc minor/patch doivent rester < 100). Ne jamais éditer
`export_presets.cfg` à la main. Procédure complète et garde-fous : `release_prod.md`.
Puis `tools/deploy_web.sh` (GitHub Pages) et `tools/publish_github.sh` (code + release sur le
dépôt public). **Ne jamais pousser l'historique local vers GitHub** : il contient une clé privée
Google et des données personnelles — le dépôt public ne reçoit qu'un instantané par version.

## Architecture

**Autoloads (globaux, déclarés dans `project.godot`)** — ordre d'init : `Layout`, `DataStore`,
`Palette`, `AppState`, `Session`, puis `Sync` (= `services/SyncEngine.gd`). `DataStore` passe
avant `Palette` pour que celle-ci lise le thème de couleur choisi dès son `_ready`.

- **`DataStore`** (`autoload/DataStore.gd`) — façade unique d'accès aux données, portage de
  `RecipeDatabase` (Python). Maintient un **cache mémoire** de `Recipe`/`Ingredient`/etc.,
  reconstruit après chaque écriture. L'UI et les services ne parlent jamais directement à
  SQLite — tout passe par `DataStore`. Deux signaux à bien distinguer :
  - `data_changed` : toute écriture, locale ou reçue du serveur.
  - `local_change` : **uniquement** une écriture faite sur cet appareil — c'est ce signal que
    `SyncEngine` écoute pour pousser sans délai, sans boucler sur les données reçues.
  - `plan_shape_changed` : la *forme* du planning change (nb de semaines, jour de début, repas/jour)
    — oblige le calendrier à se reconstruire, pas seulement à se rafraîchir.
- **`AppState`** (`autoload/AppState.gd`) — état applicatif partagé entre onglets (planning
  courant, saison). Remplace le passage de référence `meal_planner_app` de la version Python.
- **`Session`** (`autoload/Session.gd`) — session Supabase (auth email/mot de passe, persistée).
- **`Palette`** (`autoload/Palette.gd`) — thème global unique (`make_theme()`), typographie
  responsive (`apply_form_typography()`), couleurs, variantes de boutons. Plusieurs thèmes de
  couleur (`SCHEMES` : vert, orange, bleu, sombre), choisis dans Paramètres > Apparence et
  mémorisés par appareil ; les couleurs sont donc des **variables**, pas des constantes, et un
  changement recharge toute la scène (`scheme_changed` → `MainWindow`). `PRIMARY` est un
  remplissage sous encre blanche ; pour du texte ou un contour sur une surface, utiliser
  `PRIMARY_INK` (illisible sinon en thème sombre).
- **`Layout`** — constantes de mise en page responsive (ex. `SIDE_PANEL_MIN`).

**Services** (`services/`, non-autoload sauf `SyncEngine`) :
- **`LocalDatabase.gd`** — couche SQLite brute via l'addon `godot-sqlite`. Base dans
  `user://mealplanner.db`, seedée au premier lancement depuis `data/mealplanner_seed.json`.
  Colonnes de sync (`updated_at`, `deleted_at`) présentes dès l'origine ; suppressions =
  **soft-deletes** (tombstones). `LocalDatabase.SCHEMA_VERSION` migre la base au démarrage.
  Peut être redirigée par la variable d'env `MEALPLANNER_DB` (tests, vérif de migration).
- **`SyncEngine.gd`** — sync Local ↔ Supabase en **Last-Write-Wins par ligne**. SQLite local =
  source de vérité, Supabase = point de rendez-vous entre appareils, jamais bloquant. Un cycle =
  pull puis push (jamais l'inverse : on part toujours de la vue la plus fraîche). Ordre des
  tables important (`SYNC_TABLES`) : `categories`/`aisles`/`ingredients` avant `recipes`/
  `breakfasts` avant `recipe_photos` — une lecture par jointure écarterait silencieusement les
  liens vers des lignes pas encore arrivées. À `updated_at` égal, **le serveur gagne** (règle
  déterministe pour que tous les appareils convergent).
- **`MealPlanningService.gd`** — génération du planning (anti-doublon, anti-répétition de
  catégorie, positions NoBox, filtre de saison).
- **`ShoppingListService.gd`** — agrégation de la liste de courses par rayon.
- **`SupabaseClient.gd`** — client REST Supabase minimal (auth, requêtes).
- **`RecipePhoto.gd`**, **`RecipeShare.gd`**, **`QrCode.gd`** / **`QrTables.gd`** — photos de
  recettes, partage de recette encodé en QR (voir `tools/dump_qr.gd`, `tools/compare_qr.py`,
  `tools/verify_qr.sh` pour la vérification du format QR).

**Models** (`models/`, `Resource` Godot) : `Recipe`, `Ingredient`, `MealPlan`, `Breakfast`,
`RecipeFilter`.

**UI** (`ui/`) — un onglet par sous-dossier (`planning`, `breakfast`, `shopping`, `recipes`,
`ingredients`, `settings`, `onboarding`), plus `ui/components/` pour les widgets partagés
(`AutocompleteEdit`, `CategoryFilter`, `PickerPopup`, `PanelSheet`, `TouchItemList`, `TouchTap`
pour le geste tactile, `DragAutoScroll`, `KeyboardInset` pour garder le champ actif visible
au-dessus du clavier virtuel). Le calendrier (`PlanningTab`) embarque son propre éditeur de
recettes (liste, recherche, CRUD, glisser-déposer) plutôt que de dépendre de l'onglet Recettes.

## Points d'architecture à connaître avant de modifier

- **`godot-sqlite` est épinglé en v4.4**, pas la dernière v4.9 : le binaire Linux v4.9 exige
  glibc 2.33, la machine de dev est en glibc 2.31. Ne jamais mettre à jour l'addon sans vérifier
  la glibc de la cible. Les binaires iOS (240 Mo) sont volontairement exclus du dépôt.
  **Exception : les binaires web viennent de la v4.9** (ceux de la v4.4 ne se lient pas avec
  l'Emscripten de Godot 4.7 ; la glibc ne concerne pas le navigateur) — cf. `gdsqlite.gdextension`.
- **Version web (preset « Web ») : PC uniquement, rien de stocké sur le poste.**
  `LocalDatabase.ephemeral()` (vrai dans un navigateur, ou avec `MEALPLANNER_EPHEMERAL=1`)
  met la base en mémoire, ne persiste pas la session, impose l'écran de connexion à chaque
  ouverture et recharge la page à la déconnexion. Toute nouvelle écriture dans `user://` doit
  le respecter (`test_web.gd`). Sur le web, Godot n'a ni polices système (symboles via
  `assets/fonts/DejaVuSans-Symboles.ttf`) ni décompression gzip propre (`accept_gzip` coupé
  dans `SupabaseClient`).
- **`build/` est dans le projet** : `build/.gdignore` (versionné) empêche Godot d'importer les
  exports précédents et de les embarquer dans le suivant.
- **`Sync` (SyncEngine) écoute `DataStore.local_change`, jamais `data_changed`** — un service qui
  câblerait `data_changed` créerait une boucle de sync sur les données reçues du réseau.
- **Toute écriture passe par `DataStore`**, jamais directement par `LocalDatabase`, pour que le
  cache mémoire et les signaux restent cohérents.
- **Le jeu de données d'exemple (`data/mealplanner_seed.json`) doit rester dimensionné pour un
  planning complet** (14 recettes distinctes dont 4 NoBox hors saison opposée) — `test_generation.gd`
  et `test_regen.gd` le vérifient ; un seed trop maigre casse la génération.
- **La typographie responsive passe par le thème** (`Palette.apply_form_typography()`), pas par
  des tailles codées en dur dans chaque scène — c'est ce qui permet à un ajustement de se
  propager tout seul à ce qui n'en dévie pas explicitement.
