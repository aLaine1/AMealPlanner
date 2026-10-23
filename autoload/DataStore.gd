extends Node
## Façade d'accès aux données — portage de RecipeDatabase (Python).
## Backend : SQLite local (LocalDatabase / godot-sqlite), base dans user://.
## DataStore maintient un cache mémoire des Recipe/Ingredient pour les lectures et la
## génération (dataset petit) ; il est reconstruit après chaque écriture.
##
## L'API publique est identique à celle du PoC JSON : l'UI et les services n'ont pas changé.

## Chargé par preload plutôt que via l'autoload `AppState` : DataStore n'a besoin que
## d'une constante, et les tests headless l'instancient hors arbre, sans autoloads.
const AppStateScript := preload("res://autoload/AppState.gd")
## Même raison : les tests headless instancient DataStore hors arbre, où le cache de
## classes globales de Godot n'est pas garanti à jour.
const RecipePhotoScript := preload("res://services/RecipePhoto.gd")

var _db: LocalDatabase
var _recipes: Array[Recipe] = []
var _ingredients: Array[Ingredient] = []
var _categories: Array[String] = []
var _breakfasts: Array[Breakfast] = []
var _staples: Array[Ingredient] = []
var _aisles: Array[Dictionary] = []
## `recipe_id -> base64` des vignettes seules. Les images pleines ne sont jamais
## chargées en bloc : quelques dizaines suffiraient à occuper plusieurs mégaoctets.
var _photo_thumbs := {}
var _thumb_textures := {}
var _full_photo_id := ""
var _full_photo: ImageTexture = null

signal data_changed
## Émis uniquement pour une écriture faite SUR CET APPAREIL, jamais pour des données
## reçues du serveur. C'est ce qui permet à SyncEngine de pousser sans délai sans
## boucler : réagir à `data_changed` déclencherait une synchronisation à chaque pull.
signal local_change
## Émis quand la FORME du planning change — nombre de semaines, jour de début, repas par
## jour. Distinct de `data_changed` : ce n'est pas le contenu qui bouge mais le nombre de
## cases et leur signification, ce qui oblige le calendrier à se reconstruire et non
## seulement à se rafraîchir.
signal plan_shape_changed

func _ready() -> void:
	_db = LocalDatabase.new()
	_db.open()
	_refresh_cache()
	_import_legacy_json_state()

## Reprise one-shot des trois JSON de user:// vers la base. Ne s'exécute qu'une fois
## (drapeau en table meta) et laisse les fichiers en place — ils ne sont plus lus,
## mais restent comme filet de sécurité.
func _import_legacy_json_state() -> void:
	if _db.get_sync_meta("legacy_json_imported", "0") == "1":
		return

	var plan := _read_json_array("user://saved_weekplan.json")
	if not plan.is_empty():
		var names: Array[String] = []
		for n in plan:
			names.append(str(n))
		save_plan_names(names)

	var slots := _read_json_array("user://saved_breakfasts.json")
	if not slots.is_empty():
		var slot_names: Array[String] = []
		for n in slots:
			slot_names.append(str(n))
		save_breakfast_slot_names(slot_names)

	var shopping := _read_json_array("user://shopping_list.json")
	if not shopping.is_empty():
		save_shopping_items(shopping)

	_db.set_sync_meta("legacy_json_imported", "1")
	if not (plan.is_empty() and slots.is_empty() and shopping.is_empty()):
		print("DataStore : état repris depuis les anciens JSON (%d cases, %d slots, %d articles)."
			% [plan.size(), slots.size(), shopping.size()])

func _read_json_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_ARRAY else []

## Appelé par SyncEngine après un pull ayant modifié des données : le cache mémoire
## et toute l'UI abonnée à `data_changed` se remettent à jour.
func refresh_after_sync() -> void:
	_refresh_cache()
	data_changed.emit()   # volontairement PAS local_change : rien à repousser

## Préférences d'affichage propres à l'appareil (rayons repliés, etc.).
##
## Rangées dans la table `meta`, qui n'est PAS synchronisée — et c'est voulu :
## replier un rayon terminé sur le téléphone en magasin n'a aucune raison de
## modifier l'affichage du PC resté à la maison.
func get_ui_preference(key: String, fallback: String = "") -> String:
	return _db.get_sync_meta("ui/" + key, fallback)

func set_ui_preference(key: String, value: String) -> void:
	_db.set_sync_meta("ui/" + key, value)

## Base locale, pour le moteur de sync (qui a besoin d'un accès ligne à ligne que
## l'API métier de DataStore n'expose pas).
func local_database() -> LocalDatabase:
	return _db

func _refresh_cache() -> void:
	_recipes = _db.fetch_all_recipes()
	_ingredients = _db.fetch_all_ingredients()
	_categories = _db.fetch_all_categories()
	_breakfasts = _db.fetch_all_breakfasts()
	_staples = _db.fetch_all_staples()
	_aisles = _db.fetch_aisles()
	_refresh_photo_cache()
	print("DataStore chargé: %d recettes, %d ingrédients, %d catégories, %d petits déj, %d articles de base"
		% [_recipes.size(), _ingredients.size(), _categories.size(), _breakfasts.size(), _staples.size()])

# ===== RECETTES (lecture) =====

func get_all_recipe_names() -> Array[String]:
	var names: Array[String] = []
	for r in _recipes:
		names.append(r.nom)
	names.sort_custom(TextFold.before)
	return names

func get_all_recipe_objects() -> Array[Recipe]:
	return _recipes.duplicate()

func get_recipe_by_name(recipe_name: String) -> Recipe:
	for r in _recipes:
		if r.nom == recipe_name:
			return r
	return null

func get_recipe_ingredients(recipe_name: String) -> Array[Ingredient]:
	var r := get_recipe_by_name(recipe_name)
	return r.ingredients.duplicate() if r != null else ([] as Array[Ingredient])

## Recettes employant un ingrédient — la relation inverse de `get_recipe_ingredients`,
## triées par nom. Le parcours se fait sur le cache, qui porte déjà les ingrédients de
## chaque recette : une requête SQL sur `recipe_ingredients` ne rapporterait rien de
## plus et rouvrirait la jointure à chaque sélection dans la liste.
func get_recipes_using_ingredient(ingredient_name: String) -> Array[Recipe]:
	var out: Array[Recipe] = []
	if ingredient_name == "":
		return out
	for r in _recipes:
		for ing in r.ingredients:
			if ing.nom == ingredient_name:
				out.append(r)
				break
	out.sort_custom(func(a, b): return TextFold.before(a.nom, b.nom))
	return out

# ===== INGRÉDIENTS (lecture) =====

func get_all_ingredients() -> Array[Ingredient]:
	return _ingredients.duplicate()

func get_all_ingredient_names() -> Array[String]:
	var names: Array[String] = []
	for i in _ingredients:
		names.append(i.nom)
	names.sort_custom(TextFold.before)
	return names

func get_all_ingredient_categories() -> Array[String]:
	var seen := {}
	for i in _ingredients:
		seen[i.aisle] = true
	var out: Array[String] = []
	for k in seen.keys():
		out.append(k)
	out.sort()
	return out

func get_all_recipe_categories() -> Array[String]:
	return _categories.duplicate()

# ===== GÉNÉRATION FILTRÉE =====

func get_random_recipe_with_filter(recipe_filter: RecipeFilter) -> Recipe:
	var pool: Array[Recipe] = []
	for r in _recipes:
		if recipe_filter.matches(r):
			pool.append(r)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]

# ===== RECETTES (écriture) =====

func add_recipe(recipe: Recipe) -> String:
	var rid := _db.insert_recipe(recipe)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
	return rid

func update_recipe(recipe: Recipe) -> void:
	_db.update_recipe(recipe)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func delete_recipe_by_id(recipe_id: String) -> void:
	_db.delete_recipe(recipe_id)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

# ===== PHOTOS DE RECETTES =====

## Vignette d'une recette, ou `null` si elle n'en a pas — les appelants affichent alors
## leur pastille de catégorie habituelle.
##
## Les textures sont décodées une fois puis gardées : la bibliothèque reconstruit ses
## cartes à chaque frappe dans la recherche, et redécoder soixante-dix JPEG à chaque
## fois se verrait.
func get_photo_thumb(recipe_id: String) -> ImageTexture:
	if recipe_id == "" or not _photo_thumbs.has(recipe_id):
		return null
	if not _thumb_textures.has(recipe_id):
		_thumb_textures[recipe_id] = RecipePhotoScript.decode(_photo_thumbs[recipe_id])
	return _thumb_textures[recipe_id]

func has_photo(recipe_id: String) -> bool:
	return _photo_thumbs.has(recipe_id)

## Image pleine, décodée à la demande. Une seule est gardée en mémoire : elles pèsent
## chacune des centaines de kilooctets, et un seul écran à la fois en montre une.
func get_photo(recipe_id: String) -> ImageTexture:
	if recipe_id == "" or not _photo_thumbs.has(recipe_id):
		return null
	if _full_photo_id != recipe_id:
		_full_photo = RecipePhotoScript.decode(_db.fetch_photo(recipe_id))
		_full_photo_id = recipe_id
	return _full_photo

## Photo sous sa forme stockée — les deux tailles en base64 — pour le format
## d'échange. Distinct de `get_photo`, qui rend une texture prête à afficher.
func photo_payload(recipe_id: String) -> Dictionary:
	if not _photo_thumbs.has(recipe_id):
		return {}
	return {"image": _db.fetch_photo(recipe_id), "thumb": str(_photo_thumbs[recipe_id])}

func set_recipe_photo(recipe_id: String, image_b64: String, thumb_b64: String) -> void:
	_db.upsert_photo(recipe_id, image_b64, thumb_b64)
	_invalidate_photo(recipe_id)
	_refresh_photo_cache()
	data_changed.emit()
	local_change.emit()

func clear_recipe_photo(recipe_id: String) -> void:
	_db.delete_photo(recipe_id)
	_invalidate_photo(recipe_id)
	_refresh_photo_cache()
	data_changed.emit()
	local_change.emit()

func _invalidate_photo(recipe_id: String) -> void:
	_thumb_textures.erase(recipe_id)
	if _full_photo_id == recipe_id:
		_full_photo_id = ""
		_full_photo = null

## Ne jette que les vignettes dont la donnée a réellement changé. Tout vider à chaque
## rafraîchissement ferait redécoder l'intégralité des photos au moindre ajout
## d'ingrédient, alors qu'elles n'ont pas bougé.
func _refresh_photo_cache() -> void:
	var fresh := _db.fetch_photo_thumbs()
	for recipe_id in _thumb_textures.keys():
		if str(fresh.get(recipe_id, "")) != str(_photo_thumbs.get(recipe_id, "")):
			_thumb_textures.erase(recipe_id)
	if not fresh.has(_full_photo_id) or str(fresh.get(_full_photo_id, "")) \
			!= str(_photo_thumbs.get(_full_photo_id, "")):
		_full_photo_id = ""
		_full_photo = null
	_photo_thumbs = fresh

# ===== PETITS DÉJEUNERS =====

func get_all_breakfast_names() -> Array[String]:
	var names: Array[String] = []
	for b in _breakfasts:
		names.append(b.nom)
	names.sort_custom(TextFold.before)
	return names

func get_all_breakfast_objects() -> Array[Breakfast]:
	return _breakfasts.duplicate()

func get_breakfast_by_name(name: String) -> Breakfast:
	for b in _breakfasts:
		if b.nom == name:
			return b
	return null

## Renvoie jusqu'à `count` petits déjeuners aléatoires DISTINCTS.
func get_random_breakfasts(count: int) -> Array[Breakfast]:
	var pool := _breakfasts.duplicate()
	pool.shuffle()
	return pool.slice(0, min(count, pool.size()))

func add_breakfast(b: Breakfast) -> String:
	var bid := _db.insert_breakfast(b)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
	return bid

func update_breakfast(b: Breakfast) -> void:
	_db.update_breakfast(b)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func delete_breakfast_by_id(breakfast_id: String) -> void:
	_db.delete_breakfast(breakfast_id)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

# ===== MARQUEUR DE TRANSPORT =====
#
# Une recette marquée « ne se transporte pas » est réservée aux soirs qui ne sont pas
# suivis d'une journée de travail — ceux dont les restes n'auront pas à partir en
# gamelle. Le champ s'appelle `nobox` en base pour des raisons historiques ; le
# renommer imposerait une migration locale ET distante pour aucun bénéfice.
#
# Désactivé, le mécanisme disparaît entièrement de l'interface et de la génération.

func is_transport_marker_enabled() -> bool:
	return _db.get_setting(LocalDatabase.SETTING_TRANSPORT_ENABLED, "0") == "1"

func set_transport_marker_enabled(enabled: bool) -> void:
	_db.set_setting(LocalDatabase.SETTING_TRANSPORT_ENABLED, "1" if enabled else "0")
	data_changed.emit()
	local_change.emit()

## Soirs réservés, en couples (jour de la semaine, repas) — lundi = 0, repas 0 = midi ou repas
## unique. C'est la forme STOCKÉE, celle qui a un sens durable : un rythme de travail est
## hebdomadaire, il ne dépend ni de la durée du planning ni du jour où il commence.
func get_transport_weekdays() -> Array[Vector2i]:
	var marks: Array[Vector2i] = []
	if not is_transport_marker_enabled():
		return marks
	var raw := _db.get_setting(LocalDatabase.SETTING_TRANSPORT_SLOTS,
		LocalDatabase.DEFAULT_TRANSPORT_WEEKDAYS)
	for piece in raw.split(",", false):
		var parts := piece.strip_edges().split(":")
		if parts.is_empty():
			continue
		var weekday := posmod(int(parts[0]), 7)
		var meal := int(parts[1]) if parts.size() > 1 else 0
		var mark := Vector2i(weekday, maxi(0, meal))
		if not marks.has(mark):
			marks.append(mark)
	marks.sort()
	return marks

## Le rang du repas est CONSERVÉ tel qu'il est donné. Il était auparavant réécrit d'office sur
## le dernier repas de la journée — « le soir » —, ce qui rendait le premier repas impossible à
## réserver et déplaçait les marques dans le dos de l'utilisateur au moindre changement de forme.
## Les deux repas se cochent maintenant séparément, et ce qui est stocké est ce qui a été coché.
func set_transport_weekdays(marks: Array) -> void:
	var pieces: Array[String] = []
	for mark in marks:
		var value: Vector2i = mark
		pieces.append("%d:%d" % [posmod(value.x, 7),
			clampi(value.y, 0, LocalDatabase.PLAN_MEALS_MAX - 1)])
	_db.set_setting(LocalDatabase.SETTING_TRANSPORT_SLOTS, ",".join(pieces))
	data_changed.emit()
	local_change.emit()

## Cases réservées, en indices absolus dans le planning courant. Vide si le mécanisme est
## désactivé : les appelants n'ont ainsi pas à tester l'interrupteur séparément.
##
## C'est la forme DÉRIVÉE, recalculée à chaque lecture depuis les couples ci-dessus. Le
## calendrier et la génération raisonnent en indices, mais ces indices ne sont plus stockés :
## changer le jour de début ou la durée les recompose au lieu de les décaler, et les semaines
## ajoutées reçoivent leurs soirs réservés sans que personne ait à les redésigner.
func get_transport_slots() -> Array[int]:
	var slots: Array[int] = []
	var marks := get_transport_weekdays()
	if marks.is_empty():
		return slots
	var meals := plan_meals_per_day()
	for day_index in range(plan_day_count()):
		var weekday := plan_weekday_of(day_index)
		for mark in marks:
			if mark.x != weekday:
				continue
			# Un repas par jour : le soir marqué désigne le repas unique de la journée.
			var meal := mini(mark.y, meals - 1)
			var slot := day_index * meals + meal
			if not slots.has(slot):
				slots.append(slot)
	slots.sort()
	return slots

# ===== FORME DU PLANNING =====
#
# Quatre valeurs étaient codées en dur : 14 cases, un début le samedi, un repas par jour, un
# nombre de convives implicite. Elles sont désormais lues ici, et leurs défauts reproduisent
# exactement la 1.7 — voir 0_plan_1.8.0.md. Tout ce qui a besoin de la forme du planning doit
# passer par ces accesseurs et non par une constante.

func plan_weeks() -> int:
	return _db.plan_weeks()

func plan_week_start() -> int:
	return _db.plan_week_start()

func plan_meals_per_day() -> int:
	return _db.plan_meals_per_day()

## Nombre de JOURS couverts. Distinct du nombre de cases, qui compte les repas.
func plan_day_count() -> int:
	return _db.plan_day_count()

## Nombre de CASES du planning, c'est-à-dire de repas à remplir.
func plan_slot_count() -> int:
	return _db.plan_slot_count()

func household_servings() -> int:
	return _db.household_servings()

func onboarding_done() -> bool:
	return _db.onboarding_done()

## Écrit un réglage de forme et prévient l'interface. Un seul point d'entrée : c'est lui qui
## garantit que personne ne modifie la forme sans que le calendrier l'apprenne.
func set_plan_shape(weeks: int, week_start: int, meals_per_day: int) -> void:
	_db.set_setting(LocalDatabase.SETTING_PLAN_WEEKS,
		str(clampi(weeks, LocalDatabase.PLAN_WEEKS_MIN, LocalDatabase.PLAN_WEEKS_MAX)))
	_db.set_setting(LocalDatabase.SETTING_PLAN_WEEK_START, str(posmod(week_start, 7)))
	_db.set_setting(LocalDatabase.SETTING_PLAN_MEALS_PER_DAY,
		str(clampi(meals_per_day, 1, LocalDatabase.PLAN_MEALS_MAX)))
	# Les repas réservés ne sont PLUS repris ici. Ils désignaient auparavant « le dernier repas
	# de la journée », si bien que passer à deux repas déplaçait la marque d'office. Chaque
	# marque porte maintenant son rang, choisi explicitement : la déplacer reviendrait à défaire
	# ce que l'utilisateur vient de cocher. Un rang qui dépasse le nombre de repas du moment est
	# ramené à la lecture, dans `get_transport_slots` — sans être écrasé en base, pour qu'il
	# revienne intact si l'on rétablit le second repas.
	plan_shape_changed.emit()
	data_changed.emit()
	local_change.emit()

func set_household_servings(servings: int) -> void:
	_db.set_setting(LocalDatabase.SETTING_HOUSEHOLD_SERVINGS, str(maxi(1, servings)))
	data_changed.emit()
	local_change.emit()

func set_onboarding_done(done: bool) -> void:
	_db.set_setting(LocalDatabase.SETTING_ONBOARDING_DONE, "1" if done else "0")
	local_change.emit()

## Noms des repas d'une journée, dans l'ordre.
##
## « 1er repas » et « 2ème repas », et non « midi » et « soir ». Ces deux mots-là décidaient
## à la place de l'utilisateur : rien n'oblige les deux repas cuisinés d'une journée à être
## le déjeuner et le dîner, et un foyer qui cuisine le soir pour deux jours n'y retrouvait
## pas ses habitudes. Le rang, lui, est vrai dans tous les cas.
##
## Les plats qui ne se transportent pas se désignent en conséquence par leur rang, ce qui
## permet d'ailleurs de réserver l'un OU l'autre repas — ce que « soir » interdisait.
const MEAL_NAMES := ["1er repas", "2ème repas"]

## Abréviations des jours, lundi = 0. Sert aux libellés du planning et aux réglages.
const WEEKDAY_SHORT := ["Lun.", "Mar.", "Mer.", "Jeu.", "Ven.", "Sam.", "Dim."]
const WEEKDAY_LONG := ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]

## Libellé de chaque JOUR du planning : « Sam. S1 », « Dim. S1 », « Lun. S2 »…
##
## Le numéro de semaine est celui du CALENDRIER et non du planning : il change au passage
## d'un lundi, pas tous les sept jours depuis le début. C'est ce que faisaient les libellés
## écrits à la main de la 1.7 — un planning commençant un samedi affiche donc « S1 » pour ses
## deux premiers jours, puis « S2 » à partir du lundi suivant. Reproduit à l'identique pour
## qu'un foyer déjà installé ne voie rien changer.
func plan_day_labels() -> Array[String]:
	var labels: Array[String] = []
	var week := 1
	for index in range(plan_day_count()):
		var weekday := _db.plan_weekday_of(index)
		if weekday == 0 and index > 0:
			week += 1
		labels.append("%s S%d" % [WEEKDAY_SHORT[weekday], week])
	return labels

## Jour de la semaine (lundi = 0) du n-ième jour du planning.
func plan_weekday_of(day_index: int) -> int:
	return _db.plan_weekday_of(day_index)

## Libellé de chaque CASE : le jour, et le repas quand il y en a deux.
##
## À un repas par jour, la mention serait du bruit — il n'y a rien à distinguer.
func plan_slot_labels() -> Array[String]:
	var days := plan_day_labels()
	var meals := plan_meals_per_day()
	var labels: Array[String] = []
	for index in range(plan_slot_count()):
		var slot := plan_slot_at(index)
		if meals == 1:
			labels.append(days[slot.x])
		else:
			labels.append("%s · %s" % [days[slot.x], MEAL_NAMES[slot.y]])
	return labels

# ===== RAYONS =====
#
# Remplacent trois listes codées en dur qui avaient déjà divergé : celle de la liste
# de courses, celle des articles de base, et une troisième déduite des rayons
# effectivement utilisés par les ingrédients.

## Noms des rayons, dans l'ordre de parcours en magasin.
func get_aisle_names() -> Array[String]:
	var names: Array[String] = []
	for aisle in _aisles:
		names.append(str(aisle["name"]))
	return names

## Rayons complets (id, nom, rang) — pour l'éditeur.
func get_aisles() -> Array[Dictionary]:
	return _aisles.duplicate(true)

## Rayon de repli, garanti présent.
func fallback_aisle() -> String:
	return LocalDatabase.FALLBACK_AISLE

func add_aisle(name: String) -> String:
	var aid := _db.insert_aisle(name)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
	return aid

func rename_aisle(aisle_id: String, new_name: String) -> void:
	_db.rename_aisle(aisle_id, new_name)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func delete_aisle(aisle_id: String) -> void:
	_db.delete_aisle(aisle_id)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func reorder_aisles(ordered_ids: Array) -> void:
	_db.reorder_aisles(ordered_ids)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

# ===== ARTICLES DE BASE (staples) =====

func get_all_staples() -> Array[Ingredient]:
	return _staples.duplicate()

func add_staple(ing: Ingredient) -> String:
	var sid := _db.insert_staple(ing)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
	return sid

func update_staple(ing: Ingredient) -> void:
	_db.update_staple(ing)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func delete_staple_by_id(staple_id: String) -> void:
	_db.delete_staple(staple_id)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

# =====================================================================
# ÉTAT APPLICATIF PERSISTÉ — planning, slots petit déj, liste de courses
#
# Ces trois états vivaient dans des JSON de user:// (saved_weekplan.json,
# saved_breakfasts.json, shopping_list.json). Ils sont désormais en base, en lignes
# indépendantes (une par position / par slot / par article), pour deux raisons :
#   * la sync fusionne alors au grain de la case ou de l'article — deux appareils
#     qui touchent des cases différentes ne s'écrasent pas (§3.4.1) ;
#   * le planning est référencé par ID de recette et non par nom, ce qui corrige la
#     casse au renommage signalée en §2.3 du plan.
#
# Toutes les écritures sont DIFFÉRENTIELLES : seules les lignes réellement modifiées
# voient leur updated_at bouger. Réécrire les 14 cases (ou les 45 articles) à chaque
# sauvegarde les marquerait toutes comme fraîches et ferait gagner l'appareil qui
# sauvegarde en dernier sur *toute* la liste, ce qui viderait le LWW par ligne de
# son intérêt.
# =====================================================================

func get_recipe_by_id(recipe_id: String) -> Recipe:
	for r in _recipes:
		if r.id == recipe_id:
			return r
	return null

func get_breakfast_by_id(breakfast_id: String) -> Breakfast:
	for b in _breakfasts:
		if b.id == breakfast_id:
			return b
	return null

## Les 14 cases sous forme de noms affichables. Une case peut porter soit une recette
## connue (résolue par id), soit un plat saisi à la main (custom_label).
## Case (jour, repas) correspondant au n-ième emplacement du planning.
##
## L'ordre est chronologique : jour 1 midi, jour 1 soir, jour 2 midi… C'est celui de la vue
## liste, celui des cases du calendrier, et celui des indices dont parle le réglage des soirs
## réservés. Le JOUR ne dépend pas du nombre de repas — c'est ce qui permet d'activer le second
## repas sans renuméroter ce qui est déjà enregistré.
func plan_slot_at(slot_index: int) -> Vector2i:
	var meals := plan_meals_per_day()
	return Vector2i(slot_index / meals, slot_index % meals)

func load_plan_names() -> Array[String]:
	var stored := _db.fetch_plan_positions()
	var names: Array[String] = []
	for i in range(plan_slot_count()):
		var entry: Dictionary = stored.get(plan_slot_at(i), {})
		var rid := str(entry.get("recipe_id", ""))
		if rid != "":
			var r := get_recipe_by_id(rid)
			names.append(r.nom if r != null else "")
		else:
			names.append(str(entry.get("custom_label", "")))
	return names

func save_plan_names(names: Array[String]) -> void:
	var current := _db.fetch_plan_positions()
	var touched := false
	for i in range(plan_slot_count()):
		var display := (str(names[i]) if i < names.size() else "").strip_edges()
		var r := get_recipe_by_name(display) if display != "" else null
		var recipe_id := r.id if r != null else ""
		var custom := "" if (r != null or display == "") else display

		var slot := plan_slot_at(i)
		var existing: Dictionary = current.get(slot, {})
		if str(existing.get("recipe_id", "")) == recipe_id \
				and str(existing.get("custom_label", "")) == custom:
			continue  # inchangé : ne pas toucher updated_at
		_db.set_plan_position(slot.x, slot.y, recipe_id, custom)
		touched = true
	# Signalé seulement si une case a bougé : ces méthodes sont appelées à chaque
	# sauvegarde, y compris quand rien n'a changé.
	if touched:
		local_change.emit()

func load_breakfast_slot_names() -> Array[String]:
	var stored := _db.fetch_breakfast_slots()
	var names: Array[String] = []
	for i in range(AppStateScript.BREAKFAST_SLOTS):
		var bid := str(stored.get(i, ""))
		var b := get_breakfast_by_id(bid) if bid != "" else null
		names.append(b.nom if b != null else "")
	return names

func save_breakfast_slot_names(names: Array[String]) -> void:
	var current := _db.fetch_breakfast_slots()
	var touched := false
	for i in range(AppStateScript.BREAKFAST_SLOTS):
		var display := (str(names[i]) if i < names.size() else "").strip_edges()
		var b := get_breakfast_by_name(display) if display != "" else null
		var bid := b.id if b != null else ""
		if str(current.get(i, "")) == bid:
			continue
		_db.set_breakfast_slot(i, bid)
		touched = true
	if touched:
		local_change.emit()

## Articles de la liste de courses : [{item_key, nom, aisle, quantite, unite, checked}]
func load_shopping_items() -> Array[Dictionary]:
	return _db.fetch_shopping_items()

## Enregistre la liste, en ne touchant que ce qui a changé. Les articles absents de
## `items` sont tombstonés un par un (et non effacés en bloc) pour que la suppression
## se propage sans emporter les articles que d'autres appareils viennent d'ajouter.
func save_shopping_items(items: Array) -> void:
	var current := {}
	for row in _db.fetch_shopping_items():
		current[row["item_key"]] = row

	var touched := false
	var seen := {}
	for item in items:
		var nom := str(item.get("nom", "")).strip_edges()
		# La grille garde une ligne vide en bas de chaque rayon pour la saisie : c'est
		# de l'échafaudage d'UI, pas un article — et toutes ces lignes partageraient
		# la même clé "||".
		if nom == "":
			continue
		var unite := str(item.get("unite", ""))
		var key := ShoppingListService.item_key(nom, unite)
		seen[key] = true
		var aisle := str(item.get("aisle", "Autres"))
		var qty := float(item.get("quantite", 0))
		var checked := bool(item.get("checked", false))

		var prev: Dictionary = current.get(key, {})
		if not prev.is_empty() and prev["nom"] == nom and prev["aisle"] == aisle \
				and is_equal_approx(prev["quantite"], qty) and prev["unite"] == unite \
				and prev["checked"] == checked:
			continue
		_db.upsert_shopping_item(key, nom, aisle, qty, unite, checked)
		touched = true

	for key in current.keys():
		if not seen.has(key):
			_db.delete_shopping_item(key)
			touched = true

	if touched:
		local_change.emit()

# ===== INGRÉDIENTS (écriture) =====

func add_ingredient(name: String, aisle: String = "Divers") -> String:
	var iid := _db.insert_ingredient(name, aisle)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
	return iid

func update_ingredient(ing: Ingredient) -> void:
	_db.update_ingredient(ing)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()

func delete_ingredient_by_name(name: String) -> void:
	_db.delete_ingredient_by_name(name)
	_refresh_cache()
	data_changed.emit()
	local_change.emit()
