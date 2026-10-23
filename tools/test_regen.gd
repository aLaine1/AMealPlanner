extends SceneTree
## Test headless : regénération d'une seule case (E4).
## godot --headless --script res://tools/test_regen.gd

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
	var check := func(label: String, ok: bool):
		print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])

	var plan := svc.generate_random_meal_plan("ete")

	# --- Case standard (position 3, 0-indexée) ---
	var pos := 3
	var before = plan.recipes[pos]
	var ok := svc.replace_recipe_in_plan(plan, pos, "ete")
	var after = plan.recipes[pos]
	check.call("remplacement réussi", ok)
	check.call("recette différente", after != null and after.id != before.id)
	check.call("pas de doublon introduit", not _has_duplicate(plan))
	check.call("saison 'ete' respectée", after.saison != "ete")
	check.call("pas de catégorie répétée à ±2 jours (case regénérée)",
		not _category_clash(plan, pos, 2))

	# --- Toutes les cases respectent la fenêtre ±2 après génération globale ---
	var all_ok := true
	for i in range(plan.recipes.size()):
		if _category_clash(plan, i, 2):
			all_ok = false
	check.call("génération globale : aucune répétition de catégorie à ±2 jours", all_ok)

	# --- Une case réservée doit le rester après regénération ---
	var nb_ok := svc.replace_recipe_in_plan(plan, 0, "ete")
	check.call("case réservée le reste", nb_ok and plan.recipes[0].nobox)

	# --- Toutes les positions restent valides ---
	check.call("14 cases toujours remplies", plan.filled_count() == 14)

	quit()

func _ids(plan) -> Array:
	var out := []
	for r in plan.recipes:
		if r != null:
			out.append(r.id)
	return out

## Vrai si la recette en `pos` partage une catégorie avec un voisin à ±`gap` (cases vides ignorées).
func _category_clash(plan, pos: int, gap: int) -> bool:
	var r = plan.recipes[pos]
	if r == null:
		return false
	var start: int = max(0, pos - gap)
	var end: int = min(plan.recipes.size() - 1, pos + gap)
	for i in range(start, end + 1):
		if i == pos:
			continue
		var other = plan.recipes[i]
		if other == null:
			continue
		for c in r.categories:
			if other.categories.has(c):
				return true
	return false

func _has_duplicate(plan) -> bool:
	var seen := {}
	for r in plan.recipes:
		if r != null:
			if seen.has(r.id):
				return true
			seen[r.id] = true
	return false
