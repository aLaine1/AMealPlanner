class_name PanelSheet
extends Window
## Fenêtre d'accueil temporaire pour un panneau qui vit ailleurs le reste du temps.
##
## Sur téléphone, les panneaux latéraux — bibliothèque de recettes, choix de petits
## déjeuners — n'ont pas la place de tenir à côté de leur écran. Les masquer rendait
## inaccessible tout ce qu'ils portent : créer, modifier, partager, importer, et depuis
## les photos, l'appareil photo. Un onglet supplémentaire les aurait rendus permanents
## alors qu'on n'y va qu'occasionnellement, et aurait chargé la barre de navigation.
##
## Le panneau est donc **déplacé** ici le temps de la consultation, puis rendu à son
## conteneur d'origine. C'est le même nœud qui voyage, comme les cases du calendrier
## entre grille et liste : en dupliquer un second obligerait à tenir deux sélections et
## deux listes filtrées d'accord.
##
##     PanelSheet.present(self, _recipe_panel, home, "Mes recettes")

## `owner_node` reçoit la fenêtre : elle vit dans l'arbre de l'écran appelant, et
## disparaît avec lui si celui-ci est libéré pendant la consultation.
static func present(owner_node: Node, panel: Control, home: Control, sheet_title: String) -> PanelSheet:
	var sheet := PanelSheet.new()
	sheet._panel = panel
	sheet._home = home
	sheet.title = sheet_title
	owner_node.add_child(sheet)
	sheet.popup_centered()
	return sheet

var _panel: Control
var _home: Control

func _ready() -> void:
	Layout.fit_window(self, Vector2i(760, 720), Vector2i(520, 520))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(_dismiss)

	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	# En plein écran sur téléphone, la barre de titre du système n'existe pas : ce
	# bouton est le seul moyen de sortir, avec le geste « retour » d'Android.
	var back := Button.new()
	back.text = "←  Fermer"
	back.theme_type_variation = "GhostButton"
	back.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	back.pressed.connect(_dismiss)
	column.add_child(back)

	if _panel != null:
		if _panel.get_parent() != null:
			_panel.get_parent().remove_child(_panel)
		_panel.visible = true
		# Le panneau porte la largeur d'un panneau latéral de bureau ; ici il occupe
		# toute la fenêtre.
		_panel.custom_minimum_size = Vector2.ZERO
		_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		column.add_child(_panel)

## Rend le panneau à son conteneur d'origine avant de disparaître — sans quoi il serait
## libéré avec la fenêtre, et l'écran appelant se retrouverait sans lui au retour du
## format bureau.
func _dismiss() -> void:
	if _panel != null and is_instance_valid(_panel):
		if _panel.get_parent() != null:
			_panel.get_parent().remove_child(_panel)
		if _home != null and is_instance_valid(_home):
			_home.add_child(_panel)
			_panel.visible = false
	queue_free()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_dismiss()
