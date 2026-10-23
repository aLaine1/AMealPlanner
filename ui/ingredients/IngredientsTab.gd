class_name IngredientsTab
extends Control
## Onglet "Ingrédients" : liste recherchable + rayon + CRUD (popups).
## Portage de ingredients_tab.ModernIngredientEditorApp.

const TouchItemListScript := preload("res://ui/components/TouchItemList.gd")

## Typé par le script préchargé et non par son `class_name` : le cache des classes
## globales n'est pas garanti à jour en lancement headless (cf. services/Uuid.gd).
var _list  ## TouchItemList
var _search: LineEdit
var _count: Label
var _filter: CategoryFilter
var _split: BoxContainer
var _detail: VBoxContainer
var _edit_btn: Button
var _delete_btn: Button
var _all: Array[Ingredient] = []
var _current: Ingredient = null

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_reload()
	DataStore.data_changed.connect(_reload)

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Éditeur d'Ingrédients"
	# 20 comme les sections voisines, et repliable : à 22 sans repli, le titre poussait
	# le compteur hors de la largeur d'un téléphone.
	title.add_theme_font_size_override("font_size", 20)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_count = Label.new()
	_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	header.add_child(_count)

	_search = LineEdit.new()
	_search.placeholder_text = "Rechercher un ingrédient..."
	# Ici la « catégorie » d'un ingrédient est son rayon — le même vocabulaire visuel
	# que le filtre des recettes, sur la donnée qui classe les ingrédients.
	_filter = CategoryFilter.new()
	_filter.setup(_search)
	_filter.changed.connect(_apply_filter)
	root.add_child(_filter)

	# BoxContainer nu plutôt que HBox : son orientation bascule à l'exécution, la liste
	# et le cadre passant côte à côte sur ordinateur et l'un sous l'autre sur téléphone.
	_split = BoxContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_theme_constant_override("separation", 12)
	root.add_child(_split)

	_list = TouchItemListScript.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_select)
	_split.add_child(_list)

	var detail_card := PanelContainer.new()
	detail_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.add_child(detail_card)

	var detail_margin := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		detail_margin.add_theme_constant_override(m, 14)
	detail_card.add_child(detail_margin)

	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 12)
	detail_margin.add_child(_detail)
	_render_detail()

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 6)
	actions.add_theme_constant_override("v_separation", 6)
	root.add_child(actions)

	var add_btn := Button.new()
	add_btn.text = "Ajouter un ingrédient"
	add_btn.pressed.connect(_on_add)
	actions.add_child(add_btn)

	_edit_btn = Button.new()
	_edit_btn.text = "Modifier"
	_edit_btn.theme_type_variation = "GhostButton"
	_edit_btn.disabled = true
	_edit_btn.pressed.connect(_on_edit)
	actions.add_child(_edit_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Supprimer"
	_delete_btn.theme_type_variation = "DangerButton"
	_delete_btn.disabled = true
	_delete_btn.pressed.connect(_on_delete)
	actions.add_child(_delete_btn)

	Layout.form_changed.connect(func(_f): _apply_form())
	_apply_form()

## Ordinateur : liste à largeur fixe, cadre à droite. Téléphone : les deux empilés, la
## liste au-dessus — côte à côte dans 412 unités, aucun des deux n'est lisible.
func _apply_form() -> void:
	var phone := Layout.is_phone()
	_split.vertical = phone
	_list.custom_minimum_size = Vector2(0, 200) if phone else Vector2(260, 0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL if phone else Control.SIZE_FILL

func _reload() -> void:
	_all = DataStore.get_all_ingredients()
	_all.sort_custom(func(a, b): return TextFold.before(a.nom, b.nom))
	if _filter != null:
		_filter.set_options(DataStore.get_aisle_names())
	_apply_filter(_search.text if _search else "")
	# La sélection est réaccrochée à l'objet frais du cache, et pas seulement invalidée
	# quand l'ingrédient disparaît : garder l'ancien laisserait le cadre afficher un rayon
	# périmé après une modification — faite ici, ou arrivée d'un autre appareil.
	if _current != null:
		_select_by_name(_current.nom)

func _apply_filter(text: String) -> void:
	# Repli d'accents comme partout ailleurs : « echalote » doit trouver « échalote ».
	var needle := TextFold.fold(text.strip_edges())
	var items: Array[Ingredient] = []
	for ing in _all:
		if needle != "" and not TextFold.fold(ing.nom).contains(needle):
			continue
		if _filter != null and not _filter.matches([ing.aisle]):
			continue
		items.append(ing)
	_populate(items)

func _populate(items: Array) -> void:
	_list.clear()
	for ing in items:
		_list.add_item(ing.nom)
	_count.text = "(%d ingrédients)" % items.size()

func _on_select(idx: int) -> void:
	_select_by_name(_list.get_item_text(idx))

func _select_by_name(ingredient_name: String) -> void:
	_current = null
	for ing in _all:
		if ing.nom == ingredient_name:
			_current = ing
			break
	_edit_btn.disabled = _current == null
	_delete_btn.disabled = _current == null
	_render_detail()

# ===== Cadre d'information =====

## Identité de l'ingrédient, puis les recettes qui l'emploient. Reconstruit à chaque
## sélection : le rayon comme la liste des recettes peuvent avoir changé entre deux
## affichages.
func _render_detail() -> void:
	for child in _detail.get_children():
		# Détaché tout de suite, et pas seulement mis en file de libération : `queue_free`
		# seul ne retire du parent qu'en fin de frame, et le cadre empilerait l'ancien
		# contenu sous le nouveau le temps d'une image — visible ici, où la sélection
		# change au clic.
		_detail.remove_child(child)
		child.queue_free()

	if _current == null:
		_detail.add_child(_mk_hint(
			"Sélectionnez un ingrédient pour voir son rayon et les recettes qui l'utilisent."))
		return

	_detail.add_child(_mk_identity(_current))
	_detail.add_child(HSeparator.new())

	var users := DataStore.get_recipes_using_ingredient(_current.nom)
	var heading := Label.new()
	heading.text = "Utilisé dans %d recette%s" % [users.size(), "s" if users.size() > 1 else ""]
	heading.add_theme_font_size_override("font_size", 12)
	heading.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	_detail.add_child(heading)

	if users.is_empty():
		_detail.add_child(_mk_hint("Aucune recette ne l'utilise pour l'instant."))
		return

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail.add_child(scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 8)
	Layout.scroll_body(scroll).add_child(rows)
	for recipe in users:
		rows.add_child(_mk_recipe_row(recipe))

## En-tête du cadre : pastille à initiale (même vocabulaire visuel que les cartes de
## recettes) + nom et rayon.
func _mk_identity(ing: Ingredient) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(36, 36)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar.draw.connect(func(): avatar.draw_circle(Vector2(18, 18), 18, Palette.SECONDARY))
	row.add_child(avatar)

	var initial := Label.new()
	initial.text = ing.nom.substr(0, 1).to_upper() if ing.nom != "" else "?"
	initial.set_anchors_preset(Control.PRESET_FULL_RECT)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.add_theme_font_size_override("font_size", 16)
	initial.add_theme_color_override("font_color", Palette.ink_on(Palette.SECONDARY))
	avatar.add_child(initial)

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	titles.add_theme_constant_override("separation", 2)
	row.add_child(titles)

	var name_label := Label.new()
	name_label.text = ing.nom
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Palette.PRIMARY_INK)
	titles.add_child(name_label)

	var aisle_label := Label.new()
	aisle_label.text = "Rayon : %s" % ing.aisle
	aisle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	aisle_label.add_theme_font_size_override("font_size", 12)
	aisle_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	titles.add_child(aisle_label)

	return row

## Une recette utilisatrice : pastille de sa catégorie, nom, et quantité employée.
func _mk_recipe_row(recipe: Recipe) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var category := recipe.categories[0] if not recipe.categories.is_empty() else ""
	var color := Palette.category_color(category)
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func(): dot.draw_circle(Vector2(5, 5), 5, color))
	row.add_child(dot)

	var name_label := Label.new()
	name_label.text = recipe.nom
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	row.add_child(name_label)

	var qty := _quantity_in(recipe)
	if qty != "":
		var qty_label := Label.new()
		qty_label.text = qty
		qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		row.add_child(qty_label)

	return row

## Quantité de l'ingrédient courant telle que cette recette la demande ("" si non
## renseignée) — l'information n'a de sens que recette par recette.
func _quantity_in(recipe: Recipe) -> String:
	for ing in recipe.ingredients:
		if ing.nom == _current.nom:
			return ing.quantity_label()
	return ""

func _mk_hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	return label

func _on_add() -> void:
	_open_popup(null)

func _on_edit() -> void:
	if _current != null:
		_open_popup(_current)

func _open_popup(ing: Ingredient) -> void:
	var popup := IngredientPopup.new()
	popup.ingredient = ing
	add_child(popup)
	popup.popup_centered()

func _on_delete() -> void:
	if _current == null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.theme = Palette.ui_theme
	dlg.dialog_text = "Supprimer l'ingrédient '%s' ?" % _current.nom
	dlg.title = "Confirmation"
	add_child(dlg)
	var target_name := _current.nom
	dlg.confirmed.connect(func():
		DataStore.delete_ingredient_by_name(target_name)
		_current = null
		_edit_btn.disabled = true
		_delete_btn.disabled = true
		_render_detail()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

func refresh() -> void:
	_reload()
