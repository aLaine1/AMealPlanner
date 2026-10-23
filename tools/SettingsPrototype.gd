extends Node
## Prototype jetable : compare trois dispositions pour l'écran de réglages.
## Lancé par tools/prototype_settings.sh, qui travaille sur une COPIE de la base.
##
## Autoload temporaire — ne doit jamais rester dans project.godot.
##
## Les sections sont les vraies (AccountTab, AislesTab…), pas des maquettes : ce qu'on
## voit est exactement ce que donnerait chaque disposition.

enum Mode { SIDEBAR, DRILLDOWN, SINGLE_PAGE }

const SECTIONS := [
	{"name": "Compte", "script": "res://ui/settings/AccountTab.gd"},
	{"name": "Planning", "script": "res://ui/settings/PlanningSettingsTab.gd"},
	{"name": "Rayons", "script": "res://ui/settings/AislesTab.gd"},
	{"name": "Ingrédients", "script": "res://ui/ingredients/IngredientsTab.gd"},
	{"name": "Articles de base", "script": "res://ui/settings/StaplesTab.gd"},
]

var _mode: Mode = Mode.SIDEBAR
var _body: Control
var _detail := -1        ## drill-down : -1 = liste, sinon index de section
var _current := 0        ## barre latérale : section affichée

func _ready() -> void:
	await get_tree().create_timer(0.8).timeout
	_open()

func _open() -> void:
	var window := Window.new()
	window.title = "Prototype — dispositions des réglages"
	window.size = Vector2i(1100, 720)
	window.min_size = Vector2i(360, 480)
	window.theme = Palette.ui_theme
	window.close_requested.connect(func(): get_tree().quit())
	get_tree().root.add_child(window)

	var background := ColorRect.new()
	background.color = Palette.WINDOW_BG
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	window.add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	window.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	root.add_child(_build_switcher())

	_body = PanelContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_body)

	_render()
	window.popup_centered()

func _build_switcher() -> Control:
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)

	var label := Label.new()
	label.text = "Disposition :"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	bar.add_child(label)

	for entry in [
		{"mode": Mode.SIDEBAR, "text": "Barre latérale"},
		{"mode": Mode.DRILLDOWN, "text": "Liste + sous-écrans"},
		{"mode": Mode.SINGLE_PAGE, "text": "Page unique"},
	]:
		var button := Button.new()
		button.text = entry["text"]
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		var mode: Mode = entry["mode"]
		button.pressed.connect(func():
			_mode = mode
			_detail = -1
			_render())
		bar.add_child(button)

	var hint := Label.new()
	hint.text = "  (copie de la base — tu peux tout modifier sans risque ; redimensionne la fenêtre pour voir le comportement mobile)"
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	bar.add_child(hint)
	return bar

# =====================================================================

func _render() -> void:
	for child in _body.get_children():
		child.queue_free()
	match _mode:
		Mode.SIDEBAR:
			_body.add_child(_render_sidebar())
		Mode.DRILLDOWN:
			_body.add_child(_render_drilldown())
		_:
			_body.add_child(_render_single_page())

func _make_section(index: int) -> Control:
	var section: Control = load(str(SECTIONS[index]["script"])).new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return section

## Sections à gauche, contenu à droite. Sur écran étroit, bascule automatiquement
## vers la liste à sous-écrans — c'est la variante « responsive » proposée.
func _render_sidebar() -> Control:
	if Layout.is_phone():
		return _render_drilldown()

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var menu := VBoxContainer.new()
	menu.custom_minimum_size = Vector2(190, 0)
	menu.add_theme_constant_override("separation", 4)
	row.add_child(menu)

	for index in range(SECTIONS.size()):
		var button := Button.new()
		button.text = str(SECTIONS[index]["name"])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		button.theme_type_variation = "" if index == _current else "GhostButton"
		button.pressed.connect(func():
			_current = index
			_render())
		menu.add_child(button)

	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(_make_section(_current))
	row.add_child(panel)
	return row

## Liste de sections, puis sous-écran avec retour.
func _render_drilldown() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)

	if _detail < 0:
		for index in range(SECTIONS.size()):
			var button := Button.new()
			button.text = "%s        ›" % str(SECTIONS[index]["name"])
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.theme_type_variation = "GhostButton"
			button.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)
			button.pressed.connect(func():
				_detail = index
				_render())
			column.add_child(button)
		return column

	var back := Button.new()
	back.text = "←  %s" % str(SECTIONS[_detail]["name"])
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.theme_type_variation = "GhostButton"
	back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	back.pressed.connect(func():
		_detail = -1
		_render())
	column.add_child(back)
	column.add_child(_make_section(_detail))
	return column

## Toutes les sections empilées dans un seul défilement.
##
## Chaque section reçoit une hauteur fixe : ce sont des écrans entiers, qui n'ont pas
## de hauteur naturelle. C'est précisément la limite de cette disposition.
func _render_single_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 14)
	Layout.scroll_body(scroll).add_child(column)

	for index in range(SECTIONS.size()):
		var heading := Label.new()
		heading.text = str(SECTIONS[index]["name"]).to_upper()
		heading.add_theme_font_size_override("font_size", 12)
		heading.add_theme_color_override("font_color", Palette.PRIMARY)
		column.add_child(heading)

		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(0, 430)
		panel.add_child(_make_section(index))
		column.add_child(panel)
	return scroll
