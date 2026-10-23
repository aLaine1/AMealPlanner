class_name Ingredient
extends Resource
## Ingrédient avec quantité, unité et rayon (aisle). Portage de models.Ingredient.

@export var id: String = ""  ## UUID v4, "" si non persisté
@export var nom: String = ""
@export var quantite: float = 0.0
@export var unite: String = ""
@export var aisle: String = "Divers"  ## rayon magasin (= 'category' dans l'ancien modèle)

static func from_dict(d: Dictionary) -> Ingredient:
	var ing := Ingredient.new()
	ing.id = str(d.get("ingredient_id", d.get("id", "")))
	ing.nom = str(d.get("name", d.get("nom", "")))
	ing.quantite = float(d.get("quantity", d.get("quantite", 0.0)))
	ing.unite = str(d.get("unit", d.get("unite", "")))
	ing.aisle = str(d.get("aisle", d.get("category", "Divers")))
	return ing

func duplicate_ingredient() -> Ingredient:
	var ing := Ingredient.new()
	ing.id = id
	ing.nom = nom
	ing.quantite = quantite
	ing.unite = unite
	ing.aisle = aisle
	return ing

## "nom : quantité unité" (équivalent __str__ Python)
func to_display() -> String:
	return "%s : %d %s" % [nom, round(quantite), unite]

## "300 g", "1.5 L", "g" à quantité nulle, "" si rien n'est renseigné. Les décimales
## inutiles sont retirées : une quantité saisie « 2 » est stockée en float et
## s'afficherait sinon « 2.00 ».
func quantity_label() -> String:
	var unit := unite.strip_edges()
	if quantite <= 0.0:
		return unit
	var qty := "%d" % round(quantite) if is_equal_approx(quantite, round(quantite)) \
		else String.num(quantite, 2).rstrip("0").rstrip(".")
	return qty if unit == "" else qty + " " + unit
