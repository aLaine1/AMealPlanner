class_name PickerPopup
extends Window
## Sélecteur au toucher : une recherche et une liste de choix en grandes lignes.
##
## Remplace le glisser-déposer sur mobile. Le DnD reste le geste naturel à la souris
## — on voit la case de départ et celle d'arrivée en même temps — mais au doigt il
## suppose de maintenir l'appui en faisant défiler une liste de 73 recettes d'une
## seule main. Choisir dans une liste plein écran est plus rapide et ne rate jamais
## sa cible.
##
## Générique : le calendrier y choisit des recettes, l'onglet Petit Déj des petits
## déjeuners. Les entrées sont fournies par l'appelant, qui indique par `recipe_entries`
## si ce sont des recettes — auquel cas les lignes reçoivent photo, couleur de catégorie
## et filtre, comme dans la bibliothèque.

const RecipeRowScript := preload("res://ui/components/RecipeRow.gd")
const TouchTapScript := preload("res://ui/components/TouchTap.gd")

signal chosen(name: String)
signal cleared

const ROW_HEIGHT := 52

## Les entrées désignent des recettes de `DataStore` : lignes illustrées et filtre par
## catégorie. À défaut, le sélecteur reste la simple liste de libellés qu'il était — les
## petits déjeuners n'ont ni photo ni catégorie, et un filtre vide ne ferait qu'occuper
## le haut de l'écran.
##
## À poser avant l'ajout à l'arbre, comme `setup()`.
var recipe_entries := false

var _heading: Label
var _search: LineEdit
var _filter: CategoryFilter = null
var _list: VBoxContainer
var _entries: Array[String] = []
var _allow_clear := false

## `entries` : noms proposés. `current` : sélection actuelle, mise en évidence.
## `allow_clear` : propose « Vider la case » (inutile si la case est déjà vide).
##
## Appelable avant comme après l'ajout à l'arbre : `add_child()` déclenche `_ready()`,
## qui peuplerait sinon la liste avant d'avoir reçu la moindre entrée.
func setup(dialog_title: String, entries: Array, current: String = "",
		allow_clear: bool = false) -> void:
	title = dialog_title
	_entries.assign(entries)
	_allow_clear = allow_clear
	set_meta("current", current)
	if _list != null:
		_refresh()
	if _heading != null:
		_heading.text = dialog_title

func _ready() -> void:
	Layout.fit_window(self, Vector2i(460, 620), Vector2i(360, 420))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)

	var background := ColorRect.new()
	background.color = Palette.WINDOW_BG
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# En-tête explicite : en plein écran sur téléphone, la barre de titre de la fenêtre
	# n'est pas visible. Sans ce bouton, le seul moyen de sortir serait de choisir une
	# entrée — un sélecteur dont on ne peut pas se raviser.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	var heading := Label.new()
	heading.text = title
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(heading)
	_heading = heading

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.theme_type_variation = "GhostButton"
	close_btn.tooltip_text = "Annuler"
	close_btn.custom_minimum_size = Vector2(Layout.TOUCH_TARGET, Layout.TOUCH_TARGET)
	close_btn.pressed.connect(queue_free)
	header.add_child(close_btn)

	_search = LineEdit.new()
	_search.placeholder_text = "Rechercher…"
	_search.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	if recipe_entries:
		# Le composant ENGLOBE le champ : il le reparente et pose les pastilles dessous.
		_filter = CategoryFilter.new()
		_filter.setup(_search)
		_filter.set_options(DataStore.get_all_recipe_categories())
		_filter.changed.connect(func(_t): _refresh())
		root.add_child(_filter)
	else:
		_search.text_changed.connect(func(_t): _refresh())
		root.add_child(_search)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Zone morte : un contact doit franchir quelques unités avant de devenir un
	# défilement, sinon l'hésitation du doigt en visant une ligne fait glisser la liste.
	scroll.scroll_deadzone = 8
	root.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	Layout.scroll_body(scroll).add_child(_list)

	if _allow_clear:
		var clear_btn := Button.new()
		clear_btn.text = "Vider la case"
		clear_btn.theme_type_variation = "DangerButton"
		clear_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		clear_btn.pressed.connect(func():
			cleared.emit()
			queue_free())
		root.add_child(clear_btn)

	_populate(_entries)
	# Le clavier logiciel masquerait la moitié de la liste : sur téléphone on laisse
	# l'utilisateur toucher le champ s'il veut vraiment filtrer.
	if not Layout.is_phone():
		_search.grab_focus()

## Applique les deux filtres à la fois. Le texte seul ne suffit plus : une catégorie
## cochée sans terme de recherche doit restreindre la liste, et un terme de recherche
## ne doit pas passer outre la catégorie cochée.
func _refresh() -> void:
	var needle := TextFold.fold(_search.text if _search != null else "")
	var matches: Array[String] = []
	for entry in _entries:
		if needle != "" and not TextFold.fold(entry).contains(needle):
			continue
		if _filter != null and not _filter.matches(_categories_of(entry)):
			continue
		matches.append(entry)
	_populate(matches)

func _categories_of(entry: String) -> Array:
	var recipe: Recipe = DataStore.get_recipe_by_name(entry)
	return recipe.categories if recipe != null else []

func _populate(entries: Array) -> void:
	for child in _list.get_children():
		child.queue_free()

	if entries.is_empty():
		var empty := Label.new()
		empty.text = "Aucun résultat."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		empty.custom_minimum_size = Vector2(0, 80)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_list.add_child(empty)
		return

	var current := str(get_meta("current", ""))
	for entry in entries:
		_list.add_child(_make_row(str(entry), str(entry) == current))

## Une ligne, et non un `Button`.
##
## Le bouton consommait l'événement pour son propre compte : le `ScrollContainer` ne
## voyait jamais le glissement, et cette liste — la seule de l'application à en être
## restée là — refusait tout simplement de défiler au doigt. `TouchTap` remet les deux
## gestes d'accord : le contact remonte au conteneur, et le choix n'a lieu qu'au
## relâchement, sur place. C'est le remède déjà appliqué à la liste de courses, aux
## cartes de la bibliothèque et aux cases du calendrier.
func _make_row(entry: String, is_current: bool) -> Control:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	var sb := Palette.card_style()
	sb.set_content_margin_all(8)
	sb.shadow_size = 4
	if is_current:
		sb.bg_color = Palette.CELL_HOVER
		sb.set_border_width_all(2)
		sb.border_color = Palette.PRIMARY_INK
	row.add_theme_stylebox_override("panel", sb)

	if recipe_entries:
		row.add_child(RecipeRowScript.build(entry, 36, 16))
	else:
		var label := Label.new()
		label.text = entry
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
		row.add_child(label)

	TouchTapScript.connect_tap(row, func():
		chosen.emit(entry)
		queue_free())
	return row

## Le geste « retour » d'Android doit refermer la fenêtre, pas quitter l'application.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
