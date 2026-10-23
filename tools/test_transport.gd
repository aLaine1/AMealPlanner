extends SceneTree
## Marqueur « ne se transporte pas » : réglage, cases réservées, désactivation.
## godot --headless --path . --script res://tools/test_transport.gd
##
## Un plat marqué se transporte mal en gamelle : on le réserve aux soirs qui ne sont
## pas suivis d'une journée de travail. Quels soirs dépend du rythme du foyer, d'où le
## réglage — et tout le monde n'emporte pas son repas, d'où l'interrupteur.

var _fails := 0

func _initialize() -> void:
	await process_frame
	var store := root.get_node_or_null("/root/DataStore")
	if store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return

	print("--- Défaut sur une installation neuve ---")
	# Désactivé par défaut : un foyer qui n'emporte pas ses repas ne doit pas se voir
	# imposer la notion. La migration l'active si des recettes portent déjà le marqueur.
	_check("désactivé par défaut", not store.is_transport_marker_enabled())
	_check("aucune case réservée tant qu'il est désactivé",
		store.get_transport_slots().is_empty())

	print("--- Activation et cases réservées ---")
	store.set_transport_marker_enabled(true)
	# Vendredi et samedi, et non plus des indices absolus : le rythme de travail est
	# hebdomadaire. Les indices en sont DÉRIVÉS pour le planning courant — 14 jours à partir
	# d'un samedi donnent bien 0, 6, 7, 13, ce qui vérifie la dérivation autant que le réglage.
	store.set_transport_weekdays([Vector2i(4, 0), Vector2i(5, 0)])
	_check("activé", store.is_transport_marker_enabled())
	var expected: Array[int] = [0, 6, 7, 13]
	_check("cases dérivées pour 14 jours à partir d'un samedi",
		store.get_transport_slots() == expected)

	var service := MealPlanningService.new(store)
	var plan := service.generate_random_meal_plan("ete")
	var respected := true
	var filled := 0
	for index in range(14):
		var recipe = plan.get_recipe_at(index)
		if recipe == null:
			continue
		filled += 1
		if index in [0, 6, 7, 13] and not recipe.nobox:
			respected = false
	_check("les cases réservées reçoivent des plats marqués", respected)
	_check("les 14 cases sont remplies", filled == 14)

	print("--- Cases personnalisées ---")
	# Lundi et mardi : jours 2 et 9 du planning courant, ainsi que 3 et 10.
	store.set_transport_weekdays([Vector2i(0, 0), Vector2i(1, 0)])
	var custom := MealPlanningService.new(store)
	var custom_plan := custom.generate_random_meal_plan("")
	var custom_ok := true
	for index in [2, 3, 9, 10]:
		var recipe = custom_plan.get_recipe_at(index)
		if recipe != null and not recipe.nobox:
			custom_ok = false
	# Les anciennes positions ne doivent plus rien imposer.
	_check("les cases choisies sont respectées", custom_ok)
	var expected_custom: Array[int] = [2, 3, 9, 10]
	_check("le réglage est bien pris en compte à la construction du service",
		custom.transport_slots == expected_custom)

	print("--- Désactivation ---")
	store.set_transport_marker_enabled(false)
	var free := MealPlanningService.new(store)
	_check("plus aucune case réservée", free.transport_slots.is_empty())
	var free_plan := free.generate_random_meal_plan("ete")
	var free_filled := 0
	for index in range(14):
		if free_plan.get_recipe_at(index) != null:
			free_filled += 1
	# Sans contrainte, la génération doit rester capable de remplir : forcer
	# `nobox = false` partout exclurait au contraire les plats marqués du planning.
	_check("le planning se remplit toujours", free_filled == 14)

	store.set_transport_marker_enabled(false)
	store.set_transport_weekdays([Vector2i(4, 0), Vector2i(5, 0)])

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
