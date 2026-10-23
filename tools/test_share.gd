extends SceneTree
## Partage de recettes : aller-retour, robustesse du code, règles d'import.
## godot --headless --path . --script res://tools/test_share.gd

const Share := preload("res://services/RecipeShare.gd")

var _fails := 0

func _initialize() -> void:
	await process_frame
	var store := root.get_node_or_null("/root/DataStore")
	if store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return

	print("--- Aller-retour ---")
	var source = load("res://models/Recipe.gd").new()
	source.nom = "ZZZ Crêpes de partage"
	source.saison = "hiver"
	source.nobox = true
	source.etapes = "Mélanger.\nCuire à feu doux."
	var cats: Array[String] = ["Pâtes"]
	source.categories = cats
	var ing = load("res://models/Ingredient.gd").new()
	ing.nom = "ZZZ farine de partage"
	ing.quantite = 250.0
	ing.unite = "g"
	ing.aisle = store.fallback_aisle()
	var ings: Array[Ingredient] = [ing]
	source.ingredients = ings

	var code: String = Share.pack([source])
	_check("le code porte le préfixe versionné", code.begins_with(Share.PREFIX))
	var unpacked: Dictionary = Share.unpack(code)
	_check("déballage réussi", unpacked["ok"])
	_check("une recette", unpacked["recipes"].size() == 1)
	var entry: Dictionary = unpacked["recipes"][0]
	_check("nom conservé", str(entry["n"]) == source.nom)
	_check("saison conservée", str(entry["e"]) == "hiver")
	_check("marqueur de transport conservé", bool(entry["b"]))
	# Les sauts de ligne des étapes sont ce qui casse le plus facilement à l'encodage.
	_check("étapes et retours à la ligne conservés", str(entry["s"]) == source.etapes)
	_check("ingrédient conservé",
		entry["i"].size() == 1 and str(entry["i"][0]["n"]) == "ZZZ farine de partage"
		and float(entry["i"][0]["q"]) == 250.0)

	print("--- Codes invalides ---")
	for bad in ["", "bonjour", "AMEAL1:", "AMEAL1:pastdubase64!!", Share.PREFIX + "YWJj"]:
		var result: Dictionary = Share.unpack(bad)
		_check("refusé : %s" % (bad.substr(0, 20) if bad != "" else "(vide)"),
			not result["ok"] and str(result["error"]) != "")
	# Tronquer un code doit être détecté, pas produire une recette amputée.
	var truncated: Dictionary = Share.unpack(code.substr(0, code.length() - 20))
	_check("code tronqué détecté", not truncated["ok"])

	print("--- Import ---")
	var before: int = store.get_all_recipe_objects().size()
	var report: Dictionary = Share.import_recipes(store, unpacked["recipes"])
	_check("une recette importée", int(report["imported"]) == 1)
	_check("comptée dans le catalogue", store.get_all_recipe_objects().size() == before + 1)
	var landed = store.get_recipe_by_name("ZZZ Crêpes de partage")
	_check("relue depuis la base", landed != null and landed.ingredients.size() == 1)
	_check("ingrédient créé au passage",
		store.get_all_ingredient_names().has("ZZZ farine de partage"))

	# Réimporter ne doit RIEN écraser : l'utilisateur compare puis choisit.
	var again: Dictionary = Share.import_recipes(store, unpacked["recipes"])
	_check("le doublon est renommé, pas écrasé", int(again["renamed"]) == 1)
	_check("les deux versions coexistent",
		store.get_recipe_by_name("ZZZ Crêpes de partage") != null
		and store.get_recipe_by_name("ZZZ Crêpes de partage (2)") != null)

	print("--- Rayon inconnu du destinataire ---")
	var exotic := {"n": "ZZZ Plat exotique", "e": "toute", "b": false, "s": "", "c": [],
		"i": [{"n": "ZZZ épice rare", "q": 1, "u": "", "a": "Rayon Qui N'Existe Pas"}]}
	Share.import_recipes(store, [exotic])
	var imported = store.get_recipe_by_name("ZZZ Plat exotique")
	# Sinon on inventerait des rayons dans la liste du destinataire.
	_check("l'ingrédient tombe dans le rayon de repli",
		imported != null and imported.ingredients[0].aisle == store.fallback_aisle())
	_check("aucun rayon inventé",
		not store.get_aisle_names().has("Rayon Qui N'Existe Pas"))

	print("--- Taille des lots ---")
	var many := []
	for recipe in store.get_all_recipe_objects():
		many.append(recipe)
	var bundle: String = Share.pack(many)
	print("  %d recettes → %d o" % [many.size(), bundle.length()])
	var round_trip: Dictionary = Share.unpack(bundle)
	_check("un lot complet se déballe", round_trip["ok"]
		and round_trip["recipes"].size() == many.size())

	print("--- Partage par référence (1.6) ---")
	# Le code ne porte plus les recettes mais un jeton : c'est ce qui permet aux photos
	# de voyager, une seule d'entre elles pesant cent fois la capacité d'un QR.
	var token_code: String = Share.token_code("0123456789abcdef0123456789abcdef")
	_check("un code de référence est reconnu", Share.is_token_code(token_code))
	_check("jeton extrait", Share.extract_token(token_code) == "0123456789abcdef0123456789abcdef")
	_check("un code autoportant n'est pas pris pour une référence",
		not Share.is_token_code(bundle))
	_check("extraction refusée sur un code autoportant", Share.extract_token(bundle) == "")
	# Court : c'est tout l'intérêt — un QR de jeton reste scannable quel que soit le
	# nombre de recettes partagées.
	_check("le code de référence tient dans un QR", token_code.length() < Share.QR_LIMIT)

	print("--- Les photos voyagent avec les recettes ---")
	var photo_recipe = store.get_recipe_by_name("ZZZ Crêpes de partage")
	var pixels := Image.create(200, 150, false, Image.FORMAT_RGB8)
	pixels.fill(Color(0.2, 0.6, 0.4))
	var prepared: Dictionary = load("res://services/RecipePhoto.gd").from_image(pixels)
	store.set_recipe_photo(photo_recipe.id, prepared["image"], prepared["thumb"])

	# Sans magasin, la charge reste autoportante et donc sans photo : c'est le format
	# qu'on ne peut pas alourdir.
	var without: Dictionary = Share.unpack(Share.pack([photo_recipe]))
	_check("sans magasin, aucune photo n'est jointe", not without["recipes"][0].has("p"))

	var with_photo: Dictionary = Share.unpack(Share.pack([photo_recipe], store))
	_check("avec magasin, la photo est jointe", with_photo["recipes"][0].has("p"))

	var received: Dictionary = Share.import_recipes(store, with_photo["recipes"])
	var landed_photo = store.get_recipe_by_name("ZZZ Crêpes de partage (3)")
	if landed_photo == null:
		landed_photo = store.get_recipe_by_name("ZZZ Crêpes de partage (2)")
	_check("la recette reçue arrive avec sa photo",
		landed_photo != null and store.has_photo(landed_photo.id))
	_check("et la vignette est relisible",
		landed_photo != null and store.get_photo_thumb(landed_photo.id) != null)
	_check("une recette importée est bien comptée", int(received["imported"]) == 1)

	for name in ["ZZZ Crêpes de partage", "ZZZ Crêpes de partage (2)",
			"ZZZ Crêpes de partage (3)", "ZZZ Plat exotique"]:
		var recipe = store.get_recipe_by_name(name)
		if recipe != null:
			store.delete_recipe_by_id(recipe.id)
	store.delete_ingredient_by_name("ZZZ farine de partage")
	store.delete_ingredient_by_name("ZZZ épice rare")

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
