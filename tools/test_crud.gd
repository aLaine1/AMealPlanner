extends SceneTree
## Test headless du CRUD SQLite (add / update / delete, recettes + ingrédients).
## godot --headless --script res://tools/test_crud.gd

func _initialize() -> void:
	var db := LocalDatabase.new()
	db.open()

	var pass_count := 0
	var fail_count := 0
	var check := func(label: String, ok: bool):
		print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])

	# Comptes de départ : le test doit se refermer dessus, quel que soit le jeu de
	# données (base réelle ou jeu d'exemple sur une base jetable).
	var initial_recipes := db.fetch_all_recipes().size()

	print("--- CRUD Ingrédient ---")
	var before := db.fetch_all_ingredients().size()
	db.insert_ingredient("TestIngrédient", "Frais")
	var after_add := db.fetch_all_ingredients().size()
	check.call("ajout ingrédient", after_add == before + 1)

	# update
	var target: Ingredient = null
	for i in db.fetch_all_ingredients():
		if i.nom == "TestIngrédient":
			target = i
	target.aisle = "Picard"
	db.update_ingredient(target)
	var reread: Ingredient = null
	for i in db.fetch_all_ingredients():
		if i.nom == "TestIngrédient":
			reread = i
	check.call("update ingrédient (aisle=Picard)", reread != null and reread.aisle == "Picard")

	db.delete_ingredient_by_name("TestIngrédient")
	var after_del := db.fetch_all_ingredients().size()
	check.call("soft-delete ingrédient", after_del == before)

	print("--- CRUD Recette ---")
	var r := Recipe.new()
	r.nom = "Recette Test Zzz"
	r.saison = "hiver"
	r.nobox = true
	r.etapes = "Étape 1.\nÉtape 2."
	r.categories = ["Pâtes"] as Array[String]
	var ing := Ingredient.new()
	ing.nom = "pâtes"
	ing.quantite = 200.0
	ing.unite = "g"
	r.ingredients = [ing] as Array[Ingredient]

	var rec_before := db.fetch_all_recipes().size()
	var new_id := db.insert_recipe(r)
	var fetched := db.fetch_recipe_by_name("Recette Test Zzz")
	check.call("ajout recette", fetched != null and fetched.ingredients.size() == 1)
	check.call("recette nobox + saison", fetched.nobox and fetched.saison == "hiver")
	check.call("recette catégorie liée", fetched.categories.has("Pâtes"))

	# update : renommer + changer ingrédients
	fetched.nom = "Recette Test Modifiée"
	fetched.nobox = false
	var ing2 := Ingredient.new()
	ing2.nom = "tomate"
	ing2.quantite = 3
	ing2.unite = ""
	fetched.ingredients = [ing2] as Array[Ingredient]
	db.update_recipe(fetched)
	var upd := db.fetch_recipe_by_name("Recette Test Modifiée")
	check.call("update recette (nom, ingrédients remplacés)",
		upd != null and not upd.nobox and upd.ingredients.size() == 1 and upd.ingredients[0].nom == "tomate")

	# L'éditeur ne saisit pas le rayon : ses ingrédients arrivent avec celui par défaut du
	# modèle. Enregistrer la recette ne doit pas pour autant déplacer un ingrédient existant.
	db.insert_ingredient("ZZZ Rayonné", "Frais")
	var ing3 := Ingredient.new()
	ing3.nom = "zzz rayonné"
	ing3.quantite = 1
	upd.ingredients = [ing3] as Array[Ingredient]
	db.update_recipe(upd)
	var kept := ""
	for i in db.fetch_all_ingredients():
		if i.nom == "ZZZ Rayonné":
			kept = i.aisle
	check.call("éditer une recette garde le rayon de ses ingrédients (%s)" % kept, kept == "Frais")
	upd = db.fetch_recipe_by_name("Recette Test Modifiée")
	db.delete_ingredient_by_name("ZZZ Rayonné")

	db.delete_recipe(new_id)
	var rec_after := db.fetch_all_recipes().size()
	check.call("soft-delete recette", rec_after == rec_before)
	check.call("recette supprimée invisible", db.fetch_recipe_by_name("Recette Test Modifiée") == null)

	print("--- Persistance (recomptage) ---")
	check.call("aucune fuite : compte de recettes inchangé",
		db.fetch_all_recipes().size() == initial_recipes)

	quit()
