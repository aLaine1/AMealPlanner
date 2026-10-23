class_name StaplesTab
extends Control
## Éditeur des "articles de base" (F4) : liste éditable, ajoutés automatiquement
## à la liste de courses lors de la génération.

const TouchItemListScript := preload("res://ui/components/TouchItemList.gd")

## Typé par le script préchargé et non par son `class_name` : le cache des classes
## globales n'est pas garanti à jour en lancement headless (cf. services/Uuid.gd).
var _list  ## TouchItemList
var _search: LineEdit
var _count: Label
var _edit_btn: Button
var _delete_btn: Button
var _all: Array[Ingredient] = []
var _shown: Array[Ingredient] = []
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
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Articles de base"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_count = Label.new()
	_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	header.add_child(_count)


	_search = LineEdit.new()
	_search.placeholder_text = "Rechercher..."
	_search.text_changed.connect(func(_t): _apply_filter())
	root.add_child(_search)

	_list = TouchItemListScript.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_select)
	root.add_child(_list)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	root.add_child(actions)

	var add_btn := Button.new()
	add_btn.text = "Ajouter"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(func(): _open_popup(null))
	actions.add_child(add_btn)

	_edit_btn = Button.new()
	_edit_btn.text = "Modifier"
	_edit_btn.theme_type_variation = "OutlineButton"
	_edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_btn.disabled = true
	_edit_btn.pressed.connect(func(): if _current: _open_popup(_current))
	actions.add_child(_edit_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Supprimer"
	_delete_btn.theme_type_variation = "DangerButton"
	_delete_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delete_btn.disabled = true
	_delete_btn.pressed.connect(_on_delete)
	actions.add_child(_delete_btn)

func _reload() -> void:
	_all = DataStore.get_all_staples()
	_apply_filter()
	if _current != null and _all.filter(func(s): return s.id == _current.id).is_empty():
		_current = null
		_edit_btn.disabled = true
		_delete_btn.disabled = true

func _apply_filter() -> void:
	var needle := (_search.text if _search else "").to_lower().strip_edges()
	_shown = _all if needle == "" else _all.filter(func(s): return s.nom.to_lower().contains(needle))
	_list.clear()
	for s in _shown:
		var qty := str(int(round(s.quantite))) if absf(s.quantite - round(s.quantite)) < 0.001 else str(s.quantite)
		_list.add_item("%s — %s %s   ·   %s" % [s.nom, qty, s.unite, s.aisle])
	_count.text = "(%d)" % _shown.size()

func _on_select(idx: int) -> void:
	_current = _shown[idx] if idx >= 0 and idx < _shown.size() else null
	_edit_btn.disabled = _current == null
	_delete_btn.disabled = _current == null

func _open_popup(staple: Ingredient) -> void:
	var popup := StaplePopup.new()
	popup.staple = staple
	add_child(popup)
	popup.popup_centered()

func _on_delete() -> void:
	if _current == null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.theme = Palette.ui_theme
	dlg.dialog_text = "Supprimer l'article '%s' ?" % _current.nom
	dlg.title = "Confirmation"
	add_child(dlg)
	var target_id := _current.id
	dlg.confirmed.connect(func():
		DataStore.delete_staple_by_id(target_id)
		_current = null
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
