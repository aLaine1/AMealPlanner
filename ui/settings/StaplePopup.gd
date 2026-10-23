class_name StaplePopup
extends Window
## Formulaire de création / édition d'un article de base (nom, rayon, quantité, unité).

const OptionKeysScript := preload("res://ui/components/OptionKeys.gd")
const ArrowNavigationScript := preload("res://ui/components/ArrowNavigation.gd")

signal saved

const COMMON_UNITS := ["", "g", "kg", "ml", "l", "pièce", "boîte", "rouleau", "paquet", "sachet"]

var staple: Ingredient = null  ## null = création

var _name: LineEdit
var _aisle: OptionButton
var _qty: LineEdit
var _unit: AutocompleteEdit
var _error: Label

func _ready() -> void:
	title = "Modifier l'article" if staple != null else "Ajouter un article de base"
	Layout.fit_window(self, Vector2i(380, 320), Vector2i(380, 320))
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
		margin.add_theme_constant_override(m, 16)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	vb.add_child(ArrowNavigationScript.new())   # ↑ / ↓ d'un champ à l'autre (2.0.13)

	vb.add_child(_label("Nom *"))
	_name = LineEdit.new()
	vb.add_child(_name)

	vb.add_child(_label("Rayon"))
	_aisle = OptionButton.new()
	OptionKeysScript.attach(_aisle)   # ↑ / ↓ changent le rayon (2.0.11)
	for a in DataStore.get_aisle_names():
		_aisle.add_item(a)
	vb.add_child(_aisle)

	var qu := HBoxContainer.new()
	qu.add_theme_constant_override("separation", 8)
	vb.add_child(qu)
	var qbox := VBoxContainer.new()
	qbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qbox.add_child(_label("Quantité"))
	_qty = LineEdit.new()
	_qty.text = "1"
	qbox.add_child(_qty)
	qu.add_child(qbox)
	var ubox := VBoxContainer.new()
	ubox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ubox.add_child(_label("Unité"))
	_unit = AutocompleteEdit.new()
	_unit.suggestions = COMMON_UNITS
	ubox.add_child(_unit)
	qu.add_child(ubox)

	_error = _label("")
	_error.add_theme_color_override("font_color", Palette.ERROR)
	_error.visible = false
	vb.add_child(_error)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vb.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.theme_type_variation = "GhostButton"
	cancel.pressed.connect(queue_free)
	buttons.add_child(cancel)
	var save := Button.new()
	save.text = "Sauvegarder"
	save.pressed.connect(_on_save)
	buttons.add_child(save)

	if staple != null:
		_name.text = staple.nom
		_select_option(_aisle, staple.aisle)
		_qty.text = _fmt_qty(staple.quantite)
		_unit.text = staple.unite

func _on_save() -> void:
	var name := _name.text.strip_edges()
	if name == "":
		_error.text = "Le nom est obligatoire."
		_error.visible = true
		return
	var ing := staple if staple != null else Ingredient.new()
	ing.nom = name
	ing.aisle = _aisle.get_item_text(_aisle.selected) if _aisle.selected >= 0 else "Autres"
	ing.quantite = _parse_float(_qty.text)
	ing.unite = _unit.text.strip_edges()
	if staple != null:
		DataStore.update_staple(ing)
	else:
		DataStore.add_staple(ing)
	saved.emit()
	queue_free()

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _select_option(opt: OptionButton, value: String) -> void:
	for i in range(opt.item_count):
		if opt.get_item_text(i) == value:
			opt.select(i)
			return

func _fmt_qty(q: float) -> String:
	return str(int(round(q))) if absf(q - round(q)) < 0.001 else str(q)

func _parse_float(s: String) -> float:
	var t := s.strip_edges().replace(",", ".")
	return t.to_float() if t.is_valid_float() else 1.0
