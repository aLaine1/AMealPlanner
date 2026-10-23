class_name AislesTab
extends Control
## Éditeur des rayons de magasin : ajouter, renommer, réordonner, supprimer.
##
## Les rayons étaient codés en dur à trois endroits — la liste de courses, les
## articles de base, et une troisième liste déduite des rayons déjà employés par les
## ingrédients. Elles avaient divergé, et « Picard » n'a de sens que pour certains
## foyers. C'est désormais une donnée unique, ordonnée et synchronisée.
##
## **L'ordre est l'essentiel**, davantage que les noms : il détermine l'ordre des
## groupes dans la liste de courses, donc le parcours du magasin.

const TouchItemListScript := preload("res://ui/components/TouchItemList.gd")

## Typé par le script préchargé et non par son `class_name` : le cache des classes
## globales n'est pas garanti à jour en lancement headless (cf. services/Uuid.gd).
var _list  ## TouchItemList
var _count: Label
var _rename_btn: Button
var _delete_btn: Button
var _up_btn: Button
var _down_btn: Button
var _aisles: Array[Dictionary] = []

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
	title.text = "Rayons"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_count = Label.new()
	_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	header.add_child(_count)

	_list = TouchItemListScript.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func(_i): _refresh_buttons())
	root.add_child(_list)

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	root.add_child(actions)

	var add_btn := _make_button("Ajouter")
	add_btn.pressed.connect(_on_add)
	actions.add_child(add_btn)

	_rename_btn = _make_button("Renommer", "OutlineButton")
	_rename_btn.pressed.connect(_on_rename)
	actions.add_child(_rename_btn)

	_up_btn = _make_button("▲", "OutlineButton")
	_up_btn.tooltip_text = "Monter dans le parcours du magasin — l'ordre de cette liste est celui des groupes de la liste de courses"
	_up_btn.pressed.connect(func(): _move(-1))
	actions.add_child(_up_btn)

	_down_btn = _make_button("▼", "OutlineButton")
	_down_btn.tooltip_text = "Descendre dans le parcours du magasin — l'ordre de cette liste est celui des groupes de la liste de courses"
	_down_btn.pressed.connect(func(): _move(1))
	actions.add_child(_down_btn)

	_delete_btn = _make_button("Supprimer", "DangerButton")
	_delete_btn.pressed.connect(_on_delete)
	actions.add_child(_delete_btn)

func _make_button(text: String, variation := "") -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	if variation != "":
		button.theme_type_variation = variation
	return button

# =====================================================================

func _reload() -> void:
	var previous := _selected_id()
	_aisles = DataStore.get_aisles()
	_list.clear()
	for aisle in _aisles:
		_list.add_item(str(aisle["name"]))
	_count.text = "(%d)" % _aisles.size()

	for index in range(_aisles.size()):
		if str(_aisles[index]["id"]) == previous:
			_list.select(index)
			break
	_refresh_buttons()

func _selected_id() -> String:
	var selection: Array = _list.get_selected_items()
	if selection.is_empty() or selection[0] >= _aisles.size():
		return ""
	return str(_aisles[selection[0]]["id"])

func _selected_index() -> int:
	var selection: Array = _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1

func _refresh_buttons() -> void:
	var index := _selected_index()
	var has_selection := index >= 0
	_rename_btn.disabled = not has_selection
	_up_btn.disabled = not has_selection or index == 0
	_down_btn.disabled = not has_selection or index >= _aisles.size() - 1
	# Le rayon de repli accueille le contenu des rayons supprimés : le supprimer
	# ferait disparaître des articles de la liste de courses.
	_delete_btn.disabled = not has_selection or _is_fallback(index)

func _is_fallback(index: int) -> bool:
	return index >= 0 and index < _aisles.size() \
		and str(_aisles[index]["name"]) == DataStore.fallback_aisle()

# =====================================================================

func _on_add() -> void:
	var prompt := TextPromptPopup.new()
	prompt.setup("Nouveau rayon", "Nom du rayon, tel qu'il apparaîtra dans la liste de courses.",
		"", "Surgelés, Boucherie, Cave…")
	add_child(prompt)
	prompt.submitted.connect(func(name: String):
		if _name_exists(name):
			_warn("Ce rayon existe déjà.")
			return
		DataStore.add_aisle(name))
	prompt.popup_centered()

func _on_rename() -> void:
	var index := _selected_index()
	if index < 0:
		return
	var aisle := _aisles[index]
	var prompt := TextPromptPopup.new()
	prompt.setup("Renommer le rayon",
		"Les ingrédients et articles rattachés à ce rayon suivront le nouveau nom.",
		str(aisle["name"]))
	add_child(prompt)
	prompt.submitted.connect(func(name: String):
		if name != str(aisle["name"]) and _name_exists(name):
			_warn("Ce rayon existe déjà.")
			return
		DataStore.rename_aisle(str(aisle["id"]), name))
	prompt.popup_centered()

func _on_delete() -> void:
	var index := _selected_index()
	if index < 0 or _is_fallback(index):
		return
	var aisle := _aisles[index]
	var dialog := ConfirmationDialog.new()
	dialog.title = "Supprimer le rayon"
	dialog.dialog_text = "Supprimer « %s » ?\n\nLes ingrédients et articles qui s'y trouvent seront rattachés à « %s »." \
		% [str(aisle["name"]), DataStore.fallback_aisle()]
	add_child(dialog)
	dialog.confirmed.connect(func(): DataStore.delete_aisle(str(aisle["id"])))
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	dialog.popup_centered()

## Déplace le rayon sélectionné dans le parcours.
func _move(offset: int) -> void:
	var index := _selected_index()
	var target := index + offset
	if index < 0 or target < 0 or target >= _aisles.size():
		return
	var ordered: Array = []
	for aisle in _aisles:
		ordered.append(str(aisle["id"]))
	var moved: String = ordered[index]
	ordered.remove_at(index)
	ordered.insert(target, moved)
	DataStore.reorder_aisles(ordered)

func _name_exists(name: String) -> bool:
	var needle := TextFold.fold(name)
	for aisle in _aisles:
		if TextFold.fold(str(aisle["name"])) == needle:
			return true
	return false

func _warn(message: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Rayons"
	dialog.dialog_text = message
	add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()
