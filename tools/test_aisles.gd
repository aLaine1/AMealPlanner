extends SceneTree
## Rayons personnalisables : ordre, renommage en cascade, suppression sans perte.
## godot --headless --path . --script res://tools/test_aisles.gd
##
## Le point sensible est le renommage : ingrédients, articles de base et articles de
## courses référencent le rayon par son NOM. Sans report du nouveau nom, tout ce
## contenu resterait rattaché à un rayon qui n'existe plus — et disparaîtrait des
## groupes de la liste de courses.

var _fails := 0

func _initialize() -> void:
	await process_frame
	var store := root.get_node_or_null("/root/DataStore")
	if store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return
	var db = store.local_database()

	print("--- Amorçage ---")
	var names: Array = store.get_aisle_names()
	_check("rayons initialisés", names.size() >= 5)
	_check("le rayon de repli existe", names.has(store.fallback_aisle()))
	# Il accueille le contenu des rayons supprimés : le placer ailleurs qu'en fin de
	# parcours n'aurait pas de sens en magasin.
	_check("le repli est en dernier", names[names.size() - 1] == store.fallback_aisle())
	_check("plus de « Autre » en doublon de « Autres »", not names.has("Autre"))

	print("--- Ajout et ordre ---")
	var before: int = store.get_aisles().size()
	var new_id: String = store.add_aisle("ZZZ Cave")
	_check("rayon ajouté", store.get_aisles().size() == before + 1)

	var ordered: Array = []
	for aisle in store.get_aisles():
		ordered.append(str(aisle["id"]))
	var last: String = ordered.pop_back()
	ordered.push_front(last)
	store.reorder_aisles(ordered)
	_check("réordonnancement appliqué",
		str(store.get_aisles()[0]["id"]) == last)

	print("--- Renommage en cascade ---")
	store.add_ingredient("ZZZ Vin", "ZZZ Cave")
	var staple = load("res://models/Ingredient.gd").new()
	staple.nom = "ZZZ Bouchons"
	staple.aisle = "ZZZ Cave"
	staple.quantite = 1.0
	store.add_staple(staple)
	db.upsert_shopping_item("zzz-vin||", "ZZZ Vin", "ZZZ Cave", 1.0, "", false)

	store.rename_aisle(new_id, "ZZZ Caviste")

	_check("le rayon porte le nouveau nom",
		store.get_aisle_names().has("ZZZ Caviste"))
	var ingredient_aisle: String = _scalar(db, "SELECT aisle FROM ingredients WHERE name='ZZZ Vin';")
	_check("l'ingrédient a suivi", ingredient_aisle == "ZZZ Caviste")
	_check("l'article de base a suivi",
		_scalar(db, "SELECT aisle FROM staples WHERE name='ZZZ Bouchons';") == "ZZZ Caviste")
	_check("l'article de courses a suivi",
		_scalar(db, "SELECT aisle FROM shopping_items WHERE item_key='zzz-vin||';") == "ZZZ Caviste")
	# Sans cela, l'autre appareil garderait l'ancien nom sur ses ingrédients.
	_check("le report est marqué à pousser",
		int(_scalar(db, "SELECT dirty FROM ingredients WHERE name='ZZZ Vin';")) == 1)

	print("--- Suppression ---")
	var renamed_id := ""
	for aisle in store.get_aisles():
		if str(aisle["name"]) == "ZZZ Caviste":
			renamed_id = str(aisle["id"])
	store.delete_aisle(renamed_id)
	_check("rayon supprimé", not store.get_aisle_names().has("ZZZ Caviste"))
	# Le contenu ne doit jamais rester rattaché à un rayon disparu.
	_check("l'ingrédient est rattaché au repli",
		_scalar(db, "SELECT aisle FROM ingredients WHERE name='ZZZ Vin';") == store.fallback_aisle())
	_check("l'article de courses aussi",
		_scalar(db, "SELECT aisle FROM shopping_items WHERE item_key='zzz-vin||';") == store.fallback_aisle())

	print("--- Le rayon de repli est protégé ---")
	var fallback_id := ""
	for aisle in store.get_aisles():
		if str(aisle["name"]) == store.fallback_aisle():
			fallback_id = str(aisle["id"])
	store.delete_aisle(fallback_id)
	_check("le repli résiste à la suppression",
		store.get_aisle_names().has(store.fallback_aisle()))

	db._db.query("DELETE FROM ingredients WHERE name LIKE 'ZZZ %';")
	db._db.query("DELETE FROM staples WHERE name LIKE 'ZZZ %';")
	db._db.query("DELETE FROM shopping_items WHERE item_key LIKE 'zzz-%';")

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _scalar(db, sql: String) -> String:
	db._db.query(sql)
	if db._db.query_result.is_empty():
		return "<aucune ligne>"
	return str(db._db.query_result[0].values()[0])

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
