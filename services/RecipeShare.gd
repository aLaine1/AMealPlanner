extends RefCounted
## Format d'échange de recettes : emballage, déballage, import.
##
## Une charge utile est un texte `AMEAL1:<base64(gzip(json))>`, autoportant : aucun
## serveur, aucun compte, aucune connexion. Assez court pour tenir dans un QR jusqu'à
## une dizaine de recettes — gzip mutualise beaucoup d'une recette à l'autre.
##
## Tout voyage par NOM, jamais par identifiant : les UUID du destinataire diffèrent
## des nôtres. C'est le même parti pris que la synchronisation pour les catégories.
##
## Chargé par preload : cf. services/Uuid.gd.

## Préfixe versionné : permet de reconnaître un code d'un coup d'œil, de rejeter
## proprement un texte quelconque collé par erreur, et de faire évoluer le format.
const PREFIX := "AMEAL1:"

## Partage par RÉFÉRENCE : le code ne porte plus les recettes mais un jeton, le
## contenu vivant sur le compte de l'émetteur. Introduit en 1.6 pour que les photos
## puissent voyager — un QR lisible plafonne à ~1200 octets, une photo normalisée en
## pèse 131 000, soit cent fois trop.
##
## `AMEAL1` reste lu à l'import : des codes autoportants ont pu être émis et gardés,
## et rien n'oblige à les invalider.
const TOKEN_PREFIX := "AMEAL2:"

## Durée de vie d'un partage déposé, en jours. Assez long pour qu'un code affiché sur
## un frigo serve encore la semaine suivante, assez court pour que la table ne
## conserve pas indéfiniment des recettes que personne ne réclamera.
const SHARE_DAYS := 30

## Limite pratique d'un QR lisible sur un écran de téléphone. Au-delà, l'application
## propose le code en texte plutôt qu'un QR trop dense pour être scanné.
const QR_LIMIT := 1200

# =====================================================================
# Emballage
# =====================================================================

## `store` facultatif : fourni, les photos des recettes rejoignent la charge utile.
## Un partage autoportant (QR de version 1) doit s'en passer, faute de place.
static func pack(recipes: Array, store = null) -> String:
	var payload := {"v": 1, "r": []}
	for recipe in recipes:
		var entry := _recipe_to_dict(recipe)
		if store != null and store.has_photo(recipe.id):
			# Déjà stockée en base64 : elle traverse le format d'échange sans
			# transcodage, exactement comme elle traverse la synchronisation.
			entry["p"] = store.photo_payload(recipe.id)
		payload["r"].append(entry)
	var json := JSON.stringify(payload)
	var packed := json.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
	return PREFIX + Marshalls.raw_to_base64(packed)

static func _recipe_to_dict(recipe) -> Dictionary:
	# Clés d'une lettre : à une dizaine de recettes, les noms de champs pèsent
	# sensiblement dans ce qui doit tenir dans un QR.
	var ingredients := []
	for ing in recipe.ingredients:
		ingredients.append({
			"n": ing.nom, "q": ing.quantite, "u": ing.unite, "a": ing.aisle,
		})
	return {
		"n": recipe.nom,
		"e": recipe.saison,
		"b": recipe.nobox,
		"s": recipe.etapes,
		"c": recipe.categories,
		"i": ingredients,
		# Parts. La lettre « d » et non « p » : celle-ci désigne déjà la PHOTO, et la
		# collision faisait lire la photo comme un nombre de parts — l'import s'arrêtait sur
		# un « int() » impossible. Absent d'un code émis avant la 1.8, et lu comme 0, soit
		# « autant que le foyer » : le champ s'ajoute sans changer la version du format, un
		# champ inconnu étant ignoré par les lecteurs plus anciens.
		"d": recipe.servings,
	}

# =====================================================================
# Déballage
# =====================================================================

## Renvoie { ok, recipes (Array[Dictionary]), error }.
## Ne touche à rien : sert aussi à prévisualiser avant d'importer.
static func unpack(code: String) -> Dictionary:
	var trimmed := code.strip_edges()
	if not trimmed.begins_with(PREFIX):
		return _failure("Ce texte n'est pas un code de partage AMeal Planner.")

	var raw := Marshalls.base64_to_raw(trimmed.substr(PREFIX.length()))
	if raw.is_empty():
		return _failure("Code illisible : il a probablement été tronqué à la copie.")

	var json_bytes := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if json_bytes.is_empty():
		return _failure("Code abîmé : il manque une partie du texte.")

	var parsed = JSON.parse_string(json_bytes.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("r"):
		return _failure("Code abîmé : contenu inattendu.")
	# Un code produit par une version plus récente peut contenir des champs qu'on ne
	# saurait pas lire : mieux vaut le dire que d'importer une recette amputée.
	if int(parsed.get("v", 1)) > 1:
		return _failure("Ce code vient d'une version plus récente de l'application.")

	var recipes := []
	for entry in parsed["r"]:
		if typeof(entry) == TYPE_DICTIONARY and str(entry.get("n", "")).strip_edges() != "":
			recipes.append(entry)
	if recipes.is_empty():
		return _failure("Ce code ne contient aucune recette.")
	return {"ok": true, "recipes": recipes, "error": ""}

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "recipes": [], "error": message}

## Vrai si le texte désigne un partage déposé plutôt qu'un code autoportant.
static func is_token_code(code: String) -> bool:
	return code.strip_edges().begins_with(TOKEN_PREFIX)

## Jeton nu d'un code de référence, "" si le texte n'en est pas un.
static func extract_token(code: String) -> String:
	var trimmed := code.strip_edges()
	if not trimmed.begins_with(TOKEN_PREFIX):
		return ""
	return trimmed.substr(TOKEN_PREFIX.length()).strip_edges()

static func token_code(token: String) -> String:
	return TOKEN_PREFIX + token

# =====================================================================
# Import
# =====================================================================

## Ajoute les recettes d'une charge déballée. Renvoie { imported, renamed }.
##
## Rien n'est jamais écrasé : une recette dont le nom existe déjà est ajoutée sous un
## nom suffixé. Le destinataire compare puis supprime ce qu'il veut — l'inverse lui
## ferait perdre sa version sans l'avoir demandé.
static func import_recipes(store, entries: Array) -> Dictionary:
	var imported := 0
	var renamed := 0
	var known_aisles: Array = store.get_aisle_names()
	var fallback: String = store.fallback_aisle()

	for entry in entries:
		var recipe := Recipe.new()
		recipe.nom = _unique_name(store, str(entry.get("n", "")))
		if recipe.nom != str(entry.get("n", "")):
			renamed += 1
		recipe.saison = str(entry.get("e", "toute"))
		recipe.nobox = bool(entry.get("b", false))
		recipe.etapes = str(entry.get("s", ""))
		recipe.servings = maxi(0, int(entry.get("d", 0)))

		var categories: Array[String] = []
		for category in entry.get("c", []):
			categories.append(str(category))
		recipe.categories = categories

		var ingredients: Array[Ingredient] = []
		for source in entry.get("i", []):
			var ing := Ingredient.new()
			ing.nom = str(source.get("n", ""))
			ing.quantite = float(source.get("q", 0))
			ing.unite = str(source.get("u", ""))
			# Le rayon de l'expéditeur peut ne pas exister chez le destinataire : on
			# rattache au repli plutôt que d'inventer des rayons dans sa liste.
			var aisle := str(source.get("a", fallback))
			ing.aisle = aisle if known_aisles.has(aisle) else fallback
			ingredients.append(ing)
		recipe.ingredients = ingredients

		var recipe_id: String = store.add_recipe(recipe)
		# La photo suit la recette quand l'expéditeur en a joint une. Elle est déjà
		# normalisée — même borne de taille, même format — puisqu'elle a traversé
		# RecipePhoto chez lui.
		var photo = entry.get("p", null)
		if typeof(photo) == TYPE_DICTIONARY \
				and str(photo.get("image", "")) != "" and str(photo.get("thumb", "")) != "":
			store.set_recipe_photo(recipe_id, str(photo["image"]), str(photo["thumb"]))
		imported += 1

	return {"imported": imported, "renamed": renamed}

static func _unique_name(store, wanted: String) -> String:
	if store.get_recipe_by_name(wanted) == null:
		return wanted
	var index := 2
	while store.get_recipe_by_name("%s (%d)" % [wanted, index]) != null:
		index += 1
	return "%s (%d)" % [wanted, index]
