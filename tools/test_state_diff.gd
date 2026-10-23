extends SceneTree
## Vérifie que la persistance du planning et de la liste de courses est bien
## DIFFÉRENTIELLE : sauvegarder ne doit toucher l'updated_at que des lignes
## réellement modifiées.
##
## Enjeu : si une sauvegarde rafraîchit les 14 cases (ou les 60 articles), toutes
## repartent avec un horodatage neuf et l'appareil qui sauvegarde en dernier gagne
## sur la liste ENTIÈRE — le LWW par ligne ne protège plus rien. C'est silencieux
## en local et ne se voit qu'entre deux appareils, d'où ce test.
##
## godot --headless --path . --script res://tools/test_state_diff.gd

var _fails := 0

func _initialize() -> void:
	# DataStore est instancié à la main : en mode --script les autoloads ne sont pas
	# résolus à la compilation (même convention que les autres tests headless).
	var DataStore = load("res://autoload/DataStore.gd").new()
	DataStore._db = LocalDatabase.new()
	DataStore._db.open()
	DataStore._refresh_cache()
	var raw = DataStore._db._db

	# Sauvegarde de l'état réel pour le restaurer en fin de test.
	raw.query("SELECT * FROM meal_plan_positions;")
	var saved_plan: Array = raw.query_result.duplicate(true)
	raw.query("SELECT * FROM shopping_items;")
	var saved_items: Array = raw.query_result.duplicate(true)
	raw.query("DELETE FROM meal_plan_positions;")
	raw.query("DELETE FROM shopping_items;")

	var recipes: Array = DataStore.get_all_recipe_objects()

	print("--- Planning : écriture différentielle ---")
	var names: Array[String] = []
	for i in range(14):
		names.append("")
	names[0] = recipes[0].nom
	names[1] = recipes[1].nom
	names[5] = "Restes du frigo"       # plat libre, sans recette correspondante
	DataStore.save_plan_names(names)

	_check("seules les cases non vides créent une ligne", _row_count(raw, "meal_plan_positions") == 3)
	var stamps := _stamps(raw, "meal_plan_positions", "position_index")
	_check("case 5 stockée en libellé libre",
		_scalar(raw, "SELECT custom_label FROM meal_plan_positions WHERE position_index=5;") == "Restes du frigo")
	_check("case 0 stockée par ID de recette",
		_scalar(raw, "SELECT recipe_id FROM meal_plan_positions WHERE position_index=0;") == recipes[0].id)

	await _tick()
	# Re-sauvegarder à l'identique ne doit RIEN toucher.
	DataStore.save_plan_names(names)
	_check("sauvegarde à l'identique : aucun updated_at ne bouge",
		_stamps(raw, "meal_plan_positions", "position_index") == stamps)

	await _tick()
	# Modifier une seule case ne doit toucher que celle-là.
	names[1] = recipes[2].nom
	DataStore.save_plan_names(names)
	var after := _stamps(raw, "meal_plan_positions", "position_index")
	_check("case modifiée : updated_at rafraîchi", after[1] > stamps[1])
	_check("case 0 intacte", after[0] == stamps[0])
	_check("case 5 intacte", after[5] == stamps[5])

	print("--- Liste de courses : écriture différentielle ---")
	var items := [
		{"nom": "Tomate", "quantite": 3.0, "unite": "", "aisle": "Fruits et Légumes", "checked": false},
		{"nom": "Lait", "quantite": 1.0, "unite": "l", "aisle": "Frais", "checked": false},
		{"nom": "Riz", "quantite": 500.0, "unite": "g", "aisle": "Divers", "checked": false},
		# Ligne de saisie vide de la grille : ne doit pas être persistée.
		{"nom": "", "quantite": 1.0, "unite": "", "aisle": "Autres", "checked": false},
	]
	DataStore.save_shopping_items(items)
	_check("les lignes vides de la grille ne sont pas persistées",
		_row_count(raw, "shopping_items") == 3)

	var istamps := _stamps(raw, "shopping_items", "item_key")
	await _tick()
	DataStore.save_shopping_items(items)
	_check("sauvegarde à l'identique : aucun article ne bouge",
		_stamps(raw, "shopping_items", "item_key") == istamps)

	await _tick()
	items[1]["checked"] = true          # on coche le lait, en magasin
	DataStore.save_shopping_items(items)
	var iafter := _stamps(raw, "shopping_items", "item_key")
	var lait := ShoppingListService.item_key("Lait", "l")
	var tomate := ShoppingListService.item_key("Tomate", "")
	_check("article coché : updated_at rafraîchi", iafter[lait] > istamps[lait])
	_check("les autres articles ne bougent pas", iafter[tomate] == istamps[tomate])

	await _tick()
	items.remove_at(2)                  # on retire le riz
	DataStore.save_shopping_items(items)
	_check("article retiré : tombstone et non effacement",
		_scalar(raw, "SELECT COUNT(*) FROM shopping_items WHERE deleted_at IS NOT NULL;") == 1)
	_check("article retiré invisible en lecture", DataStore.load_shopping_items().size() == 2)

	# Restauration de l'état réel de l'utilisateur.
	raw.query("DELETE FROM meal_plan_positions;")
	raw.query("DELETE FROM shopping_items;")
	for row in saved_plan:
		raw.query_with_bindings("""INSERT INTO meal_plan_positions
			(position_index, recipe_id, custom_label, updated_at, deleted_at, dirty)
			VALUES (?, ?, ?, ?, ?, ?);""",
			[row["position_index"], row["recipe_id"], row["custom_label"],
			row["updated_at"], row["deleted_at"], row["dirty"]])
	for row in saved_items:
		raw.query_with_bindings("""INSERT INTO shopping_items
			(item_key, name, aisle, quantity, unit, checked, updated_at, deleted_at, dirty)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);""",
			[row["item_key"], row["name"], row["aisle"], row["quantity"], row["unit"],
			row["checked"], row["updated_at"], row["deleted_at"], row["dirty"]])

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

## Les horodatages sont en millisecondes : sans attente, deux écritures successives
## porteraient la même valeur et le test ne prouverait rien.
func _tick() -> void:
	await create_timer(0.05).timeout

func _stamps(raw, table: String, key_column: String) -> Dictionary:
	raw.query("SELECT %s AS k, updated_at FROM %s;" % [key_column, table])
	var out := {}
	for row in raw.query_result:
		out[row["k"]] = int(row["updated_at"])
	return out

func _row_count(raw, table: String) -> int:
	return int(_scalar(raw, "SELECT COUNT(*) FROM %s WHERE deleted_at IS NULL;" % table))

func _scalar(raw, sql: String):
	raw.query(sql)
	return raw.query_result[0].values()[0]

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
