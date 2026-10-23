class_name MealPlanningService
extends RefCounted
## Génération de plannings. Portage de meal_planning_service.MealPlanningService.

## Nombre de cases à remplir. Lu dans les réglages du foyer et non plus figé à 14 : le
## planning couvre de 1 à 4 semaines, à un ou deux repas par jour. La valeur de repli est
## celle de la 1.7, pour qu'un service construit sans magasin — les tests — se comporte comme
## avant. Voir 0_plan_1.8.0.md.
const FALLBACK_POSITIONS := 14
var total_positions := FALLBACK_POSITIONS

const CATEGORY_GAP := 2  ## une catégorie ne doit pas se répéter à moins de CATEGORY_GAP jours

## Cases réservées aux plats qui ne se transportent pas, en indices 0..13. Lues
## depuis les réglages du foyer plutôt que figées : le rythme de travail — donc les
## soirs sans gamelle le lendemain — varie d'un foyer à l'autre.
## Vide = mécanisme désactivé, aucune contrainte de transport à la génération.
var transport_slots: Array[int] = []

var _store  ## DataStore

func _init(store) -> void:
	_store = store
	if store != null and store.has_method("get_transport_slots"):
		transport_slots = store.get_transport_slots()
	if store != null and store.has_method("plan_slot_count"):
		total_positions = maxi(1, store.plan_slot_count())

## Génère un planning complet. excluded_season : "ete" | "hiver" | "".
func generate_random_meal_plan(excluded_season: String = "") -> MealPlan:
	var plan := MealPlan.new()
	var selected_ids: Array[String] = []

	plan.resize_positions(total_positions)
	for position in range(1, total_positions + 1):
		var f := _create_filter_for_position(position, plan, selected_ids, excluded_season)
		var recipe: Recipe = _store.get_random_recipe_with_filter(f)
		if recipe != null:
			plan.set_recipe(position - 1, recipe)
			selected_ids.append(recipe.id)
		else:
			plan.set_recipe(position - 1, null)
	return plan

## Remplace une seule case (0-indexée) en respectant les mêmes règles.
func replace_recipe_in_plan(plan: MealPlan, position: int, excluded_season: String = "") -> bool:
	if position < 0 or position >= plan.recipes.size():
		return false
	var selected_ids: Array[String] = []
	for r in plan.recipes:
		if r != null:
			selected_ids.append(r.id)
	var f := _create_filter_for_position(position + 1, plan, selected_ids, excluded_season)
	var new_recipe: Recipe = _store.get_random_recipe_with_filter(f)
	if new_recipe != null:
		plan.recipes[position] = new_recipe
		return true
	return false

func _create_filter_for_position(position: int, current_plan: MealPlan,
		selected_ids: Array[String], excluded_season: String) -> RecipeFilter:
	var f := RecipeFilter.new()
	if excluded_season != "":
		f.set_season(excluded_season)
	for rid in selected_ids:
		f.exclude_recipe(rid)
	# Sans case réservée, on ne contraint pas du tout : forcer `nobox = false` sur
	# toutes les positions exclurait les plats marqués de tout le planning.
	if not transport_slots.is_empty():
		f.set_nobox((position - 1) in transport_slots)
	# Anti-répétition de catégorie : fenêtre de ±CATEGORY_GAP jours autour de la case.
	for cat in _categories_near(current_plan, position - 1, CATEGORY_GAP):
		f.exclude_category(cat)
	return f

## Catégories présentes dans une fenêtre de ±`gap` positions autour de `index0`
## (la position `index0` elle-même est ignorée ; les cases vides aussi).
##
## Unifie génération et regénération :
##  - en génération (remplissage gauche→droite), les cases à droite sont encore vides
##    → seul le passé compte (équivaut à l'ancien "regarde les N derniers repas") ;
##  - en regénération d'une case, les voisins des DEUX côtés sont pris en compte.
func _categories_near(plan: MealPlan, index0: int, gap: int) -> Array[String]:
	var cats: Array[String] = []
	var start: int = max(0, index0 - gap)
	var end: int = min(plan.recipes.size() - 1, index0 + gap)
	for i in range(start, end + 1):
		if i == index0:
			continue
		var r = plan.recipes[i]
		if r != null:
			for c in r.categories:
				if not cats.has(c):
					cats.append(c)
	return cats
