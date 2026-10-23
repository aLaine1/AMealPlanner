class_name PhotoCropPopup
extends Window
## Choix de la partie de la photo qui servira de vignette.
##
## La vignette est **carrée** — c'est elle qui s'affiche dans la bibliothèque et dans
## les cases du calendrier — alors qu'une photo ne l'est presque jamais. Il faut donc
## en prélever un carré, et le prendre au centre sans rien demander tombait à côté du
## sujet une fois sur deux : un plat rarement centré, une assiette en bas du cadre.
##
## L'image **entière** est conservée par ailleurs : ce cadre ne choisit que la vignette,
## il ne jette rien. C'est aussi pourquoi la zone extérieure est assombrie plutôt que
## masquée — elle reste visible, on voit ce qu'on ne prend pas.
##
##     var popup := PhotoCropPopup.new()
##     popup.source = image
##     popup.confirmed_crop.connect(func(rect: Rect2i): ...)
##     add_child(popup); popup.popup_centered()

## Zone retenue, en pixels de l'image source.
signal confirmed_crop(rect: Rect2i)

## Part du côté le plus court occupée par le cadre à l'ouverture.
const DEFAULT_RATIO := 0.9
const MIN_RATIO := 0.25
## Rayon de saisie d'un coin, généreux : viser un angle au doigt demande sinon une
## précision qu'on n'a pas en tenant le téléphone.
const HANDLE_RADIUS := 44.0

var source: Image

var _preview: TextureRect
var _overlay: Control
## Centre du cadre, en coordonnées normalisées de l'image (0..1).
var _center := Vector2(0.5, 0.5)
## Côté du cadre, en fraction du côté le plus court de l'image.
var _ratio := DEFAULT_RATIO
## Geste en cours. Le coin saisi l'emporte sur le déplacement : c'est la plus petite
## cible des deux.
enum Gesture { NONE, MOVE, RESIZE }
var _gesture := Gesture.NONE
## Coin opposé, immobile pendant un redimensionnement.
var _anchor := Vector2.ZERO
## Écart entre le doigt et le centre du cadre au moment de la saisie.
var _grab_offset := Vector2.ZERO

func _ready() -> void:
	title = "Cadrer la vignette"
	Layout.fit_window(self, Vector2i(720, 720), Vector2i(480, 560))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)
	_build()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 14)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var hint := Label.new()
	hint.text = "Déplace le cadre, ou tire un coin pour l'agrandir. " \
		+ "Cette partie sera la vignette des listes."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	column.add_child(hint)

	# L'image et le voile partagent le même parent et les mêmes dimensions : le voile
	# se dessine dans le repère de la zone d'image, ce qui évite d'avoir à convertir
	# des coordonnées entre deux échelles.
	var stage := Control.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.clip_contents = true
	column.add_child(stage)

	_preview = TextureRect.new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Toute l'image reste visible : on ne peut pas cadrer ce qu'on ne voit pas.
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture = ImageTexture.create_from_image(source) if source != null else null
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(_preview)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.draw.connect(_draw_overlay)
	_overlay.gui_input.connect(_on_overlay_input)
	_overlay.resized.connect(func(): _overlay.queue_redraw())
	stage.add_child(_overlay)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.theme_type_variation = "GhostButton"
	cancel.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	cancel.pressed.connect(queue_free)
	buttons.add_child(cancel)

	var accept := Button.new()
	accept.text = "Valider"
	accept.custom_minimum_size = Vector2(140, Layout.TOUCH_TARGET)
	accept.pressed.connect(_on_accept)
	buttons.add_child(accept)

## Rectangle occupé par l'image dans la zone d'affichage, bandes comprises. Le cadre
## de sélection s'y rapporte : hors de lui, il n'y a pas d'image à prélever.
func _image_rect() -> Rect2:
	if source == null or _overlay == null:
		return Rect2()
	var view := _overlay.size
	var image_size := Vector2(source.get_size())
	if image_size.x <= 0.0 or image_size.y <= 0.0 or view.x <= 0.0 or view.y <= 0.0:
		return Rect2()
	var scale: float = minf(view.x / image_size.x, view.y / image_size.y)
	var drawn := image_size * scale
	return Rect2((view - drawn) * 0.5, drawn)

## Cadre de sélection à l'écran.
func _crop_rect() -> Rect2:
	var area := _image_rect()
	if area.size.x <= 0.0:
		return Rect2()
	var side: float = minf(area.size.x, area.size.y) * _ratio
	var center := area.position + _center * area.size
	return Rect2(center - Vector2(side, side) * 0.5, Vector2(side, side))

func _draw_overlay() -> void:
	var area := _image_rect()
	if area.size.x <= 0.0:
		return
	var crop := _crop_rect()
	# Quatre bandes plutôt qu'un rectangle troué : le dessin direct n'offre pas de
	# découpe, et quatre rectangles se calculent sans surprise.
	var veil := Color(0, 0, 0, 0.55)
	_overlay.draw_rect(Rect2(area.position,
		Vector2(area.size.x, crop.position.y - area.position.y)), veil)
	_overlay.draw_rect(Rect2(Vector2(area.position.x, crop.end.y),
		Vector2(area.size.x, area.end.y - crop.end.y)), veil)
	_overlay.draw_rect(Rect2(Vector2(area.position.x, crop.position.y),
		Vector2(crop.position.x - area.position.x, crop.size.y)), veil)
	_overlay.draw_rect(Rect2(Vector2(crop.end.x, crop.position.y),
		Vector2(area.end.x - crop.end.x, crop.size.y)), veil)

	_overlay.draw_rect(crop, Color.WHITE, false, 2.0)
	# Équerres d'angle : elles rendent le cadre lisible sur une photo claire, et
	# signalent où saisir pour redimensionner — la poignée est invisible autrement.
	var mark: float = minf(28.0, crop.size.x * 0.28)
	for corner in [
		[crop.position, Vector2(1, 0), Vector2(0, 1)],
		[Vector2(crop.end.x, crop.position.y), Vector2(-1, 0), Vector2(0, 1)],
		[Vector2(crop.position.x, crop.end.y), Vector2(1, 0), Vector2(0, -1)],
		[crop.end, Vector2(-1, 0), Vector2(0, -1)],
	]:
		_overlay.draw_line(corner[0], corner[0] + corner[1] * mark, Color.WHITE, 5.0)
		_overlay.draw_line(corner[0], corner[0] + corner[2] * mark, Color.WHITE, 5.0)

func _on_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_begin_gesture(button.position)
		else:
			_gesture = Gesture.NONE
	elif event is InputEventMouseMotion and _gesture != Gesture.NONE:
		_continue_gesture((event as InputEventMouseMotion).position)

## Décide, à l'appui, si l'on redimensionne par un coin ou si l'on déplace le cadre.
##
## Le coin l'emporte quand le doigt en est proche : c'est la cible la plus petite, et
## la plus facile à manquer. Un appui hors du cadre le fait venir sous le doigt, ce qui
## évite de le pousser sur toute la largeur pour changer de sujet.
func _begin_gesture(position: Vector2) -> void:
	var crop := _crop_rect()
	if crop.size.x <= 0.0:
		return

	var corners := [crop.position, Vector2(crop.end.x, crop.position.y),
		Vector2(crop.position.x, crop.end.y), crop.end]
	var nearest := 0
	var best := INF
	for index in range(corners.size()):
		var distance: float = position.distance_to(corners[index])
		if distance < best:
			best = distance
			nearest = index
	if best <= HANDLE_RADIUS:
		_gesture = Gesture.RESIZE
		# Le coin OPPOSÉ reste fixe : le cadre s'ouvre et se ferme depuis lui, comme on
		# étire une sélection.
		_anchor = corners[3 - nearest]
		return

	_gesture = Gesture.MOVE
	if crop.has_point(position):
		# Déplacement relatif : le cadre ne saute pas sous le doigt au premier contact.
		_grab_offset = position - crop.get_center()
	else:
		_grab_offset = Vector2.ZERO
		_set_center_from(position)

func _continue_gesture(position: Vector2) -> void:
	if _gesture == Gesture.MOVE:
		_set_center_from(position - _grab_offset)
	elif _gesture == Gesture.RESIZE:
		_resize_from(position)

func _set_center_from(position: Vector2) -> void:
	var area := _image_rect()
	if area.size.x <= 0.0:
		return
	_center = (position - area.position) / area.size
	_clamp_center()
	_overlay.queue_redraw()

## Le cadre reste carré : on retient le plus grand des deux écarts au coin d'ancrage,
## sans quoi tirer en diagonale donnerait un rectangle.
func _resize_from(position: Vector2) -> void:
	var area := _image_rect()
	if area.size.x <= 0.0:
		return
	var shortest: float = minf(area.size.x, area.size.y)
	var span := (position - _anchor).abs()
	var side: float = clampf(maxf(span.x, span.y), shortest * MIN_RATIO, shortest)

	# Le cadre grandit depuis l'ancre, dans la direction où le doigt est parti.
	var direction := Vector2(
		1.0 if position.x >= _anchor.x else -1.0,
		1.0 if position.y >= _anchor.y else -1.0)
	var centre := _anchor + direction * side * 0.5
	_ratio = side / shortest
	_center = (centre - area.position) / area.size
	_clamp_center()
	_overlay.queue_redraw()

## Le cadre ne sort jamais de l'image : au-delà, il n'y a rien à prélever.
func _clamp_center() -> void:
	var area := _image_rect()
	if area.size.x <= 0.0:
		return
	var side: float = minf(area.size.x, area.size.y) * _ratio
	var half := Vector2(side, side) * 0.5 / area.size
	_center.x = clampf(_center.x, half.x, 1.0 - half.x)
	_center.y = clampf(_center.y, half.y, 1.0 - half.y)

func _on_accept() -> void:
	confirmed_crop.emit(_source_rect())
	queue_free()

## Traduit le cadre en pixels de l'image d'origine.
func _source_rect() -> Rect2i:
	if source == null:
		return Rect2i()
	var image_size := Vector2(source.get_size())
	var side: float = minf(image_size.x, image_size.y) * _ratio
	var center := _center * image_size
	var origin := center - Vector2(side, side) * 0.5
	origin.x = clampf(origin.x, 0.0, maxf(0.0, image_size.x - side))
	origin.y = clampf(origin.y, 0.0, maxf(0.0, image_size.y - side))
	return Rect2i(Vector2i(origin.round()), Vector2i(int(round(side)), int(round(side))))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
