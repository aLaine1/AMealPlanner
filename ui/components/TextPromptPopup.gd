class_name TextPromptPopup
extends Window
## Petite boîte de saisie : un titre, une explication, un champ, valider/annuler.
##
## Sert aux plats saisis à la main dans le calendrier — un repas prévu qui ne
## correspond à aucune recette de la base (« Restaurant », « Restes », « Chez mes
## parents »). Ces libellés sont stockés dans `meal_plan_positions.custom_label` et
## n'entrent donc jamais dans la bibliothèque de recettes.
##
## Distinct de `PickerPopup`, qui choisit dans une liste existante : détourner son
## champ de recherche en saisie libre aurait rendu les deux gestes ambigus.

signal submitted(text: String)

var _field: LineEdit
var _title := ""
var _prompt := ""
var _initial := ""
var _placeholder := ""
## Type de clavier virtuel proposé au doigt — DEFAULT (texte) sauf demande contraire. La
## quantité de la liste de courses passe DECIMAL : demander le texte complet pour taper
## un nombre serait un détour, en marchant, pour ce qui est toujours un nombre.
var _keyboard_type := LineEdit.KEYBOARD_TYPE_DEFAULT

func setup(dialog_title: String, prompt: String, initial: String = "",
		placeholder: String = "", keyboard_type := LineEdit.KEYBOARD_TYPE_DEFAULT) -> void:
	_title = dialog_title
	_prompt = prompt
	_initial = initial
	_placeholder = placeholder
	_keyboard_type = keyboard_type
	title = dialog_title
	if _field != null:
		_field.text = initial
		_field.virtual_keyboard_type = keyboard_type

func _ready() -> void:
	title = _title
	Layout.fit_window(self, Vector2i(440, 240), Vector2i(320, 200))
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
		margin.add_theme_constant_override(side, 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var heading := Label.new()
	heading.text = _title
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	root.add_child(heading)

	var prompt := Label.new()
	prompt.text = _prompt
	prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prompt.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	root.add_child(prompt)

	_field = LineEdit.new()
	_field.text = _initial
	_field.placeholder_text = _placeholder
	_field.virtual_keyboard_type = _keyboard_type
	_field.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_field.text_submitted.connect(func(_t): _submit())
	root.add_child(_field)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var actions := HFlowContainer.new()
	actions.alignment = HFlowContainer.ALIGNMENT_END
	actions.add_theme_constant_override("h_separation", 8)
	root.add_child(actions)

	var cancel := Button.new()
	cancel.text = "Annuler"
	cancel.theme_type_variation = "GhostButton"
	cancel.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	cancel.pressed.connect(queue_free)
	actions.add_child(cancel)

	var confirm := Button.new()
	confirm.text = "Valider"
	confirm.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	confirm.pressed.connect(_submit)
	actions.add_child(confirm)

	_field.grab_focus()
	_field.select_all()

func _submit() -> void:
	var value := _field.text.strip_edges()
	if value == "":
		# Valider à vide reviendrait à vider la case sans le dire ; la suppression a sa
		# propre entrée de menu.
		_field.grab_focus()
		return
	submitted.emit(value)
	queue_free()

## Le geste « retour » d'Android doit refermer la fenêtre, pas quitter l'application.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
