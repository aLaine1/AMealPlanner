class_name LocalDatabase
extends RefCounted
## Accès SQLite local (godot-sqlite). Base créée dans user:// (writable, y compris export).
## Au 1er lancement, la base est créée puis semée depuis data/mealplanner_seed.json.
##
## ===== Schéma v2 — préparation de la sync Supabase (Phase 2) =====
##
## 1. **Clés primaires en UUID texte** et non plus en INTEGER AUTOINCREMENT : deux
##    appareils éditant hors-ligne attribueraient le même prochain entier et
##    entreraient en collision à la première sync. Cf. services/Uuid.gd.
## 2. **`updated_at` en millisecondes** (l'ancien schéma était en secondes) — même
##    représentation que côté Postgres, la comparaison LWW est une comparaison
##    d'entiers des deux côtés.
## 3. **Invariant de suppression** : un soft-delete écrit `deleted_at` ET `updated_at`.
##    Le pull incrémental filtrant sur `updated_at`, un tombstone qui ne bouge pas
##    `updated_at` ne serait jamais propagé aux autres appareils.
## 4. **`dirty`** : 1 = écrit localement, à pousser ; 0 = à jour vis-à-vis du serveur.
##    Le moteur de sync met à 0 après un push réussi, et écrit à 0 ce qu'il pull —
##    sans quoi tout ce qui est reçu serait aussitôt renvoyé.
##
## Granularité : la recette est un **agrégat**. `recipe_ingredients`,
## `recipe_categories` et `breakfast_ingredients` sont des tables filles locales
## (pratiques pour requêter/joindre) réécrites en bloc à chaque sauvegarde du parent ;
## elles n'ont donc pas de colonnes de sync propres, elles suivent l'`updated_at` du
## parent. Décision prise avec l'utilisateur, cf. supabase/README.md.

const DEFAULT_DB_PATH := "user://mealplanner.db"
const SEED_PATH := "res://data/mealplanner_seed.json"
const SCHEMA_VERSION := 8
const Uuid := preload("res://services/Uuid.gd")

## Tables portant des colonnes de sync (updated_at / deleted_at / dirty).
const SYNCED_TABLES := [
	"recipes", "ingredients", "categories", "breakfasts", "staples",
	"aisles", "settings", "meal_plan_positions", "breakfast_slots", "shopping_items",
	"recipe_photos",
]

## Tables de liaison, locales : elles ne voyagent pas (recettes et petits déjeuners
## portent leurs liens en jsonb), mais elles suivent le sort des lignes qu'elles relient.
const LINK_TABLES := ["recipe_ingredients", "recipe_categories", "breakfast_ingredients"]

## Compte auquel cette base appartient. Une base = UN compte.
const ACCOUNT_KEY := "account_id"

## Horodatage du semis mis de côté pour les seuls rayons, dont l'écartement ne peut pas
## être décidé au même moment que le reste (cf. `discard_seed_aisles`).
const SEED_AISLES_KEY := "seed_aisles_stamp"

## Réglages du foyer, synchronisés. Distincts de la table `meta`, qui reste locale à
## l'appareil (curseurs de sync, préférences d'affichage) : ceux-ci décrivent comment
## le planning est construit, ce qui concerne tous les appareils.
# ===== Forme du planning (1.8) =====
#
# Ces quatre réglages remplacent autant de valeurs qui étaient codées en dur : 14 cases, 14
# jours consécutifs commençant un samedi, un repas par jour, et un nombre de convives
# implicite. Leurs défauts REPRODUISENT exactement ce comportement — c'est la garantie qu'un
# foyer déjà installé ne voit rien changer. Voir 0_plan_1.8.0.md, étape 1.
#
# Réglages du FOYER et non de l'appareil : ils vivent dans `settings`, qui est synchronisée.
# Les deux téléphones d'un foyer doivent voir le même planning.
const SETTING_PLAN_WEEKS := "plan/weeks"
const SETTING_PLAN_WEEK_START := "plan/week_start"
const SETTING_PLAN_MEALS_PER_DAY := "plan/meals_per_day"
const SETTING_HOUSEHOLD_SERVINGS := "household/servings"
const SETTING_ONBOARDING_DONE := "onboarding/done"

## 2 semaines de 7 jours = les 14 cases de la 1.7.
const DEFAULT_PLAN_WEEKS := 2
const PLAN_WEEKS_MIN := 1
const PLAN_WEEKS_MAX := 4
## Jour de début, lundi = 0 comme dans `Time` : 5 = samedi, celui de la 1.7.
const DEFAULT_PLAN_WEEK_START := 5
const DEFAULT_PLAN_MEALS_PER_DAY := 1
const PLAN_MEALS_MAX := 2
## Quatre parts : la valeur retenue pour les deux comptes existants (plan, décision D4).
## Sert de repère aux recettes dont le nombre de parts n'est pas renseigné, si bien que le
## facteur d'échelle vaut 1 et qu'aucune quantité ne bouge.
const DEFAULT_HOUSEHOLD_SERVINGS := 4

const SETTING_TRANSPORT_ENABLED := "transport/enabled"
const SETTING_TRANSPORT_SLOTS := "transport/slots"

## Soirs historiquement réservés aux plats qui ne se transportent pas : vendredi et
## samedi, les seuls qui ne soient pas suivis d'une journée de travail.
## Soirs réservés, en couples « jour de la semaine:repas » — lundi = 0, repas 0 = midi ou
## repas unique, 1 = soir. Vendredi et samedi par défaut : les soirs qui ne sont pas suivis
## d'une journée de travail, et donc dont les restes ne partiront pas en gamelle.
##
## C'était auparavant une liste d'indices ABSOLUS (« 0,6,7,13 »), qui ne voulaient dire quelque
## chose que parce que le planning faisait quatorze jours à partir d'un samedi. Changer le jour
## de début les décalait en silence, et rallonger le planning laissait les semaines ajoutées
## sans aucun soir réservé. Voir 0_plan_1.8.0.md, piège 1.
const DEFAULT_TRANSPORT_WEEKDAYS := "4:0,5:0"
## Ancien format, conservé pour la migration et pour les tests qui décrivent la 1.7.
const LEGACY_DEFAULT_TRANSPORT_SLOTS := "0,6,7,13"

## Rayon de repli : tout ingrédient dont le rayon a été supprimé y atterrit. Doit
## toujours exister, sinon des articles disparaîtraient de la liste de courses.
const FALLBACK_AISLE := "Autres"

## Rayons par défaut, dans l'ordre du parcours en magasin. Reprend l'ordre qui était
## codé en dur dans la liste de courses, suivi des rayons qui n'existaient que pour
## les articles de base.
const DEFAULT_AISLES := [
	"Frais", "Fruits et Légumes", "Divers", "Asiatique", "Picard",
	"Hygiène", "Ménage", "Boulangerie", "Confiserie", FALLBACK_AISLE,
]

var _db  ## SQLite

## Chemin de la base, surchargeable par la variable d'environnement MEALPLANNER_DB.
##
## Les tests headless écrivaient dans la base RÉELLE de l'utilisateur : ils y ont déjà
## laissé des doublons de catégories et fait perdre une liste de courses. Ils tournent
## désormais sur une base jetable, ce qui les rend aussi déterministes — ils partent du
## jeu d'exemple embarqué plutôt que d'un contenu qui change à chaque synchronisation.
static func db_path() -> String:
	if ephemeral():
		return ":memory:"
	var override := OS.get_environment("MEALPLANNER_DB")
	return override if override != "" else DEFAULT_DB_PATH

## Version web : rien ne reste sur le poste. Elle sert sur un ordinateur d'emprunt, où
## laisser la base ou la session derrière soi livrerait le foyer au suivant. La base vit
## donc en mémoire, la session aussi, et le compte est le seul chemin vers les données —
## connexion obligatoire, déconnexion = page rechargée, donc tout oublié.
##
## MEALPLANNER_EPHEMERAL=1 donne le même comportement hors navigateur : c'est ce qui
## permet de l'éprouver en headless (`test_web.gd`) et sur le poste de développement.
static func ephemeral() -> bool:
	return OS.has_feature("web") or OS.get_environment("MEALPLANNER_EPHEMERAL") == "1"

func open() -> void:
	_db = SQLite.new()
	_db.path = db_path()
	_db.foreign_keys = false  # les liens sont gérés applicativement (sync = arrivées désordonnées)
	_db.open_db()
	_create_meta()
	_migrate_if_needed()
	_create_schema()
	_repair_schema()
	# Les lignes semées partagent toutes le MÊME updated_at, mémorisé en meta : c'est
	# ce qui permet ensuite de les reconnaître et de les jeter si l'appareil se
	# connecte à un compte qui a déjà des données (cf. discard_seed_rows).
	var seed_stamp := int(get_sync_meta("seed_stamp", "0"))
	if _count("recipes") == 0 or _count("staples") == 0:
		if seed_stamp == 0:
			seed_stamp = _now()
			set_sync_meta("seed_stamp", str(seed_stamp))
	if _count("recipes") == 0:
		_seed_from_json(seed_stamp)
	if _count("staples") == 0:
		_seed_staples(seed_stamp)
	if _count("aisles") == 0:
		_seed_aisles(seed_stamp)

	# Les soirs réservés étaient des indices absolus : convertis une fois pour toutes.
	migrate_transport_slots()

	# La réconciliation des homonymes tournait uniquement après un pull. Un appareil
	# qui ne synchronise pas — ou dont la synchronisation ne rapporte rien — gardait
	# donc ses doublons indéfiniment. C'est une passe sur quelques dizaines de lignes,
	# autant la faire à chaque ouverture.
	var merged := merge_duplicate_ingredients() + merge_duplicate_categories() \
		+ merge_duplicate_aisles()
	if merged > 0:
		print("LocalDatabase : %d doublon(s) de nom résorbé(s)." % merged)

# =====================================================================
# Versionnement & migration
# =====================================================================

func _create_meta() -> void:
	_db.query("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);")

func get_sync_meta(key: String, fallback: String = "") -> String:
	_db.query_with_bindings("SELECT value FROM meta WHERE key = ?;", [key])
	if _db.query_result.is_empty():
		return fallback
	return str(_db.query_result[0]["value"])

func set_sync_meta(key: String, value: String) -> void:
	_db.query_with_bindings(
		"INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?;",
		[key, value, value])

## Détecte une base au schéma v1 (ids entiers) et la convertit en v2 (UUID).
## Les tables v1 sont conservées sous le suffixe `_v1` — filet de sécurité, et rend
## la migration rejouable si elle échoue en cours de route (§3.6 du plan).
func _migrate_if_needed() -> void:
	var version := int(get_sync_meta("schema_version", "0"))
	if version >= SCHEMA_VERSION:
		return
	if not _table_exists("recipes"):
		# Base neuve : rien à migrer, le schéma v2 sera créé directement.
		set_sync_meta("schema_version", str(SCHEMA_VERSION))
		return
	# Chaque étape s'applique à toute base plus ancienne qu'elle, dans l'ordre. L'ancienne
	# forme en `if version == N` réaffectait `version` à la main : la v5 → v6, placée en
	# dernier, laissait une base ≤ v5 sauter la v6 → v7 et la v7 → v8, et cette base se
	# retrouvait marquée v8 sans `meal_slot` ni `servings` (cf. _repair_schema).
	if version < 2:
		_migrate_v1_to_v2()
	if version < 3:
		_migrate_v2_to_v3()
	if version < 4:
		_migrate_v3_to_v4()
	if version < 5:
		_migrate_v4_to_v5()
	if version < 6:
		_migrate_v5_to_v6()
	if version < 7:
		_migrate_v6_to_v7()
	if version < 8:
		_migrate_v7_to_v8()
	set_sync_meta("schema_version", str(SCHEMA_VERSION))

## Rattrape les colonnes qu'une migration sautée a laissées manquer, quelle que soit la
## version enregistrée : une base passée par l'ancienne chaîne est marquée v8 et ne
## repasserait jamais par _migrate_if_needed.
##
## Le curseur de pull de la table réparée repart de zéro. Pendant que la colonne manquait,
## chaque ligne reçue échouait à l'écriture mais le curseur avançait quand même : ces
## lignes ne reviendraient plus jamais. Un pull complet est idempotent (LWW).
func _repair_schema() -> void:
	if not _column_exists("meal_plan_positions", "meal_slot"):
		push_warning("LocalDatabase : colonne meal_slot absente, réparation…")
		_migrate_v6_to_v7()
		set_sync_meta("sync_cursor_meal_plan_positions", "0")
	if not _column_exists("recipes", "servings"):
		push_warning("LocalDatabase : colonne servings absente, réparation…")
		_migrate_v7_to_v8()
		set_sync_meta("sync_cursor_recipes", "0")

## v8 : nombre de parts par recette.
##
## Simple ajout de colonne, sans reprise : 0 se lit « autant que le foyer », donc le facteur
## d'échelle vaut 1 et aucune quantité ne bouge. Les deux comptes existants recevront la
## valeur 4 par le SQL du plan, ce qui ne change rien non plus mais rend l'information
## exploitable par un foyer d'une autre taille.
func _migrate_v7_to_v8() -> void:
	print("LocalDatabase : migration v7 → v8 (parts par recette)…")
	if not _table_exists("recipes"):
		_create_schema()
		return
	if not _column_exists("recipes", "servings"):
		_db.query("ALTER TABLE recipes ADD COLUMN servings INTEGER NOT NULL DEFAULT 0;")

func _column_exists(table: String, column: String) -> bool:
	_db.query("PRAGMA table_info(%s);" % table)
	for row in _db.query_result:
		if str(row.get("name", "")) == column:
			return true
	return false

## v7 : un second repas possible par jour.
##
## `meal_plan_positions` gagne `meal_slot` — 0 = midi ou repas unique, 1 = soir — et sa clé
## primaire devient (jour, repas). SQLite ne sait pas modifier une clé primaire : la table est
## donc recopiée. Les lignes existantes prennent `meal_slot = 0`, ce qui les laisse exactement
## où elles étaient : le jour ne change pas de numéro, et c'est tout l'objet de cette forme à
## deux coordonnées. Voir 0_plan_1.8.0.md, piège 2.
##
## Les colonnes de synchronisation sont recopiées telles quelles : une ligne déjà poussée reste
## propre, une ligne en attente le reste aussi.
func _migrate_v6_to_v7() -> void:
	print("LocalDatabase : migration v6 → v7 (un second repas par jour)…")
	if not _table_exists("meal_plan_positions"):
		_create_schema()
		return
	# Table recréée par une étape antérieure (la v1 → v2 la crée déjà à deux coordonnées) :
	# la recopier écraserait les soirs sur les midis.
	if _column_exists("meal_plan_positions", "meal_slot"):
		return
	_db.query("DROP TABLE IF EXISTS meal_plan_positions_v6;")
	_db.query("ALTER TABLE meal_plan_positions RENAME TO meal_plan_positions_v6;")
	_create_schema()
	_db.query("""
		INSERT INTO meal_plan_positions
			(position_index, meal_slot, recipe_id, custom_label, updated_at, deleted_at, dirty)
		SELECT position_index, 0, recipe_id, custom_label, updated_at, deleted_at, dirty
		FROM meal_plan_positions_v6;""")
	_db.query("DROP TABLE meal_plan_positions_v6;")

## v6 : photos de recettes. Rien à reprendre — la table est simplement créée, vide.
func _migrate_v5_to_v6() -> void:
	print("LocalDatabase : migration v5 → v6 (photos de recettes)…")
	_create_schema()

## v5 : réglages du foyer en base, à commencer par le marqueur de transport.
##
## Le mécanisme est activé si des recettes portent déjà le marqueur — un foyer qui
## s'en sert ne voit donc aucun changement, et une installation neuve démarre sans
## cette notion.
func _migrate_v4_to_v5() -> void:
	print("LocalDatabase : migration v4 → v5 (réglages du foyer)…")
	_create_schema()
	_db.query("SELECT COUNT(*) AS n FROM recipes WHERE nobox = 1 AND deleted_at IS NULL;")
	var uses_marker := int(_db.query_result[0]["n"]) > 0
	set_setting(SETTING_TRANSPORT_ENABLED, "1" if uses_marker else "0")
	set_setting(SETTING_TRANSPORT_SLOTS, DEFAULT_TRANSPORT_WEEKDAYS)
	print("LocalDatabase : marqueur de transport %s." % ["désactivé", "activé"][int(uses_marker)])

## v4 : les rayons deviennent une donnée ordonnée et modifiable, au lieu de trois
## listes codées en dur qui avaient déjà divergé (liste de courses, articles de base,
## et une troisième déduite des ingrédients existants).
func _migrate_v3_to_v4() -> void:
	print("LocalDatabase : migration v3 → v4 (rayons personnalisables)…")
	_create_schema()

	# « Autre » n'existait que pour les articles de base, « Autres » ailleurs : deux
	# orthographes pour le même rayon de repli.
	_db.query_with_bindings("UPDATE staples SET aisle = ? WHERE aisle = 'Autre';", [FALLBACK_AISLE])

	var names: Array[String] = []
	for name in DEFAULT_AISLES:
		names.append(str(name))
	# Tout rayon déjà utilisé mais absent des valeurs par défaut est conservé : on ne
	# perd pas un rayon que l'utilisateur avait saisi à la main.
	for table in ["ingredients", "staples"]:
		_db.query("SELECT DISTINCT aisle FROM %s WHERE deleted_at IS NULL;" % table)
		for row in _db.query_result:
			var found := str(row["aisle"]).strip_edges()
			if found != "" and not names.has(found):
				names.insert(names.size() - 1, found)   # avant « Autres », qui reste dernier

	var now := _now()
	for index in range(names.size()):
		_db.query_with_bindings(
			"INSERT INTO aisles (id, name, sort_order, updated_at) VALUES (?, ?, ?, ?);",
			[Uuid.v4(), names[index], index, now])
	print("LocalDatabase : %d rayons initialisés." % names.size())

## v3 : lève la contrainte UNIQUE sur ingredients.name et categories.name.
## SQLite ne sait pas supprimer une contrainte : il faut reconstruire la table.
func _migrate_v2_to_v3() -> void:
	print("LocalDatabase : migration v2 → v3 (levée des contraintes UNIQUE de nom)…")
	for t in ["ingredients", "categories"]:
		if not _table_exists(t):
			continue
		_db.query("SELECT * FROM %s;" % t)
		var rows: Array = _db.query_result.duplicate(true)
		_db.query("DROP TABLE %s;" % t)
		_create_schema()
		for row in rows:
			var columns: Array = row.keys()
			var placeholders := ",".join(columns.map(func(_c): return "?"))
			_db.query_with_bindings(
				"INSERT INTO %s (%s) VALUES (%s);" % [t, ",".join(columns), placeholders],
				row.values())

func _table_exists(name: String) -> bool:
	_db.query_with_bindings(
		"SELECT name FROM sqlite_master WHERE type='table' AND name = ?;", [name])
	return not _db.query_result.is_empty()

func _migrate_v1_to_v2() -> void:
	print("LocalDatabase : migration du schéma v1 (ids entiers) → v2 (UUID)…")

	# 1. Tout relire en mémoire (jeu de données de l'ordre de la centaine de lignes).
	var old := {}
	for t in ["recipes", "ingredients", "categories", "breakfasts", "staples",
			"recipe_ingredients", "recipe_categories", "breakfast_ingredients"]:
		if _table_exists(t):
			_db.query("SELECT * FROM %s;" % t)
			old[t] = _db.query_result.duplicate(true)
		else:
			old[t] = []

	# 2. Une correspondance ancien entier → nouvel UUID, par table.
	var ids := {}
	for t in ["recipes", "ingredients", "categories", "breakfasts", "staples"]:
		var m := {}
		for row in old[t]:
			m[int(row["id"])] = Uuid.v4()
		ids[t] = m

	# 3. Ranger les tables v1 de côté plutôt que les supprimer.
	for t in ["recipes", "ingredients", "categories", "breakfasts", "staples",
			"recipe_ingredients", "recipe_categories", "breakfast_ingredients"]:
		if _table_exists(t):
			_db.query("DROP TABLE IF EXISTS %s_v1;" % t)
			_db.query("ALTER TABLE %s RENAME TO %s_v1;" % [t, t])

	_create_schema()

	# 4. Réinsérer. Les updated_at v1 sont en secondes → × 1000.
	#    dirty = 1 partout : cette base n'a jamais été synchronisée, tout est à pousser.
	for row in old["ingredients"]:
		_db.query_with_bindings(
			"""INSERT INTO ingredients (id, name, aisle, updated_at, deleted_at, dirty)
			   VALUES (?, ?, ?, ?, ?, 1);""",
			[ids["ingredients"][int(row["id"])], row["name"], row.get("aisle", "Divers"),
			_ms(row.get("updated_at", 0)), _ms_or_null(row.get("deleted_at"))])

	for row in old["categories"]:
		_db.query_with_bindings(
			"INSERT INTO categories (id, name, updated_at, deleted_at, dirty) VALUES (?, ?, ?, NULL, 1);",
			[ids["categories"][int(row["id"])], row["name"], _now()])

	for row in old["recipes"]:
		_db.query_with_bindings(
			"""INSERT INTO recipes (id, name, season, nobox, steps, updated_at, deleted_at, dirty)
			   VALUES (?, ?, ?, ?, ?, ?, ?, 1);""",
			[ids["recipes"][int(row["id"])], row["name"], row.get("season", "toute"),
			int(row.get("nobox", 0)), row.get("steps", ""),
			_ms(row.get("updated_at", 0)), _ms_or_null(row.get("deleted_at"))])

	for row in old["breakfasts"]:
		_db.query_with_bindings(
			"""INSERT INTO breakfasts (id, name, updated_at, deleted_at, dirty)
			   VALUES (?, ?, ?, ?, 1);""",
			[ids["breakfasts"][int(row["id"])], row["name"],
			_ms(row.get("updated_at", 0)), _ms_or_null(row.get("deleted_at"))])

	for row in old["staples"]:
		_db.query_with_bindings(
			"""INSERT INTO staples (id, name, aisle, quantity, unit, updated_at, deleted_at, dirty)
			   VALUES (?, ?, ?, ?, ?, ?, ?, 1);""",
			[ids["staples"][int(row["id"])], row["name"], row.get("aisle", "Autres"),
			float(row.get("quantity", 1)), row.get("unit", ""),
			_ms(row.get("updated_at", 0)), _ms_or_null(row.get("deleted_at"))])

	# Tables filles : on ignore silencieusement les liens orphelins (ids absents des maps).
	for row in old["recipe_ingredients"]:
		var rid = ids["recipes"].get(int(row["recipe_id"]))
		var iid = ids["ingredients"].get(int(row["ingredient_id"]))
		if rid == null or iid == null:
			continue
		_db.query_with_bindings(
			"""INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit)
			   VALUES (?, ?, ?, ?);""",
			[rid, iid, float(row.get("quantity", 0)), row.get("unit", "")])

	for row in old["recipe_categories"]:
		var rid2 = ids["recipes"].get(int(row["recipe_id"]))
		var cid = ids["categories"].get(int(row["category_id"]))
		if rid2 == null or cid == null:
			continue
		_db.query_with_bindings(
			"INSERT INTO recipe_categories (recipe_id, category_id) VALUES (?, ?);", [rid2, cid])

	for row in old["breakfast_ingredients"]:
		var bid = ids["breakfasts"].get(int(row["breakfast_id"]))
		var iid2 = ids["ingredients"].get(int(row["ingredient_id"]))
		if bid == null or iid2 == null:
			continue
		_db.query_with_bindings(
			"""INSERT INTO breakfast_ingredients (breakfast_id, ingredient_id, quantity, unit)
			   VALUES (?, ?, ?, ?);""",
			[bid, iid2, float(row.get("quantity", 0)), row.get("unit", "")])

	print("LocalDatabase : migration v1→v2 terminée (%d recettes, %d ingrédients). "
		% [old["recipes"].size(), old["ingredients"].size()]
		+ "Tables d'origine conservées sous le suffixe _v1.")

## Secondes (v1) → millisecondes (v2). Tolère une valeur déjà en ms.
func _ms(value) -> int:
	var v := int(value)
	if v <= 0:
		return _now()
	return v * 1000 if v < 100000000000 else v

func _ms_or_null(value):
	if value == null:
		return null
	var v := int(value)
	return null if v <= 0 else _ms(v)

# =====================================================================
# Schéma v2
# =====================================================================

func _create_schema() -> void:
	_db.query("""
		CREATE TABLE IF NOT EXISTS recipes (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			season TEXT DEFAULT 'toute',
			nobox INTEGER DEFAULT 0,
			steps TEXT DEFAULT '',
			servings INTEGER NOT NULL DEFAULT 0,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS ingredients (
			id TEXT PRIMARY KEY,
			-- Pas de UNIQUE sur name : deux appareils hors-ligne peuvent créer le même
			-- nom d'ingrédient avec des UUID différents. La contrainte ferait échouer le
			-- pull de façon définitive (chaque sync rejouerait la même violation). Les
			-- doublons de nom sont réconciliés après coup par SyncEngine.
			name TEXT NOT NULL,
			aisle TEXT DEFAULT 'Divers',
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS categories (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,   -- idem ingredients : pas de UNIQUE, cf. ci-dessus
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS aisles (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			-- Rang de parcours en magasin : c'est l'intérêt principal de la
			-- personnalisation, bien plus que les noms eux-mêmes.
			sort_order INTEGER DEFAULT 0,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS settings (
			key TEXT PRIMARY KEY,
			value TEXT DEFAULT '',
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS breakfasts (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS staples (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			aisle TEXT DEFAULT 'Autres',
			quantity REAL DEFAULT 1,
			unit TEXT DEFAULT '',
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")

	# --- Tables filles de l'agrégat (pas de colonnes de sync : suivent le parent) ---
	_db.query("""
		CREATE TABLE IF NOT EXISTS recipe_ingredients (
			recipe_id TEXT, ingredient_id TEXT, quantity REAL DEFAULT 0, unit TEXT DEFAULT ''
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS recipe_categories (
			recipe_id TEXT, category_id TEXT
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS breakfast_ingredients (
			breakfast_id TEXT, ingredient_id TEXT, quantity REAL DEFAULT 0, unit TEXT DEFAULT ''
		);""")

	# --- État applicatif synchronisé (remplace les JSON de user://) ---
	# Clé naturelle sur la position : deux appareils convergent sur la même ligne
	# sans coordination d'id, donc réarranger des cases différentes fusionne.
	_db.query("""
		CREATE TABLE IF NOT EXISTS meal_plan_positions (
			position_index INTEGER NOT NULL,
			meal_slot INTEGER NOT NULL DEFAULT 0,
			recipe_id TEXT,
			custom_label TEXT DEFAULT '',
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1,
			PRIMARY KEY (position_index, meal_slot)
		);""")
	_db.query("""
		CREATE TABLE IF NOT EXISTS breakfast_slots (
			slot INTEGER PRIMARY KEY,
			breakfast_id TEXT,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	# item_key : clé stable dérivée du nom + unité normalisés, pour que deux appareils
	# générant la même liste produisent les mêmes clés (cf. ShoppingListService).
	_db.query("""
		CREATE TABLE IF NOT EXISTS shopping_items (
			item_key TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			aisle TEXT DEFAULT 'Autres',
			quantity REAL DEFAULT 0,
			unit TEXT DEFAULT '',
			checked INTEGER DEFAULT 0,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")

	# Photos dans leur PROPRE table, et non en colonne de `recipes` : `fetch_all_recipes`
	# fait un SELECT * rejoué à chaque écriture, qui traînerait alors plusieurs mégaoctets
	# d'images en mémoire à chaque ajout d'ingrédient.
	#
	# Images stockées en base64 plutôt qu'en BLOB : c'est la forme sous laquelle elles
	# voyagent de toute façon (PostgREST échange du JSON), et l'éviter imposerait un
	# encodage/décodage à chaque cycle de synchronisation. Le surcoût de 33 % sur le
	# disque est le prix d'un moteur de sync qui n'a aucun cas particulier à connaître.
	_db.query("""
		CREATE TABLE IF NOT EXISTS recipe_photos (
			-- La recette elle-même est la clé : une photo par recette, et la ligne
			-- disparaît avec elle.
			recipe_id TEXT PRIMARY KEY,
			-- JPEG, côté long ramené à PHOTO_MAX_SIDE.
			image TEXT NOT NULL,
			-- Vignette carrée PHOTO_THUMB_SIDE, stockée et non recalculée : les listes
			-- l'affichent des dizaines de fois par écran, redimensionner à chaque
			-- affichage se verrait au défilement.
			thumb TEXT NOT NULL,
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")

	_db.query("CREATE INDEX IF NOT EXISTS recipe_ingredients_idx ON recipe_ingredients (recipe_id);")
	_db.query("CREATE INDEX IF NOT EXISTS recipe_categories_idx ON recipe_categories (recipe_id);")
	_db.query("CREATE INDEX IF NOT EXISTS breakfast_ingredients_idx ON breakfast_ingredients (breakfast_id);")
	for t in SYNCED_TABLES:
		_db.query("CREATE INDEX IF NOT EXISTS %s_dirty_idx ON %s (dirty);" % [t, t])

# =====================================================================
# Amorçage
# =====================================================================

## Articles de base par défaut : volontairement génériques (produits d'entretien et
## fonds de placard courants). L'ancienne liste, héritée de _add_basic_items côté
## Python, contenait des produits d'hygiène très personnels, qui n'ont pas à être
## embarqués dans une application distribuée. La liste est de toute façon éditable
## depuis Paramètres > Articles de base.
func _seed_staples(seed_stamp: int) -> void:
	var defaults := [
		["Papier WC", "Ménage", 1, ""], ["Sopalin", "Ménage", 1, ""],
		["Mouchoirs", "Ménage", 1, ""], ["Produit vaisselle", "Ménage", 1, ""],
		["Lessive", "Ménage", 1, ""], ["Vinaigre blanc", "Ménage", 1, ""],
		["Savon main", "Ménage", 1, ""],
		["Farine", "Boulangerie", 1, "kg"], ["Sucre", "Boulangerie", 1, "kg"],
		["Levure", "Boulangerie", 1, ""],
		["Huile d'olive", "Divers", 1, ""], ["Sel", "Divers", 1, ""],
		["Poivre", "Divers", 1, ""], ["Café", "Divers", 1, ""],
	]
	for s in defaults:
		_db.query_with_bindings(
			"INSERT INTO staples (id, name, aisle, quantity, unit, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
			[Uuid.v4(), s[0], s[1], float(s[2]), s[3], seed_stamp])
	print("LocalDatabase : articles de base semés.")

## Le seed JSON porte encore les ids entiers de l'ancienne base `recettes.db` : ils ne
## servent qu'à relier recettes et ingrédients dans le fichier, et sont convertis en
## UUID à l'insertion. Inutile donc de régénérer le seed.
func _seed_from_json(seed_stamp: int) -> void:
	if not FileAccess.file_exists(SEED_PATH):
		push_warning("LocalDatabase: seed introuvable, base vide.")
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(SEED_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return

	var now := seed_stamp
	var ing_ids := {}   # id entier du seed -> UUID
	for ing in data.get("ingredients", []):
		var uid: String = Uuid.v4()
		ing_ids[int(ing["id"])] = uid
		_db.query_with_bindings(
			"INSERT OR IGNORE INTO ingredients (id, name, aisle, updated_at) VALUES (?, ?, ?, ?);",
			[uid, ing["name"], ing.get("aisle", "Divers"), now])

	for cat in data.get("categories", []):
		_category_id(str(cat), now)

	for r in data.get("recipes", []):
		var rid: String = Uuid.v4()
		_db.query_with_bindings(
			"INSERT INTO recipes (id, name, season, nobox, steps, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
			[rid, r["name"], r.get("season", "toute"),
			1 if r.get("nobox", false) else 0, r.get("steps", ""), now])
		for ing in r.get("ingredients", []):
			var iid = ing_ids.get(int(ing["ingredient_id"]))
			if iid == null:
				continue
			_db.query_with_bindings(
				"INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit) VALUES (?, ?, ?, ?);",
				[rid, iid, float(ing.get("quantity", 0)), ing.get("unit", "")])
		for cat_name in r.get("categories", []):
			_db.query_with_bindings(
				"INSERT INTO recipe_categories (recipe_id, category_id) VALUES (?, ?);",
				[rid, _category_id(str(cat_name), now)])
	print("LocalDatabase semée depuis le seed JSON.")

func _seed_aisles(seed_stamp: int) -> void:
	for index in range(DEFAULT_AISLES.size()):
		_db.query_with_bindings(
			"INSERT INTO aisles (id, name, sort_order, updated_at) VALUES (?, ?, ?, ?);",
			[Uuid.v4(), DEFAULT_AISLES[index], index, seed_stamp])

# =====================================================================
# Réglages du foyer
# =====================================================================

func get_setting(key: String, fallback: String = "") -> String:
	_db.query_with_bindings(
		"SELECT value FROM settings WHERE key = ? AND deleted_at IS NULL;", [key])
	if _db.query_result.is_empty():
		return fallback
	return str(_db.query_result[0]["value"])

# ===== Forme du planning : lecture et écriture =====

## Nombre de semaines couvertes par le planning, borné à 1..4.
## Convertit les soirs réservés de l'ancien format — indices absolus — vers des couples
## « jour:repas ». Sans effet si c'est déjà fait.
##
## La conversion emploie le jour de début COURANT, qui est le même que celui sous lequel les
## indices avaient été écrits : la 1.7 n'en connaissait pas d'autre. Deux appareils qui la
## jouent chacun de leur côté aboutissent donc au même résultat, ce qui est nécessaire puisque
## ce réglage est synchronisé.
func migrate_transport_slots() -> bool:
	var raw := get_setting(SETTING_TRANSPORT_SLOTS, "")
	if raw == "" or raw.contains(":"):
		return false   # rien à convertir, ou déjà converti
	var start := plan_week_start()
	var weekdays := {}
	for piece in raw.split(",", false):
		var index := int(piece.strip_edges())
		if index < 0:
			continue
		weekdays[posmod(start + index, 7)] = true
	var marks: Array[String] = []
	var ordered: Array = weekdays.keys()
	ordered.sort()
	for weekday in ordered:
		# Repas 0 : la 1.7 n'avait qu'un repas par jour. L'étape 4 distinguera midi et soir.
		marks.append("%d:0" % weekday)
	set_setting(SETTING_TRANSPORT_SLOTS, ",".join(marks))
	print("LocalDatabase : soirs réservés convertis « %s » → « %s »." % [raw, ",".join(marks)])
	return true

func plan_weeks() -> int:
	return clampi(int(get_setting(SETTING_PLAN_WEEKS, str(DEFAULT_PLAN_WEEKS))),
		PLAN_WEEKS_MIN, PLAN_WEEKS_MAX)

## Jour où commence la semaine de planning. Lundi = 0.
func plan_week_start() -> int:
	return posmod(int(get_setting(SETTING_PLAN_WEEK_START, str(DEFAULT_PLAN_WEEK_START))), 7)

func plan_meals_per_day() -> int:
	return clampi(int(get_setting(SETTING_PLAN_MEALS_PER_DAY,
		str(DEFAULT_PLAN_MEALS_PER_DAY))), 1, PLAN_MEALS_MAX)

## Nombre de JOURS du planning. Distinct du nombre de cases, qui compte les repas.
func plan_day_count() -> int:
	return plan_weeks() * 7

## Nombre de CASES du planning : un ou deux repas par jour.
func plan_slot_count() -> int:
	return plan_day_count() * plan_meals_per_day()

func household_servings() -> int:
	return maxi(1, int(get_setting(SETTING_HOUSEHOLD_SERVINGS,
		str(DEFAULT_HOUSEHOLD_SERVINGS))))

func onboarding_done() -> bool:
	return get_setting(SETTING_ONBOARDING_DONE, "0") == "1"

## Jour de la semaine (lundi = 0) du n-ième jour du planning.
func plan_weekday_of(day_index: int) -> int:
	return posmod(plan_week_start() + day_index, 7)

func set_setting(key: String, value: String) -> void:
	var now := _now()
	_db.query_with_bindings("""
		INSERT INTO settings (key, value, updated_at, deleted_at, dirty)
		VALUES (?, ?, ?, NULL, 1)
		ON CONFLICT(key) DO UPDATE
		SET value = ?, updated_at = ?, deleted_at = NULL, dirty = 1;""",
		[key, value, now, value, now])

# =====================================================================
# Rayons
# =====================================================================

## Rayons vivants, dans l'ordre de parcours.
func fetch_aisles() -> Array[Dictionary]:
	_db.query("SELECT * FROM aisles WHERE deleted_at IS NULL ORDER BY sort_order, name;")
	var out: Array[Dictionary] = []
	for row in _db.query_result:
		out.append({"id": str(row["id"]), "name": str(row["name"]),
			"sort_order": int(row["sort_order"])})
	return out

func insert_aisle(name: String) -> String:
	_db.query("SELECT COALESCE(MAX(sort_order), -1) AS m FROM aisles;")
	var next_order := int(_db.query_result[0]["m"]) + 1
	var aid: String = Uuid.v4()
	_db.query_with_bindings(
		"INSERT INTO aisles (id, name, sort_order, updated_at) VALUES (?, ?, ?, ?);",
		[aid, name, next_order, _now()])
	return aid

## Renomme un rayon ET reporte le nouveau nom sur tout ce qui le référence.
##
## Les ingrédients, articles de base et articles de courses stockent le NOM du rayon,
## pas son identifiant — même parti pris que pour les catégories de recettes, qui
## voyagent aussi par nom dans la synchronisation. Sans ce report, renommer laisserait
## tout le contenu rattaché à un rayon qui n'existe plus.
func rename_aisle(aisle_id: String, new_name: String) -> void:
	var row := fetch_row("aisles", "id", aisle_id)
	if row.is_empty():
		return
	var old_name := str(row["name"])
	if old_name == new_name:
		return
	var now := _now()
	_db.query_with_bindings(
		"UPDATE aisles SET name=?, updated_at=?, dirty=1 WHERE id=?;", [new_name, now, aisle_id])
	for table in ["ingredients", "staples", "shopping_items"]:
		_db.query_with_bindings(
			"UPDATE %s SET aisle=?, updated_at=?, dirty=1 WHERE aisle=?;" % table,
			[new_name, now, old_name])

## Supprime un rayon et rattache son contenu au rayon de repli : un ingrédient sans
## rayon valide disparaîtrait de la liste de courses.
func delete_aisle(aisle_id: String) -> void:
	var row := fetch_row("aisles", "id", aisle_id)
	if row.is_empty():
		return
	var name := str(row["name"])
	if name == FALLBACK_AISLE:
		return   # le rayon de repli ne peut pas être supprimé
	var now := _now()
	for table in ["ingredients", "staples", "shopping_items"]:
		_db.query_with_bindings(
			"UPDATE %s SET aisle=?, updated_at=?, dirty=1 WHERE aisle=?;" % table,
			[FALLBACK_AISLE, now, name])
	_soft_delete("aisles", "id", aisle_id)

## Réécrit l'ordre de parcours à partir d'une liste ordonnée d'identifiants.
func reorder_aisles(ordered_ids: Array) -> void:
	var now := _now()
	for index in range(ordered_ids.size()):
		_db.query_with_bindings(
			"UPDATE aisles SET sort_order=?, updated_at=?, dirty=1 WHERE id=?;",
			[index, now, str(ordered_ids[index])])

# =====================================================================
# Lectures
# =====================================================================

func fetch_all_recipes() -> Array[Recipe]:
	_db.query("SELECT * FROM recipes WHERE deleted_at IS NULL ORDER BY name;")
	var rows: Array = _db.query_result.duplicate()
	var out: Array[Recipe] = []
	for row in rows:
		out.append(_build_recipe(row))
	return out

func fetch_recipe_by_name(recipe_name: String) -> Recipe:
	_db.query_with_bindings("SELECT * FROM recipes WHERE name = ? AND deleted_at IS NULL LIMIT 1;", [recipe_name])
	if _db.query_result.is_empty():
		return null
	return _build_recipe(_db.query_result[0])

func fetch_all_ingredients() -> Array[Ingredient]:
	_db.query("SELECT * FROM ingredients WHERE deleted_at IS NULL ORDER BY name;")
	var out: Array[Ingredient] = []
	for row in _db.query_result:
		var ing := Ingredient.new()
		ing.id = str(row["id"])
		ing.nom = str(row["name"])
		ing.aisle = str(row["aisle"])
		out.append(ing)
	return out

func fetch_all_categories() -> Array[String]:
	_db.query("SELECT name FROM categories WHERE deleted_at IS NULL ORDER BY name;")
	var out: Array[String] = []
	for row in _db.query_result:
		out.append(str(row["name"]))
	return out

func _build_recipe(row: Dictionary) -> Recipe:
	var r := Recipe.new()
	r.id = str(row["id"])
	r.nom = str(row["name"])
	r.saison = str(row["season"])
	r.nobox = int(row["nobox"]) != 0
	r.etapes = str(row["steps"])
	r.servings = int(row.get("servings", 0))
	# Ingrédients
	_db.query_with_bindings("""
		SELECT i.id, i.name, i.aisle, ri.quantity, ri.unit
		FROM recipe_ingredients ri JOIN ingredients i ON ri.ingredient_id = i.id
		WHERE ri.recipe_id = ?;""", [r.id])
	var ings: Array[Ingredient] = []
	for irow in _db.query_result:
		var ing := Ingredient.new()
		ing.id = str(irow["id"])
		ing.nom = str(irow["name"])
		ing.aisle = str(irow["aisle"])
		ing.quantite = float(irow["quantity"])
		ing.unite = str(irow["unit"])
		ings.append(ing)
	r.ingredients = ings
	# Catégories
	_db.query_with_bindings("""
		SELECT c.name FROM recipe_categories rc JOIN categories c ON rc.category_id = c.id
		WHERE rc.recipe_id = ?;""", [r.id])
	var cats: Array[String] = []
	for crow in _db.query_result:
		cats.append(str(crow["name"]))
	r.categories = cats
	return r

# ===== Petits déjeuners (lecture) =====

func fetch_all_breakfasts() -> Array[Breakfast]:
	_db.query("SELECT * FROM breakfasts WHERE deleted_at IS NULL ORDER BY name;")
	var rows: Array = _db.query_result.duplicate()
	var out: Array[Breakfast] = []
	for row in rows:
		out.append(_build_breakfast(row))
	return out

func fetch_breakfast_by_name(name: String) -> Breakfast:
	_db.query_with_bindings("SELECT * FROM breakfasts WHERE name = ? AND deleted_at IS NULL LIMIT 1;", [name])
	if _db.query_result.is_empty():
		return null
	return _build_breakfast(_db.query_result[0])

func _build_breakfast(row: Dictionary) -> Breakfast:
	var b := Breakfast.new()
	b.id = str(row["id"])
	b.nom = str(row["name"])
	_db.query_with_bindings("""
		SELECT i.id, i.name, i.aisle, bi.quantity, bi.unit
		FROM breakfast_ingredients bi JOIN ingredients i ON bi.ingredient_id = i.id
		WHERE bi.breakfast_id = ?;""", [b.id])
	var ings: Array[Ingredient] = []
	for irow in _db.query_result:
		var ing := Ingredient.new()
		ing.id = str(irow["id"])
		ing.nom = str(irow["name"])
		ing.aisle = str(irow["aisle"])
		ing.quantite = float(irow["quantity"])
		ing.unite = str(irow["unit"])
		ings.append(ing)
	b.ingredients = ings
	return b

# ===== Petits déjeuners (écriture) =====

func insert_breakfast(b: Breakfast) -> String:
	var bid: String = Uuid.v4() if b.id == "" else b.id
	_db.query_with_bindings(
		"INSERT INTO breakfasts (id, name, updated_at) VALUES (?, ?, ?);", [bid, b.nom, _now()])
	_write_breakfast_links(bid, b)
	return bid

func update_breakfast(b: Breakfast) -> void:
	_db.query_with_bindings(
		"UPDATE breakfasts SET name=?, updated_at=?, dirty=1 WHERE id=?;", [b.nom, _now(), b.id])
	_db.query_with_bindings("DELETE FROM breakfast_ingredients WHERE breakfast_id=?;", [b.id])
	_write_breakfast_links(b.id, b)

func delete_breakfast(breakfast_id: String) -> void:
	_soft_delete("breakfasts", "id", breakfast_id)

func _write_breakfast_links(breakfast_id: String, b: Breakfast) -> void:
	for ing in b.ingredients:
		var iid := _ingredient_id(ing.nom, ing.aisle)
		_db.query_with_bindings(
			"INSERT INTO breakfast_ingredients (breakfast_id, ingredient_id, quantity, unit) VALUES (?, ?, ?, ?);",
			[breakfast_id, iid, ing.quantite, ing.unite])

# ===== Articles de base (staples) — réutilise le modèle Ingredient =====

func fetch_all_staples() -> Array[Ingredient]:
	_db.query("SELECT * FROM staples WHERE deleted_at IS NULL ORDER BY aisle, name;")
	var out: Array[Ingredient] = []
	for row in _db.query_result:
		var ing := Ingredient.new()
		ing.id = str(row["id"])
		ing.nom = str(row["name"])
		ing.aisle = str(row["aisle"])
		ing.quantite = float(row["quantity"])
		ing.unite = str(row["unit"])
		out.append(ing)
	return out

func insert_staple(ing: Ingredient) -> String:
	var sid: String = Uuid.v4() if ing.id == "" else ing.id
	_db.query_with_bindings(
		"INSERT INTO staples (id, name, aisle, quantity, unit, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
		[sid, ing.nom, ing.aisle, ing.quantite, ing.unite, _now()])
	return sid

func update_staple(ing: Ingredient) -> void:
	_db.query_with_bindings(
		"UPDATE staples SET name=?, aisle=?, quantity=?, unit=?, updated_at=?, dirty=1 WHERE id=?;",
		[ing.nom, ing.aisle, ing.quantite, ing.unite, _now(), ing.id])

func delete_staple(staple_id: String) -> void:
	_soft_delete("staples", "id", staple_id)

# ===== Recettes (écriture) =====

func insert_recipe(recipe: Recipe) -> String:
	var rid: String = Uuid.v4() if recipe.id == "" else recipe.id
	_db.query_with_bindings(
		"INSERT INTO recipes (id, name, season, nobox, steps, servings, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[rid, recipe.nom, recipe.saison, 1 if recipe.nobox else 0, recipe.etapes,
		maxi(0, recipe.servings), _now()])
	_write_recipe_links(rid, recipe)
	return rid

func update_recipe(recipe: Recipe) -> void:
	_db.query_with_bindings(
		"UPDATE recipes SET name=?, season=?, nobox=?, steps=?, servings=?, updated_at=?, dirty=1 WHERE id=?;",
		[recipe.nom, recipe.saison, 1 if recipe.nobox else 0, recipe.etapes,
		maxi(0, recipe.servings), _now(), recipe.id])
	_db.query_with_bindings("DELETE FROM recipe_ingredients WHERE recipe_id=?;", [recipe.id])
	_db.query_with_bindings("DELETE FROM recipe_categories WHERE recipe_id=?;", [recipe.id])
	_write_recipe_links(recipe.id, recipe)

func delete_recipe(recipe_id: String) -> void:
	_soft_delete("recipes", "id", recipe_id)
	# La photo suit la recette, et par tombstone : sans quoi elle resterait sur le
	# serveur, et le prochain appareil à se synchroniser la retéléchargerait pour une
	# recette qui n'existe plus. Sans effet si la recette n'en avait pas.
	_soft_delete("recipe_photos", "recipe_id", recipe_id)

# =====================================================================
# Photos de recettes
# =====================================================================

## Toutes les vignettes en un aller-retour : `{recipe_id: base64}`. Les listes en
## affichent des dizaines à la fois ; les demander une par une multiplierait les
## requêtes à chaque reconstruction de la bibliothèque.
func fetch_photo_thumbs() -> Dictionary:
	_db.query("SELECT recipe_id, thumb FROM recipe_photos WHERE deleted_at IS NULL;")
	var out := {}
	for row in _db.query_result:
		out[str(row["recipe_id"])] = str(row["thumb"])
	return out

## Image pleine d'une recette, "" si elle n'en a pas. Chargée à la demande et jamais
## avec le reste : c'est la seule donnée de l'application qui se compte en centaines
## de kilooctets.
func fetch_photo(recipe_id: String) -> String:
	_db.query_with_bindings(
		"SELECT image FROM recipe_photos WHERE recipe_id=? AND deleted_at IS NULL;", [recipe_id])
	if _db.query_result.is_empty():
		return ""
	return str(_db.query_result[0]["image"])

func has_photo(recipe_id: String) -> bool:
	_db.query_with_bindings(
		"SELECT 1 AS n FROM recipe_photos WHERE recipe_id=? AND deleted_at IS NULL;", [recipe_id])
	return not _db.query_result.is_empty()

func upsert_photo(recipe_id: String, image_b64: String, thumb_b64: String) -> void:
	var now := _now()
	_db.query_with_bindings("""
		INSERT INTO recipe_photos (recipe_id, image, thumb, updated_at, deleted_at, dirty)
		VALUES (?, ?, ?, ?, NULL, 1)
		ON CONFLICT(recipe_id) DO UPDATE
		SET image=?, thumb=?, updated_at=?, deleted_at=NULL, dirty=1;""",
		[recipe_id, image_b64, thumb_b64, now, image_b64, thumb_b64, now])

func delete_photo(recipe_id: String) -> void:
	_soft_delete("recipe_photos", "recipe_id", recipe_id)

func _write_recipe_links(recipe_id: String, recipe: Recipe) -> void:
	for ing in recipe.ingredients:
		var iid := _ingredient_id(ing.nom, ing.aisle)
		_db.query_with_bindings(
			"INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit) VALUES (?, ?, ?, ?);",
			[recipe_id, iid, ing.quantite, ing.unite])
	for cat_name in recipe.categories:
		if str(cat_name).strip_edges() == "":
			continue
		_db.query_with_bindings(
			"INSERT INTO recipe_categories (recipe_id, category_id) VALUES (?, ?);",
			[recipe_id, _category_id(cat_name)])

# ===== Ingrédients (écriture) =====

func insert_ingredient(name: String, aisle: String) -> String:
	# Réactive un éventuel tombstone du même nom, sinon insère. Même précaution que
	# pour les catégories : rapprochement au critère de la fusion (casse et espaces
	# ignorés), et une ligne vivante prime sur un tombstone.
	_db.query_with_bindings("""
		SELECT id FROM ingredients WHERE LOWER(TRIM(name)) = LOWER(TRIM(?))
		ORDER BY (deleted_at IS NULL) DESC, id LIMIT 1;""", [name])
	if not _db.query_result.is_empty():
		var existing := str(_db.query_result[0]["id"])
		_db.query_with_bindings(
			"UPDATE ingredients SET aisle=?, deleted_at=NULL, updated_at=?, dirty=1 WHERE id=?;",
			[aisle, _now(), existing])
		return existing
	var iid: String = Uuid.v4()
	_db.query_with_bindings("INSERT INTO ingredients (id, name, aisle, updated_at) VALUES (?, ?, ?, ?);",
		[iid, name, aisle, _now()])
	return iid

func update_ingredient(ing: Ingredient) -> void:
	_db.query_with_bindings("UPDATE ingredients SET name=?, aisle=?, updated_at=?, dirty=1 WHERE id=?;",
		[ing.nom, ing.aisle, _now(), ing.id])

func delete_ingredient_by_name(name: String) -> void:
	_db.query_with_bindings("""
		DELETE FROM recipe_ingredients WHERE ingredient_id IN
		(SELECT id FROM ingredients WHERE name = ?);""", [name])
	_soft_delete("ingredients", "name", name)

# =====================================================================
# État applicatif synchronisé : planning, slots petit déj, liste de courses
# =====================================================================

## Le planning est stocké **par position** (14 lignes indépendantes) et non comme un
## document unique : réarranger des cases différentes sur deux appareils fusionne
## alors proprement, seule une même case éditée des deux côtés applique LWW (§3.4.1).
## Cases du planning, indexées par (jour, repas). Les deux coordonnées sont nécessaires depuis
## la v7 : un jour peut porter deux repas, et le jour ne doit pas changer de numéro pour
## autant.
func fetch_plan_positions() -> Dictionary:
	_db.query("SELECT * FROM meal_plan_positions WHERE deleted_at IS NULL;")
	var out := {}
	for row in _db.query_result:
		out[Vector2i(int(row["position_index"]), int(row["meal_slot"]))] = {
			"recipe_id": str(row["recipe_id"]) if row["recipe_id"] != null else "",
			"custom_label": str(row["custom_label"]),
		}
	return out

func set_plan_position(index: int, meal: int, recipe_id: String,
		custom_label: String = "") -> void:
	_db.query_with_bindings("""
		INSERT INTO meal_plan_positions (position_index, meal_slot, recipe_id, custom_label, updated_at, deleted_at, dirty)
		VALUES (?, ?, ?, ?, ?, NULL, 1)
		ON CONFLICT(position_index, meal_slot) DO UPDATE
		SET recipe_id = ?, custom_label = ?, updated_at = ?, deleted_at = NULL, dirty = 1;""",
		[index, meal, recipe_id if recipe_id != "" else null, custom_label, _now(),
		recipe_id if recipe_id != "" else null, custom_label, _now()])

func fetch_breakfast_slots() -> Dictionary:
	_db.query("SELECT * FROM breakfast_slots WHERE deleted_at IS NULL;")
	var out := {}
	for row in _db.query_result:
		out[int(row["slot"])] = str(row["breakfast_id"]) if row["breakfast_id"] != null else ""
	return out

func set_breakfast_slot(slot: int, breakfast_id: String) -> void:
	_db.query_with_bindings("""
		INSERT INTO breakfast_slots (slot, breakfast_id, updated_at, deleted_at, dirty)
		VALUES (?, ?, ?, NULL, 1)
		ON CONFLICT(slot) DO UPDATE
		SET breakfast_id = ?, updated_at = ?, deleted_at = NULL, dirty = 1;""",
		[slot, breakfast_id if breakfast_id != "" else null, _now(),
		breakfast_id if breakfast_id != "" else null, _now()])

func fetch_shopping_items() -> Array[Dictionary]:
	_db.query("SELECT * FROM shopping_items WHERE deleted_at IS NULL ORDER BY aisle, name;")
	var out: Array[Dictionary] = []
	for row in _db.query_result:
		out.append({
			"item_key": str(row["item_key"]),
			"nom": str(row["name"]),
			"aisle": str(row["aisle"]),
			"quantite": float(row["quantity"]),
			"unite": str(row["unit"]),
			"checked": int(row["checked"]) != 0,
		})
	return out

func upsert_shopping_item(item_key: String, name: String, aisle: String,
		quantity: float, unit: String, checked: bool) -> void:
	var now := _now()
	var chk := 1 if checked else 0
	_db.query_with_bindings("""
		INSERT INTO shopping_items (item_key, name, aisle, quantity, unit, checked, updated_at, deleted_at, dirty)
		VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 1)
		ON CONFLICT(item_key) DO UPDATE
		SET name = ?, aisle = ?, quantity = ?, unit = ?, checked = ?, updated_at = ?, deleted_at = NULL, dirty = 1;""",
		[item_key, name, aisle, quantity, unit, chk, now,
		name, aisle, quantity, unit, chk, now])

## Coche/décoche un article — l'écriture la plus fréquente (usage en magasin), et
## celle dont la fusion par item évite tout conflit entre appareils.
func set_shopping_item_checked(item_key: String, checked: bool) -> void:
	_db.query_with_bindings(
		"UPDATE shopping_items SET checked=?, updated_at=?, dirty=1 WHERE item_key=?;",
		[1 if checked else 0, _now(), item_key])

## Tombstone un article retiré de la liste.
func delete_shopping_item(item_key: String) -> void:
	_soft_delete("shopping_items", "item_key", item_key)

## Tombstone tous les articles courants (régénération de la liste). Les articles
## restent en base pour que la suppression se propage aux autres appareils.
func clear_shopping_items() -> void:
	var now := _now()
	_db.query_with_bindings(
		"UPDATE shopping_items SET deleted_at=?, updated_at=?, dirty=1 WHERE deleted_at IS NULL;",
		[now, now])

# =====================================================================
# Support de synchronisation (utilisé par SyncEngine)
# =====================================================================

## Lignes écrites localement et pas encore poussées — tombstones compris.
func fetch_dirty(table: String) -> Array:
	_db.query("SELECT * FROM %s WHERE dirty = 1;" % table)
	return _db.query_result.duplicate(true)

## Marque une ligne comme poussée, mais seulement si elle n'a pas été rééditée
## entre-temps : sans la clause sur updated_at, une modification faite pendant
## l'envoi serait considérée comme synchronisée et ne partirait jamais.
## `key_columns` accepte plusieurs colonnes séparées par des virgules, et `key_values` autant de
## valeurs. `meal_plan_positions` a une clé locale à DEUX colonnes depuis la v7 : sans cela,
## marquer une case propre marquerait aussi l'autre repas du même jour.
## `key_values` accepte une valeur seule ou un tableau : la quasi-totalité des tables ont une
## clé locale d'une colonne, et les faire toutes passer par un tableau n'aurait rien clarifié.
func mark_clean(table: String, key_columns: String, key_values, updated_at: int) -> void:
	var values: Array = key_values if key_values is Array else [key_values]
	var conditions: Array[String] = []
	for column in key_columns.split(","):
		conditions.append("%s = ?" % column.strip_edges())
	var bindings := values.duplicate()
	bindings.append(updated_at)
	_db.query_with_bindings(
		"UPDATE %s SET dirty = 0 WHERE %s AND updated_at = ?;" % [
			table, " AND ".join(conditions)], bindings)

func fetch_row(table: String, key_columns: String, key_values) -> Dictionary:
	var values: Array = key_values if key_values is Array else [key_values]
	var conditions: Array[String] = []
	for column in key_columns.split(","):
		conditions.append("%s = ?" % column.strip_edges())
	# `duplicate()` et non le tableau reçu : `query_with_bindings` VIDE le tableau qu'on lui
	# passe. L'appelant qui garde ses valeurs de clé pour la suite — c'est le cas du moteur de
	# synchronisation depuis les clés composites — se retrouvait sinon avec un tableau vide, et
	# les liens d'une recette n'étaient plus écrits.
	_db.query_with_bindings("SELECT * FROM %s WHERE %s;" % [
		table, " AND ".join(conditions)], values.duplicate())
	if _db.query_result.is_empty():
		return {}
	return _db.query_result[0].duplicate(true)

## Ramène à `now` toute ligne locale dont l'horodatage dépasse `now + max_drift` (écrite par une
## horloge déréglée, avant la 1.10.0 ou entre deux recalibrages) et la repart `dirty = 1` pour
## que le correctif se propage. Une telle ligne gagnerait le LWW contre toute édition saine —
## c'est-à-dire que ce que les autres appareils modifient serait ignoré sur celui-ci.
## `deleted_at` suit `updated_at` (invariant de suppression, cf. en-tête). Renvoie le nombre de lignes.
func heal_future_rows(now: int, max_drift: int) -> int:
	var healed := 0
	for table in SYNCED_TABLES:
		_db.query_with_bindings(
			"SELECT COUNT(*) AS n FROM %s WHERE updated_at > ?;" % table, [now + max_drift])
		var count := int(_db.query_result[0]["n"])
		if count == 0:
			continue
		_db.query_with_bindings(
			"UPDATE %s SET updated_at = ?, deleted_at = CASE WHEN deleted_at IS NULL THEN NULL ELSE ? END, dirty = 1 WHERE updated_at > ?;" % table,
			[now, now, now + max_drift])
		healed += count
	return healed

## Écrit une ligne venue du serveur. `row` doit contenir toutes les colonnes locales,
## dirty inclus (0 : ce qui vient du serveur n'a pas à y être renvoyé).
## Renvoie false si SQLite refuse l'écriture (colonne inconnue, contrainte…).
func sync_write_row(table: String, key_columns: String, row: Dictionary) -> bool:
	var keys: Array[String] = []
	for column in key_columns.split(","):
		keys.append(column.strip_edges())
	var columns: Array = row.keys()
	var placeholders := ",".join(columns.map(func(_c): return "?"))
	var assignments: Array = columns.filter(func(c): return not keys.has(c)) \
		.map(func(c): return "%s = excluded.%s" % [c, c])
	return _db.query_with_bindings(
		"INSERT INTO %s (%s) VALUES (%s) ON CONFLICT(%s) DO UPDATE SET %s;" % [
			table, ",".join(columns), placeholders, ",".join(keys), ",".join(assignments)],
		row.values())

## Ingrédients (ou catégories) d'une recette, sous la forme attendue par le jsonb
## distant : [{ingredient_id, quantity, unit}].
func fetch_recipe_ingredient_links(recipe_id: String) -> Array:
	_db.query_with_bindings(
		"SELECT ingredient_id, quantity, unit FROM recipe_ingredients WHERE recipe_id = ?;",
		[recipe_id])
	return _db.query_result.duplicate(true)

func fetch_recipe_category_names(recipe_id: String) -> Array:
	_db.query_with_bindings("""
		SELECT c.name FROM recipe_categories rc JOIN categories c ON rc.category_id = c.id
		WHERE rc.recipe_id = ?;""", [recipe_id])
	var out := []
	for row in _db.query_result:
		out.append(str(row["name"]))
	return out

func fetch_breakfast_ingredient_links(breakfast_id: String) -> Array:
	_db.query_with_bindings(
		"SELECT ingredient_id, quantity, unit FROM breakfast_ingredients WHERE breakfast_id = ?;",
		[breakfast_id])
	return _db.query_result.duplicate(true)

## Réécrit les tables filles d'une recette à partir des données distantes.
## Les catégories arrivent par NOM (et non par id) : c'est ce qui permet à deux
## appareils ayant créé « Pâtes » avec des UUID différents de converger malgré tout.
func sync_write_recipe_children(recipe_id: String, links: Array, category_names: Array) -> void:
	_db.query_with_bindings("DELETE FROM recipe_ingredients WHERE recipe_id = ?;", [recipe_id])
	_db.query_with_bindings("DELETE FROM recipe_categories WHERE recipe_id = ?;", [recipe_id])
	for link in links:
		_db.query_with_bindings(
			"INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit) VALUES (?, ?, ?, ?);",
			[recipe_id, str(link.get("ingredient_id", "")),
			float(link.get("quantity", 0)), str(link.get("unit", ""))])
	for name in category_names:
		if str(name).strip_edges() == "":
			continue
		_db.query_with_bindings(
			"INSERT INTO recipe_categories (recipe_id, category_id) VALUES (?, ?);",
			[recipe_id, _category_id(str(name))])

func sync_write_breakfast_children(breakfast_id: String, links: Array) -> void:
	_db.query_with_bindings("DELETE FROM breakfast_ingredients WHERE breakfast_id = ?;", [breakfast_id])
	for link in links:
		_db.query_with_bindings(
			"INSERT INTO breakfast_ingredients (breakfast_id, ingredient_id, quantity, unit) VALUES (?, ?, ?, ?);",
			[breakfast_id, str(link.get("ingredient_id", "")),
			float(link.get("quantity", 0)), str(link.get("unit", ""))])

## Fusionne les ingrédients homonymes créés indépendamment sur plusieurs appareils.
## Règle déterministe : le plus petit UUID l'emporte, les autres sont tombstonés et
## toutes les références sont repointées — chaque appareil aboutit donc au même
## résultat sans se concerter. Renvoie le nombre de doublons résorbés.
func merge_duplicate_ingredients() -> int:
	_db.query("""
		SELECT LOWER(TRIM(name)) AS key, COUNT(*) AS n FROM ingredients
		WHERE deleted_at IS NULL GROUP BY key HAVING n > 1;""")
	var duplicates: Array = _db.query_result.duplicate(true)
	var merged := 0
	for dup in duplicates:
		_db.query_with_bindings("""
			SELECT id FROM ingredients WHERE LOWER(TRIM(name)) = ? AND deleted_at IS NULL
			ORDER BY id;""", [dup["key"]])
		var ids: Array = _db.query_result.duplicate(true)
		var keeper := str(ids[0]["id"])
		for i in range(1, ids.size()):
			var loser := str(ids[i]["id"])
			_db.query_with_bindings(
				"UPDATE recipe_ingredients SET ingredient_id = ? WHERE ingredient_id = ?;", [keeper, loser])
			_db.query_with_bindings(
				"UPDATE breakfast_ingredients SET ingredient_id = ? WHERE ingredient_id = ?;", [keeper, loser])
			_soft_delete("ingredients", "id", loser)
			merged += 1
	return merged

func merge_duplicate_categories() -> int:
	_db.query("""
		SELECT LOWER(TRIM(name)) AS key, COUNT(*) AS n FROM categories
		WHERE deleted_at IS NULL GROUP BY key HAVING n > 1;""")
	var duplicates: Array = _db.query_result.duplicate(true)
	var merged := 0
	for dup in duplicates:
		_db.query_with_bindings("""
			SELECT id FROM categories WHERE LOWER(TRIM(name)) = ? AND deleted_at IS NULL
			ORDER BY id;""", [dup["key"]])
		var ids: Array = _db.query_result.duplicate(true)
		var keeper := str(ids[0]["id"])
		for i in range(1, ids.size()):
			var loser := str(ids[i]["id"])
			_db.query_with_bindings(
				"UPDATE recipe_categories SET category_id = ? WHERE category_id = ?;", [keeper, loser])
			_soft_delete("categories", "id", loser)
			merged += 1
	return merged

## Résorbe les rayons portant le même nom. Manquait à l'appel : `aisles` est né en 1.1,
## après cette réconciliation, et deux exemplaires de « Frais » — l'un semé localement,
## l'autre venu du compte — pouvaient donc cohabiter indéfiniment.
##
## Rien à repointer, contrairement aux ingrédients et catégories : le rayon est
## référencé par son NOM. Deux homonymes désignent déjà la même chose pour tout ce qui
## s'y rattache, il suffit d'en tombstoner un.
##
## Le gardien est le premier par (dirty, id) et non par id seul : à égalité de nom, la
## ligne déjà synchronisée est celle du compte, et c'est SON ordre de parcours que
## l'utilisateur a choisi. Une fois les deux exemplaires passés par le serveur, plus
## aucun n'est `dirty` et l'id tranche seul — donc tous les appareils convergent sur le
## même gardien.
func merge_duplicate_aisles() -> int:
	_db.query("""
		SELECT LOWER(TRIM(name)) AS key, COUNT(*) AS n FROM aisles
		WHERE deleted_at IS NULL GROUP BY key HAVING n > 1;""")
	var duplicates: Array = _db.query_result.duplicate(true)
	var merged := 0
	for dup in duplicates:
		_db.query_with_bindings("""
			SELECT id FROM aisles WHERE LOWER(TRIM(name)) = ? AND deleted_at IS NULL
			ORDER BY dirty, id;""", [dup["key"]])
		var ids: Array = _db.query_result.duplicate(true)
		for i in range(1, ids.size()):
			_soft_delete("aisles", "id", str(ids[i]["id"]))
			merged += 1
	return merged

## Supprime les lignes issues du jeu d'exemple embarqué.
##
## Appelé quand l'appareil reçoit ses premières données d'un compte : le seed n'est
## qu'un contenu de démarrage, il n'a pas à cohabiter avec les vraies recettes. Sans
## cela, une installation neuve qui se connecte afficherait DEUX exemplaires de tout
## — les siens semés localement (UUID tirés au hasard à l'installation) et ceux tirés
## du compte — et pousserait les premiers, contaminant les autres appareils.
##
## Ne sont supprimées que les lignes encore intactes : `updated_at` égal à
## l'horodatage de semis ET `dirty = 1` (jamais synchronisées). Une recette d'exemple
## que l'utilisateur aurait modifiée, ou qu'il aurait créée lui-même avant de se
## connecter, porte un autre horodatage et survit — elle sera poussée normalement.
##
## Suppression sèche et non tombstone : ces lignes n'ont jamais existé sur le
## serveur, il n'y a rien à y propager.
func discard_seed_rows() -> int:
	var stamp := int(get_sync_meta("seed_stamp", "0"))
	if stamp == 0:
		return 0
	var removed := 0
	# Noms et identifiants écartés, pour retirer ensuite ce qui en DÉRIVE : une liste
	# de courses ou un planning bâtis sur des recettes d'exemple n'ont plus de sens
	# une fois ces recettes parties, et partiraient sinon polluer le compte.
	var discarded_names := {}
	var discarded_recipes := {}
	var discarded_breakfasts := {}

	for table in ["recipes", "ingredients", "categories", "breakfasts", "staples"]:
		_db.query_with_bindings(
			"SELECT id, name FROM %s WHERE updated_at = ? AND dirty = 1;" % table, [stamp])
		var ids: Array = _db.query_result.duplicate(true)
		for row in ids:
			var rid := str(row["id"])
			if table == "ingredients" or table == "staples":
				discarded_names[str(row["name"]).strip_edges().to_lower()] = true
			elif table == "recipes":
				discarded_recipes[rid] = true
			elif table == "breakfasts":
				discarded_breakfasts[rid] = true
			match table:
				"recipes":
					_db.query_with_bindings("DELETE FROM recipe_ingredients WHERE recipe_id = ?;", [rid])
					_db.query_with_bindings("DELETE FROM recipe_categories WHERE recipe_id = ?;", [rid])
				"breakfasts":
					_db.query_with_bindings("DELETE FROM breakfast_ingredients WHERE breakfast_id = ?;", [rid])
				"ingredients":
					_db.query_with_bindings("DELETE FROM recipe_ingredients WHERE ingredient_id = ?;", [rid])
					_db.query_with_bindings("DELETE FROM breakfast_ingredients WHERE ingredient_id = ?;", [rid])
				"categories":
					_db.query_with_bindings("DELETE FROM recipe_categories WHERE category_id = ?;", [rid])
			_db.query_with_bindings("DELETE FROM %s WHERE id = ?;" % table, [rid])
			removed += 1
	removed += _discard_seed_derivatives(discarded_names, discarded_recipes, discarded_breakfasts)

	# Les rayons ne partent PAS ici. Leur garde-fou — ne les retirer que si le compte en
	# apporte d'autres — ne peut pas être évalué à cet instant : cet écartement est
	# déclenché par la première ligne reçue, donc pendant le pull de la première table,
	# alors que `aisles` n'a même pas encore été demandé. La condition était donc
	# toujours fausse, les dix rayons d'exemple survivaient à chaque connexion, et la
	# fusion des homonymes les mettait en tombstone juste après pour les pousser au
	# compte. L'horodatage est mis de côté pour qu'on puisse encore les reconnaître une
	# fois le pull terminé.
	set_sync_meta(SEED_AISLES_KEY, str(stamp))
	set_sync_meta("seed_stamp", "0")
	if removed > 0:
		print("LocalDatabase : %d ligne(s) du jeu d'exemple écartées au profit des données du compte." % removed)
	return removed

## Écarte les rayons semés, traités à part des autres tables pour deux raisons.
##
## D'abord un garde-fou : ils ne partent que si le compte en apporte d'autres. Un
## serveur dont le schéma précède la 1.1 ne renvoie pas la table `aisles` — le cycle
## l'ignore alors au lieu de s'interrompre — et les effacer laisserait l'appareil sans
## aucun rayon, donc toute la liste de courses sous « Autres ».
##
## Ensuite le repli, qui doit survivre à l'opération : c'est lui qui recueille le
## contenu des rayons disparus, et un ingrédient rattaché à un rayon inexistant sort
## de la liste de courses.
func _discard_seed_aisles(stamp: int) -> int:
	_db.query_with_bindings("""
		SELECT COUNT(*) AS n FROM aisles
		WHERE deleted_at IS NULL AND NOT (updated_at = ? AND dirty = 1);""", [stamp])
	if _db.query_result.is_empty() or int(_db.query_result[0]["n"]) == 0:
		return 0

	_db.query_with_bindings(
		"SELECT id FROM aisles WHERE updated_at = ? AND dirty = 1;", [stamp])
	var removed := 0
	for row in _db.query_result.duplicate(true):
		_db.query_with_bindings("DELETE FROM aisles WHERE id = ?;", [str(row["id"])])
		removed += 1

	_db.query_with_bindings(
		"SELECT COUNT(*) AS n FROM aisles WHERE name = ? AND deleted_at IS NULL;",
		[FALLBACK_AISLE])
	if int(_db.query_result[0]["n"]) == 0:
		_db.query("SELECT COALESCE(MAX(sort_order), -1) AS m FROM aisles;")
		var next_order := int(_db.query_result[0]["m"]) + 1
		_db.query_with_bindings(
			"INSERT INTO aisles (id, name, sort_order, updated_at) VALUES (?, ?, ?, ?);",
			[Uuid.v4(), FALLBACK_AISLE, next_order, _now()])

	_reattach_orphan_aisles()
	return removed

## Rattache au rayon de repli tout contenu visant un rayon qui n'existe plus — un
## ingrédient créé avant la connexion, rangé dans un rayon d'exemple que le compte ne
## connaît pas. Sans cela il disparaîtrait de la liste de courses, qui groupe par rayon.
func _reattach_orphan_aisles() -> void:
	var live := {}
	_db.query("SELECT name FROM aisles WHERE deleted_at IS NULL;")
	for row in _db.query_result:
		live[str(row["name"])] = true

	var now := _now()
	for table in ["ingredients", "staples", "shopping_items"]:
		_db.query("SELECT DISTINCT aisle FROM %s;" % table)
		for row in _db.query_result.duplicate(true):
			var aisle := str(row["aisle"])
			if aisle == "" or live.has(aisle):
				continue
			_db.query_with_bindings(
				"UPDATE %s SET aisle=?, updated_at=?, dirty=1 WHERE aisle=?;" % table,
				[FALLBACK_AISLE, now, aisle])

## Retire ce qui découle du jeu d'exemple : articles de courses issus de ses
## ingrédients, cases de planning et emplacements de petit déjeuner qui le référencent.
##
## Ces lignes ne portent pas l'horodatage de semis — elles ont été produites plus tard,
## en générant une liste ou en planifiant — et échappaient donc à l'abandon. Un appareil
## qui générait sa liste de courses AVANT de se connecter poussait ainsi les ingrédients
## du jeu d'exemple sur le compte, où ils se répliquaient sur tous les autres.
##
## Suppression sèche : rien de tout cela n'a encore atteint le serveur, l'abandon ayant
## lieu pendant le tout premier pull, avant le moindre envoi.
func _discard_seed_derivatives(names: Dictionary, recipes: Dictionary,
		breakfasts: Dictionary) -> int:
	var removed := 0

	# On ne vise que les articles portant un nom écarté : ce que l'utilisateur a
	# ajouté lui-même avant de se connecter doit survivre.
	_db.query("SELECT item_key, name FROM shopping_items;")
	for row in _db.query_result.duplicate(true):
		if names.has(str(row["name"]).strip_edges().to_lower()):
			_db.query_with_bindings("DELETE FROM shopping_items WHERE item_key = ?;",
				[str(row["item_key"])])
			removed += 1

	_db.query("SELECT position_index, recipe_id FROM meal_plan_positions;")
	for row in _db.query_result.duplicate(true):
		if row["recipe_id"] != null and recipes.has(str(row["recipe_id"])):
			_db.query_with_bindings(
				"DELETE FROM meal_plan_positions WHERE position_index = ?;",
				[int(row["position_index"])])
			removed += 1

	_db.query("SELECT slot, breakfast_id FROM breakfast_slots;")
	for row in _db.query_result.duplicate(true):
		if row["breakfast_id"] != null and breakfasts.has(str(row["breakfast_id"])):
			_db.query_with_bindings("DELETE FROM breakfast_slots WHERE slot = ?;",
				[int(row["slot"])])
			removed += 1

	return removed

## Le jeu d'exemple devient la collection de l'utilisateur : il cesse d'être un seed.
## Sans cet oubli volontaire, l'abandon resterait armé indéfiniment et une ligne qui
## porterait par hasard l'horodatage de semis pourrait être supprimée bien plus tard.
func adopt_seed() -> void:
	set_sync_meta("seed_stamp", "0")
	# Les rayons d'exemple deviennent les siens comme le reste : plus rien à écarter.
	set_sync_meta(SEED_AISLES_KEY, "0")

## Écarte les rayons du jeu d'exemple, une fois le pull complet — c'est le seul moment
## où l'on sait si le compte en apporte d'autres. Sans effet si l'appareil n'a pas de
## semis en attente, ou si le compte n'a livré aucun rayon.
func discard_seed_aisles() -> int:
	var stamp := int(get_sync_meta(SEED_AISLES_KEY, "0"))
	if stamp == 0:
		return 0
	var removed := _discard_seed_aisles(stamp)
	# Une seule tentative : si le compte n'a apporté aucun rayon, les siens n'arriveront
	# pas davantage au cycle suivant, et les rayons d'exemple sont alors les seuls que
	# l'appareil possède — les retirer le laisserait sans aucun rayon.
	set_sync_meta(SEED_AISLES_KEY, "0")
	if removed > 0:
		print("LocalDatabase : %d rayon(s) du jeu d'exemple écartés au profit du compte." % removed)
	return removed

## true si des lignes du jeu d'exemple sont encore présentes et jamais synchronisées.
func has_pending_seed() -> bool:
	return int(get_sync_meta("seed_stamp", "0")) != 0

# =====================================================================
# Une base = un compte
# =====================================================================

## Rattache la base à `account_id`. Renvoie `true` si elle appartenait à un AUTRE
## compte et vient donc d'être remise à neuf.
##
## Rien ne s'en occupait, et le mélange était silencieux : `sign_out()` efface la session
## sans toucher à la base, et `sign_in()` ne compare rien. Une base ayant servi à deux
## comptes accumulait donc leurs lignes — relevé sur le poste de développement : 48
## catégories pour 8 noms, six exemplaires de « Légumes ».
##
## Or **aucune table locale ne porte de propriétaire** : tout ce qui parcourt la base
## croit n'avoir affaire qu'au compte courant. `merge_duplicate_*` résorbait ainsi les
## homonymes À TRAVERS les comptes, et poussait des tombstones visant les lignes
## d'autrui. Refusées par la RLS dans le meilleur des cas — l'erreur qui a mis sur la
## piste, « new row violates row-level security policy (USING expression) », réservée à
## l'échec d'un `ON CONFLICT DO UPDATE` sur une ligne qu'on ne possède pas. Appliquées
## dans le pire : supprimant chez l'un ce qui appartenait à l'autre, sans un mot.
##
## Changer de compte équivaut donc à une installation neuve. Le contenu de l'ancien
## compte n'est pas perdu — il est sur SON compte. Les éditions locales jamais
## synchronisées le sont, et c'est le seul choix cohérent : elles ne peuvent pas être
## poussées vers un compte qui n'est pas le leur.
func claim_account(account_id: String) -> bool:
	if account_id == "":
		return false
	var known := get_sync_meta(ACCOUNT_KEY, "")
	if known == account_id:
		return false
	if known == "":
		# Première synchronisation de cette base : elle adopte le compte sans rien jeter.
		# C'est aussi le chemin des bases antérieures à ce marqueur, dont on ne peut plus
		# savoir à qui elles appartiennent.
		set_sync_meta(ACCOUNT_KEY, account_id)
		return false
	reset_for_account(account_id)
	return true

## Vide tout le contenu synchronisable et repart comme au premier lancement.
func reset_for_account(account_id: String) -> void:
	for table in SYNCED_TABLES + LINK_TABLES:
		_db.query("DELETE FROM %s;" % table)

	# Les curseurs AVANT tout : ils datent du dernier passage de l'ancien compte. Laissés
	# en place, le premier pull ne demanderait que les lignes plus récentes que cette
	# date — et la base resterait vide de tout ce que le nouveau compte contient déjà.
	_db.query("DELETE FROM meta WHERE key LIKE 'sync_cursor_%';")
	set_sync_meta("sync_watermark", "0")
	set_sync_meta(ACCOUNT_KEY, account_id)

	# Jeu d'exemple réarmé, exactement comme sur une installation neuve : un compte qui a
	# déjà des données l'écartera au premier pull, un compte vierge fera poser la
	# question. Sans lui, l'appareil se retrouverait sans aucun rayon, et toute la liste
	# de courses sous « Autres ».
	var stamp := _now()
	set_sync_meta("seed_stamp", str(stamp))
	_seed_from_json(stamp)
	_seed_staples(stamp)
	_seed_aisles(stamp)
	print("LocalDatabase : base rattachée à un nouveau compte — contenu précédent écarté.")

# =====================================================================
# Utilitaires
# =====================================================================

## Soft-delete respectant l'invariant de sync : `deleted_at` ET `updated_at` sont
## écrits, sinon le tombstone ne serait jamais récupéré par un pull incrémental.
func _soft_delete(table: String, key_column: String, key_value) -> void:
	var now := _now()
	_db.query_with_bindings(
		"UPDATE %s SET deleted_at=?, updated_at=?, dirty=1 WHERE %s=?;" % [table, key_column],
		[now, now, key_value])

func _ingredient_id(name: String, aisle: String) -> String:
	return insert_ingredient(name, aisle)

## Identifiant d'une catégorie, créée si elle n'existe pas.
##
## Le rapprochement est insensible à la casse et aux espaces de bord, et emploie donc
## exactement le critère de `merge_duplicate_categories`. Avec une égalité stricte,
## « Pâtes » et « pâtes » créaient deux catégories que la fusion recollait ensuite :
## autant ne pas les séparer.
## `stamp` : horodatage à inscrire sur une catégorie CRÉÉE ici. Zéro = maintenant.
##
## Le semis doit le renseigner. Sans lui, `_now()` était appelé pour le compte de chaque
## catégorie, quelques dizaines de millisecondes après le `seed_stamp` mémorisé en meta —
## et `discard_seed_rows()`, qui reconnaît une ligne d'exemple à l'égalité stricte de son
## `updated_at` avec ce stamp, n'en voyait donc AUCUNE. Les huit catégories d'exemple
## survivaient à chaque connexion, se retrouvaient en doublon avec celles du compte, et la
## fusion des homonymes tranchait par le plus petit id : une fois sur deux c'est la ligne
## DU COMPTE qui perdait, mise en tombstone et remplacée par celle de l'appareil neuf.
## Mesuré sur le compte de test : 3 catégories légitimes supprimées sur 8, et 16 lignes
## là où 8 suffisent.
func _category_id(name: String, stamp: int = 0) -> String:
	# ORDER BY (deleted_at IS NULL) DESC : une ligne VIVANTE prime sur un tombstone du
	# même nom. Sans ce tri, on pouvait ressusciter le perdant d'une fusion alors que
	# le gagnant existait toujours — le doublon se reformait après chaque fusion, en
	# boucle. On ne ressuscite donc que s'il n'existe aucune ligne vivante.
	_db.query_with_bindings("""
		SELECT id FROM categories WHERE LOWER(TRIM(name)) = LOWER(TRIM(?))
		ORDER BY (deleted_at IS NULL) DESC, id LIMIT 1;""", [name])
	if not _db.query_result.is_empty():
		var existing := str(_db.query_result[0]["id"])
		_db.query_with_bindings(
			"UPDATE categories SET deleted_at=NULL, updated_at=?, dirty=1 WHERE id=? AND deleted_at IS NOT NULL;",
			[_now(), existing])
		return existing
	var cid: String = Uuid.v4()
	_db.query_with_bindings("INSERT INTO categories (id, name, updated_at) VALUES (?, ?, ?);",
		[cid, name, stamp if stamp > 0 else _now()])
	return cid

func _count(table: String) -> int:
	_db.query("SELECT COUNT(*) AS n FROM %s;" % table)
	return int(_db.query_result[0]["n"])

## Décalage horloge serveur − horloge locale, renseigné par Session après connexion.
## Le LWW compare des horodatages produits par des appareils différents : sans cette
## correction, une machine dont l'horloge avance gagnerait systématiquement.
var clock_offset_ms: int = 0

## Horodatage d'édition, en millisecondes epoch (cf. en-tête).
func _now() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) + clock_offset_ms
