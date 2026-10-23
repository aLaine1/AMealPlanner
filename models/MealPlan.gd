class_name MealPlan
extends Resource
## Planning de repas. Portage de models.MealPlan.
## recipes : un élément par case, chacun étant un Recipe ou null (case vide).
##
## Le nombre de cases n'est plus fixe depuis la 1.8 : il vient des réglages du foyer, que ce
## modèle ne connaît pas. Il naît donc à la taille de la 1.7 et se redimensionne à la demande
## — un planning construit sans précaution garde ainsi le comportement d'avant.

const DEFAULT_POSITIONS := 14

var recipes: Array = []  ## contient des Recipe ou null (untyped pour autoriser null)

func _init() -> void:
	recipes.resize(DEFAULT_POSITIONS)

## Ajuste le nombre de cases. Les cases existantes sont conservées : réduire n'efface que
## le surplus, agrandir complète avec des cases vides.
func resize_positions(count: int) -> void:
	recipes.resize(maxi(0, count))

func set_recipe(position: int, recipe) -> void:
	if position < 0:
		return
	if position >= recipes.size():
		recipes.resize(position + 1)
	recipes[position] = recipe

func get_recipe_at(position: int):
	if position >= 0 and position < recipes.size():
		return recipes[position]
	return null

func to_recipe_names() -> Array[String]:
	var names: Array[String] = []
	for r in recipes:
		names.append(r.nom if r != null else "")
	return names

## Agrège tous les ingrédients par (nom, unité) en sommant les quantités.
##
## `household` : nombre de convives, pour mettre les recettes à l'échelle. Zéro — la valeur par
## défaut — laisse les quantités telles qu'elles sont écrites, ce qui était le comportement
## avant les parts.
func get_all_ingredients(household: int = 0) -> Array[Ingredient]:
	var acc := {}  # key "nom||unite" -> Ingredient
	for r in recipes:
		if r == null:
			continue
		for ing in r.ingredients_for(household):
			var key := "%s||%s" % [ing.nom, ing.unite]
			if acc.has(key):
				acc[key].quantite += ing.quantite
			else:
				acc[key] = ing.duplicate_ingredient()
	var out: Array[Ingredient] = []
	for v in acc.values():
		out.append(v)
	return out

func filled_count() -> int:
	var n := 0
	for r in recipes:
		if r != null:
			n += 1
	return n
