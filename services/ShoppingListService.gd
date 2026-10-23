class_name ShoppingListService
extends RefCounted
## Génération de la liste de courses : agrège les ingrédients du planning + extras
## (petits déjeuners, articles de base) par rayon.
##
## Les "articles de base" ne sont plus codés en dur : ils sont désormais éditables
## (table staples / DataStore) et passés par l'appelant via `extra` (F4).

## Renvoie { aisle: Array[Ingredient] }.
## `extra` : ingrédients supplémentaires à fusionner (petits déjeuners, articles de base).
## `household` : nombre de convives. Les recettes écrites pour un autre nombre de parts sont
## mises à l'échelle ICI, à l'agrégation — jamais en base. Zéro laisse les quantités telles
## qu'elles sont écrites.
func get_shopping_list_for_plan(plan: MealPlan, extra: Array[Ingredient] = [],
		household: int = 0) -> Dictionary:
	var combined := _aggregate([plan.get_all_ingredients(household), extra])
	var by_aisle := {}
	for ing in combined:
		var aisle: String = ing.aisle if ing.aisle != "" else "Autres"
		if not by_aisle.has(aisle):
			by_aisle[aisle] = [] as Array[Ingredient]
		by_aisle[aisle].append(ing)
	return by_aisle

## Clé stable d'un article de la liste de courses, dérivée du nom et de l'unité
## normalisés. Elle sert à la fois de clé d'agrégation et de clé primaire de
## `shopping_items` : deux appareils qui génèrent la même liste doivent produire
## exactement les mêmes clés, sinon cocher un article sur l'un créerait un doublon
## sur l'autre au lieu de fusionner.
static func item_key(nom: String, unite: String) -> String:
	return "%s||%s" % [nom.strip_edges().to_lower(), unite.strip_edges().to_lower()]

## Texte saisi → quantité. Partagée par la grille (bureau) et la case de quantité éditable
## du mode magasin (téléphone) : une virgule doit se lire comme un point dans les deux, et
## diverger sur ce détail ferait accepter en silence côté bureau ce que l'autre refuse.
static func parse_quantity(text: String) -> float:
	var t := text.strip_edges().replace(",", ".")
	return t.to_float() if t.is_valid_float() else 0.0

## Texte saisi COMBINÉ (« 500 g », « 1,5 kg », « 4 tranches », ou juste « kg » sans nombre)
## → { quantite, unite }. Sert l'éditeur du mode magasin (1.10.5) : l'unité y est éditée
## dans le MÊME champ que la quantité plutôt que dans une case à part, pour rester au plus
## près de ce que l'article affiche déjà.
##
## Le nombre est le préfixe le plus long fait de chiffres/point/virgule ; le reste, une
## fois débarrassé des espaces qui les séparaient, est l'unité. Sans préfixe numérique
## valide, tout le texte devient l'unité et la quantité tombe à 0 — le symétrique exact de
## `ShoppingStoreList._format_quantity`, qui n'affiche alors que l'unité.
static func parse_quantity_and_unit(text: String) -> Dictionary:
	var t := text.strip_edges()
	var i := 0
	while i < t.length() and "0123456789.,".contains(t[i]):
		i += 1
	var number_part := t.substr(0, i)
	if number_part != "" and number_part.replace(",", ".").is_valid_float():
		return {"quantite": parse_quantity(number_part), "unite": t.substr(i).strip_edges()}
	return {"quantite": 0.0, "unite": t}

## Ordre d'affichage des articles d'un rayon, commun aux deux vues : d'abord ce qui
## reste à prendre, puis ce qui est coché, chaque groupe par ordre alphabétique.
##
## Cocher pousse donc l'article en bas de SON rayon, et non en bas de la liste entière :
## l'ordre des rayons est le parcours du magasin, déplacer un article hors du sien le
## ferait réapparaître dans une allée déjà quittée.
##
## Les lignes sans nom ferment la marche — ce sont les articles en cours de saisie dans
## la grille, qui n'ont rien à faire en tête de rayon le temps qu'on les tape.
static func display_order(rows: Array) -> Array:
	var sorted := rows.duplicate()
	sorted.sort_custom(func(a, b):
		var rank_a := _display_rank(a)
		var rank_b := _display_rank(b)
		if rank_a != rank_b:
			return rank_a < rank_b
		return TextFold.before(str(a.get("nom", "")), str(b.get("nom", ""))))
	return sorted

static func _display_rank(row) -> int:
	if str(row.get("nom", "")).strip_edges() == "":
		return 2
	return 1 if row.get("checked", false) else 0

## Agrège plusieurs listes d'ingrédients par (nom, unité) en sommant les quantités.
func _aggregate(lists: Array) -> Array[Ingredient]:
	var acc := {}
	for lst in lists:
		for ing in lst:
			var key := item_key(ing.nom, ing.unite)
			if acc.has(key):
				acc[key].quantite += ing.quantite
			else:
				acc[key] = ing.duplicate_ingredient()
	var out: Array[Ingredient] = []
	for v in acc.values():
		out.append(v)
	return out
