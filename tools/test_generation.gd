extends SceneTree
## Test headless de la logique de génération (hors UI).
## Lancer : godot --headless --script res://tools/test_generation.gd

func _initialize() -> void:
	var store = load("res://autoload/DataStore.gd").new()
	store._db = LocalDatabase.new()
	store._db.open()
	store._refresh_cache()

	# Le marqueur « ne se transporte pas » est DÉSACTIVÉ sur une installation neuve :
	# le test doit donc l'activer explicitement, au lieu de présumer un défaut.
	store.set_transport_marker_enabled(true)
	# Vendredis et samedis, comme le défaut : les soirs sans journée de travail
	# le lendemain. Exprimés en jours de la semaine depuis la 1.8, plus en indices.
	store.set_transport_weekdays([Vector2i(4, 0), Vector2i(5, 0)])

	var svc := MealPlanningService.new(store)
	var plan := svc.generate_random_meal_plan("ete")  # exclut les recettes "ete"

	var names: Array[String] = []
	for r in plan.recipes:
		names.append(r.nom if r != null else "<vide>")

	print("--- Planning généré (14 positions) ---")
	for i in range(names.size()):
		var tag := "  [non transportable]" if i in [0, 6, 7, 13] else ""
		print("  %2d: %s%s" % [i + 1, names[i], tag])

	# Vérifs
	print("\n--- Vérifications ---")
	print("Cases remplies      : %d / 14" % plan.filled_count())

	var dup := false
	var seen := {}
	for r in plan.recipes:
		if r != null:
			if seen.has(r.id):
				dup = true
			seen[r.id] = true
	print("Aucun doublon       : %s" % ("OK" if not dup else "ÉCHEC"))

	var nobox_ok := true
	for idx in [0, 6, 7, 13]:
		var r = plan.recipes[idx]
		if r != null and not r.nobox:
			nobox_ok = false
	print("Cases réservées      : %s" % ("OK" if nobox_ok else "ÉCHEC"))

	# Désactivé, le mécanisme ne doit plus contraindre : un plat qui ne se transporte
	# pas peut alors tomber n'importe où, et surtout aucune case ne doit rester vide
	# faute de candidat.
	store.set_transport_marker_enabled(false)
	var free_svc := MealPlanningService.new(store)
	var free_plan := free_svc.generate_random_meal_plan("ete")
	var filled := 0
	for r in free_plan.recipes:
		if r != null:
			filled += 1
	print("Sans contrainte      : %s" % ("OK" if filled == 14 else "ÉCHEC"))
	store.set_transport_marker_enabled(true)

	var season_ok := true
	for r in plan.recipes:
		if r != null and r.saison == "ete":
			season_ok = false
	print("Saison 'ete' exclue  : %s" % ("OK" if season_ok else "ÉCHEC"))

	var svc2 := ShoppingListService.new()
	var shopping := svc2.get_shopping_list_for_plan(plan)
	var total := 0
	for aisle in shopping.keys():
		total += shopping[aisle].size()
	print("Liste de courses     : %d articles, %d rayons" % [total, shopping.size()])

	quit()
