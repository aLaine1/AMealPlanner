extends SceneTree
## Test headless des invariants du schéma v2 dont dépend la sync Supabase.
## godot --headless --path . --script res://tools/test_sync_schema.gd
##
## Ces invariants sont peu visibles depuis l'UI mais leur violation ne se manifeste
## qu'au moment d'une sync entre deux appareils — donc trop tard. D'où ce test.

const UUID_RE := "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

## Seuil discriminant secondes / millisecondes : ~2001 en ms, ~an 33000 en s.
const MS_FLOOR := 1000000000000

var _fails := 0

func _initialize() -> void:
	var db := LocalDatabase.new()
	db.open()
	var raw = db._db

	# Ce test écrit dans les tables d'état applicatif (planning, courses, slots).
	# On met de côté leur contenu réel et on le restaure à la fin : ces tables
	# portent les données de l'utilisateur, pas des fixtures.
	var backup := {}
	for t in ["meal_plan_positions", "shopping_items", "breakfast_slots"]:
		raw.query("SELECT * FROM %s;" % t)
		backup[t] = raw.query_result.duplicate(true)
		raw.query("DELETE FROM %s;" % t)

	print("--- Format des identifiants ---")
	var re := RegEx.new()
	re.compile(UUID_RE)
	for table in ["recipes", "ingredients", "categories", "breakfasts", "staples"]:
		raw.query("SELECT id FROM %s;" % table)
		var bad := 0
		for row in raw.query_result:
			if re.search(str(row["id"])) == null:
				bad += 1
		_check("%s : tous les id sont des UUID v4" % table, bad == 0,
			"%d id non conformes" % bad)

	print("--- Horodatages en millisecondes ---")
	for table in ["recipes", "ingredients", "staples"]:
		raw.query("SELECT MIN(updated_at) AS m FROM %s WHERE updated_at > 0;" % table)
		var m := int(raw.query_result[0]["m"])
		_check("%s : updated_at en ms" % table, m > MS_FLOOR,
			"min=%d, ressemble à des secondes" % m)

	print("--- Invariant de suppression (tombstone propageable) ---")
	var r := Recipe.new()
	r.nom = "ZZZ Test Sync"
	r.saison = "toute"
	var rid := db.insert_recipe(r)
	_check("id renvoyé à l'insertion est un UUID", re.search(rid) != null, rid)

	raw.query_with_bindings("SELECT dirty FROM recipes WHERE id=?;", [rid])
	_check("une ligne créée localement est dirty", int(raw.query_result[0]["dirty"]) == 1)

	db.delete_recipe(rid)
	raw.query_with_bindings("SELECT updated_at, deleted_at, dirty FROM recipes WHERE id=?;", [rid])
	var row = raw.query_result[0]
	# Le pull incrémental filtre sur updated_at : un tombstone qui laisse updated_at
	# inchangé ne serait jamais récupéré par les autres appareils.
	_check("le soft-delete écrit deleted_at", row["deleted_at"] != null)
	_check("le soft-delete bouge aussi updated_at",
		row["deleted_at"] != null and int(row["updated_at"]) == int(row["deleted_at"]),
		"updated_at=%s deleted_at=%s" % [row["updated_at"], row["deleted_at"]])
	_check("le tombstone est dirty", int(row["dirty"]) == 1)
	_check("la ligne supprimée est invisible en lecture",
		db.fetch_recipe_by_name("ZZZ Test Sync") == null)
	raw.query_with_bindings("DELETE FROM recipes WHERE id=?;", [rid])

	print("--- Planning par position ---")
	var recipes := db.fetch_all_recipes()
	# Depuis la 1.8 une case se désigne par (jour, repas) : le jour ne change pas de numéro
	# quand le foyer passe à deux repas par jour.
	db.set_plan_position(0, 0, recipes[0].id)
	db.set_plan_position(3, 0, "", "Restes du frigo")
	var positions := db.fetch_plan_positions()
	_check("position 0 relue",
		positions.get(Vector2i(0, 0), {}).get("recipe_id", "") == recipes[0].id)
	_check("position 3 : plat saisi à la main",
		positions.get(Vector2i(3, 0), {}).get("custom_label", "") == "Restes du frigo")
	# Réécrire la même position doit mettre à jour, pas dupliquer (clé naturelle).
	db.set_plan_position(0, 0, recipes[1].id)
	raw.query("SELECT COUNT(*) AS n FROM meal_plan_positions WHERE position_index = 0;")
	_check("une seule ligne par position", int(raw.query_result[0]["n"]) == 1)
	_check("position 0 mise à jour",
		db.fetch_plan_positions().get(Vector2i(0, 0), {}).get("recipe_id", "") == recipes[1].id)

	# Le second repas du même jour est une ligne DISTINCTE, et le jour garde son numéro.
	db.set_plan_position(0, 1, recipes[2].id)
	raw.query("SELECT COUNT(*) AS n FROM meal_plan_positions WHERE position_index = 0;")
	_check("deux repas au même jour : deux lignes", int(raw.query_result[0]["n"]) == 2)
	var both := db.fetch_plan_positions()
	_check("  le midi est intact",
		both.get(Vector2i(0, 0), {}).get("recipe_id", "") == recipes[1].id)
	_check("  le soir est à côté",
		both.get(Vector2i(0, 1), {}).get("recipe_id", "") == recipes[2].id)
	raw.query("DELETE FROM meal_plan_positions WHERE position_index = 0 AND meal_slot = 1;")

	print("--- Liste de courses par item ---")
	db.clear_shopping_items()
	db.upsert_shopping_item("tomate|kg", "Tomate", "Fruits et Légumes", 2.0, "kg", false)
	db.upsert_shopping_item("lait|l", "Lait", "Frais", 1.0, "l", false)
	_check("2 articles en liste", db.fetch_shopping_items().size() == 2)

	db.set_shopping_item_checked("tomate|kg", true)
	var items := db.fetch_shopping_items()
	var tomate := {}
	for it in items:
		if it["item_key"] == "tomate|kg":
			tomate = it
	_check("article coché", tomate.get("checked", false) == true)
	_check("l'autre article reste décoché",
		items.filter(func(i): return i["item_key"] == "lait|l")[0]["checked"] == false)

	# La régénération doit laisser des tombstones, pas effacer : sinon la suppression
	# ne se propage pas aux autres appareils.
	db.clear_shopping_items()
	_check("liste vidée côté lecture", db.fetch_shopping_items().is_empty())
	raw.query("SELECT COUNT(*) AS n FROM shopping_items WHERE deleted_at IS NOT NULL;")
	_check("les articles vidés laissent un tombstone", int(raw.query_result[0]["n"]) >= 2)

	print("--- Slots petit déjeuner ---")
	db.set_breakfast_slot(2, "")
	_check("slot vide persisté", db.fetch_breakfast_slots().has(2))

	_restore(raw, backup)

	print("")
	if _fails == 0:
		print("Tous les invariants de sync sont respectés.")
	else:
		print("%d invariant(s) violé(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		_fails += 1
	var suffix := "" if ok or detail == "" else "  (%s)" % detail
	print("  [%s] %s%s" % ["OK" if ok else "ÉCHEC", label, suffix])

## Remet les tables d'état dans l'état exact où le test les a trouvées.
func _restore(raw, backup: Dictionary) -> void:
	for t in backup.keys():
		raw.query("DELETE FROM %s;" % t)
		for row in backup[t]:
			var columns: Array = row.keys()
			var placeholders := ",".join(columns.map(func(_c): return "?"))
			raw.query_with_bindings(
				"INSERT INTO %s (%s) VALUES (%s);" % [t, ",".join(columns), placeholders],
				row.values())
