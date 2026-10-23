class_name RecipeFilter
extends RefCounted
## Filtre de sélection de recettes. Portage de models.RecipeFilter.

var excluded_categories: Array[String] = []
var excluded_recipes: Array[String] = []   ## ids (UUID)
var include_nobox = null                    ## null | true | false (tri-état)
var excluded_season: String = ""            ## "" = aucune exclusion

func exclude_category(category: String) -> RecipeFilter:
	excluded_categories.append(category)
	return self

func exclude_recipe(recipe_id: String) -> RecipeFilter:
	excluded_recipes.append(recipe_id)
	return self

func set_nobox(include: bool) -> RecipeFilter:
	include_nobox = include
	return self

func set_season(season_to_exclude: String) -> RecipeFilter:
	excluded_season = season_to_exclude
	return self

func matches(recipe: Recipe) -> bool:
	# Catégories exclues
	for cat in excluded_categories:
		if recipe.categories.has(cat):
			return false
	# Recettes exclues
	if excluded_recipes.has(recipe.id):
		return false
	# NoBox (tri-état)
	if include_nobox != null:
		if include_nobox and not recipe.nobox:
			return false
		if not include_nobox and recipe.nobox:
			return false
	# Saison exclue
	if excluded_season != "" and recipe.saison == excluded_season:
		return false
	return true
