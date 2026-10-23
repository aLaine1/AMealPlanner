class_name BreakfastTab
extends Control
## Onglet "Petit Déj" : 4 slots à remplir (drag depuis la liste ou tirage aléatoire),
## + éditeur des choix de petit déjeuner (CRUD). Les slots alimentent la liste de courses.

const PanelSheetScript := preload("res://ui/components/PanelSheet.gd")
const DragAutoScrollScript := preload("res://ui/components/DragAutoScroll.gd")

const SLOT_COUNT := 4

var _slots: Array[MealCell] = []
## Colonne de droite, dont la largeur suit celle du panneau recettes du calendrier.
var _side_panel: Control = null
## Panneau « Mes petits déjeuners » et titre : masqués sur téléphone, où ils
## déborderaient de l'écran. Même traitement que le panneau recettes du calendrier.
var _choices_panel: Control
var _choices_panel_home: Control
## Bouton d'accès au panneau, téléphone seulement, au bas de l'onglet sous un séparateur.
var _choices_sheet_btn: Button
var _sheet_row: VBoxContainer
var _choices_sheet: Window
var _tab_title: Label
## Comme pour le calendrier, ce sont les MÊMES cellules qui voyagent entre la grille
## 2x2 (bureau) et la liste verticale (téléphone) : les dupliquer obligerait à
## synchroniser deux états.
var _grid_view: Control
var _list_view: Control
var _grid_slots: Array[Control] = []
var _list_slots: Array[Control] = []
var _list: RecipeListDrag
var _search: LineEdit
var _count: Label
var _edit_btn: Button
var _delete_btn: Button
var _all_names: Array[String] = []
var _current: Breakfast = null

var _undo_stack: Array = []
var _redo_stack: Array = []
var _prev_slots: Array = []
var _last_commit_frame := -1

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_reload_list()
	_load_slots()
	_prev_slots = _snapshot_slots()
	DataStore.data_changed.connect(_on_data_changed)
	Layout.form_changed.connect(func(_f): _apply_form())
	_apply_form()

## Sur téléphone les 4 emplacements occupent toute la largeur ; le panneau de choix,
## large de 300 unités, sortirait de l'écran.
func _apply_form() -> void:
	var phone := Layout.is_phone()
	if _sheet_row != null:
		_sheet_row.visible = phone
	if not phone and _choices_sheet != null and is_instance_valid(_choices_sheet):
		_choices_sheet._dismiss()
		_choices_sheet = null
	# Masqué chez lui sur téléphone : la feuille l'empruntera à la demande.
	if _choices_panel.get_parent() == _choices_panel_home:
		_choices_panel.visible = not phone
		_choices_panel.custom_minimum_size = Vector2.ZERO if phone \
			else Vector2(Layout.side_panel_width(), 0)
	_tab_title.visible = not phone
	_grid_view.visible = not phone
	_list_view.visible = phone

	var slots := _list_slots if phone else _grid_slots
	for index in range(_slots.size()):
		var cell := _slots[index]
		var target := slots[index]
		if cell.get_parent() == target:
			continue
		if cell.get_parent() != null:
			cell.get_parent().remove_child(cell)
		target.add_child(cell)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for cell in _slots:
		cell.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW) if phone else Vector2(120, 60)

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	_tab_title = Label.new()
	_tab_title.text = "Petits Déjeuners"
	_tab_title.add_theme_font_size_override("font_size", 24)
	_tab_title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	root.add_child(_tab_title)

	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 20)
	root.add_child(main)

	_build_slots(main)
	_build_choices_panel(main)

func _build_slots(parent: Control) -> void:
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	parent.add_child(left)

	# Carte (même format que la carte du calendrier)
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(card)
	_grid_view = card

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(grid)

	for i in range(SLOT_COUNT):
		var slot := MarginContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		slot.custom_minimum_size = Vector2(120, 60)
		grid.add_child(slot)
		_grid_slots.append(slot)

		var cell := MealCell.new()
		cell.position_index = i
		cell.is_nobox = false
		slot.add_child(cell)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell.custom_minimum_size = Vector2(120, 60)
		cell.cell_changed.connect(_on_slot_changed)
		cell.context_requested.connect(_on_slot_context)
		_slots.append(cell)

	# La liste est ajoutée avant la barre d'actions : masquer la grille sur téléphone
	# ferait sinon remonter les boutons au-dessus des emplacements, à rebours du
	# calendrier où ils restent en bas, sous le pouce.
	_build_slots_list(left)

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	left.add_child(actions)

	var rand_btn := Button.new()
	rand_btn.text = "Tirer aléatoirement"
	rand_btn.pressed.connect(_on_random)
	actions.add_child(rand_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Tout effacer"
	clear_btn.theme_type_variation = "OutlineButton"
	clear_btn.pressed.connect(_on_clear_all)
	actions.add_child(clear_btn)

	_build_sheet_access(left)

## Accès au panneau de choix, sur téléphone : au BAS de l'onglet, sous un séparateur.
## Même traitement que la bibliothèque de recettes du calendrier — il était mêlé aux
## commandes de tirage alors qu'il mène ailleurs, et à peine visible.
func _build_sheet_access(parent: Control) -> void:
	_sheet_row = VBoxContainer.new()
	_sheet_row.add_theme_constant_override("separation", 10)
	_sheet_row.visible = false
	parent.add_child(_sheet_row)

	_sheet_row.add_child(HSeparator.new())

	_choices_sheet_btn = Button.new()
	_choices_sheet_btn.text = "Liste des petits déj"
	_choices_sheet_btn.theme_type_variation = "OutlineButton"
	_choices_sheet_btn.pressed.connect(_open_choices_sheet)
	_choices_sheet_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_choices_sheet_btn.custom_minimum_size = Vector2(220, Layout.TOUCH_TARGET)
	_sheet_row.add_child(_choices_sheet_btn)

## Mise en page téléphone : les 4 choix empilés. Une grille 2x2 sur un écran étroit
## donne des cartes très hautes et étroites, difficiles à lire d'un coup d'œil ;
## empilées, elles gardent la même forme que les repas du calendrier.
func _build_slots_list(parent: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	_list_view = scroll
	# Quatre emplacements tiennent presque toujours à l'écran, et le défilement aux bords
	# n'y servira guère : ce qui compte ici est le gel du panoramique pendant qu'une case
	# est portée par le doigt — sans lui, la liste suit le doigt en même temps qu'elle.
	scroll.add_child(DragAutoScrollScript.new())

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	Layout.scroll_body(scroll).add_child(column)

	for i in range(SLOT_COUNT):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(row)

		var caption := Label.new()
		caption.text = "Choix %d" % (i + 1)
		caption.custom_minimum_size = Vector2(64, 0)
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.add_theme_font_size_override("font_size", 13)
		caption.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		row.add_child(caption)

		var slot := MarginContainer.new()
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)
		row.add_child(slot)
		_list_slots.append(slot)


## Même chemin que la bibliothèque de recettes de l'onglet Calendrier : sur téléphone
## le panneau se replie derrière un bouton, faute de place à côté des emplacements.
func _open_choices_sheet() -> void:
	if _choices_sheet != null and is_instance_valid(_choices_sheet):
		return
	_choices_sheet = PanelSheetScript.present(
		self, _choices_panel, _choices_panel_home, "Mes petits déjeuners")

func _build_choices_panel(parent: Control) -> void:
	var right := VBoxContainer.new()
	_choices_panel = right
	_choices_panel_home = parent
	# Même largeur que la bibliothèque de recettes de l'onglet Calendrier : les deux
	# panneaux sont côte à côte dans la même fenêtre au fil de la navigation, et des
	# largeurs différentes se remarqueraient en passant de l'un à l'autre.
	right.custom_minimum_size = Vector2(Layout.side_panel_width(), 0)
	_side_panel = right
	Layout.viewport_resized.connect(_resize_side_panel)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	parent.add_child(right)

	# Carte (même format que le panneau recettes du calendrier)
	var card := PanelContainer.new()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(card)

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 8)
	card.add_child(panel)

	var header := HBoxContainer.new()
	panel.add_child(header)
	var sec := _mk_section("Mes petits déjeuners")
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(sec)
	_count = Label.new()
	_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	header.add_child(_count)

	_search = LineEdit.new()
	_search.placeholder_text = "Rechercher..."
	_search.text_changed.connect(_on_search)
	panel.add_child(_search)

	_list = RecipeListDrag.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_select)
	panel.add_child(_list)

	# 3 boutons sur une rangée, largeur égale (comme le calendrier)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	panel.add_child(actions)

	var add_btn := Button.new()
	add_btn.text = "Ajouter"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(_on_add)
	actions.add_child(add_btn)

	_edit_btn = Button.new()
	_edit_btn.text = "Modifier"
	_edit_btn.theme_type_variation = "OutlineButton"
	_edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_btn.disabled = true
	_edit_btn.pressed.connect(_on_edit)
	actions.add_child(_edit_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Supprimer"
	_delete_btn.theme_type_variation = "DangerButton"
	_delete_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delete_btn.disabled = true
	_delete_btn.pressed.connect(_on_delete)
	actions.add_child(_delete_btn)

# ===== Liste des choix =====

func _reload_list() -> void:
	_all_names = DataStore.get_all_breakfast_names()
	_apply_filter(_search.text if _search else "")

func _apply_filter(text: String) -> void:
	var needle := text.to_lower().strip_edges()
	var names := _all_names if needle == "" else _all_names.filter(
		func(n): return n.to_lower().contains(needle))
	_list.clear()
	for n in names:
		_list.add_item(n)
	_count.text = "(%d)" % names.size()

func _on_search(text: String) -> void:
	_apply_filter(text)

func _on_list_select(idx: int) -> void:
	_current = DataStore.get_breakfast_by_name(_list.get_item_text(idx))
	_edit_btn.disabled = _current == null
	_delete_btn.disabled = _current == null

func _on_data_changed() -> void:
	_reload_list()
	# Les 4 emplacements aussi : eux non plus ne se rechargeaient pas.
	var names := DataStore.load_breakfast_slot_names()
	for i in range(mini(_slots.size(), names.size())):
		if _slots[i].recipe_name != names[i]:
			_slots[i].set_recipe_name(names[i])
	if _current != null:
		_current = DataStore.get_breakfast_by_name(_current.nom)
	if _current == null:
		_edit_btn.disabled = true
		_delete_btn.disabled = true

# ===== Slots =====

func _on_random() -> void:
	var picks := DataStore.get_random_breakfasts(SLOT_COUNT)
	for i in range(SLOT_COUNT):
		_slots[i].set_recipe_name(picks[i].nom if i < picks.size() else "")
	_sync_slots()
	_commit_change()

func _on_clear_all() -> void:
	for cell in _slots:
		cell.set_recipe_name("")
	_sync_slots()
	_commit_change()

func _on_slot_changed() -> void:
	_sync_slots()
	_commit_change()

# ===== Annuler / Rétablir (état = les 4 slots) =====

func _snapshot_slots() -> Array:
	var out: Array = []
	for c in _slots:
		out.append(c.recipe_name)
	return out

func _commit_change() -> void:
	var f := Engine.get_process_frames()
	if f == _last_commit_frame:
		_prev_slots = _snapshot_slots()
		return
	_last_commit_frame = f
	_undo_stack.append(_prev_slots.duplicate())
	if _undo_stack.size() > 100:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_prev_slots = _snapshot_slots()

func _apply_slots(slots: Array) -> void:
	for i in range(_slots.size()):
		_slots[i].set_recipe_name(str(slots[i]) if i < slots.size() else "")
	_sync_slots()
	_prev_slots = _snapshot_slots()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(_snapshot_slots())
	_apply_slots(_undo_stack.pop_back())

func redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(_snapshot_slots())
	_apply_slots(_redo_stack.pop_back())

func _on_slot_context(cell: MealCell, screen_pos: Vector2) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	var filled := cell.recipe_name.strip_edges() != ""
	# Un emplacement vide ouvrait auparavant un menu vide (retour immédiat) : sans
	# panneau latéral sur mobile, il n'y avait alors aucun moyen de le remplir.
	menu.add_item("Choisir un autre petit déjeuner…" if filled else "Choisir un petit déjeuner…", 0)
	if filled:
		menu.add_item("Retirer", 1)
	menu.id_pressed.connect(func(id): _handle_slot_context(cell, id))
	menu.popup_hide.connect(func(): menu.queue_free())
	menu.position = Vector2i(screen_pos)
	menu.popup()

func _handle_slot_context(cell: MealCell, id: int) -> void:
	if id == 0:
		_open_breakfast_picker(cell)
	else:
		cell.set_recipe_name("")
		_sync_slots()
		_commit_change()

func _open_breakfast_picker(cell: MealCell) -> void:
	var names := DataStore.get_all_breakfast_names()
	if names.is_empty():
		var dialog := AcceptDialog.new()
		dialog.title = "Aucun petit déjeuner"
		dialog.dialog_text = "Ajoute d'abord des petits déjeuners depuis la version bureau."
		add_child(dialog)
		dialog.confirmed.connect(dialog.queue_free)
		dialog.canceled.connect(dialog.queue_free)
		dialog.popup_centered()
		return
	var picker := PickerPopup.new()
	picker.setup("Choisir un petit déjeuner", names, cell.recipe_name,
		cell.recipe_name.strip_edges() != "")
	add_child(picker)
	picker.chosen.connect(func(name: String):
		cell.set_recipe_name(name)
		_sync_slots()
		_commit_change())
	picker.cleared.connect(func():
		cell.set_recipe_name("")
		_sync_slots()
		_commit_change())
	picker.popup_centered()

## Méthode nommée et non lambda : une lambda qui ne mentionne pas `self` n'a pas d'objet
## propre, et Godot ne la débranche donc JAMAIS — elle survit à l'onglet qui l'a posée et
## continue d'écrire dans une capture libérée. Le signal étant porté par un autoload, la
## connexion durerait autant que l'application.
func _resize_side_panel(_width: float) -> void:
	if _side_panel != null and is_instance_valid(_side_panel):
		_side_panel.custom_minimum_size.x = Layout.side_panel_width()

func _sync_slots() -> void:
	var names: Array[String] = []
	for cell in _slots:
		names.append(cell.recipe_name)
	AppState.set_breakfast_slots(names)
	_save_slots()

func _save_slots() -> void:
	var names: Array[String] = []
	for cell in _slots:
		names.append(cell.recipe_name)
	DataStore.save_breakfast_slot_names(names)

func _load_slots() -> void:
	var names := DataStore.load_breakfast_slot_names()
	if names.is_empty():
		return
	for i in range(SLOT_COUNT):
		_slots[i].set_recipe_name(names[i] if i < names.size() else "")
	_sync_slots()

# ===== CRUD choix =====

func _on_add() -> void:
	_open_popup(null)

func _on_edit() -> void:
	if _current != null:
		_open_popup(_current)

func _open_popup(b: Breakfast) -> void:
	var popup := BreakfastPopup.new()
	popup.breakfast = b
	add_child(popup)
	popup.popup_centered()

func _on_delete() -> void:
	if _current == null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.theme = Palette.ui_theme
	dlg.dialog_text = "Supprimer le petit déjeuner '%s' ?" % _current.nom
	dlg.title = "Confirmation"
	add_child(dlg)
	var target_id := _current.id
	dlg.confirmed.connect(func():
		DataStore.delete_breakfast_by_id(target_id)
		_current = null
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

# ===== Utilitaires =====

func _mk_section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", Palette.PRIMARY_INK)
	return l
