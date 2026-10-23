class_name SharePopup
extends Window
## Choix des recettes à partager. Le code produit s'affiche dans `ShareCodePopup`.
##
## Un seul écran pour une recette comme pour un lot — la seule différence est que le
## QR cesse d'être lisible au-delà d'une dizaine de recettes, et l'écran le dit alors
## au lieu d'afficher un code trop dense pour être scanné.
##
## Une seule colonne, en tout format. Le QR occupait autrefois la moitié droite de
## l'écran : sur téléphone les deux colonnes réclamaient près de 600 unités pour 412
## disponibles, et le QR y réservait sa place bien avant d'avoir quoi que ce soit à
## montrer. Il a désormais sa fenêtre, qui ne s'ouvre qu'une fois le partage déposé.
##
## Il n'y a pas de lecture de QR dans l'application — cela demanderait la caméra et un
## décodeur. L'appareil photo du téléphone lit le code et affiche le texte, qu'on colle
## dans « Importer ».

const Share := preload("res://services/RecipeShare.gd")
const TouchTapScript := preload("res://ui/components/TouchTap.gd")
const ShareCodePopupScript := preload("res://ui/recipes/ShareCodePopup.gd")

var preselected: String = ""   ## nom de la recette cochée à l'ouverture

var _status: Label
var _publish_btn: Button
var _count: Label
var _checks: Array[CheckBox] = []
var _recipes: Array = []
## Vrai pendant « Tout sélectionner » / « Tout désélectionner » : sans cela, chaque case
## basculée relancerait le récapitulatif, soit 73 parcours de la liste pour un seul geste.
var _bulk := false

func _ready() -> void:
	title = "Partager des recettes"
	Layout.fit_window(self, Vector2i(880, 640), Vector2i(680, 520))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)

	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 14)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	root.add_child(_build_header())

	var selection := _build_selection()
	selection.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(selection)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	root.add_child(_status)

	_publish_btn = Button.new()
	_publish_btn.text = "Créer le partage"
	_publish_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_publish_btn.pressed.connect(_on_publish)
	root.add_child(_publish_btn)

	_refresh()

func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	var back := Button.new()
	back.text = "←  Fermer"
	back.theme_type_variation = "GhostButton"
	back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	back.pressed.connect(queue_free)
	header.add_child(back)

	var heading := Label.new()
	heading.text = "Partager des recettes"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(heading)
	return header

func _build_selection() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)

	_count = Label.new()
	_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	column.add_child(_count)

	# Partager toute sa collection sur un appareil neuf, ou repartir d'une liste vierge
	# après s'être trompé, demandait 73 touchers. HFlowContainer : sur un écran étroit
	# les deux boutons passent à la ligne au lieu d'être poussés hors champ.
	var bulk := HFlowContainer.new()
	bulk.add_theme_constant_override("h_separation", 8)
	bulk.add_theme_constant_override("v_separation", 8)
	column.add_child(bulk)
	bulk.add_child(_make_bulk_button("Tout sélectionner", true))
	bulk.add_child(_make_bulk_button("Tout désélectionner", false))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	Layout.scroll_body(scroll).add_child(list)

	_recipes = DataStore.get_all_recipe_objects()
	_recipes.sort_custom(func(a, b): return TextFold.before(a.nom, b.nom))
	for recipe in _recipes:
		list.add_child(_make_row(recipe))
	return column

func _make_bulk_button(label: String, on: bool) -> Button:
	var button := Button.new()
	button.text = label
	button.theme_type_variation = "OutlineButton"
	button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func(): _set_all(on))
	return button

## Une ligne entière est la cible, et non la seule case : cible de 400 x 48, atteignable
## au pouce sans viser. C'est aussi ce qui rend le défilement possible — la case à cocher
## est mise hors d'atteinte du pointeur (`MOUSE_FILTER_IGNORE`) et ne sert plus qu'à
## afficher son état. Un `CheckBox` traite le clic pour son propre compte : laissé actif,
## il se cocherait AUSSI au terme d'un balayage de défilement.
func _make_row(recipe) -> Control:
	var row := MarginContainer.new()
	row.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)

	var check := CheckBox.new()
	check.text = recipe.nom
	check.button_pressed = recipe.nom == preselected
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.toggled.connect(func(_on): _refresh())
	row.add_child(check)
	_checks.append(check)

	TouchTapScript.connect_tap(row, func(): check.button_pressed = not check.button_pressed)
	return row

# =====================================================================

func _selected() -> Array:
	var out := []
	for index in range(_checks.size()):
		if _checks[index].button_pressed:
			out.append(_recipes[index])
	return out

func _set_all(on: bool) -> void:
	_bulk = true
	for check in _checks:
		check.button_pressed = on
	_bulk = false
	_refresh()

func _refresh() -> void:
	if _bulk:
		return
	var chosen := _selected()
	_count.text = "%d recette(s) sur %d" % [chosen.size(), _recipes.size()]

	# Le code n'est pas fabriqué ici : déposer le partage demande le réseau. Le bouton
	# s'en charge à la demande, plutôt que de publier à chaque case cochée.
	_publish_btn.disabled = chosen.is_empty()
	_status.text = "Coche les recettes à partager." if chosen.is_empty() \
		else "%d recette(s) sélectionnée(s)" % chosen.size()

## Dépose le partage et ouvre la fenêtre du code qui y renvoie.
##
## Le code ne contient pas les recettes mais un jeton : c'est ce qui permet d'y joindre
## les photos, qu'un QR n'aurait jamais pu porter. En contrepartie le partage demande une
## connexion — des deux côtés — et cesse de fonctionner au bout de `Share.SHARE_DAYS`
## jours.
func _on_publish() -> void:
	var chosen := _selected()
	if chosen.is_empty():
		return
	_publish_btn.disabled = true
	_status.text = "Dépôt du partage…"

	var payload: String = Share.pack(chosen, DataStore)
	var token: String = await Session.publish_share(payload)
	if token == "":
		_publish_btn.disabled = false
		_status.text = Session.last_error()
		return

	_refresh()
	var popup: Window = ShareCodePopupScript.new()
	popup.code = Share.token_code(token)
	add_child(popup)
	popup.popup_centered()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
