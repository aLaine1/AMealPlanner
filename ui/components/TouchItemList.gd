class_name TouchItemList
extends ScrollContainer
## Liste à sélection unique qui se laisse défiler au doigt.
##
## Remplace `ItemList`, qui ne sait pas défiler au toucher : il n'offre que sa barre de
## défilement — quelques unités de large, invisable au pouce — et la molette. Un balayage
## parti d'une de ses lignes la SÉLECTIONNE au lieu de faire défiler, si bien que les
## trois listes des Paramètres (ingrédients, rayons, articles de base) étaient
## inatteignables au-delà de ce qui tenait à l'écran. Sur 142 ingrédients, cela fait
## beaucoup d'inatteignable.
##
## Même mécanique que partout ailleurs dans l'application : des lignes en
## `MOUSE_FILTER_PASS` qui n'agissent qu'au relâchement sur place, via `TouchTap`.
##
## Expose le sous-ensemble d'`ItemList` qu'emploient ces écrans — `clear`, `add_item`,
## `select`, `get_selected_items`, `get_item_text`, `item_selected` — pour rester un
## remplacement direct.

signal item_selected(index: int)

const TouchTapScript := preload("res://ui/components/TouchTap.gd")

var _rows: VBoxContainer
var _labels: Array[Label] = []
var _items: Array[String] = []
var _selected := -1

func _init() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 2)
	add_child(_rows)

func clear() -> void:
	for row in _rows.get_children():
		_rows.remove_child(row)
		row.queue_free()
	_labels.clear()
	_items.clear()
	_selected = -1

func add_item(text: String) -> void:
	var index := _items.size()
	_items.append(text)

	var row := PanelContainer.new()
	# Toute la ligne est la cible, et non le seul libellé : au doigt, viser un texte de
	# 13 unités de haut n'est pas une option.
	row.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)
	_rows.add_child(row)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(margin)

	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Un libellé long — « Farine — 1 kg · Divers » — se replie plutôt que d'élargir la
	# liste : le défilement horizontal est fermé, il sortirait sinon de l'écran.
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(label)
	_labels.append(label)

	TouchTapScript.connect_tap(row, func(): _on_row_tapped(index))
	_paint(index)

func _on_row_tapped(index: int) -> void:
	select(index)
	item_selected.emit(index)

## Comme `ItemList.select` : change la sélection sans émettre le signal. Les appelants
## s'en servent pour rétablir une sélection après reconstruction, et l'émission
## relancerait alors leur propre rafraîchissement.
func select(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	var previous := _selected
	_selected = index
	if previous >= 0:
		_paint(previous)
	_paint(index)

func deselect_all() -> void:
	var previous := _selected
	_selected = -1
	if previous >= 0:
		_paint(previous)

## Tableau à zéro ou un élément — la liste est à sélection unique.
func get_selected_items() -> Array:
	return [] if _selected < 0 else [_selected]

func get_item_text(index: int) -> String:
	return _items[index] if index >= 0 and index < _items.size() else ""

func get_item_count() -> int:
	return _items.size()

func _paint(index: int) -> void:
	if index < 0 or index >= _rows.get_child_count():
		return
	var row := _rows.get_child(index) as PanelContainer
	var label := _labels[index]
	var chosen := index == _selected
	var box := StyleBoxFlat.new()
	box.bg_color = Palette.CELL_HOVER if chosen else Color(0, 0, 0, 0)
	box.set_corner_radius_all(8)
	row.add_theme_stylebox_override("panel", box)
	label.add_theme_color_override("font_color",
		Palette.PRIMARY_INK if chosen else Palette.TEXT_PRIMARY)
