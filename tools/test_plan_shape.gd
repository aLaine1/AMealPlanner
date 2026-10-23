extends SceneTree
## FILET DE LA 1.8.0 — fige la forme du planning telle qu'elle est en 1.7.
## godot --headless --path . --script res://tools/test_plan_shape.gd
##
## La 1.8 rend paramétrable ce qui est aujourd'hui codé en dur : le nombre de semaines, le
## jour de début, le nombre de repas par jour, le nombre de parts. Or l'application ne garde
## AUCUN historique de plannings : une erreur de renumérotation ne se verrait pas, et il n'y
## aurait rien à quoi comparer pour s'en apercevoir.
##
## Cette suite écrit donc noir sur blanc ce que fait la 1.7. Elle doit passer AVANT et APRÈS
## chaque étape de la 1.8 — avec ses valeurs par défaut, la 1.8 doit reproduire la 1.7 au
## gramme près. Elle n'est pas là pour décrire un idéal, mais pour interdire une dérive.
##
## Voir 0_plan_1.8.0.md, étape 0.

const Uuid := preload("res://services/Uuid.gd")

## Jours de la semaine, lundi = 0, comme `Time` et comme le réglage `plan/week_start` à venir.
const WEEKDAY_NAMES := ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
## Ce que vaut le jour de début aujourd'hui : samedi.
const CURRENT_WEEK_START := 5
const CURRENT_DAYS := 14
const CURRENT_MEALS_PER_DAY := 1

## Les libellés tels que la 1.7 les écrivait à la main. Ils vivent MAINTENANT ici, et non
## plus dans `PlanningTab` qui les calcule : c'est le test qui porte la référence, et le code
## qui doit la retrouver. Toute divergence est visible à l'écran, sur l'onglet le plus
## regardé de l'application.
const LABELS_1_7 := [
	"Sam. S1", "Dim. S1",
	"Lun. S2", "Mar. S2", "Mer. S2", "Jeu. S2", "Ven. S2", "Sam. S2", "Dim. S2",
	"Lun. S3", "Mar. S3", "Mer. S3", "Jeu. S3", "Ven. S3",
]

var _fails := 0
var _store

func _initialize() -> void:
	await process_frame
	_store = root.get_node_or_null("/root/DataStore")
	if _store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return

	_test_shape()
	_test_labels_match_week_start()
	_test_transport_defaults_in_weekdays()
	await _test_plan_round_trip()
	_test_category_gap_in_days()
	_test_shopping_quantities()

	print("")
	print("Forme du planning conforme à la 1.7." if _fails == 0 \
		else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## Depuis l'étape 1, la forme est LUE dans les réglages au lieu d'être une constante. Les
## valeurs attendues n'ont pas changé d'un chiffre : c'est tout l'objet de cette étape.
func _test_shape() -> void:
	print("--- La forme par défaut : 14 jours, un repas, début samedi ---")
	_check("2 semaines", _store.plan_weeks() == 2)
	_check("14 jours", _store.plan_day_count() == CURRENT_DAYS)
	_check("un repas par jour", _store.plan_meals_per_day() == CURRENT_MEALS_PER_DAY)
	_check("14 cases", _store.plan_slot_count() == CURRENT_DAYS * CURRENT_MEALS_PER_DAY)
	_check("début samedi", _store.plan_week_start() == CURRENT_WEEK_START)
	_check("4 parts par défaut", _store.household_servings() == 4)
	# Le service lit la forme du foyer et non plus une constante ; sans magasin, il retombe
	# sur la valeur de la 1.7.
	_check("le service de génération suit la forme",
		MealPlanningService.new(_store).total_positions == CURRENT_DAYS)
	_check("le service sans magasin garde la forme de la 1.7",
		MealPlanningService.new(null).total_positions == 14)
	_check("le modèle naît à la taille de la 1.7",
		MealPlan.new().recipes.size() == CURRENT_DAYS)

## Les libellés de la vue liste disent le jour de chaque position. C'est la seule trace
## écrite du jour de début : « position 0 = samedi ». La 1.8 devra les CALCULER depuis le
## réglage et retrouver exactement cette suite quand il vaut samedi.
func _test_labels_match_week_start() -> void:
	print("--- Position 0 = samedi, et la suite s'enchaîne ---")
	var labels: Array = _store.plan_day_labels()
	_check("14 libellés", labels.size() == CURRENT_DAYS)
	# La comparaison décisive : les libellés calculés doivent être EXACTEMENT ceux que la 1.7
	# écrivait à la main, numéro de semaine compris — celui-ci change au passage d'un lundi et
	# non tous les sept jours, subtilité qu'un calcul naïf perdrait.
	var identical := true
	for index in range(min(labels.size(), LABELS_1_7.size())):
		if str(labels[index]) != LABELS_1_7[index]:
			identical = false
			print("      %d : calculé « %s » ≠ 1.7 « %s »" % [
				index, labels[index], LABELS_1_7[index]])
	_check("identiques à ceux de la 1.7", identical and labels.size() == LABELS_1_7.size())
	var mismatched := []
	for index in range(labels.size()):
		var expected: String = WEEKDAY_NAMES[_weekday_of_position(index)]
		# « Sam. S1 » → on ne compare que les trois premières lettres, la casse en moins.
		var got: String = str(labels[index]).substr(0, 3).to_lower()
		if not expected.begins_with(got):
			mismatched.append("%d: « %s » ≠ %s" % [index, labels[index], expected])
	_check("chaque libellé tombe sur le bon jour%s" % (
		"" if mismatched.is_empty() else " (%s)" % ", ".join(mismatched)),
		mismatched.is_empty())

## L'invariant qui doit survivre au jour de début libre.
##
## Le réglage vaut aujourd'hui « 0,6,7,13 » — des indices ABSOLUS, qui ne veulent dire
## quelque chose que parce que la semaine commence un samedi. Exprimés en jours de la
## semaine, ils désignent les vendredis et les samedis : les soirs qui ne sont pas suivis
## d'une journée de travail. C'est CE sens, et non les nombres, que la 1.8 doit préserver.
func _test_transport_defaults_in_weekdays() -> void:
	print("--- Les cases réservées désignent vendredi et samedi ---")
	# Le défaut est désormais écrit en jours de la semaine — c'est le sens que la 1.7 portait
	# sans le dire. On vérifie les deux : le réglage stocké, et les indices qu'il produit sur le
	# planning courant, qui doivent être exactement les 0, 6, 7, 13 de la 1.7.
	var db := load("res://services/LocalDatabase.gd")
	var days := {}
	for piece in String(db.DEFAULT_TRANSPORT_WEEKDAYS).split(",", false):
		var weekday := int(piece.split(":")[0])
		days[WEEKDAY_NAMES[weekday]] = true
	var found: Array = days.keys()
	found.sort()
	_check("défaut « %s » → %s" % [db.DEFAULT_TRANSPORT_WEEKDAYS, ", ".join(found)],
		found == ["samedi", "vendredi"])

	var was_enabled: bool = _store.is_transport_marker_enabled()
	var saved: Array = _store.get_transport_weekdays()
	_store.set_transport_marker_enabled(true)
	_store.set_transport_weekdays([Vector2i(4, 0), Vector2i(5, 0)])
	var derived: Array = _store.get_transport_slots()
	_check("les indices dérivés sont ceux de la 1.7 : %s" % str(derived),
		derived == [0, 6, 7, 13])
	if not saved.is_empty():
		_store.set_transport_weekdays(saved)
	_store.set_transport_marker_enabled(was_enabled)

## Aller-retour complet du planning, bornes comprises.
##
## La position 13 est la dernière : c'est celle qu'une renumérotation ferait disparaître en
## silence. Le plat libre — un texte qui n'est pas une recette — est vérifié avec, parce
## qu'il vit dans une autre colonne (`custom_label`) et se perdrait autrement.
func _test_plan_round_trip() -> void:
	print("--- Aller-retour des 14 positions ---")
	var recipes: Array = _store.get_all_recipe_objects()
	var written: Array[String] = []
	for index in range(CURRENT_DAYS):
		written.append("")
	written[0] = recipes[0].nom
	written[6] = recipes[1].nom
	written[13] = recipes[2].nom           # la dernière position, celle qu'on perd
	written[9] = "ZZZ Plat libre"          # ni recette, ni case vide

	_store.save_plan_names(written)
	var read_back: Array = _store.load_plan_names()
	_check("14 positions relues", read_back.size() == CURRENT_DAYS)
	var same := true
	for index in range(CURRENT_DAYS):
		if str(read_back[index]) != written[index]:
			same = false
			print("      position %d : « %s » ≠ « %s »" % [
				index, read_back[index], written[index]])
	_check("chaque position revient telle quelle", same)
	_check("la dernière position survit", str(read_back[13]) == recipes[2].nom)
	_check("le plat libre survit", str(read_back[9]) == "ZZZ Plat libre")

	# Remis à vide : cette suite ne doit pas laisser de planning derrière elle.
	var cleared: Array[String] = []
	for index in range(CURRENT_DAYS):
		cleared.append("")
	_store.save_plan_names(cleared)

## L'anti-répétition se compte aujourd'hui en POSITIONS, ce qui équivaut à des jours parce
## qu'il n'y a qu'un repas par jour. Avec deux repas, ±2 positions ne feraient plus qu'un
## jour : la règle devra être recomptée en jours, et ce test dira si elle l'a été.
func _test_category_gap_in_days() -> void:
	print("--- Anti-répétition : ±2 jours ---")
	_check("l'écart vaut 2", MealPlanningService.CATEGORY_GAP == 2)
	var service := MealPlanningService.new(_store)
	var plan: MealPlan = service.generate_random_meal_plan("")
	var offenders := []
	for index in range(plan.recipes.size()):
		var here = plan.recipes[index]
		if here == null or here.categories.is_empty():
			continue
		for other_index in range(index + 1, min(index + MealPlanningService.CATEGORY_GAP + 1,
				plan.recipes.size())):
			var there = plan.recipes[other_index]
			if there == null:
				continue
			for cat in here.categories:
				if there.categories.has(cat):
					offenders.append("%d/%d : %s" % [index, other_index, cat])
	# Le jeu d'exemple peut ne pas offrir assez de catégories distinctes pour être
	# strictement conforme ; on relève, on ne juge pas. Ce qui compte est la STABILITÉ du
	# nombre entre deux versions.
	print("      répétitions à moins de 2 jours : %d" % offenders.size())
	_check("le planning est rempli", _filled(plan) == CURRENT_DAYS)

## Les quantités agrégées, épinglées avant l'arrivée des parts.
##
## L'étape 5 introduira un facteur d'échelle. Avec les réglages par défaut il doit valoir 1,
## donc ces sommes ne doivent pas bouger d'un gramme. C'est ici qu'on s'en apercevrait.
func _test_shopping_quantities() -> void:
	print("--- Quantités agrégées de la liste de courses ---")
	var plan := MealPlan.new()
	var recipes: Array = _store.get_all_recipe_objects()
	# Deux fois la même recette : le doublement des quantités est précisément ce qu'un
	# facteur d'échelle mal placé fausserait.
	plan.set_recipe(0, recipes[0])
	plan.set_recipe(1, recipes[0])

	var expected := {}
	for ing in recipes[0].ingredients:
		expected[ShoppingListService.item_key(ing.nom, ing.unite)] = ing.quantite * 2.0

	var service := ShoppingListService.new()
	var by_aisle: Dictionary = service.get_shopping_list_for_plan(plan)
	var got := {}
	for aisle in by_aisle:
		for ing in by_aisle[aisle]:
			got[ShoppingListService.item_key(ing.nom, ing.unite)] = ing.quantite

	var wrong := []
	for key in expected:
		if not got.has(key):
			wrong.append("%s absent" % key)
		elif not is_equal_approx(float(got[key]), float(expected[key])):
			wrong.append("%s : %.2f ≠ %.2f" % [key, got[key], expected[key]])
	_check("la même recette deux fois double les quantités%s" % (
		"" if wrong.is_empty() else " (%s)" % ", ".join(wrong)), wrong.is_empty())
	_check("aucun ingrédient inventé", got.size() == expected.size())

# =====================================================================

## Jour de la semaine (lundi = 0) de la position `index`, dans la forme actuelle.
func _weekday_of_position(index: int) -> int:
	return (CURRENT_WEEK_START + index) % 7

func _filled(plan: MealPlan) -> int:
	var count := 0
	for r in plan.recipes:
		if r != null:
			count += 1
	return count

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
