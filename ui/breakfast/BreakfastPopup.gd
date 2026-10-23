class_name BreakfastPopup
extends Window
## Popup de création / édition d'un choix de petit déjeuner (nom + ingrédients).
## Usage : var p = BreakfastPopup.new(); p.breakfast = <Breakfast|null>; add_child(p);
##         p.saved.connect(...); p.popup_centered()

signal saved

const KeyboardInsetScript := preload("res://ui/components/KeyboardInset.gd")

const COMMON_UNITS := ["g", "kg", "ml", "l", "c.à.s", "c.à.c", "pièce", "tranche", "pincée", "verre", "boîte", "bol"]

var breakfast: Breakfast = null  ## null = création

var _name: LineEdit
var _rows_box: VBoxContainer
var _rows: Array = []
var _error: Label
var _ing_suggestions: Array[String] = []

func _ready() -> void:
	title = "Modifier le petit déjeuner" if breakfast != null else "Ajouter un petit déjeuner"
	Layout.fit_window(self, Vector2i(520, 520), Vector2i(520, 480))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)
	_ing_suggestions = DataStore.get_all_ingredient_names()
	_build()
	_fill_from_breakfast()

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
	outer.add_theme_constant_override("separation", 8)
	margin.add_child(outer)

	outer.add_child(_mk_label("Nom du petit déjeuner *"))
	_name = LineEdit.new()
	_name.placeholder_text = "Ex: Porridge banane"
	outer.add_child(_name)

	var ing_header := HBoxContainer.new()
	outer.add_child(ing_header)
	var ing_title := _mk_label("Ingrédients")
	ing_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ing_header.add_child(ing_title)
	var add_btn := Button.new()
	add_btn.text = "+ Ajouter"
	add_btn.pressed.connect(func(): _add_row())
	ing_header.add_child(add_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	# Chaque ligne ajoutée pousse la suivante vers le bas, donc vers le clavier.
	scroll.add_child(KeyboardInsetScript.new())
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 4)
	Layout.scroll_body(scroll).add_child(_rows_box)

	_error = _mk_label("")
	_error.add_theme_color_override("font_color", Palette.ERROR)
	_error.visible = false
	outer.add_child(_error)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	outer.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.theme_type_variation = "GhostButton"
	cancel.pressed.connect(queue_free)
	buttons.add_child(cancel)
	var save := Button.new()
	save.text = "Sauvegarder"
	save.pressed.connect(_on_save)
	buttons.add_child(save)

func _add_row(nom := "", qty := "", unit := "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var name_edit := AutocompleteEdit.new()
	name_edit.placeholder_text = "Ingrédient"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.suggestions = _ing_suggestions
	name_edit.text = nom
	row.add_child(name_edit)

	var qty_edit := LineEdit.new()
	qty_edit.placeholder_text = "Qté"
	qty_edit.custom_minimum_size = Vector2(60, 0)
	qty_edit.text = qty
	row.add_child(qty_edit)

	var unit_edit := AutocompleteEdit.new()
	unit_edit.placeholder_text = "Unité"
	unit_edit.custom_minimum_size = Vector2(80, 0)
	unit_edit.suggestions = COMMON_UNITS
	unit_edit.text = unit
	row.add_child(unit_edit)

	var entry := {"root": row, "name": name_edit, "qty": qty_edit, "unit": unit_edit}
	var remove := Button.new()
	remove.text = "X"
	remove.pressed.connect(func(): _remove_row(entry))
	row.add_child(remove)

	_rows.append(entry)
	_rows_box.add_child(row)

func _remove_row(entry: Dictionary) -> void:
	_rows.erase(entry)
	entry["root"].queue_free()
	if _rows.is_empty():
		_add_row()

func _fill_from_breakfast() -> void:
	if breakfast == null:
		_add_row()
		return
	_name.text = breakfast.nom
	if breakfast.ingredients.is_empty():
		_add_row()
	else:
		for ing in breakfast.ingredients:
			_add_row(ing.nom, str(ing.quantite), ing.unite)

func _on_save() -> void:
	var name := _name.text.strip_edges()
	if name == "":
		_show_error("Le nom est obligatoire.")
		return
	var ings: Array[Ingredient] = []
	for entry in _rows:
		var iname: String = entry["name"].text.strip_edges()
		if iname == "":
			continue
		var ing := Ingredient.new()
		ing.nom = iname
		ing.quantite = _parse_float(entry["qty"].text)
		ing.unite = entry["unit"].text.strip_edges()
		ings.append(ing)
	if ings.is_empty():
		_show_error("Ajoutez au moins un ingrédient.")
		return

	var b := Breakfast.new()
	b.nom = name
	b.ingredients = ings
	if breakfast != null:
		b.id = breakfast.id
		DataStore.update_breakfast(b)
	else:
		DataStore.add_breakfast(b)
	saved.emit()
	queue_free()

func _parse_float(s: String) -> float:
	var t := s.strip_edges().replace(",", ".")
	return t.to_float() if t.is_valid_float() else 0.0

func _show_error(msg: String) -> void:
	_error.text = msg
	_error.visible = true

func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
