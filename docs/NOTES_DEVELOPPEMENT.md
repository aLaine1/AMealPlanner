# AMeal Planner — Refonte Godot 4.7 (Proof of Concept)

Portage du planificateur de repas Python/CustomTkinter vers **Godot 4.7**.
Ce dossier contient le **PoC PC** : l'objectif de cette étape est de prouver que la version Godot
fonctionne sur ordinateur (sans compte ni cloud pour l'instant).

Journal de développement : décisions, pièges et état des fonctionnalités, version après version.

## Lancer le projet

```bash
# Éditeur
/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64 --editor --path .

# Exécution directe
/home/laine-a-2/packages/Godot/Godot_v4.7-stable_linux.x86_64 --path .
```

## Jeu de démarrage et données du compte

`data/mealplanner_seed.json` contient un **jeu d'exemple neutre** (28 recettes
génériques, 55 ingrédients) semé au premier lancement. Il sert uniquement à ce que
l'app soit utilisable immédiatement, avant toute connexion.

Son sort dépend de ce que contient le compte auquel l'appareil se connecte :

| Compte | Comportement |
|--------|--------------|
| **Contient déjà des données** | Le jeu d'exemple est **écarté** dès la première ligne reçue, au profit des recettes du compte. Cas de tout appareil supplémentaire d'un foyer existant. |
| **Vierge** | Le push est **suspendu** et l'utilisateur est interrogé : garder les recettes d'exemple comme point de départ (elles deviennent alors sa collection, sur tous ses appareils) ou repartir d'une base vierge. |

Une recette d'exemple **modifiée** par l'utilisateur, ou qu'il a créée lui-même avant
de se connecter, porte un autre horodatage : elle survit dans tous les cas et part sur
le compte normalement.

> La question n'est posée qu'une fois, et jamais sur un foyer déjà constitué. Elle est
> présentée par un `AcceptDialog` à deux boutons et non un `ConfirmationDialog` :
> fermer ce dernier par la croix déclenche `canceled`, soit ici la suppression des
> recettes. Ignorer la question doit être sans effet — elle est simplement reposée à
> la synchronisation suivante.

> ⚠️ Le seed doit rester **dimensionné pour un planning complet** : 14 recettes
> distinctes, dont 4 NoBox, une fois la saison opposée exclue. Un jeu trop maigre
> laisse des cases vides et empêche la regénération unitaire. `test_generation.gd` et
> `test_regen.gd` le vérifient.

L'export des données personnelles de l'ancienne `recettes.db` est conservé sous
`tools/recettes_export_personnel.json` — artefact de migration, **plus chargé par
l'app**, et à exclure de l'export Android en Phase 3. Pour le régénérer :

```bash
python3 tools/migrate_db_to_json.py
```

## Tester la logique de génération (headless, sans UI)

```bash
Godot_v4.7-stable_linux.x86_64 --headless --script res://tools/test_generation.gd
```
Vérifie : 14 cases remplies, aucun doublon, positions NoBox (1/7/8/14), exclusion de saison,
génération de la liste de courses.

## Typographie : deux points de plus sur grand écran (1.7.11)

Sur un écran de bureau, la taille pensée pour un téléphone tenu à trente centimètres
demande un effort de lecture. `Palette.apply_form_typography()` ajoute donc **deux points
hors téléphone**, en un seul endroit et par le **thème** — partagé, il se propage de
lui-même à tout ce qui ne s'en écarte pas explicitement. Les titres et les légendes, qui
portent leur propre taille, ne bougent pas : ils sont déjà dimensionnés pour leur rôle.

Rien n'est ajouté sur téléphone : le contenu y est déjà mis à l'échelle selon la densité
de l'écran, et deux points de plus feraient déborder ce qui tient de justesse — la barre
d'onglets d'abord, qui ne dispose que de 22 unités de marge à 320.

Deux exceptions, toutes deux **mesurées à la capture** avant d'être décidées :

- **Les boutons ne bougent pas.** À 16, la barre d'actions de la bibliothèque se replie sur
  une rangée de plus et prend cette hauteur à la liste des recettes, qui perd une ligne et
  se retrouve coupée. C'était déjà noté à l'époque où la taille de base est passée de 14 à
  15 ; l'avoir vérifié à l'image l'a confirmé. Le libellé d'un bouton se lit d'ailleurs par
  sa forme et sa position autant que par sa taille.
- **Les pastilles de filtre gagnent un seul point**, deux les faisant passer à la ligne sur
  une fenêtre étroite où elles sont déjà nombreuses.

Un effet de bord assumé : `SIDE_PANEL_MIN` passe de 300 à **320**. À 300, un nom comme
« Croque-monsieur végétarien » ne tenait plus dans sa carte et se coupait en plein mot.
Vingt unités prises au calendrier, qui en compte plusieurs centaines.

## Décisions de PoC (à connaître)

- **Stockage = SQLite** via l'addon **`godot-sqlite`** (couche `LocalDatabase` + `DataStore`).
  La base est créée dans `user://mealplanner.db` et **semée au 1er lancement** depuis
  `data/mealplanner_seed.json`. Le JSON ne sert plus qu'à l'amorçage.
  - Colonnes de sync `updated_at` / `deleted_at` déjà présentes ; les suppressions sont des
    **soft-deletes** (tombstones) — prêt pour la Phase 2 (LWW + Supabase, cf. plan §3.4.1).
  - `DataStore` reste une **façade** avec cache mémoire : brancher Supabase ne touchera pas l'UI.
- **Pas de compte / pas de sync** dans ce PoC (priorité = app PC qui tourne).
- **Google Sheets abandonné** : la liste de courses est **native** (cases à cocher dans l'app).

> Les binaires **iOS** de l'addon (240 Mo) sont exclus du dépôt : ils pèseraient 89 %
> de son poids pour une plateforme reportée. Ils sont présents sur le disque de dev ;
> pour un poste neuf visant iOS, récupérer l'addon complet depuis
> [ses releases](https://github.com/2shady4u/godot-sqlite/releases) (v4.4, cf. ci-dessous).

### ⚠️ Version de l'addon godot-sqlite (important)

L'addon est **épinglé à la release v4.4** (binaire Linux compilé pour **GLIBC 2.28**), et **non** la
dernière v4.9. Raison : la machine de dev est **Ubuntu 20.04 (glibc 2.31)** alors que le binaire
Linux de v4.9 exige **glibc 2.33**. La v4.4 (GDExtension `compatibility_minimum = 4.3`) se charge
sans problème dans Godot 4.7 et embarque aussi les binaires **Android** (arm64 + x86_64) pour la
Phase 2. Ne pas « mettre à jour » l'addon sans vérifier la glibc de la cible.

## État des fonctionnalités (parité avec la version Python)

| Fonction | État PoC |
|----------|----------|
| Calendrier 14 cases (2 semaines, masque actif/inactif) | ✅ |
| Positions NoBox (1/7/8/14) mises en évidence | ✅ |
| Génération aléatoire filtrée (saison, anti-doublon, anti-répétition de catégorie) | ✅ |
| Toggle saison Hiver / Mix / Été (**Mix** par défaut : n'exclut rien) | ✅ |
| Drag & drop natif (liste→case, échange case↔case) | ✅ |
| Au doigt : balayage = défilement, appui bref = menu, appui long = déplacer la case | ✅ |
| Bouton Retour d'Android : ferme la fenêtre, puis revient à l'accueil, puis quitte | ⏳ à valider sur appareil |
| Clavier virtuel : le champ saisi reste visible au-dessus de lui | ✅ |
| Menu contextuel case (ingrédients / étapes / **regénérer** / supprimer / ajouter) | ✅ |
| Regénérer une seule case (E4 — saison, anti-doublon, NoBox, **anti-répétition catégorie ±2 jours**) | ✅ |
| Recherche de recettes (tolérante aux accents) | ✅ |
| Sauvegarde / chargement du planning (local `user://`) | ✅ |
| Liste de courses agrégée par rayon + articles de base + cases à cocher | ✅ |
| Recettes : liste + recherche + détail | ✅ |
| Ingrédients : liste + recherche + détail | ✅ |
| **CRUD** recettes (popup : nom, saison, catégorie, NoBox, ingrédients dynamiques, étapes) | ✅ |
| **CRUD** ingrédients (popup : nom + rayon) | ✅ |
| **Autocomplétion** nom d'ingrédient + unité (accents tolérés, clavier + souris) | ✅ |
| **Filtre par catégorie** (recettes) / par rayon (ingrédients) : pilules sous la recherche | ✅ |
| **Photos de recettes** : bibliothèque, calendrier, popups — synchronisées entre appareils | ✅ |
| Photo prise avec l'appareil du téléphone (écran de visée maison) | ⏳ à valider sur appareil |
| Cadre d'information d'un ingrédient : rayon + recettes qui l'emploient et leurs quantités | ✅ |
| Persistance réelle (SQLite `user://`, soft-delete) | ✅ |
| Onglet Petit Déj : choix (CRUD, ingrédients) + 4 slots (drag/aléatoire/persistés) | ✅ |
| Petits déjeuners sélectionnés → alimentent la liste de courses (agrégée) | ✅ |
| **Paramètres** (⚙ en-tête) : éditeur d'ingrédients + articles de base | ✅ |
| **Articles de base éditables** (F4, table `staples`) → injectés dans la liste de courses | ✅ |
| Undo/Redo (Ctrl+Z/Y) : calendrier, petit déj, liste de courses (routeur global) | ✅ |
| Persistance en base du planning (par **ID**), des slots petit déj et de la liste de courses | ✅ |
| Schéma prêt pour la sync : UUID, horodatages ms, tombstones propageables, drapeau `dirty` | ✅ |
| Schéma Postgres + RLS Supabase (`supabase/schema.sql`) | ✅ |
| Client Supabase (auth email/mot de passe, session persistée) | ✅ |
| Moteur de sync LWW (pull/push incrémental, tombstones, curseurs) | ✅ |
| Écran Compte + indicateur de sync + sync auto (2 min) | ✅ |
| Jeu d'exemple neutre, écarté à l'arrivée des données du compte | ✅ |
| Validation de la sync entre deux appareils réels | ⏳ à faire |
| Second compte sur un appareil déjà utilisé : base remise à neuf, pas de mélange | ✅ |
| Chaîne d'export Android (APK signé, arm64) | ✅ |
| Validation sur appareil réel | ⏳ à faire |

## Structure

```
GODOT_REFACTOR/
├── project.godot            # autoloads : Palette, DataStore, AppState, Session, Sync
├── supabase_config.json     # URL + clé anon (NON versionné, cf. .example)
├── addons/godot-sqlite/     # GDExtension SQLite (v4.4, binaires multi-plateforme)
├── data/mealplanner_seed.json
├── supabase/                # schema.sql (Postgres + RLS) et marche à suivre — Phase 2
├── tools/                   # migrate_db_to_json.py + tests headless
├── autoload/                # Palette.gd, DataStore.gd (façade+cache), AppState.gd, Session.gd
├── models/                  # Ingredient, Recipe, MealPlan, RecipeFilter (Resources)
├── services/                # LocalDatabase (SQLite), MealPlanningService, ShoppingListService
└── ui/
    ├── MainWindow.tscn/.gd
    ├── planning/            # PlanningTab (calendrier + éditeur recettes intégré), MealCell, RecipeListDrag
    ├── breakfast/           # BreakfastTab (slots + éditeur intégré), BreakfastPopup
    ├── shopping/ShoppingTab.gd
    ├── recipes/            # RecipePopup (formulaire recette, ouvert depuis le Calendrier)
    ├── ingredients/        # IngredientsTab, IngredientPopup
    └── components/         # AutocompleteEdit (champ avec suggestions), CategoryFilter
                            #   (recherche + filtre par catégorie repliable)
```

## Design & responsivité

- **Thème global** unique (`Palette.make_theme()`, appliqué à la fenêtre et aux popups) : palette verte,
  coins arrondis, ombres douces sur les cartes (`PanelContainer`), champs et listes bordés, onglets
  colorés. Variantes de boutons : primaire (vert plein), `GhostButton` (secondaire discret),
  `DangerButton` (suppression, rouge).
- **Responsivité** :
  - Fenêtre à taille minimale **900×600** ; contenu des onglets dans des `MarginContainer`.
  - Le **calendrier** est une grille **extensible** (les cases remplissent l'espace et rétrécissent) :
    le panneau « Mes Recettes » (avec le bouton **Ajouter**) reste toujours visible — c'était le bug
    signalé (calendrier à largeur fixe qui poussait le panneau hors écran).
  - Les **barres d'actions** utilisent des `HFlowContainer` : les boutons se replient sur plusieurs
    lignes quand la largeur manque, au lieu de déborder.
- Un utilitaire de capture hors écran (`tools/Screenshotter.gd`, non autoloadé) permet de rendre l'app
  sous Xvfb pour vérifier le rendu sans écran.

## Navigation

- **Planner** → *Calendrier* (planning + **éditeur de recettes intégré** : liste, recherche,
  Ajouter/Modifier/Supprimer, glisser-déposer vers le calendrier) · *Petit Déj* · *Liste de course*
- **Ingrédients** (onglet de premier niveau) → éditeur d'ingrédients

> L'ancien onglet « Éditeur > Recettes » a été supprimé : l'édition des recettes vit désormais dans
> l'onglet Calendrier (même design que l'onglet Petit Déj). Seul l'éditeur d'ingrédients reste séparé.

## Tests headless

```bash
G=Godot_v4.7-stable_linux.x86_64
$G --headless --path . --script res://tools/test_sqlite.gd       # extension chargée
$G --headless --path . --script res://tools/test_generation.gd   # génération de planning
$G --headless --path . --script res://tools/test_crud.gd         # CRUD SQLite
$G --headless --path . --script res://tools/test_regen.gd        # regénération d'une case
$G --headless --path . --script res://tools/test_breakfast.gd    # petits déjeuners
$G --headless --path . --script res://tools/test_autocomplete.gd # autocomplétion
$G --headless --path . --script res://tools/test_sync_schema.gd  # invariants de sync (schéma v2)
$G --headless --path . --script res://tools/test_state_diff.gd   # écritures différentielles
$G --headless --path . --script res://tools/test_sync_merge.gd   # arbitrage LWW (sans réseau)
$G --headless --path . --script res://tools/test_windows.gd      # les 7 fenêtres secondaires
$G --headless --path . --script res://tools/test_shopping_collapse.gd
$G --headless --path . --script res://tools/test_touch_drag.gd    # gestes tactiles d'une case
$G --headless --path . --script res://tools/test_go_back.gd       # bouton Retour d'Android
$G --headless --path . --script res://tools/test_keyboard.gd      # cohabitation avec le clavier virtuel
$G --headless --path . --script res://tools/test_tabs.gd          # les 3 onglets tiennent sur tout téléphone
$G --headless --path . --script res://tools/test_recipe_card.gd    # fiche recette : lecture, édition, planning
$G --headless --path . --script res://tools/test_plan_shape.gd     # FILET 1.8 : forme du planning en 1.7
$G --headless --path . --script res://tools/test_plan_weeks.gd     # 1 à 4 semaines, jour de début, second repas
$G --headless --path . --script res://tools/test_servings.gd       # parts par recette et mise à l'échelle
$G --headless --path . --script res://tools/test_onboarding.gd     # première mise en route : connexion + questionnaire
$G --headless --path . --script res://tools/test_supabase.gd     # connectivité + RLS (réseau requis)
```

`test_sync_schema` et `test_state_diff` couvrent des invariants **invisibles en local** :
ils ne se manifestent qu'entre deux appareils, donc trop tard pour être découverts à la
main. `test_windows` instancie les sept fenêtres secondaires et vérifie qu'elles
construisent bien leur contenu et offrent une sortie — un `_notification` mal placé y avait
envoyé toute la construction de l'interface, ce que le lancement à blanc de l'application
ne pouvait pas voir puisqu'il n'ouvre aucune popup.

## Phase 2 — compte & synchronisation Supabase

### Ce qui est fait

Le socle local est en place (`schéma v2`) :

- **Clés primaires en UUID** au lieu d'entiers auto-incrémentés. Deux appareils éditant
  hors-ligne attribueraient sinon le même id à deux recettes différentes, et la première
  sync les ferait entrer en collision. Migration en place, les tables d'origine sont
  conservées sous le suffixe `_v1`.
- **`updated_at` en millisecondes** (même représentation que Postgres) et **`deleted_at`**
  écrit *en même temps qu'`updated_at`* : le pull incrémental filtrant sur `updated_at`,
  un tombstone qui ne le bouge pas ne se propagerait jamais.
- **`dirty`** : marque ce qui a été écrit localement et reste à pousser.
- **Planning, slots petit déj et liste de courses en base**, une ligne par position / slot /
  article, et le planning référencé **par ID de recette** (il survit désormais au renommage).
  Les anciens JSON de `user://` sont repris automatiquement au premier lancement, une seule
  fois, et laissés en place comme filet de sécurité.
- Toutes les écritures d'état sont **différentielles** : sauvegarder ne rafraîchit que les
  lignes réellement modifiées. Sans cela, cocher un article ferait repartir les 60 articles
  avec un horodatage neuf et l'appareil qui sauvegarde en dernier gagnerait sur la liste
  entière — le LWW par ligne ne protégerait plus rien.

Côté serveur, [`supabase/schema.sql`](supabase/schema.sql) et sa
[marche à suivre](supabase/README.md) sont prêts à être exécutés.

Le projet Supabase est créé et le schéma déployé. Vérifié contre le serveur : RLS refuse
les écritures anonymes, les inscriptions sont fermées, `server_now_ms()` répond.

**Client & sync** (`services/SupabaseClient.gd`, `autoload/Session.gd`,
`services/SyncEngine.gd`) :

- Auth email/mot de passe, session restaurée au lancement via le refresh token. Supabase
  fait **tourner** ce jeton à chaque renouvellement : le nouveau est repersisté, sinon la
  session suivante serait invalide. En cas de coupure réseau le jeton est **conservé** —
  l'effacer forcerait une resaisie du mot de passe à chaque perte de connexion.
- Cycle **pull puis push**, table par table, avec un curseur `updated_at` par table.
  `categories` et `ingredients` passent avant `recipes` : une recette dont les ingrédients
  ne sont pas encore arrivés perdrait ces ingrédients, la lecture passant par une jointure.
- À `updated_at` égal, **le serveur tranche** — règle déterministe, tous les appareils
  convergent sur la même valeur.
- Les **homonymes** créés en parallèle sur deux appareils (même nom d'ingrédient, UUID
  différents) sont réconciliés après chaque pull : le plus petit UUID gagne, les références
  sont repointées, le perdant est tombstoné. La contrainte `UNIQUE` locale a dû être levée
  (schéma v3) : elle aurait fait échouer le pull **définitivement**, la même violation se
  rejouant à chaque cycle.
- Sync automatique toutes les 2 min + une au lancement (différée de 3 s, le démarrage
  n'attend jamais le réseau) + à la demande depuis l'en-tête ou l'écran Compte.

**UI** : onglet **Compte** dans les Paramètres (connexion, état, sync manuelle,
déconnexion) et badge d'état dans l'en-tête. Hors-ligne y est présenté comme un mode
normal et non comme une erreur — seul un échec véritable passe en couleur d'alerte.

### Ce qui reste

**Valider la sync entre deux appareils réels.** Tout est testé unitairement (l'arbitrage
LWW est couvert sans réseau par `test_sync_merge.gd`), mais le cycle complet contre le
serveur attend une première connexion depuis l'app.

L'app reste **pleinement utilisable hors-ligne** : la base locale est la source de vérité,
Supabase n'est qu'un point de rendez-vous.

## Phase 3 — Android

Chantier à part entière, au-delà du simple export :

### Mise en page adaptative — fait

`autoload/Layout.gd` déduit le format de la **largeur logique du viewport**, pas d'un test
« est-ce Android ». Une tablette en paysage garde donc la mise en page bureau, et surtout le
mode téléphone se teste en redimensionnant la fenêtre :

```bash
tools/shoot.sh <nom> 412x915 "Liste de course"   # capture sous Xvfb
Godot_v4.7-stable_linux.x86_64 --path . --resolution 412x915
```

Cela a imposé de passer `window/stretch/mode` de `canvas_items` à `disabled` : avec un
viewport de base de 1280×800, la largeur logique restait bloquée à 1280 quelle que soit la
fenêtre — la mise en page ne pouvait qu'être mise à l'échelle, jamais réarrangée.

- **Liste de courses** : vue « magasin » (`ShoppingStoreList`), liste continue groupée par
  rayon, lignes entières tactiles, sans édition, **rayons repliables** (état mémorisé sur
  l'appareil, hors synchronisation). Vue distincte du tableur de bureau, avec lequel elle
  partage le tableau d'articles.
  - Le toucher est distingué du glissement de défilement (`_connect_tap`) : les lignes sont
    en `MOUSE_FILTER_PASS` et n'agissent qu'au relâchement, si le doigt n'a pas glissé de
    plus de 8 unités. En `STOP`, elles consommaient l'événement et le défilement au doigt
    était purement et simplement impossible.
    - Ce raisonnement vit dans **`TouchTap`** depuis la 1.7.4 : le même défaut est revenu
      trois fois — lignes de courses, cartes de la bibliothèque, cases à cocher du
      partage —, et deux copies auraient divergé à la première correction. Les deux
      gardes y sont indissociables : `PASS` pour que l'événement remonte au conteneur, et
      déclenchement au relâchement sur place, sans quoi tout balayage cocherait au
      passage — pire que l'absence de défilement, puisqu'on modifierait la liste en
      cherchant simplement à la lire.
    - Une cible tactile ne doit **pas** être un `Button` : celui-ci traite le clic pour
      son propre compte et s'activerait AUSSI au terme d'un balayage. Le bouton — ou la
      case à cocher — passe en `MOUSE_FILTER_IGNORE` à l'intérieur de la cible, où il ne
      sert plus qu'à afficher son état ; c'est la ligne entière qui reçoit le toucher.
  - **Ajout de dernière minute** (1.6.2, réparé en 1.7) : un champ au **pied de chaque rayon**, où le
    rayon d'arrivée est donné par l'endroit où l'on écrit — sans avoir à le choisir ni à
    le deviner du nom saisi. Les ingrédients connus s'y proposent d'eux-mêmes, pour ne
    pas taper le nom en entier au doigt. Redemander un article déjà présent ne crée pas
    de doublon : il redevient à prendre.
    - Ces suggestions n'apparaissaient en réalité **jamais**. `AutocompleteEdit` parente
      sa popup à la fenêtre englobante — un `ScrollContainer` parent la rognerait — mais
      ce rattachement a lieu pendant que ladite fenêtre monte ses propres enfants, ce
      qu'un nœud n'accepte pas. La popup n'entrait donc pas dans l'arbre, et rien ne le
      disait hors d'une erreur en console. Rattachement différé depuis la 1.7, et
      `test_autocomplete` reproduit la cascade — son filtrage, lui, a toujours été juste,
      c'est pourquoi les vérifications existantes n'y voyaient que du feu.
  - **Retrait par appui long**, contrepartie nécessaire de l'ajout : sans lui, une faute de
    frappe validée resterait sur la liste jusqu'au retour devant le PC, la vue magasin ne
    sachant par ailleurs que cocher. Appui long plutôt qu'une croix sur chaque ligne, qu'on
    toucherait par mégarde en cochant.
- **Le clavier virtuel ne recouvre plus le champ qu'on remplit** (`KeyboardInset`, 1.7.2).
  Le clavier d'Android se pose PAR-DESSUS l'application : ni la fenêtre ni le viewport ne
  rétrécissent, et rien n'avertit le `ScrollContainer` que sa moitié basse a disparu. Le
  champ d'ajout closant son rayon, il se trouvait presque toujours dessous — on y tapait
  à l'aveugle.
  - **Une marge basse avant le défilement**, et non le défilement seul : la liste est déjà
    à son terme, et son dernier champ ne peut pas remonter d'un pixel tant que le contenu
    n'a pas grandi de la hauteur du clavier.
  - Cette hauteur est rendue **en pixels physiques** quand toute l'interface se mesure en
    unités logiques (`Layout.keyboard_units`). Prise telle quelle, sur le Redmi de test
    (~440 dpi, échelle 2,75) un clavier de 900 px vaudrait 900 unités sur un écran qui
    n'en compte que 915 : l'application se croirait recouverte de fond en comble. À
    l'échelle 1 de tout poste de développement, la confusion est invisible.
  - La **popup de suggestions bascule au-dessus du champ** quand elle ne tient plus
    dessous : posée sous un champ qui surplombe le clavier, elle tombait derrière lui, et
    les suggestions sont précisément ce qui évite de taper un nom en entier au doigt.
  - Posé aussi sur le formulaire de recette et celui de petit déjeuner, longs et saisis
    de bout en bout au doigt. Les autres champs de l'app sont hors liste défilante, donc
    hors d'atteinte du clavier.
- **Calendrier et Petit Déj** : les mêmes `MealCell` voyagent entre la grille (bureau) et une
  liste verticale (téléphone) — les dupliquer obligerait à synchroniser deux états.
- **Pas de glisser-déposer depuis la bibliothèque au doigt** : les cartes étaient en
  `MOUSE_FILTER_STOP` et démarraient un glissement, si bien que le geste de défilement
  était capturé par la carte et que la liste refusait de bouger (corrigé en 1.6.3). Le
  glisser-déposer n'a de toute façon pas de sens depuis la bibliothèque sur téléphone,
  où le calendrier n'est jamais visible en même temps qu'elle.
- **Déplacer un repas au doigt, par appui long** (1.7). Entre cases, en revanche, le
  glisser-déposer garde tout son sens : les deux sont dans la même liste, et échanger
  deux jours est l'ajustement le plus courant après une génération. Trois gestes
  partagent donc un unique contact sur la case (`MealCell._touch_input`) :
  - **balayage** → défilement de la liste. La case est en `MOUSE_FILTER_PASS` et
    abandonne dès que le doigt a glissé de plus de 8 unités ; en `STOP`, elle consommait
    l'événement et un balayage parti d'une case — c'est-à-dire presque partout, les
    cases occupant toute la largeur — ne faisait rien défiler du tout.
  - **appui bref** → menu de la case. C'est l'action la plus fréquente, elle garde le
    geste le plus simple.
  - **appui long** (450 ms) → la case se soulève, franchement (bordure, ombre portée,
    léger agrandissement) : c'est le seul retour dont dispose le doigt, là où la souris
    a le curseur et l'aperçu de glissement. Le glissement qui suit la déplace ; reposée
    sans avoir bougé, elle n'ouvre pas le menu — la prise était visible, un menu
    surprendrait.
  - `can_be_dragged()` porte cette décision, et non `_get_drag_data` directement : elle
    est ainsi vérifiable sans écran ni glissement réel.
  - **`DragAutoScroll`** rend au conteneur un défilement utilisable pendant le
    déplacement : il en devient le **seul** défilement, et il défile aux bords.
    - Aux bords, parce que sans cela le déplacement n'atteint que ce qui est déjà
      affiché : sur quatorze cases pour dix visibles, le doigt tient la case et plus
      rien ne peut faire défiler.
    - Le seul, parce qu'en 1.7.0 un même doigt portait la case ET la liste. La case
      étant en `MOUSE_FILTER_PASS` — sans quoi aucun balayage ne ferait défiler quoi que
      ce soit —, l'événement remontait au `ScrollContainer`, qui panoramiquait pendant
      que la case se déplaçait. Les deux mouvements s'annulaient : la case restait sous
      le doigt sans jamais changer de voisins, et le dépôt n'échangeait rien. Mesuré :
      100 unités de défilement parasite pour un geste de 100 unités.
    - Gel par `MOUSE_FILTER_IGNORE` sur `NOTIFICATION_DRAG_BEGIN`, que le moteur
      distribue à tout l'arbre au moment même où le glissement démarre — surveiller
      `gui_is_dragging()` depuis `_process` laisserait passer une image de panoramique.
      `IGNORE` ne rend le conteneur transparent qu'à lui-même : ses cases continuent de
      recevoir les événements, et donc d'accueillir le dépôt. Un `SCROLL_MODE_DISABLED`,
      lui, ramènerait la position à zéro et interdirait le défilement aux bords.
  - Les mêmes gestes valent pour les quatre emplacements du Petit Déj, qui sont les
    mêmes `MealCell` — et sa liste porte le même `DragAutoScroll`, pour le gel plus que
    pour le défilement.
- **Les trois listes des Paramètres se laissent défiler** (`TouchItemList`, 1.7.7).
  `ItemList` n'offre pour défiler que sa barre — quelques unités de large, invisable au
  pouce — et la molette : un balayage parti d'une de ses lignes la SÉLECTIONNE. Sur 142
  ingrédients, tout ce qui dépassait du premier écran était donc inatteignable.
  - Remplacé par un `ScrollContainer` de lignes en `MOUSE_FILTER_PASS` qui n'agissent
    qu'au relâchement sur place (`TouchTap`), comme partout ailleurs. Le composant
    n'expose que le sous-ensemble d'`ItemList` employé par ces écrans, pour rester un
    remplacement direct — ingrédients, rayons et articles de base en profitent d'un coup.
  - `select()` ne réémet pas `item_selected`, comme `ItemList` : les appelants l'utilisent
    pour rétablir une sélection après reconstruction, et l'émission relancerait leur
    propre rafraîchissement.
- **La barre de navigation tient sur tout téléphone** (1.7.7). Les trois onglets tenaient
  sur l'appareil de test et pas sur un autre — question de largeur **logique**, qui dépend
  de la densité de l'écran et non de sa taille. Relevé à 320 unités : 216 de barre pour
  330 d'onglets, dont **108 de remplissage pur** (18 unités de marge de chaque côté de
  chaque onglet). **Un seul levier** : les ramener à 8, ce qui libère 60 unités.
  - Deux autres avaient été ajoutés — libellé raccourci en « Courses », police à 13 — sur
    la foi d'une mesure prise AVANT cette réduction. Remesuré, aucun des deux n'est
    nécessaire : « Liste de course » à la **police normale** exige 270 unités pour 292
    disponibles sur un écran de 320. Les deux ont été retirés (1.7.8 et 1.7.9).
  - La leçon vaut d'être notée : après une correction qui change les dimensions, les
    mesures d'avant ne valent plus rien. Trois leviers ont été empilés là où un suffisait,
    chacun jugé nécessaire sur un chiffre que le précédent avait déjà rendu faux.
  - Un plafond de largeur (`max_tab_width`) reste en filet de sécurité, posé **seulement**
    si la somme déborde. Trois mesures fausses ont été essayées avant la bonne, et elles
    valent d'être notées :
    - la `TabBar` ne s'étire pas, elle se dimensionne sur ses onglets : plafond posé →
      barre rétrécie → plafond justifié → boucle qui s'entretient seule, et trois onglets
      tronqués à 40 unités sur tout écran ;
    - le `TabContainer` n'a pas encore sa largeur définitive quand le calcul tourne ;
    - une surcharge de thème **ne se transmet pas aux enfants** : interrogée sur
      elle-même, la `TabBar` renvoyait la police et les marges du thème de base, et la
      largeur naturelle était surestimée d'un tiers.
    La place est donc déduite de la largeur du **viewport** — la même mesure dont `Layout`
    tire le format, et la seule qui soit vraie dès le départ.
- **Le message de première connexion tient dans l'écran** (1.7.7). Un `AcceptDialog` se
  dimensionne sur son texte, et sans repli il le pose sur UNE ligne : mesuré à **1092
  unités de large pour un écran de 412**. `dialog_autowrap` ne suffit pas seul — il lui
  faut une largeur cible, passée à `popup_centered`. Forcer `min_size`/`max_size` à la
  place laissait le dialogue à l'état d'un trait vertical de deux pixels. Les libellés des
  deux boutons sont raccourcis au doigt : côte à côte, ils réclamaient plus de 400 unités.
- **Accès aux bibliothèques au BAS de l'onglet, sous un séparateur** (1.7.10). Les boutons
  « Liste des recettes » et « Liste des petits déj » vivaient au bord droit d'une rangée de
  commandes, en variante fantôme. Trois défauts d'un coup : noyés parmi les commandes de
  planification alors qu'ils mènent **ailleurs**, à peine visibles, et placés au milieu de
  l'écran là où le pouce atteint le plus aisément le bas. Ils sont désormais centrés, en
  variante encadrée, sous un `HSeparator` qui dit ce qu'ils sont — non pas une commande de
  l'écran courant, mais la sortie vers un autre.
  - Centrés et non étirés : pleine largeur, ils se confondraient avec une bannière, et la
    cible tactile est déjà bien suffisante.
- **Sélecteur au toucher** (`PickerPopup`) : sur téléphone un appui simple sur une case ouvre
  son menu, dont la première entrée est « Choisir une recette… ». Remplace le glisser-déposer,
  impraticable au doigt sur une liste de 73 recettes.
- **Panneaux latéraux en feuille** (`PanelSheet`, 1.6.1). La bibliothèque de recettes
  et le choix de petits déjeuners étaient simplement *masqués* sur téléphone, faute de
  place à côté de leur écran : créer, modifier, partager ou importer une recette était
  donc impossible depuis un téléphone — et, depuis les photos, y attacher une image
  aussi, alors que c'est l'appareil qu'on a en main devant le plat.
  - Un bouton discret (« Liste des recettes », « Liste des petits déj ») les ouvre en
    plein écran le temps qu'on s'en serve. Un quatrième onglet aurait rendu permanent
    un détour occasionnel, et chargé une barre de navigation qui tient à trois.
  - C'est le **même nœud** qui voyage entre son panneau de bureau et la feuille, comme
    les cases entre grille et liste ; en dupliquer un second obligerait à tenir deux
    sélections et deux listes filtrées d'accord. La feuille le **rend** à son conteneur
    en se fermant — sinon il serait libéré avec elle, et l'écran se retrouverait sans
    lui au retour du format bureau.
- Fenêtres secondaires en plein écran sur téléphone (`Layout.fit_window`).
- **« Partager des recettes » sur une seule colonne** (1.7.3, achevé en 1.7.4). Ses deux
  colonnes côte à côte réclamaient près de 600 unités de large — 280 pour la liste des
  recettes, 280 pour le QR : sur un écran de 412, la colonne de droite commençait à 375
  et s'achevait à 655. Le QR, l'état et les deux boutons étaient dehors, et aucun geste
  ne permettait de les ramener — un plein écran n'a pas de défilement horizontal.
  - 1.7.3 les a empilées (`BoxContainer.vertical`). Piège à retenir au passage : un
    `HBoxContainer` fixe son orientation à la construction et n'en démord pas — l'écrire
    ensuite ne fait rien, et sans la moindre erreur. Il faut un `BoxContainer` nu.
  - **1.7.4 a supprimé la seconde colonne** : le QR et « Copier le code » ont leur propre
    fenêtre (`ShareCodePopup`), qui ne s'ouvre qu'une fois le partage déposé. Empilé, le
    QR restait un carré vide occupant le tiers de l'écran tant qu'il n'y avait rien à
    montrer, et « Copier le code » proposait de copier le vide. Un QR doit en outre être
    GRAND pour qu'un autre téléphone le lise, ce qu'une moitié d'écran partagée avec une
    liste de 73 recettes ne permettait pas. La fenêtre se referme, ce qui ramène à la
    sélection sans rien avoir à défaire.
  - **« Tout sélectionner » / « Tout désélectionner »** au-dessus de la liste : partager
    sa collection sur un appareil neuf, ou repartir de zéro après s'être trompé,
    demandait 73 touchers. Le basculement en lot suspend le récapitulatif — sans quoi
    chaque case relancerait un parcours de la liste, 73 fois pour un seul geste.
  - `test_windows` vérifie désormais, **pour les onze fenêtres**, que rien ne dépasse
    d'un écran de téléphone. Le contenu des `ScrollContainer` en est exclu : y déborder
    est leur raison d'être. Un bouton hors champ n'existe pas, et rien ne le signale.
- **Bouton Retour du système** (1.7). Il quittait l'application au premier appui, quoi
  qu'il y ait à l'écran : perdre une recette à moitié saisie pour avoir voulu refermer
  son formulaire est une punition disproportionnée pour un bouton qu'on touche par
  réflexe. `application/config/quit_on_go_back` passe donc à `false`, et
  `MainWindow._go_back()` défait un niveau à la fois — la fenêtre ouverte par-dessus,
  puis le détour par un autre onglet, puis l'application, qui demande un second appui
  sous 2,5 s.
  - Retour à l'onglet **d'accueil** et non au précédent : la barre n'en compte que
    trois, sans profondeur — passer de la liste de courses au calendrier est un
    déplacement latéral, pas un empilement dont on redescendrait marche à marche.
  - La fenêtre est refermée par le **même chemin que la croix de sa barre de titre**
    (`NOTIFICATION_WM_CLOSE_REQUEST` + signal `close_requested`), et non par un
    `queue_free()` : chaque fenêtre sait ce qu'elle a à rendre en partant, à commencer
    par la feuille latérale et le panneau qu'elle a emprunté.
  - Le traitement est **différé** (`call_deferred`) : le moteur distribue cette
    notification en parcourant l'arbre, qui reste verrouillé pendant le parcours.
    Le message de sortie ne pouvait pas s'y ajouter, et l'échec ne se voyait que par
    une erreur en console — sur un appareil, c'est-à-dire nulle part.

### Publier une version

La procédure complète — keystore de release, numérotation, APK signé, exécutable et
installeur Windows — est décrite dans [`release_prod.md`](release_prod.md).

```bash
source ~/.amealplanner-release.env
tools/release.sh minor
```

### Construire l'APK de développement

```bash
tools/build_android.sh              # export debug, installe si un appareil est branché
tools/build_android.sh --no-install
```

Pour les tests, toujours passer par `tools/run_tests.sh` : il détourne la base vers un
fichier jetable via `MEALPLANNER_DB`. Lancés directement, les scripts de test écrivent
dans la base **réelle** — ils y ont déjà laissé des doublons et fait perdre une liste
de courses.

Installé sur cette machine : templates d'export Godot 4.7 (~222 Mo — seuls
`android_debug.apk` et `android_release.apk` ont été extraits, `android_source.zip`
de 214 Mo ne servant qu'aux builds gradle), SDK Android réduit (~316 Mo :
`platform-tools` et `build-tools;35.0.0`), keystore de debug. **Ni gradle ni NDK** :
l'export standard re-signe l'APK pré-construit et y empaquette les `.so` du
GDExtension, ce qui suffit pour `godot-sqlite`.

Le script refuse de livrer un APK auquel manquerait `libgdsqlite` arm64, ou qui
contiendrait l'export des données personnelles.

Points de configuration notables :

- `architectures/arm64-v8a` seul — tous les téléphones récents le sont, et `x86_64`
  ne servirait qu'à un émulateur ;
- `permissions/internet` seule — la base SQLite vit dans `user://`, dans le stockage
  privé de l'app, qui n'exige aucune permission ;
- `exclude_filter="tools/*, supabase/*, *.md"` — `tools/` contient
  `recettes_export_personnel.json` ;
- `rendering/textures/vram_compression/import_etc2_astc=true` — exigé par Android,
  les GPU mobiles ne gérant pas les formats de compression du bureau ;
- `export_presets.cfg` est **versionné** : il ne contient aucun identifiant de
  signature, ceux-ci vivant dans les réglages de l'éditeur.

### Rayons personnalisables (1.1)

Les rayons de magasin étaient codés en dur **à trois endroits** — la liste de courses,
les articles de base, et une troisième liste déduite des rayons déjà employés par les
ingrédients. Elles avaient divergé (`Autre` d'un côté, `Autres` de l'autre), et
« Picard » n'a de sens que pour certains foyers.

C'est désormais une table `aisles` ordonnée et synchronisée, éditable dans
**Paramètres > Rayons**. L'ordre y est l'essentiel : il détermine celui des groupes de
la liste de courses, donc le parcours du magasin.

- Ingrédients, articles de base et articles de courses référencent le rayon par son
  **nom** — même parti pris que les catégories de recettes. Renommer reporte donc le
  nouveau nom sur tout ce qui le référence.
- Supprimer un rayon rattache son contenu au rayon de repli (`Autres`), qui ne peut
  pas être supprimé : un ingrédient rattaché à un rayon disparu sortirait de la liste.
- Le moteur de sync **ignore une table absente du serveur** au lieu d'interrompre tout
  le cycle. Sans cela, installer une version plus récente que le schéma Supabase
  casserait la synchronisation de toutes les autres tables.

> ⚠️ Née après le jeu d'exemple et la réconciliation des homonymes, cette table avait
> échappé aux deux (corrigé en 1.4.2). Un appareil qui se connectait gardait les dix
> rayons par défaut **en plus** de ceux du compte, puis les poussait — les répandant
> sur tous les autres appareils, avec des doublons de nom que rien ne résorbait.
> Toute table ajoutée au schéma doit être passée en revue dans `discard_seed_rows()`
> et dans les fusions d'homonymes, faute de quoi elle reproduira ce défaut.

### Photos de recettes (1.5)

Une photo par recette, dans une table `recipe_photos` à part — la lire avec la recette
ferait traîner plusieurs mégaoctets à chaque rafraîchissement du cache, qui est rejoué
après la moindre écriture.

Tout ce qui entre est **normalisé une fois** (`services/RecipePhoto.gd`), quelle que
soit la source : côté long ramené à 1024, JPEG qualité 0,8, plus une vignette carrée de
160 pour les listes et les cases du calendrier. Une photo de téléphone non réduite
passerait intacte en base et dans la synchronisation, où chaque ligne voyage en base64
— quelques recettes suffiraient à rendre interminable le premier pull d'un appareil
neuf. Mesuré : **131 ko** par image, **6,6 ko** par vignette.

- Stockées en **base64** et non en BLOB : c'est la forme sous laquelle elles voyagent
  de toute façon (PostgREST échange du JSON). Les 33 % de disque en plus sont le prix
  d'un moteur de sync qui n'a aucun cas particulier à connaître.
- Affichage : à la place de la pastille de catégorie dans la bibliothèque, en bandeau
  au-dessus du nom dans les cases du calendrier (à sa gauche sur téléphone, où les
  cases sont des lignes), et en tête des popups ingrédients et étapes.
- La photo suit sa recette : la supprimer **tombstone** la photo, faute de quoi elle
  resterait sur le serveur et redescendrait vers une recette disparue.
- **Une case grandit avec son texte** (1.7.12). Un nom replié sur deux lignes décalait tout
  le contenu vers le bas : « Croque-monsieur végétarien » avec une photo, sur un écran de
  360 unités. La boîte de contenu passait à 49 de haut, mais la case restait à 56 avec un
  rectangle intérieur de 40 — la boîte commençait donc à 8 et finissait à 57, soit 12
  unités au-dessus de la photo et 4 en dessous, en débordant d'une unité.
  - Cause : la boîte vivait dans un `Control` intermédiaire. **Un conteneur dispose ses
    enfants directs et remonte leur taille minimale ; un `Control` nu ne remonte rien.**
    La case ne pouvait donc pas apprendre que son texte demandait plus de place.
  - La boîte est désormais un enfant **direct** du `PanelContainer`, et le badge de
    catégorie a son propre calque transparent — étiré lui aussi au rectangle intérieur,
    de taille minimale nulle, il donne au badge un cadre stable sans peser sur la case.
  - Ne se voyait pas à 412 unités, où ce nom tient sur une ligne : c'est la largeur de
    l'appareil de test. Un écran plus étroit — donc plus dense — le repliait.
- **Un carré doit rester carré** (1.7.10). `PhotoFrame.square()` ne posait que la taille
  *minimale* ; les drapeaux par défaut laissaient donc le conteneur étirer le cadre. Dans
  une case du calendrier au format téléphone — une rangée de 56 unités de haut — un carré
  de 40 devenait un rectangle de 40 × 56, la photo étant recadrée sur cette forme et
  collée en haut. Les drapeaux sont désormais posés par `square()` elle-même : la promesse
  d'un carré doit être tenue par la fonction qui la fait. Le défaut ne se voyait pas dans
  la bibliothèque, où la rangée mesure justement la hauteur du carré.
- Le **partage les emporte** depuis la 1.6, au prix d'un changement de mécanisme
  (voir ci-dessous) : un QR ne pouvait pas les porter.

### Une base locale = un compte (1.7.5)

Symptôme : se connecter sur un **second compte** depuis un appareil qui en avait déjà
servi un autre échouait sur

```
new row violates row-level security policy (USING expression) for table "categories"
```

Cette formulation est réservée à un cas précis — l'échec d'un `INSERT … ON CONFLICT DO
UPDATE` dont la ligne **déjà en place** ne passe pas le `USING` de la politique. Ce
n'était donc pas une policy trop stricte : l'appareil tentait de **modifier la ligne d'un
autre compte**, et la RLS l'en a empêché.

- **Cause.** `sign_out()` efface la session sans toucher à la base, et `sign_in()` ne
  compare rien : une base ayant servi à deux comptes accumulait leurs lignes. Relevé sur
  le poste de développement — **48 lignes dans `categories` pour 8 noms**, six
  exemplaires de « Légumes », une génération par synchronisation.
- **Pourquoi c'est grave.** Aucune table locale ne porte de propriétaire : tout ce qui
  parcourt la base croit n'avoir affaire qu'au compte courant. `merge_duplicate_*`
  résorbait donc les homonymes **à travers les comptes** et poussait des tombstones
  visant les lignes d'autrui. Refusés ici par la RLS ; **appliqués** si la ligne visée
  appartient par hasard au compte courant — cinq catégories du compte de test étaient
  sur le point de disparaître, sans un mot. C'est le pire défaut possible pour ce
  projet : invisible sur un appareil, il détruit des données sur un autre.
- **Correctif applicatif** (`LocalDatabase.claim_account`) : la base retient le compte
  auquel elle appartient. En changer équivaut à une installation neuve — contenu vidé,
  curseurs remis à zéro, jeu d'exemple réarmé. Les curseurs surtout : conservés, le
  premier pull ne demanderait que les lignes postérieures au dernier passage de l'ancien
  compte, et la base resterait vide **sans erreur**. Une base antérieure à ce marqueur
  est adoptée telle quelle : on ne peut plus savoir à qui elle appartient.
- **Garde-fou structurel** (schéma) : la clé primaire des six tables à `id` passe de
  `(id)` à **`(owner_id, id)`**, et les `upsert` à `on_conflict=owner_id,id`. Deux
  comptes peuvent désormais détenir le même id sans se rencontrer, et aucun push ne peut
  plus atteindre la ligne d'autrui — quelle que soit l'erreur en amont.
  - ⚠️ **Ordre imposé** : rejouer `supabase/schema.sql` **avant** d'installer la 1.7.5.
    Dans l'autre sens, chaque sync échoue sur `42P10` (contrainte absente) — sans perte,
    mais sans rien synchroniser.
- Ce qui a été perdu au passage n'est pas récupérable localement mais l'est sur le
  serveur : les éditions jamais synchronisées de l'ancien compte, elles, disparaissent.
  C'est le seul choix cohérent — elles ne peuvent pas être poussées vers un compte qui
  n'est pas le leur. L'écran le dit en toutes lettres au moment où cela se produit.

### Le jeu d'exemple ne se pousse plus au compte (1.7.6)

Symptôme : une base **neuve**, connectée à un compte qui a déjà des données, annonçait
« 21 éléments envoyés » alors qu'elle n'avait rien à envoyer. `discard_seed_rows()` était
censé écarter tout le jeu d'exemple avant le push ; il n'en écartait qu'une partie.

```
recipes       28 lignes, dont  28 reconnues comme jeu d'exemple
ingredients   55 lignes, dont  55 reconnues
categories     8 lignes, dont   0 reconnues        ← jamais reconnues
staples       14 lignes, dont  14 reconnues
aisles        10 lignes, dont  10 reconnues, mais 0 retirée
```

Les 21 : **8 tombstones de catégories + 3 catégories vivantes + 10 tombstones de rayons**.
Deux causes indépendantes, aux conséquences très inégales.

- **Les catégories ne portaient pas la marque du semis.** Une ligne d'exemple se reconnaît
  à `updated_at == seed_stamp`, or `_category_id()` appelait `_now()` pour son propre
  compte — 58 à 64 ms après le stamp mémorisé. Aucune n'était donc reconnue.
  - Elles survivaient, se retrouvaient en doublon avec celles du compte, et
    `merge_duplicate_categories()` tranchait **par le plus petit id** : un tirage au sort.
    Sur les 8 noms, 3 fois c'est la ligne **du compte** qui a perdu — mise en tombstone et
    remplacée par celle de l'appareil neuf. **Trois catégories légitimes supprimées.**
  - Fonctionnellement invisible, les recettes voyageant avec leurs catégories par NOM :
    c'est exactement ce qui rendait ce défaut durable.
  - Il explique aussi les **48 catégories pour 8 noms** relevées en 1.7.5 : chaque
    installation ajoutait 8 lignes d'exemple que rien ne jetait jamais.
- **Le garde-fou des rayons était évalué trop tôt.** `_discard_seed_aisles()` ne les
  retire que si le compte en apporte d'autres — précaution juste (un serveur au schéma
  antérieur à la 1.1 n'en renvoie aucun, et les effacer laisserait la liste de courses
  entière sous « Autres »). Mais l'écartement est déclenché par la **première ligne reçue**
  du cycle, donc pendant le pull de `categories`, avant même qu'`aisles` ne soit demandé :
  la condition était toujours fausse.
  - L'écartement des rayons est donc **différé à la fin du pull** (`discard_seed_aisles`),
    et avant la fusion — sans quoi elle les prendrait pour des homonymes à tombstoner.
  - Les rayons sont les seules lignes que l'on peut différer ainsi : ils sont référencés
    par leur **nom**, il n'y a aucun lien d'id à recoller. Différer les catégories
    briserait au contraire les liens des recettes tirées entre-temps.
- `purge_tombstones()` omettait `aisles` et `recipe_photos` — nées après elle, comme la
  réconciliation des homonymes les avait oubliés. Leurs tombstones s'accumulaient sans fin.

### La fiche d'une recette (1.7.13)

La bibliothèque agissait par une **barre de cinq boutons** sous la liste : Ajouter,
Modifier, Partager, Importer, Supprimer, les deux derniers actifs ou grisés selon qu'une
ligne était surlignée quelque part au-dessus. On modifiait donc — ou l'on supprimait — une
recette sans l'avoir sous les yeux.

- **Un clic ou un toucher ouvre la fiche**, en LECTURE. C'est le geste le plus fréquent :
  on vient bien plus souvent consulter une recette que la corriger.
  - « Modifier » (en-tête) fait basculer la page entière en édition ; « Supprimer » est à
    côté. En édition, les deux disparaissent et le pied offre « Annuler » / « Sauvegarder ».
  - Le verrouillage est un **parcours récursif** du formulaire : les lignes d'ingrédients
    naissent au remplissage, après la construction, et une liste de champs tenue à la main
    aurait oublié les prochaines.
  - Les champs verrouillés gardent **l'encre du texte normal** (`font_uneditable_color`) :
    c'est ainsi qu'on lit une recette, et la couleur par défaut la rendait presque aussi
    pâle qu'un texte d'invite. La saison, elle, n'a pas de mode lecture — seul `disabled`
    la verrouille, et il éteignait son libellé : elle apparaissait comme une case vide.
- **« Ajouter au planning »**, en pied de fiche et pleine largeur, place la recette dans la
  première case libre. Aucune règle de saison ni de transport : la génération aléatoire en
  tient compte parce qu'elle choisit à notre place, un choix explicite doit être respecté.
- **Ouvrir n'est pas sélectionner.** Sur ordinateur la sélection part dès l'ENFONCEMENT,
  pour que le glisser-déposer vers le calendrier s'enchaîne. Un second signal
  (`item_activated`) attend le relâchement sur place et vérifie qu'aucun glissement n'est
  en cours : sans cette distinction, déposer une recette sur le calendrier ouvrirait aussi
  sa fiche.
- **L'en-tête est un `HFlowContainer`** : à quatre éléments sur un écran de 412, la rangée
  débordait et « Supprimer » sortait de l'écran. Le titre s'effaçant sur téléphone — le nom
  est le premier champ, juste dessous — les trois boutons tiennent dès 360.
- **En lecture, seul le défilement est possible** (1.7.14). `editable = false` ne change pas
  le FILTRE d'entrée d'un champ : celui-ci continuait de capter l'amorce du geste, et une
  page qu'on ne peut que lire devenait pénible à faire défiler. Champs et boutons
  verrouillés passent donc en `MOUSE_FILTER_IGNORE`.
  - En **édition**, ils passent en `MOUSE_FILTER_PASS` : le champ garde le toucher — sans
    quoi on ne pourrait plus y écrire — mais le laisse aussi remonter au conteneur, si bien
    qu'un balayage parti d'un champ fait défiler la page. Une **zone morte** de 8 unités
    (`scroll_deadzone`) évite que la moindre hésitation du doigt en visant un champ ne fasse
    glisser la page sous lui.
  - Le pavé d'étapes prend en lecture **la hauteur de son texte** : ne recevant plus le
    toucher, il ne peut plus défiler pour son propre compte, et la fin d'une recette longue
    serait devenue illisible à hauteur fixe.
- **Le formulaire ne déborde plus d'un écran étroit** (1.7.14). La rangée photo exigeait 360
  unités de large (aperçu de 200 + colonne de boutons) et chaque ligne d'ingrédient 311 — le
  thème donnant 85 unités de largeur minimale à tout champ. Ce minimum s'imposait à la
  fenêtre entière : sur un écran de 360, le conteneur de marges mesurait **410**, et le bord
  droit disparaissait avec la marge du bouton de pied et de la barre de défilement. Les deux
  rangées sont devenues des `HFlowContainer` — la colonne de boutons passe sous l'aperçu, la
  quantité et l'unité sous le nom — et le minimum du formulaire tombe de 360 à **166**.
  Vérifié sans débordement à 320, 360 et 393.
- Sur téléphone, une **entretoise invisible** repousse « Modifier » et « Supprimer » contre
  la marge de droite. C'est le titre qui jouait ce rôle sur ordinateur ; masqué sur
  téléphone, il ne poussait plus rien et les deux boutons restaient collés au bouton de
  fermeture.
- Il reste dans le panneau « Partager » et « Importer », qui portent sur la collection et
  non sur une recette ; « Ajouter » monte dans l'en-tête, à la place qu'occupait le
  compteur, lequel rejoint son titre : « Mes Recettes (28) ».

### Partage par référence (1.6)

Jusqu'en 1.5, le code de partage **contenait** les recettes — autoportant, sans serveur
ni compte. Les photos ont rendu ce format intenable : un QR lisible plafonne à
~1200 octets, une photo normalisée en pèse 131 000, soit cent fois trop. Aucune
compression ne rattrape un tel écart.

Le code porte donc désormais un **jeton** (`AMEAL2:<32 caractères>`), et le contenu est
déposé sur le compte de l'émetteur. Le QR mesure 40 octets quel que soit le nombre de
recettes, là où trente et une recettes sans photo en demandaient déjà 3 647 : il reste
scannable en toutes circonstances, et la taille du partage n'a plus de limite pratique.

Ce que cela coûte, et qui est assumé : **publier demande d'être connecté**, récupérer
demande le réseau, et un partage **expire au bout de 30 jours**. `AMEAL1` reste lu à
l'import — des codes autoportants ont pu être émis et gardés.

> ⚠️ La sécurité tient à un seul point. La clé anonyme Supabase est embarquée dans
> l'application, donc publique : une policy de lecture ouverte à `anon` sur
> `shared_bundles` permettrait à quiconque possède l'APK de faire un `SELECT` sans
> filtre et de récupérer les recettes **et les photos de tous les foyers**. La table
> n'est donc lisible que par son propriétaire, et le contenu ne s'obtient que par
> `fetch_shared_bundle(token)`, en `security definer` : elle ne peut rendre qu'une
> ligne, et seulement si l'on connaît son jeton — tiré côté serveur, 128 bits.
> Un jeton inconnu et un jeton périmé donnent la même réponse, pour ne pas confirmer
> l'existence d'un partage à qui essaierait des jetons au hasard.

Le QR ne peut pas être une URL cliquable : ouvrir l'application depuis un lien
demanderait un `intent-filter`, donc un build gradle, que ce projet évite. Le code se
colle dans « Importer », comme avant.

Les partages périmés sont supprimés à chaque publication — un ménage opportuniste, qui
évite d'installer un cron pour une table de quelques lignes.

#### Formats d'image acceptés

`Image.load` se fie à l'**extension** du chemin, que le sélecteur de fichiers d'Android
ne fournit pas toujours. Un JPEG pouvait donc être refusé pour une raison qui n'avait
rien à voir avec son contenu. Le chargement retombe désormais sur une lecture des
octets, en essayant les décodeurs d'après la **signature** du fichier (1.6.3).

Le HEIC — format par défaut de bien des téléphones récents — reste illisible par Godot,
mais il est reconnu et nommé : mieux vaut le dire que laisser croire à un fichier abîmé.

#### Ajouter une photo sur Android (1.5.1)

Deux sources, qui convergent vers le même traitement — `RecipePhoto` normalise aussi
bien un fichier qu'une capture, donc une photo prise à l'appareil pèse le même poids
qu'une photo choisie.

- **Choisir un fichier** passe par le sélecteur **natif** du système
  (`DisplayServer.file_dialog_show`) dès qu'il est disponible. Le `FileDialog` de Godot
  explore un système de fichiers auquel une application Android n'a pas accès : il
  reviendrait vide. Il reste le repli sur ordinateur.
- **Prendre une photo** ouvre un écran de visée maison (`ui/components/CameraCapturePopup.gd`).
  Godot ne donne pas accès à l'application photo du système : `CameraServer` ne fournit
  qu'un flux vidéo brut.
  - Le flux est rendu dans un `SubViewport`, et c'est **ce viewport** qui est capturé :
    l'image obtenue est exactement l'aperçu montré, conversion de couleur comprise.
    Lire la texture de la caméra directement obligerait à refaire cette conversion à la
    main, et à la maintenir d'accord avec celle de l'aperçu.
  - Le format dépend de l'appareil : RGB sur les caméras de bureau, **YCbCr — souvent
    en deux plans séparés — sur Android**, converti par un shader. Un format inconnu
    est annoncé plutôt qu'affiché avec des couleurs fausses.
  - Le type de données n'est lu qu'**après la première image**, signalée par
    `frame_changed`. Avant elle, un flux Android s'annonce en `FEED_RGB` même s'il
    livrera du YCbCr : l'aperçu prenait alors la branche RGB et affichait le plan de
    luminance comme du RGBA — `FEED_RGBA_IMAGE` et `FEED_Y_IMAGE` valent tous deux 0,
    c'est la même texture. Seul le canal rouge portait l'image, d'où un aperçu
    entièrement rouge où la scène restait pourtant lisible.
  - Le capteur ne tourne pas avec le téléphone : l'image arrive couchée en portrait.
    Plutôt qu'un angle codé en dur — il varie d'un appareil à l'autre — on compare les
    orientations du flux et du cadre. Le shader corrige au passage les **proportions** :
    le `TextureRect` respectait bien l'aspect, mais celui de son carré blanc de support,
    pas celui de l'image.
  - L'aperçu s'ajuste **par l'intérieur** et non par recouvrement : on ne peut pas
    cadrer ce qu'on ne voit pas, et le cadrage se choisit à l'étape suivante.

#### Cadrer la vignette (1.6)

La vignette est carrée alors qu'une photo ne l'est presque jamais ; la prendre au
centre sans rien demander manquait le sujet une fois sur deux. Un écran
(`PhotoCropPopup`) s'interpose donc entre l'image obtenue — fichier ou appareil photo —
et son enregistrement.

- La zone extérieure est **assombrie plutôt que masquée** : on voit ce qu'on ne prend pas.
- Tout se fait au doigt : tirer un coin redimensionne (le coin opposé reste fixe),
  glisser déplace sans saut au premier contact, toucher hors du cadre l'amène là.
- **L'image entière est conservée** : ce cadre ne choisit que la vignette. Les popups
  ingrédients et étapes continuent d'afficher la photo complète.
  - `CameraServer.monitoring_feeds` n'est activé que le temps de cet écran : il coûte
    en permanence et maintiendrait l'appareil photo éveillé. C'est aussi pourquoi le
    bouton « Prendre une photo » est décidé par la plateforme et non en interrogeant
    les flux, ce qui allumerait la caméra à chaque ouverture du formulaire.
  - La permission `CAMERA` est demandée à l'ouverture de l'écran, pas au lancement.

> La table doit exister côté serveur pour que la synchronisation les propage : exécuter
> la fin de [`supabase/schema.sql`](supabase/schema.sql) sur le projet Supabase. Tant
> qu'elle manque, le cycle l'ignore et les autres tables continuent de se synchroniser.

### Reste à faire

- Valider sur appareil réel : `godot-sqlite` (binaires arm64/x86_64 déjà dans l'addon)
  et la sync Supabase sur réseau mobile.
- Les réglages au doigt sont **éprouvés sur appareil** (1.7.4) : appui long de 450 ms,
  tolérance de balayage de 8 unités, marge de 8 unités au-dessus du clavier. Le
  déplacement de case complète le sélecteur (« Choisir une recette… ») sans le remplacer :
  l'un place une recette, l'autre réordonne ce qui est déjà placé.
