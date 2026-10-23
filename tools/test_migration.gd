extends SceneTree
## Migrations de schéma et réparation d'une base passée par l'ancienne chaîne.
## godot --headless --path . --script res://tools/test_migration.gd
##
## L'ancienne chaîne de _migrate_if_needed faisait sauter la v6 → v7 et la v7 → v8 à toute
## base ≤ v5 : marquée v8, elle n'avait ni `meal_slot` ni `servings`, et chaque ligne reçue
## à la sync échouait (« table recipes has no column named servings ») pendant que le
## curseur avançait — donc perdue pour de bon. Constaté sur une installation Windows restée
## longtemps sans mise à jour.
##
## Chaque scénario travaille sur sa propre base, dérivée de MEALPLANNER_DB.

## Client de substitution : sert une page de lignes « distantes » sans réseau.
class StubClient:
	const PAGE_SIZE := 1000
	var rows: Array = []
	func select_changed_since(_table, _cursor, _token, _offset) -> Dictionary:
		return {"ok": true, "data": rows}

class StubSession:
	var user_id := "00000000-0000-4000-8000-0000000000aa"
	var client := StubClient.new()
	func is_configured() -> bool: return false

const Uuid := preload("res://services/Uuid.gd")

var _fails := 0
var _base := ""

func _initialize() -> void:
	_base = OS.get_environment("MEALPLANNER_DB")
	if _base == "":
		print("  [ÉCHEC] MEALPLANNER_DB non défini : refus de toucher la vraie base")
		quit(1)
		return

	_test_from_v5()
	_test_repair_broken_v8()
	_test_healthy_untouched()
	await _test_cursor_kept_on_write_failure()

	OS.set_environment("MEALPLANNER_DB", _base)
	print("")
	print("Migrations conformes." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

# =====================================================================

## Une base v5 : planning à une coordonnée, recettes sans nombre de parts.
func _test_from_v5() -> void:
	print("--- Base v5 → v8 ---")
	var path := _fresh_path("v5")
	_degrade(path, 5)
	var db := _open(path)
	var raw = db._db
	_check("meal_slot ajouté", db._column_exists("meal_plan_positions", "meal_slot"))
	_check("servings ajouté", db._column_exists("recipes", "servings"))
	_check("version enregistrée = %d" % LocalDatabase.SCHEMA_VERSION,
		int(db.get_sync_meta("schema_version")) == LocalDatabase.SCHEMA_VERSION)
	raw.query("SELECT position_index, meal_slot, custom_label FROM meal_plan_positions;")
	var rows: Array = raw.query_result
	_check("case du planning conservée, au midi",
		rows.size() == 1 and int(rows[0]["position_index"]) == 3
		and int(rows[0]["meal_slot"]) == 0 and str(rows[0]["custom_label"]) == "Restes",
		str(rows))
	_check("recettes conservées", db._count("recipes") > 0)
	_check("écriture d'une recette reçue acceptée", db.sync_write_row("recipes", "id", {
		"id": Uuid.v4(), "name": "Distante", "servings": 4, "updated_at": 1, "dirty": 0}))
	raw.close_db()

## Une base déjà passée par l'ancienne chaîne : marquée v8, colonnes absentes, curseurs avancés.
func _test_repair_broken_v8() -> void:
	print("--- Base marquée v8 sans ses colonnes ---")
	var path := _fresh_path("broken")
	_degrade(path, 8)
	var db := _open(path)
	_check("meal_slot réparé", db._column_exists("meal_plan_positions", "meal_slot"))
	_check("servings réparé", db._column_exists("recipes", "servings"))
	_check("curseur recipes remis à zéro", db.get_sync_meta("sync_cursor_recipes") == "0")
	_check("curseur meal_plan_positions remis à zéro",
		db.get_sync_meta("sync_cursor_meal_plan_positions") == "0")
	_check("curseur d'une table saine intact",
		db.get_sync_meta("sync_cursor_ingredients") == "12345")
	db._db.close_db()

## Une base saine rouverte ne perd pas ses curseurs : la réparation ne se déclenche qu'à bon escient.
func _test_healthy_untouched() -> void:
	print("--- Base saine rouverte ---")
	var path := _fresh_path("healthy")
	var db := _open(path)
	db.set_sync_meta("sync_cursor_recipes", "777")
	db._db.close_db()
	db = _open(path)
	_check("curseur recipes conservé", db.get_sync_meta("sync_cursor_recipes") == "777")
	db._db.close_db()

## Une ligne que SQLite refuse ne doit pas faire avancer le curseur : elle reviendra au pull
## suivant, une fois la base réparée ou l'appli mise à jour.
func _test_cursor_kept_on_write_failure() -> void:
	print("--- Écriture refusée pendant le pull ---")
	var db := _open(_fresh_path("pull"))
	db.set_sync_meta("sync_cursor_ingredients", "100")
	var session := StubSession.new()
	var engine = load("res://services/SyncEngine.gd").new()
	engine.setup(db, session)
	var desc := {"table": "ingredients", "key": "id", "on_conflict": "id"}
	var now: int = db._now()

	session.client.rows = [{"id": Uuid.v4(), "name": "Inconnu", "colonne_future": 1,
		"updated_at": now, "deleted_at": null}]
	var res: Dictionary = await engine._pull_table(desc, "jeton")
	_check("pull terminé sans erreur", res.ok)
	_check("curseur conservé", db.get_sync_meta("sync_cursor_ingredients") == "100")

	session.client.rows = [{"id": Uuid.v4(), "name": "Connu",
		"updated_at": now, "deleted_at": null}]
	res = await engine._pull_table(desc, "jeton")
	_check("ligne valide appliquée", res.ok and int(res.count) == 1)
	_check("curseur avancé", db.get_sync_meta("sync_cursor_ingredients") == str(now))
	engine.free()
	db._db.close_db()

# =====================================================================

func _fresh_path(tag: String) -> String:
	var path := "%s.%s.db" % [_base, tag]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return path

func _open(path: String) -> LocalDatabase:
	OS.set_environment("MEALPLANNER_DB", path)
	var db := LocalDatabase.new()
	db.open()
	return db

## Crée une base au schéma courant puis la ramène à la forme d'avant la v7 : planning à clé
## simple, recettes sans `servings`, version enregistrée `version`.
func _degrade(path: String, version: int) -> void:
	var raw = _open(path)._db
	raw.query("DELETE FROM meal_plan_positions;")
	raw.query("DROP TABLE meal_plan_positions;")
	raw.query("""
		CREATE TABLE meal_plan_positions (
			position_index INTEGER PRIMARY KEY,
			recipe_id TEXT,
			custom_label TEXT DEFAULT '',
			updated_at INTEGER DEFAULT 0,
			deleted_at INTEGER,
			dirty INTEGER NOT NULL DEFAULT 1
		);""")
	raw.query("INSERT INTO meal_plan_positions (position_index, custom_label, updated_at) VALUES (3, 'Restes', 1);")
	_check("(préparation) suppression de servings",
		raw.query("ALTER TABLE recipes DROP COLUMN servings;"))
	for table in ["recipes", "meal_plan_positions", "ingredients"]:
		raw.query_with_bindings("INSERT OR REPLACE INTO meta (key, value) VALUES (?, '12345');",
			["sync_cursor_%s" % table])
	raw.query_with_bindings("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?);",
		[str(version)])
	raw.close_db()

func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  [OK]    %s" % label)
	else:
		_fails += 1
		print("  [ÉCHEC] %s%s" % [label, "  — " + detail if detail != "" else ""])
