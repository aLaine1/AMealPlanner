class_name Breakfast
extends Resource
## Choix de petit déjeuner : un nom + une liste d'ingrédients (comme une mini-recette).
## Entité distincte des recettes de dîner (décision produit).

@export var id: String = ""  ## UUID v4, "" si non persisté
@export var nom: String = ""
var ingredients: Array[Ingredient] = []
