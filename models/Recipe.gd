class_name Recipe
extends Resource
## Recette complète. Portage de models.Recipe.

## UUID v4 (texte). "" = recette pas encore persistée. Cf. services/Uuid.gd pour
## la raison du passage d'un entier auto-incrémenté à un UUID.
@export var id: String = ""
@export var nom: String = ""
@export var saison: String = "toute"   ## "ete" | "hiver" | "toute"
@export var nobox: bool = false
@export var etapes: String = ""
## Nombre de parts pour lequel la recette est ÉCRITE. 0 = non renseigné, ce qui se lit
## « autant que le foyer » : le facteur d'échelle vaut alors 1 et les quantités sont prises
## telles quelles. C'est ce qui rend l'arrivée des parts sans effet sur une collection déjà
## saisie — voir 0_plan_1.8.0.md, décision D4.
@export var servings: int = 0
@export var categories: Array[String] = []

var ingredients: Array[Ingredient] = []

const MEAT_KEYWORDS := ["viande", "porc", "boeuf", "agneau", "jambon", "saumon", "thon"]

static func from_dict(d: Dictionary) -> Recipe:
	var r := Recipe.new()
	r.id = str(d.get("id", ""))
	r.nom = str(d.get("name", d.get("nom", "")))
	r.saison = str(d.get("season", d.get("saison", "toute")))
	r.nobox = bool(d.get("nobox", false))
	r.etapes = str(d.get("steps", d.get("etapes", "")))
	r.servings = maxi(0, int(d.get("servings", d.get("parts", 0))))
	var cats: Array[String] = []
	for c in d.get("categories", []):
		cats.append(str(c))
	r.categories = cats
	var ings: Array[Ingredient] = []
	for ing_data in d.get("ingredients", []):
		ings.append(Ingredient.from_dict(ing_data))
	r.ingredients = ings
	return r

## Facteur à appliquer aux quantités pour nourrir `household` personnes.
##
## Vaut 1 dès que l'un des deux nombres manque : une recette sans parts renseignées est prise
## telle qu'elle est écrite, ce qui est le comportement d'avant les parts et le seul qui ne
## surprenne personne. C'est aussi ce qui rend la migration neutre.
func scale_for(household: int) -> float:
	if servings <= 0 or household <= 0:
		return 1.0
	return float(household) / float(servings)

## Ingrédients mis à l'échelle du foyer. Les quantités STOCKÉES ne sont jamais réécrites : la
## recette reste ce qu'elle est, seul ce qu'on en tire change.
func ingredients_for(household: int) -> Array[Ingredient]:
	var factor := scale_for(household)
	var out: Array[Ingredient] = []
	for ing in ingredients:
		var copy := ing.duplicate_ingredient()
		copy.quantite = ing.quantite * factor
		out.append(copy)
	return out

func is_vegetarian() -> bool:
	for ing in ingredients:
		var low := ing.nom.to_lower()
		for kw in MEAT_KEYWORDS:
			if low.contains(kw):
				return false
	return true

func has_ingredient(ingredient_name: String) -> bool:
	var needle := ingredient_name.to_lower()
	for ing in ingredients:
		if ing.nom.to_lower().contains(needle):
			return true
	return false
