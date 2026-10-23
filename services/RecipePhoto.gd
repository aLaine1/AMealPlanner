class_name RecipePhoto
extends RefCounted
## Préparation et décodage des photos de recettes.
##
## Une photo de téléphone pèse plusieurs mégaoctets et mesure des milliers de pixels de
## côté. Stockée telle quelle, elle gonflerait la base, saturerait la synchronisation
## (chaque ligne passe en JSON, donc en base64) et serait de toute façon réduite à
## l'affichage. Tout ce qui entre est donc normalisé ici, une fois : même format, même
## borne de taille, quelle que soit la source — fichier choisi ou appareil photo.
##
## Deux tailles sont conservées :
##
## - l'**image**, côté long ramené à `MAX_SIDE`, pour les popups et le calendrier ;
## - la **vignette** carrée `THUMB_SIDE`, pour les listes. Elle est stockée et non
##   recalculée à l'affichage : la bibliothèque en montre des dizaines à la fois, et
##   redimensionner à chaque construction de carte se verrait au défilement.
##
## Le JPEG est imposé même à l'entrée d'un PNG : à cette taille il pèse cinq à dix fois
## moins, et une photo de plat n'a pas de transparence à préserver. Un PNG transparent
## est aplati sur du blanc plutôt que de virer au noir.

## Côté long de l'image conservée. 1024 suffit à remplir la zone photo d'un écran de
## bureau ; au-delà on paierait des octets que personne ne regarde.
const MAX_SIDE := 1024
## 160 et non la taille d'affichage d'une vignette de liste (28) : la même image coiffe
## aussi les cases du calendrier, larges de plus de cent points sur un écran de bureau.
## Une vignette taillée au plus juste y serait visiblement floue, pour quelques
## kilooctets économisés.
const THUMB_SIDE := 160
const QUALITY := 0.8

## Garde-fou d'entrée : décompressée, une image de 40 Mpx occupe déjà 160 Mo de mémoire.
## Au-delà, mieux vaut un refus lisible qu'une fermeture brutale sur le téléphone.
const MAX_INPUT_PIXELS := 40_000_000

## Prépare une image venue d'un fichier. Renvoie
## `{ok: bool, error: String, image: String, thumb: String}` — les deux images étant
## en base64, prêtes pour la base comme pour la synchronisation.
static func from_file(path: String) -> Dictionary:
	var read := read_source(path)
	if not read.ok:
		return _failure(read.error)
	return from_image(read.image)

## Lit une image sans la normaliser : `{ok, error, image}`. Sert à l'écran de cadrage,
## qui a besoin de la photo d'origine — la réduction n'intervient qu'ensuite.
static func read_source(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "Fichier introuvable.", "image": null}

	var image := Image.new()
	if image.load(path) == OK:
		return {"ok": true, "error": "", "image": image}

	# `Image.load` se fie à l'extension du chemin. Le sélecteur de fichiers d'Android
	# rend des noms qui n'en portent pas toujours — et une photo peut avoir été
	# renommée. On relit donc les octets et on essaie les décodeurs, en s'appuyant sur
	# la signature du fichier plutôt que sur son nom.
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"ok": false, "error": "Fichier vide ou illisible.", "image": null}
	return read_bytes(bytes)

## Décode une image d'après le contenu réel des octets : `{ok, error, image}`.
static func read_bytes(bytes: PackedByteArray) -> Dictionary:
	var image := Image.new()
	for decoder in _decoder_order(bytes):
		var err := FAILED
		match decoder:
			"jpg":
				err = image.load_jpg_from_buffer(bytes)
			"png":
				err = image.load_png_from_buffer(bytes)
			"webp":
				err = image.load_webp_from_buffer(bytes)
		if err == OK and not image.is_empty():
			return {"ok": true, "error": "", "image": image}

	if _looks_like_heif(bytes):
		# Format par défaut de bien des téléphones récents, que Godot ne sait pas lire.
		# Le dire précisément vaut mieux qu'un « format non reconnu » qui laisserait
		# croire à un fichier abîmé.
		return {"ok": false, "image": null,
			"error": "Photo au format HEIC, que l'application ne sait pas lire. " \
				+ "Réglez l'appareil photo sur JPEG, ou convertissez l'image."}
	return {"ok": false, "image": null,
		"error": "Format d'image non reconnu (attendus : JPEG, PNG ou WebP)."}

## Conservé pour les appelants qui partent d'octets déjà en mémoire.
static func from_bytes(bytes: PackedByteArray) -> Dictionary:
	var read := read_bytes(bytes)
	if not read.ok:
		return _failure(read.error)
	return from_image(read.image)

## Décodeurs à essayer, le plus probable d'abord d'après la signature du fichier. Tous
## sont tentés ensuite : une signature inconnue ne condamne pas le fichier.
static func _decoder_order(bytes: PackedByteArray) -> Array:
	if bytes.size() >= 4:
		if bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
			return ["jpg", "png", "webp"]
		if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
			return ["png", "jpg", "webp"]
		if bytes.slice(0, 4).get_string_from_ascii() == "RIFF":
			return ["webp", "jpg", "png"]
	return ["jpg", "png", "webp"]

static func _looks_like_heif(bytes: PackedByteArray) -> bool:
	if bytes.size() < 12:
		return false
	if bytes.slice(4, 8).get_string_from_ascii() != "ftyp":
		return false
	var brand := bytes.slice(8, 12).get_string_from_ascii()
	return brand in ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"]

## Prépare une image déjà en mémoire — c'est par là que passe la capture de l'appareil
## photo, qui n'a pas de fichier d'origine.
## `thumb_rect` désigne, en pixels de l'image source, le carré à prélever pour la
## vignette. Vide, c'est le centre qui est pris — le comportement d'avant l'écran de
## cadrage, et le repli quand aucun choix n'est possible.
static func from_image(source: Image, thumb_rect := Rect2i()) -> Dictionary:
	if source.is_empty() or source.get_width() <= 0 or source.get_height() <= 0:
		return _failure("Image vide.")
	if source.get_width() * source.get_height() > MAX_INPUT_PIXELS:
		return _failure("Image trop grande (%d × %d)." % [source.get_width(), source.get_height()])

	# La zone est exprimée dans l'image d'ORIGINE : on prélève donc avant de réduire,
	# sinon la réduction déplacerait le cadre choisi.
	var thumb_source := source
	if thumb_rect.size.x > 0 and thumb_rect.size.y > 0:
		var bounds := Rect2i(Vector2i.ZERO, source.get_size())
		var safe := thumb_rect.intersection(bounds)
		if safe.size.x > 0 and safe.size.y > 0:
			thumb_source = source.get_region(safe)

	var full := _flattened(source)
	_fit(full, MAX_SIDE)
	var thumb := _square_thumb(_flattened(thumb_source))

	var image_bytes := full.save_jpg_to_buffer(QUALITY)
	var thumb_bytes := thumb.save_jpg_to_buffer(QUALITY)
	if image_bytes.is_empty() or thumb_bytes.is_empty():
		return _failure("L'image n'a pas pu être encodée.")

	return {
		"ok": true,
		"error": "",
		"image": Marshalls.raw_to_base64(image_bytes),
		"thumb": Marshalls.raw_to_base64(thumb_bytes),
	}

## Base64 → texture affichable. Renvoie `null` sur une donnée illisible plutôt que de
## laisser l'appelant manipuler une texture vide : une photo abîmée par un transfert ne
## doit pas casser l'écran qui l'affiche.
static func decode(encoded: String) -> ImageTexture:
	if encoded.strip_edges() == "":
		return null
	var bytes := Marshalls.base64_to_raw(encoded)
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_jpg_from_buffer(bytes) != OK:
		return null
	return ImageTexture.create_from_image(image)

## Aplatit la transparence sur du blanc. Sans cela, le JPEG — qui ignore le canal
## alpha — rend les zones transparentes en noir.
static func _flattened(source: Image) -> Image:
	var image := source.duplicate() as Image
	if not image.detect_alpha():
		image.convert(Image.FORMAT_RGB8)
		return image
	var flat := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGB8)
	flat.fill(Color.WHITE)
	image.convert(Image.FORMAT_RGBA8)
	flat.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
	return flat

## Réduit pour que le côté long tienne dans `limit`, en gardant les proportions. Une
## image déjà plus petite est laissée telle quelle : l'agrandir n'ajouterait aucun
## détail et coûterait des octets.
static func _fit(image: Image, limit: int) -> void:
	var longest := maxi(image.get_width(), image.get_height())
	if longest <= limit:
		return
	var scale := float(limit) / float(longest)
	image.resize(maxi(1, int(round(image.get_width() * scale))),
		maxi(1, int(round(image.get_height() * scale))), Image.INTERPOLATE_LANCZOS)

## Vignette carrée : recadrage centré puis réduction. Déformer aux proportions du carré
## écraserait les photos en format portrait, les plus courantes avec un téléphone.
static func _square_thumb(image: Image) -> Image:
	var side := mini(image.get_width(), image.get_height())
	var origin := Vector2i((image.get_width() - side) / 2, (image.get_height() - side) / 2)
	var thumb := image.get_region(Rect2i(origin, Vector2i(side, side)))
	thumb.resize(THUMB_SIDE, THUMB_SIDE, Image.INTERPOLATE_LANCZOS)
	return thumb

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "image": "", "thumb": ""}
