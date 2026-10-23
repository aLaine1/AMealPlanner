class_name IngredientPopup
extends Window
## Popup de création / édition d'un ingrédient. Portage de ingredient_popup.IngredientPopup.
## Usage : var p = IngredientPopup.new(); p.ingredient = <Ingredient|null>;
##         add_child(p); p.saved.connect(...); p.popup_centered()

const OptionKeysScript := preload("res://ui/components/OptionKeys.gd")
const ArrowNavigationScript := preload("res://ui/components/ArrowNavigation.gd")

signal saved

var ingredient: Ingredient = null  ## null = création

var _name: LineEdit
var _aisle: OptionButton
var _error: Label

func _ready() -> void:
	title = "Éditeur d'ingrédient"
	Layout.fit_window(self, Vector2i(360, 250), Vector2i(360, 250))
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
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)
	vb.add_child(ArrowNavigationScript.new())   # ↑ / ↓ d'un champ à l'autre (2.0.13)

	vb.add_child(_mk_label("Nom de l'ingrédient *"))
	_name = LineEdit.new()
	vb.add_child(_name)

	vb.add_child(_mk_label("Rayon"))
	_aisle = OptionButton.new()
	OptionKeysScript.attach(_aisle)   # ↑ / ↓ changent le rayon (2.0.11)
	# La liste complète des rayons, et non ceux déjà utilisés : sinon un rayon
	# fraîchement créé restait inassignable tant qu'aucun ingrédient ne l'employait.
	for aisle in DataStore.get_aisle_names():
		_aisle.add_item(aisle)
	vb.add_child(_aisle)

	_error = _mk_label("")
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

	# Pré-remplissage en édition
	if ingredient != null:
		_name.text = ingredient.nom
		_select_option(_aisle, ingredient.aisle)

func _on_save() -> void:
	var name := _name.text.strip_edges()
	if name == "":
		_show_error("Le nom est obligatoire.")
		return
	var aisle := _aisle.get_item_text(_aisle.selected) if _aisle.selected >= 0 else "Divers"
	if ingredient != null:
		ingredient.nom = name
		ingredient.aisle = aisle
		DataStore.update_ingredient(ingredient)
	else:
		DataStore.add_ingredient(name, aisle)
	saved.emit()
	queue_free()

func _show_error(msg: String) -> void:
	_error.text = msg
	_error.visible = true

func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _select_option(opt: OptionButton, value: String) -> void:
	for i in range(opt.item_count):
		if opt.get_item_text(i) == value:
			opt.select(i)
			return
