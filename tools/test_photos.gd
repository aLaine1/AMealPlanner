extends SceneTree
## Photos de recettes : normalisation à l'entrée, stockage, tombstones.
## godot --headless --path . --script res://tools/test_photos.gd
##
## Le point sensible est la TAILLE. Une photo de téléphone non réduite passerait
## intacte dans la base et dans la synchronisation, où chaque ligne voyage en base64 :
## quelques recettes suffiraient à rendre le premier pull d'un appareil neuf
## interminable. Rien ne le signalerait — tout continuerait de fonctionner, en pire.

const Photo := preload("res://services/RecipePhoto.gd")

var _fails := 0

func _initialize() -> void:
	await process_frame
	var store := root.get_node_or_null("/root/DataStore")
	if store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return
	var db = store.local_database()

	print("--- Normalisation à l'entrée ---")
	var big := _photo_like(2400, 1800)
	var prepared: Dictionary = Photo.from_image(big)
	_check("image acceptée", prepared.ok)

	var full: ImageTexture = Photo.decode(prepared.image)
	var thumb: ImageTexture = Photo.decode(prepared.thumb)
	_check("image relisible", full != null)
	_check("vignette relisible", thumb != null)
	if full != null:
		var size := full.get_size()
		print("  image : %d × %d" % [size.x, size.y])
		_check("côté long ramené à la borne", maxi(int(size.x), int(size.y)) == Photo.MAX_SIDE)
		# Déformer écraserait les photos en portrait, les plus courantes au téléphone.
		_check("proportions conservées",
			absf(size.x / size.y - 2400.0 / 1800.0) < 0.02)
	if thumb != null:
		_check("vignette carrée", thumb.get_size() == Vector2(Photo.THUMB_SIDE, Photo.THUMB_SIDE))

	var image_ko := Marshalls.base64_to_raw(prepared.image).size() / 1024.0
	var thumb_ko := Marshalls.base64_to_raw(prepared.thumb).size() / 1024.0
	print("  poids : image %.0f ko · vignette %.1f ko" % [image_ko, thumb_ko])
	# Borne large : ce qui compte est l'ordre de grandeur, pas le kilooctet près.
	_check("image sous 400 ko", image_ko < 400.0)
	_check("vignette sous 20 ko", thumb_ko < 20.0)

	print("--- Cas d'entrée ---")
	var small := _photo_like(64, 48)
	var small_prepared: Dictionary = Photo.from_image(small)
	var small_texture: ImageTexture = Photo.decode(small_prepared.image)
	# Agrandir n'ajouterait aucun détail et coûterait des octets.
	_check("une image déjà petite n'est pas agrandie",
		small_texture != null and small_texture.get_size() == Vector2(64, 48))

	# Le JPEG ignore le canal alpha : sans aplatissement, le transparent vire au NOIR.
	var transparent := Image.create(200, 200, false, Image.FORMAT_RGBA8)
	transparent.fill(Color(0, 0, 0, 0))
	var flattened: Dictionary = Photo.from_image(transparent)
	var flat_texture: ImageTexture = Photo.decode(flattened.image)
	var corner: Color = flat_texture.get_image().get_pixel(4, 4)
	_check("transparence aplatie sur du blanc, pas du noir", corner.r > 0.9 and corner.g > 0.9)

	_check("image vide refusée", not Photo.from_image(Image.new()).ok)
	_check("données illisibles → null", Photo.decode("pas du base64 !") == null)
	_check("chaîne vide → null", Photo.decode("") == null)

	print("--- Cadrage choisi de la vignette ---")
	# Une photo n'est presque jamais carrée : la vignette prélevait le centre sans rien
	# demander, ce qui manquait le sujet une fois sur deux.
	var wide := Image.create(800, 400, false, Image.FORMAT_RGB8)
	wide.fill(Color.BLACK)
	# Repère rouge franc dans le coin haut-DROIT, loin du centre.
	for x in range(600, 800):
		for y in range(0, 200):
			wide.set_pixel(x, y, Color(1, 0, 0))

	var centered: Dictionary = Photo.from_image(wide)
	var centered_thumb: ImageTexture = Photo.decode(centered.thumb)
	var centre_pixel: Color = centered_thumb.get_image().get_pixel(
		Photo.THUMB_SIDE / 2, Photo.THUMB_SIDE / 2)
	_check("sans choix, la vignette prend le centre — ici du noir",
		centre_pixel.r < 0.3)

	var chosen: Dictionary = Photo.from_image(wide, Rect2i(600, 0, 200, 200))
	var chosen_thumb: ImageTexture = Photo.decode(chosen.thumb)
	var chosen_pixel: Color = chosen_thumb.get_image().get_pixel(
		Photo.THUMB_SIDE / 2, Photo.THUMB_SIDE / 2)
	_check("avec choix, la vignette prend la zone désignée", chosen_pixel.r > 0.7)
	_check("la vignette reste carrée",
		chosen_thumb.get_size() == Vector2(Photo.THUMB_SIDE, Photo.THUMB_SIDE))
	# L'image entière est conservée : le cadrage ne choisit que la vignette.
	var chosen_full: ImageTexture = Photo.decode(chosen.image)
	_check("l'image entière est conservée",
		chosen_full.get_size() == Vector2(800, 400))

	# Une zone débordant de l'image ne doit ni planter ni produire une vignette vide.
	var overflowing: Dictionary = Photo.from_image(wide, Rect2i(700, 300, 400, 400))
	_check("zone hors cadre ramenée dans l'image", overflowing.ok
		and Photo.decode(overflowing.thumb) != null)

	print("--- Stockage ---")
	var recipe := Recipe.new()
	recipe.nom = "ZZZ Recette photographiée"
	var recipe_id: String = store.add_recipe(recipe)

	store.set_recipe_photo(recipe_id, prepared.image, prepared.thumb)
	_check("photo enregistrée", store.has_photo(recipe_id))
	_check("vignette servie comme texture", store.get_photo_thumb(recipe_id) != null)
	_check("image pleine servie à la demande", store.get_photo(recipe_id) != null)
	# La vignette est en cache, l'image pleine ne l'est pas : c'est ce qui garde la
	# mémoire bornée quand toutes les recettes sont photographiées.
	_check("une recette sans photo n'en invente pas", store.get_photo_thumb("inconnu") == null)

	print("--- Suppression ---")
	store.clear_recipe_photo(recipe_id)
	_check("photo retirée", not store.has_photo(recipe_id))
	_check("vignette retirée du cache", store.get_photo_thumb(recipe_id) == null)
	# Tombstone et non suppression sèche : la ligne existe sur le serveur, et
	# l'effacer en local seul la ferait revenir au prochain pull.
	_check("tombstone laissé pour propagation",
		_scalar(db, "SELECT COUNT(*) AS n FROM recipe_photos WHERE recipe_id='%s' AND deleted_at IS NOT NULL;" % recipe_id) == "1")

	print("--- La photo suit la recette ---")
	store.set_recipe_photo(recipe_id, prepared.image, prepared.thumb)
	store.delete_recipe_by_id(recipe_id)
	_check("supprimer la recette tombstone sa photo",
		_scalar(db, "SELECT COUNT(*) AS n FROM recipe_photos WHERE recipe_id='%s' AND deleted_at IS NOT NULL;" % recipe_id) == "1")
	_check("elle n'est plus servie", not store.has_photo(recipe_id))

	db._db.query("DELETE FROM recipe_photos WHERE recipe_id NOT IN (SELECT id FROM recipes);")
	db._db.query("DELETE FROM recipes WHERE name LIKE 'ZZZ %';")

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

## Image de test au contenu VARIÉ. Un aplat uni se compresserait à quelques octets et
## ne dirait rien du poids réel d'une photo.
func _photo_like(width: int, height: int) -> Image:
	var image := Image.create(width, height, false, Image.FORMAT_RGB8)
	for y in range(height):
		for x in range(width):
			image.set_pixel(x, y, Color(
				float(x) / width,
				float(y) / height,
				fmod(sin(float(x) * 0.05) * cos(float(y) * 0.05) + 1.0, 1.0)))
	return image

func _scalar(db, sql: String) -> String:
	db._db.query(sql)
	if db._db.query_result.is_empty():
		return "<aucune ligne>"
	return str(db._db.query_result[0].values()[0])

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
