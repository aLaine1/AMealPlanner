extends SceneTree
## Parts par recette : mise à l'échelle des quantités selon la taille du foyer.
## godot --headless --path . --script res://tools/test_servings.gd
##
## Le point délicat n'est pas le calcul, c'est sa NEUTRALITÉ. Une collection saisie avant la 1.8
## ne porte aucun nombre de parts ; ses quantités ne doivent pas bouger d'un gramme. Un facteur
## appliqué là où il ne fallait pas se verrait au magasin, pas à l'écran — trop tard.
##
## Voir 0_plan_1.8.0.md, étape 5 et décision D4.

var _fails := 0
var _store

func _initialize() -> void:
	await process_frame
	_store = root.get_node_or_null("/root/DataStore")
	if _store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return

	_test_factor()
	_test_neutral_without_servings()
	_test_scaled_shopping_list()
	_test_share_round_trip()
	await _test_slider()

	print("")
	print("Parts conformes." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _test_factor() -> void:
	print("--- Le facteur d'échelle ---")
	var r := Recipe.new()
	r.servings = 2
	_check("recette pour 2, foyer de 4 → x2", is_equal_approx(r.scale_for(4), 2.0))
	_check("recette pour 2, foyer de 2 → x1", is_equal_approx(r.scale_for(2), 1.0))
	_check("recette pour 4, foyer de 2 → x0,5", is_equal_approx(Recipe.new().scale_for(2), 1.0))
	r.servings = 4
	_check("recette pour 4, foyer de 2 → x0,5", is_equal_approx(r.scale_for(2), 0.5))
	# Les deux garde-fous : sans l'un ou l'autre des nombres, on ne calcule RIEN.
	r.servings = 0
	_check("parts non renseignées → x1", is_equal_approx(r.scale_for(4), 1.0))
	r.servings = 4
	_check("foyer inconnu → x1", is_equal_approx(r.scale_for(0), 1.0))

## La garantie de la décision D4 : une collection d'avant la 1.8 ne bouge pas.
func _test_neutral_without_servings() -> void:
	print("--- Neutralité sur une recette sans parts ---")
	var recipes: Array = _store.get_all_recipe_objects()
	var source = recipes[0]
	_check("les recettes d'exemple n'ont pas de parts", source.servings == 0)

	var scaled: Array = source.ingredients_for(_store.household_servings())
	var same: bool = scaled.size() == source.ingredients.size()
	for index in range(min(scaled.size(), source.ingredients.size())):
		if not is_equal_approx(scaled[index].quantite, source.ingredients[index].quantite):
			same = false
	_check("  quantités inchangées, au gramme près", same)
	_check("  et la recette stockée n'a pas été touchée",
		is_equal_approx(_store.get_recipe_by_name(source.nom).ingredients[0].quantite,
			source.ingredients[0].quantite))

func _test_scaled_shopping_list() -> void:
	print("--- Liste de courses mise à l'échelle ---")
	var recipes: Array = _store.get_all_recipe_objects()
	var source = recipes[0]
	var plan := MealPlan.new()
	plan.resize_positions(2)
	# La MÊME recette, écrite pour 2 parts, dans un foyer de 4 : les quantités doublent, et
	# deux fois dans le planning les double encore.
	var doubled := Recipe.new()
	doubled.nom = source.nom
	doubled.servings = 2
	doubled.ingredients = source.ingredients
	plan.set_recipe(0, doubled)
	plan.set_recipe(1, doubled)

	var service := ShoppingListService.new()
	var by_aisle: Dictionary = service.get_shopping_list_for_plan(plan, [], 4)
	var got := {}
	for aisle in by_aisle:
		for ing in by_aisle[aisle]:
			got[ShoppingListService.item_key(ing.nom, ing.unite)] = ing.quantite

	var wrong := []
	for ing in source.ingredients:
		var key := ShoppingListService.item_key(ing.nom, ing.unite)
		var expected: float = ing.quantite * 2.0 * 2.0   # x2 pour le foyer, x2 pour les deux cases
		if not got.has(key) or not is_equal_approx(float(got[key]), expected):
			wrong.append("%s : %.2f ≠ %.2f" % [key, got.get(key, -1.0), expected])
	_check("recette pour 2 servie à 4, deux fois : quantités x4%s" % (
		"" if wrong.is_empty() else " (%s)" % ", ".join(wrong)), wrong.is_empty())

	# Sans taille de foyer, rien n'est mis à l'échelle : c'est le comportement d'avant.
	var raw: Dictionary = service.get_shopping_list_for_plan(plan, [], 0)
	var raw_got := {}
	for aisle in raw:
		for ing in raw[aisle]:
			raw_got[ShoppingListService.item_key(ing.nom, ing.unite)] = ing.quantite
	var first = source.ingredients[0]
	_check("foyer inconnu : quantités telles qu'écrites",
		is_equal_approx(float(raw_got[ShoppingListService.item_key(first.nom, first.unite)]),
			first.quantite * 2.0))

## Le partage transporte les parts — sans quoi une recette reçue serait servie au petit
## bonheur, ce qui est précisément ce que ce champ vient corriger entre foyers.
func _test_share_round_trip() -> void:
	print("--- Les parts voyagent avec la recette ---")
	var Share := load("res://services/RecipeShare.gd")
	var r := Recipe.new()
	r.nom = "ZZZ Recette à parts"
	r.saison = "toute"
	r.servings = 6
	var ing := Ingredient.new()
	ing.nom = "farine"
	ing.quantite = 300.0
	ing.unite = "g"
	r.ingredients = [ing] as Array[Ingredient]

	var unpacked: Dictionary = Share.unpack(Share.pack([r]))
	_check("le code se relit", bool(unpacked.get("ok", false)))
	var entry: Dictionary = unpacked["recipes"][0]
	_check("  les parts sont dans la charge", int(entry.get("d", 0)) == 6)
	# La lettre « p » désigne la PHOTO : la collision faisait lire une image comme un nombre.
	_check("  et n'écrasent pas la photo", not entry.has("p") or entry.get("p") is Dictionary)

## Le curseur des parts de la fiche recette.
##
## Il porte DEUX rôles selon le mode, et c'est là que se joue le seul vrai risque : en
## lecture il met les quantités à l'échelle pour montrer la recette « pour huit », en
## édition il ne fait que déclarer un nombre de parts. Enchaîner les deux — consulter pour
## huit, puis cliquer sur Modifier — ne doit PAS réécrire la recette avec les quantités
## affichées. La perte serait silencieuse et définitive : la recette d'origine n'existe
## plus nulle part.
func _test_slider() -> void:
	print("--- Curseur des parts de la fiche ---")
	root.size = Vector2i(412, 915)
	await process_frame

	var recipe := Recipe.new()
	recipe.nom = "ZZZ Recette au curseur"
	recipe.servings = 4
	var flour := Ingredient.new()
	flour.nom = "Farine"
	flour.quantite = 200.0
	flour.unite = "g"
	var eggs := Ingredient.new()
	eggs.nom = "Oeufs"
	eggs.quantite = 3.0
	recipe.ingredients = [flour, eggs] as Array[Ingredient]
	var recipe_id: String = _store.add_recipe(recipe)
	recipe = _store.get_recipe_by_id(recipe_id)

	var popup: Window = load("res://ui/recipes/RecipePopup.gd").new()
	popup.recipe = recipe
	popup.editable = false
	root.add_child(popup)
	await process_frame
	await process_frame

	_check("le curseur part des parts de la recette", int(popup._servings.value) == 4)
	_check("  et va de 1 à 12",
		popup._servings.min_value == 1 and popup._servings.max_value == 12)
	_check("  il est posé entre le titre et « + Ajouter »",
		popup._servings.get_index() < popup._add_btn.get_index())
	_check("quantités affichées telles qu'écrites",
		popup._rows[0]["qty"].text == "200")

	# LECTURE : le curseur met les quantités à l'échelle, à l'écran seulement.
	popup._servings.value = 8
	await process_frame
	_check("pour 8 : la farine double (%s)" % popup._rows[0]["qty"].text,
		popup._rows[0]["qty"].text == "400")
	_check("  et les oeufs aussi", popup._rows[1]["qty"].text == "6")
	_check("  la recette en base n'a pas bougé",
		is_equal_approx(_store.get_recipe_by_id(recipe_id).ingredients[0].quantite, 200.0))

	# Retour en arrière SANS dérive : chaque valeur repart de la quantité écrite, et non
	# de celle affichée — sinon les arrondis s'ajouteraient à chaque mouvement.
	popup._servings.value = 3
	await process_frame
	popup._servings.value = 4
	await process_frame
	_check("aller-retour : la quantité d'origine revient exactement (%s)"
		% popup._rows[0]["qty"].text, popup._rows[0]["qty"].text == "200")

	# LE POINT CRITIQUE : passer en édition après avoir mis à l'échelle.
	popup._servings.value = 8
	await process_frame
	popup._on_start_editing()
	await process_frame
	_check("passage en édition : les quantités écrites reviennent",
		popup._rows[0]["qty"].text == "200")
	_check("  et le curseur reprend les parts de la recette",
		int(popup._servings.value) == 4)

	# ÉDITION : le curseur ne déclare que le nombre de parts.
	popup._servings.value = 6
	await process_frame
	_check("en édition, les quantités ne bougent pas",
		popup._rows[0]["qty"].text == "200")
	popup._on_save()
	await process_frame
	var saved = _store.get_recipe_by_id(recipe_id)
	_check("enregistré : 6 parts", saved.servings == 6)
	_check("  quantités intactes en base",
		is_equal_approx(saved.ingredients[0].quantite, 200.0))

	# `_on_save` referme la fiche : plus rien à libérer ici.
	_store.delete_recipe_by_id(recipe_id)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
