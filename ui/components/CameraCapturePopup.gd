class_name CameraCapturePopup
extends Window
## Prise de vue par l'appareil photo de l'appareil.
##
## Godot ne donne pas accès à l'application photo du système : `CameraServer` fournit
## un flux vidéo brut, et l'écran de visée est donc à construire — aperçu, déclencheur,
## et capture de ce qui est affiché.
##
## Usage :
##     var popup := CameraCapturePopup.new()
##     popup.captured.connect(func(image: Image): ...)
##     add_child(popup); popup.popup_centered()
##
## L'image renvoyée est brute ; c'est `RecipePhoto` qui la normalise ensuite, comme
## pour un fichier choisi. Les deux sources convergent donc vers le même traitement.

## Émis une seule fois, avec l'image capturée. La fenêtre se referme dans la foulée.
signal captured(image: Image)

## Le flux arrive en RGB sur les caméras de bureau, mais en YCbCr — souvent en deux
## plans séparés — sur Android. Le convertir dans un shader plutôt qu'en GDScript est
## la seule option tenable : la conversion s'applique à chaque image du flux.
const YCBCR_SHADER := """
shader_type canvas_item;

// PAS `source_color` : ce hint applique une conversion sRGB → linéaire, correcte pour
// une couleur mais fausse pour ces plans, qui portent de la luminance et de la
// chrominance brutes.
uniform sampler2D y_texture : filter_linear;
uniform sampler2D cbcr_texture : filter_linear;
// Un seul plan YCbCr entrelacé, ou deux plans séparés.
uniform bool separate_planes = true;
// Le flux arrive dans le repère du CAPTEUR, qui ne tourne pas avec le téléphone :
// tenu en portrait, on reçoit une image couchée. Ces deux uniformes la remettent
// d'aplomb, et corrigent au passage la déformation — les UV couvraient tout le cadre
// quelles que soient les proportions du flux.
uniform vec2 feed_size = vec2(1.0, 1.0);
uniform vec2 view_size = vec2(1.0, 1.0);
uniform int rotation_steps = 0;
uniform bool mirror = false;

// `uv` est passé en paramètre : les variables intégrées du langage — dont UV — ne
// sont visibles que dans `fragment()`, jamais dans une fonction auxiliaire.
vec2 oriented_uv(vec2 uv) {
	vec2 p = uv - vec2(0.5);
	if (rotation_steps == 1) {
		p = vec2(p.y, -p.x);
	} else if (rotation_steps == 2) {
		p = -p;
	} else if (rotation_steps == 3) {
		p = vec2(-p.y, p.x);
	}
	if (mirror) {
		p.x = -p.x;
	}
	// Un quart de tour échange largeur et hauteur du flux.
	vec2 source = feed_size;
	if (rotation_steps == 1 || rotation_steps == 3) {
		source = vec2(feed_size.y, feed_size.x);
	}
	// Ajustement par l'INTÉRIEUR : toute l'image tient dans le cadre, quitte à laisser
	// des bandes sur les côtés. Le recouvrement remplissait mieux l'écran, mais coupait
	// les bords — or on ne peut pas cadrer ce qu'on ne voit pas, et le recadrage se
	// choisit de toute façon à l'étape suivante.
	float scale = min(view_size.x / source.x, view_size.y / source.y);
	return p * (view_size / (source * scale)) + vec2(0.5);
}

void fragment() {
	vec2 uv = oriented_uv(UV);
	float y;
	vec2 cbcr;
	if (separate_planes) {
		y = texture(y_texture, uv).r;
		cbcr = texture(cbcr_texture, uv).rg - vec2(0.5);
	} else {
		vec4 packed = texture(y_texture, uv);
		y = packed.r;
		cbcr = packed.gb - vec2(0.5);
	}
	// BT.601, la matrice des flux caméra.
	COLOR = vec4(
		y + 1.402 * cbcr.y,
		y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
		y + 1.772 * cbcr.x,
		1.0);
}
"""

## Côté long de la photo capturée. `RecipePhoto` la ramènera de toute façon à sa
## borne — inutile de viser plus haut que ce qui sera conservé.
const CAPTURE_LONG_SIDE := 1024

## Environ deux secondes à 60 Hz : au-delà, on cesse d'attendre la première image.
const FIRST_FRAME_FRAMES := 120

var _feed: CameraFeed = null
var _viewport: SubViewport
var _status: Label
var _shoot: Button
var _switch: Button
## Index dans `CameraServer.feeds()` — un téléphone en a au moins deux.
var _feed_index := 0
## Vrai dès que le flux a livré une image — c'est à partir de là que son type de
## données est fiable.
var _frame_seen := false
## Indice du format retenu, relu pour connaître les dimensions du flux.
var _format_index := -1

func _ready() -> void:
	title = "Prendre une photo"
	Layout.fit_window(self, Vector2i(720, 620), Vector2i(480, 480))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(_close)
	_build()
	# La permission n'est demandée qu'ici, au moment où l'appareil photo sert
	# réellement : réclamée au lancement, elle n'aurait aucun sens pour l'utilisateur.
	if OS.get_name() == "Android" and not OS.request_permission("android.permission.CAMERA"):
		_set_status("Autorisation de l'appareil photo refusée.")
		return
	_start_feed()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 16)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	margin.add_child(outer)

	# Le flux est rendu dans un SubViewport et non affiché directement : la capture est
	# alors exactement ce que l'aperçu montre, conversion de couleur comprise. Lire la
	# texture de la caméra à la place obligerait à refaire la conversion à la main, et à
	# la refaire d'accord avec le shader.
	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Sans cette borne, le conteneur réclame la taille de son viewport (1024 de côté) et
	# la propage à toute la fenêtre, qui déborde alors de l'écran.
	container.custom_minimum_size = Vector2(0, 0)
	container.clip_contents = true
	outer.add_child(container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(CAPTURE_LONG_SIDE, CAPTURE_LONG_SIDE)
	_viewport.transparent_bg = false
	# Le flux change à chaque image : sans rendu continu, l'aperçu resterait figé.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	outer.add_child(_status)

	# HFlowContainer et non HBox : à trois boutons, la rangée réclamait plus que la
	# largeur d'un téléphone. Ce n'était pas seulement elle qui débordait — sa largeur
	# minimale s'imposait à toute la colonne, poussant l'APERÇU hors de l'écran.
	var buttons := HFlowContainer.new()
	buttons.alignment = FlowContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("h_separation", 8)
	buttons.add_theme_constant_override("v_separation", 8)
	outer.add_child(buttons)

	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.theme_type_variation = "GhostButton"
	cancel.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	cancel.pressed.connect(_close)
	buttons.add_child(cancel)

	_switch = Button.new()
	# Libellé court : « Changer d'objectif » à lui seul mangeait la moitié de la largeur.
	_switch.text = "Objectif"
	_switch.theme_type_variation = "OutlineButton"
	_switch.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_switch.pressed.connect(_next_feed)
	_switch.visible = false
	buttons.add_child(_switch)

	_shoot = Button.new()
	_shoot.text = "Photographier"
	# Aucune largeur imposée : c'est elle qui débordait.
	_shoot.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_shoot.disabled = true
	_shoot.pressed.connect(_capture)
	buttons.add_child(_shoot)

## Ouvre le flux courant et construit l'aperçu adapté à son format.
##
## Le serveur ne recense les appareils que si on le lui demande — `monitoring_feeds`
## vaut `false` par défaut, et l'énumérer coûte, d'où l'activation ici seulement, et
## l'extinction à la fermeture. Le recensement peut de plus prendre un instant : une
## liste vide au premier appel ne signifie pas encore qu'il n'y a pas d'appareil.
func _start_feed() -> void:
	_stop_feed()
	CameraServer.monitoring_feeds = true
	var feeds := CameraServer.feeds()
	if feeds.is_empty():
		_set_status("Recherche d'un appareil photo…")
		await get_tree().create_timer(0.8).timeout
		feeds = CameraServer.feeds()
	if feeds.is_empty():
		_set_status("Aucun appareil photo détecté sur cet appareil.")
		return
	_switch.visible = feeds.size() > 1
	_feed_index = clampi(_feed_index, 0, feeds.size() - 1)
	_feed = feeds[_feed_index]

	# Un flux doit avoir un format AVANT d'être activé — sans quoi l'activation échoue
	# (« CameraFeed format needs to be set before activating ») et l'aperçu reste noir
	# sans que rien ne le dise.
	_format_index = _pick_format(_feed)
	if _format_index < 0:
		_set_status("Cet appareil photo n'annonce aucun format exploitable.")
		return
	_feed.set_format(_format_index, {})

	_feed.set_active(true)
	if not _feed.is_active():
		_set_status("L'appareil photo n'a pas pu être démarré.")
		return

	# Le format des données n'est connu qu'une fois la PREMIÈRE image arrivée : avant,
	# le flux s'annonce en `FEED_RGB` même s'il livrera du YCbCr. Construire l'aperçu
	# tout de suite prenait donc la branche RGB et affichait la texture d'indice 0 —
	# qui, pour un flux YCbCr, est le plan de LUMINANCE. `FEED_RGBA_IMAGE` et
	# `FEED_Y_IMAGE` valent tous deux 0 : la même texture, lue comme du RGBA. Seul le
	# canal rouge portait alors l'image, d'où un aperçu entièrement rouge dans lequel
	# on distinguait pourtant la scène.
	_set_status("Démarrage de l'appareil photo…")
	await _await_first_frame(_feed)

	var preview := _build_preview(_feed)
	if preview == null:
		_set_status("Format d'image non pris en charge par cet appareil photo.")
		return
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(preview)
	_shoot.disabled = false
	_set_status(_feed.get_name())

## Attend la première image du flux, au plus `FIRST_FRAME_FRAMES` images de rendu.
##
## Le délai de garde évite de rester bloqué sur un appareil qui n'émettrait jamais :
## mieux vaut un aperçu construit sur un type peut-être imparfait qu'un écran figé sur
## « Démarrage… ».
func _await_first_frame(feed: CameraFeed) -> void:
	_frame_seen = false
	var on_frame := func(): _frame_seen = true
	feed.frame_changed.connect(on_frame)
	var frames := 0
	while not _frame_seen and frames < FIRST_FRAME_FRAMES:
		await get_tree().process_frame
		frames += 1
	if feed.frame_changed.is_connected(on_frame):
		feed.frame_changed.disconnect(on_frame)

## Choisit un format de capture parmi ceux qu'annonce l'appareil, ou -1 s'il n'en
## propose aucun.
##
## Le plus proche de la résolution de capture l'emporte, la fréquence départageant les
## ex æquo. Prendre le premier venu donnerait aussi bien du 160×120 que du 4K : le
## premier est inutilisable, le second coûte à décoder à chaque image du flux pour une
## photo qui sera de toute façon ramenée à 1024.
func _pick_format(feed: CameraFeed) -> int:
	var formats: Array = feed.get_formats()
	var best := -1
	var best_score := INF
	for index in range(formats.size()):
		var entry: Dictionary = formats[index]
		var width := int(entry.get("width", 0))
		var height := int(entry.get("height", 0))
		if width <= 0 or height <= 0:
			continue
		var fps := 0.0
		var denominator := float(entry.get("frame_denominator", 0))
		var numerator := float(entry.get("frame_numerator", 1))
		if denominator > 0.0 and numerator > 0.0:
			fps = denominator / numerator
		# Distance à la résolution visée, puis bonus de fluidité (au plus 1 point, donc
		# jamais au prix d'une résolution franchement plus mauvaise).
		var score := absf(float(width) - float(CAPTURE_LONG_SIDE)) / float(CAPTURE_LONG_SIDE)
		score += 1.0 - clampf(fps / 30.0, 0.0, 1.0)
		if score < best_score:
			best_score = score
			best = index
	return best

## Construit le `TextureRect` d'aperçu selon le format annoncé par le flux. Renvoie
## `null` pour un format qu'on ne sait pas afficher — mieux vaut le dire que montrer
## une image aux couleurs fausses.
func _build_preview(feed: CameraFeed) -> TextureRect:
	var view := TextureRect.new()
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED

	match feed.get_datatype():
		CameraFeed.FEED_RGB:
			view.texture = _camera_texture(feed, CameraServer.FEED_RGBA_IMAGE)
		CameraFeed.FEED_YCBCR, CameraFeed.FEED_YCBCR_SEP:
			var separate := feed.get_datatype() == CameraFeed.FEED_YCBCR_SEP
			var shader := Shader.new()
			shader.code = YCBCR_SHADER
			var material := ShaderMaterial.new()
			material.shader = shader
			material.set_shader_parameter("separate_planes", separate)
			material.set_shader_parameter("y_texture",
				_camera_texture(feed, CameraServer.FEED_Y_IMAGE))
			if separate:
				material.set_shader_parameter("cbcr_texture",
					_camera_texture(feed, CameraServer.FEED_CBCR_IMAGE))
			_apply_orientation(material, feed)
			view.material = material
			# Un TextureRect sans texture ne dessine rien, et le shader n'aurait donc
			# aucun pixel où s'exécuter : cette texture blanche lui sert de support.
			view.texture = _white_texture()
		_:
			return null
	return view

## Remet l'image d'aplomb et lui rend ses proportions.
##
## Le capteur ne tourne pas avec le téléphone : il livre toujours son image dans son
## repère, en paysage. Tenu en portrait, on reçoit donc une image couchée. Plutôt que
## de coder un angle en dur — il varie d'un appareil à l'autre — on compare les
## orientations : un flux plus large que haut affiché dans un cadre plus haut que large
## demande un quart de tour.
##
## L'objectif frontal est en outre inversé horizontalement, comme un miroir : c'est ce
## qu'on attend en se regardant, mais pas en photographiant un plat.
func _apply_orientation(material: ShaderMaterial, feed: CameraFeed) -> void:
	var feed_size := _feed_size(feed)
	var view_size := Vector2(_viewport.size)
	var feed_landscape := feed_size.x >= feed_size.y
	var view_landscape := view_size.x >= view_size.y

	var steps := 0
	if feed_landscape != view_landscape:
		steps = 1
	material.set_shader_parameter("feed_size", feed_size)
	material.set_shader_parameter("view_size", view_size)
	material.set_shader_parameter("rotation_steps", steps)
	material.set_shader_parameter("mirror", feed.get_position() == CameraFeed.FEED_FRONT)

	print("CameraCapture: flux %s vue %s rotation %d position %d"
		% [feed_size, view_size, steps, feed.get_position()])

## Dimensions du format retenu. Le flux ne les expose pas directement : on relit
## l'entrée choisie dans la liste des formats.
func _feed_size(feed: CameraFeed) -> Vector2:
	var formats: Array = feed.get_formats()
	if _format_index >= 0 and _format_index < formats.size():
		var entry: Dictionary = formats[_format_index]
		var width := float(entry.get("width", 0))
		var height := float(entry.get("height", 0))
		if width > 0.0 and height > 0.0:
			return Vector2(width, height)
	return Vector2(CAPTURE_LONG_SIDE, CAPTURE_LONG_SIDE)

func _camera_texture(feed: CameraFeed, which: int) -> CameraTexture:
	var texture := CameraTexture.new()
	texture.camera_feed_id = feed.get_id()
	texture.which_feed = which
	texture.camera_is_active = true
	return texture

func _white_texture() -> ImageTexture:
	var image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)

func _next_feed() -> void:
	var feeds := CameraServer.feeds()
	if feeds.size() < 2:
		return
	_feed_index = (_feed_index + 1) % feeds.size()
	_start_feed()

func _capture() -> void:
	# `SubViewportContainer.stretch` cale le viewport sur la taille du conteneur : la
	# photo hériterait donc de la taille de la FENÊTRE, et une petite fenêtre donnerait
	# une petite photo. Le temps de la capture, on rend le viewport à sa résolution
	# nominale, puis on lui rend sa souplesse d'aperçu.
	var container := _viewport.get_parent() as SubViewportContainer
	var preview_size := Vector2(_viewport.size)
	var capture_size := _capture_size(preview_size)

	container.stretch = false
	_viewport.size = capture_size
	# Le cadrage est calculé dans le shader À PARTIR de la taille de la vue : sans cette
	# mise à jour, la photo serait cadrée pour l'aperçu et non pour elle-même — en
	# portrait, on capturerait une bande prise dans un cadre paysage.
	_set_view_size(capture_size)

	# Deux images : la première applique la nouvelle taille, la seconde la dessine.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()

	_set_view_size(preview_size)
	container.stretch = true
	if image == null or image.is_empty():
		_set_status("La capture a échoué. Réessayez.")
		return
	captured.emit(image)
	_close()

## Taille de capture : le rapport de l'aperçu, côté long ramené à `CAPTURE_LONG_SIDE`.
## Une taille fixe en paysage donnerait une photo en travers dès que le téléphone est
## tenu droit.
func _capture_size(preview_size: Vector2) -> Vector2i:
	if preview_size.x <= 0.0 or preview_size.y <= 0.0:
		return Vector2i(CAPTURE_LONG_SIDE, CAPTURE_LONG_SIDE)
	var scale := float(CAPTURE_LONG_SIDE) / maxf(preview_size.x, preview_size.y)
	return Vector2i(maxi(1, int(round(preview_size.x * scale))),
		maxi(1, int(round(preview_size.y * scale))))

func _set_view_size(size) -> void:
	for child in _viewport.get_children():
		if child is TextureRect and child.material is ShaderMaterial:
			(child.material as ShaderMaterial).set_shader_parameter("view_size", Vector2(size))

func _stop_feed() -> void:
	if _feed != null:
		_feed.set_active(false)
		_feed = null
	# Le recensement a un coût permanent, et sur téléphone il maintient l'appareil
	# photo éveillé : il ne survit pas à cet écran.
	CameraServer.monitoring_feeds = false
	if _viewport != null:
		for child in _viewport.get_children():
			_viewport.remove_child(child)
			child.queue_free()

## Le flux reste ouvert tant qu'on ne le ferme pas explicitement : sur téléphone, cela
## laisserait l'appareil photo — et son voyant — actifs après la fermeture de l'écran.
func _close() -> void:
	_stop_feed()
	queue_free()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_close()
	elif what == NOTIFICATION_PREDELETE:
		if _feed != null:
			_feed.set_active(false)

func _set_status(message: String) -> void:
	if _status != null:
		_status.text = message
