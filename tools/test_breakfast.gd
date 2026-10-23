extends SceneTree
## Test headless : CRUD petits déjeuners + intégration liste de courses.
## godot --headless --script res://tools/test_breakfast.gd

func _initialize() -> void:
	var db := LocalDatabase.new()
	db.open()

	var check := func(label: String, ok: bool):
		print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])

	print("--- CRUD Petit Déjeuner ---")
	var before := db.fetch_all_breakfasts().size()

	var b := Breakfast.new()
	b.nom = "Porridge Test"
	var i1 := Ingredient.new(); i1.nom = "flocons avoine"; i1.quantite = 60; i1.unite = "g"
	var i2 := Ingredient.new(); i2.nom = "lait"; i2.quantite = 200; i2.unite = "ml"
	b.ingredients = [i1, i2] as Array[Ingredient]
	var bid := db.insert_breakfast(b)
	check.call("ajout", db.fetch_all_breakfasts().size() == before + 1)

	var fetched := db.fetch_breakfast_by_name("Porridge Test")
	check.call("2 ingrédients liés", fetched != null and fetched.ingredients.size() == 2)

	fetched.nom = "Porridge Modifié"
	fetched.ingredients = [i1] as Array[Ingredient]
	db.update_breakfast(fetched)
	var upd := db.fetch_breakfast_by_name("Porridge Modifié")
	check.call("update (nom + ingrédients)", upd != null and upd.ingredients.size() == 1)

	db.delete_breakfast(bid)
	check.call("soft-delete", db.fetch_all_breakfasts().size() == before)
	check.call("invisible après suppression", db.fetch_breakfast_by_name("Porridge Modifié") == null)

	print("--- Intégration liste de courses ---")
	# Recrée 2 petits déj pour tester l'agrégation
	var b1 := Breakfast.new(); b1.nom = "PD A"
	var a := Ingredient.new(); a.nom = "banane"; a.quantite = 2; a.unite = ""; a.aisle = "Fruits et Légumes"
	b1.ingredients = [a] as Array[Ingredient]
	db.insert_breakfast(b1)
	var b2 := Breakfast.new(); b2.nom = "PD B"
	var a2 := Ingredient.new(); a2.nom = "banane"; a2.quantite = 3; a2.unite = ""; a2.aisle = "Fruits et Légumes"
	b2.ingredients = [a2] as Array[Ingredient]
	db.insert_breakfast(b2)

	# Simule la sélection : ingrédients bruts des 2 PD
	var extra: Array[Ingredient] = []
	for pd in [db.fetch_breakfast_by_name("PD A"), db.fetch_breakfast_by_name("PD B")]:
		for ing in pd.ingredients:
			extra.append(ing)

	var svc := ShoppingListService.new()
	var empty_plan := MealPlan.new()
	var shopping := svc.get_shopping_list_for_plan(empty_plan, extra)

	# La banane doit être agrégée à 2+3 = 5 dans le rayon "Fruits et Légumes"
	var banane_qty := 0.0
	for ing in shopping.get("Fruits et Légumes", []):
		if ing.nom == "banane":
			banane_qty = ing.quantite
	check.call("agrégation courses (banane = 5)", int(banane_qty) == 5)

	# Nettoyage
	db.delete_breakfast(db.fetch_breakfast_by_name("PD A").id)
	db.delete_breakfast(db.fetch_breakfast_by_name("PD B").id)

	quit()
