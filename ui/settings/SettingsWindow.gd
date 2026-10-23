class_name SettingsWindow
extends Window
## Fenêtre « Paramètres » (ouverte via la roue crantée de l'en-tête).
##
## Barre latérale sur ordinateur, liste à sous-écrans sur téléphone — la convention de
## chaque plateforme. Auparavant une rangée d'onglets : sur téléphone, trois des cinq
## sections seulement tenaient à l'écran, les autres se cachant derrière des flèches de
## défilement d'une dizaine de pixels.
##
## Les sections sont instanciées une seule fois puis masquées, plutôt que reconstruites
## à chaque changement : cela préserve leur état — texte d'une recherche, ligne
## sélectionnée — et évite de réinterroger la base à chaque aller-retour.

## `scroll` : la section est un FORMULAIRE, dont le contenu peut dépasser la hauteur de
## l'écran sans qu'aucune liste interne ne le rattrape. Les trois autres sections portent
## déjà leur propre liste défilante ; les enfermer dans un second conteneur écraserait
## celle-ci à sa hauteur minimale, c'est-à-dire à rien.
## Le Compte n'y figure plus (2.0.8) : il a sa propre fenêtre, ouverte depuis la pastille
## de l'en-tête (cf. `AccountWindow`).
const SECTIONS := [
	{"name": "Planning", "script": "res://ui/settings/PlanningSettingsTab.gd", "scroll": true},
	{"name": "Apparence", "script": "res://ui/settings/AppearanceTab.gd", "scroll": true},
	{"name": "Rayons", "script": "res://ui/settings/AislesTab.gd"},
	{"name": "Ingrédients", "script": "res://ui/ingredients/IngredientsTab.gd"},
	{"name": "Articles de base", "script": "res://ui/settings/StaplesTab.gd"},
]

const KeyboardInsetScript := preload("res://ui/components/KeyboardInset.gd")
const MotionScript := preload("res://ui/components/Motion.gd")

var _back: Button
var _heading: Label
var _menu: VBoxContainer
var _phone_list: VBoxContainer
var _detail: PanelContainer
var _menu_buttons: Array[Button] = []
var _sections: Array[Control] = []

var _current := 0
## Téléphone seulement : -1 = liste des sections, sinon section ouverte.
var _phone_detail := -1

func _ready() -> void:
	title = "Paramètres"
	Layout.fit_window(self, Vector2i(920, 660), Vector2i(760, 560))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)

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

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	root.add_child(_build_header())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	root.add_child(body)

	_menu = VBoxContainer.new()
	_menu.custom_minimum_size = Vector2(190, 0)
	_menu.add_theme_constant_override("separation", 4)
	body.add_child(_menu)

	_phone_list = VBoxContainer.new()
	_phone_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phone_list.add_theme_constant_override("separation", 4)
	body.add_child(_phone_list)

	_detail = PanelContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Sur téléphone la carte se contente de dix unités au lieu de dix-huit. Additionnées à
	# la marge de la fenêtre et à celle de la section, les marges par défaut prenaient
	# 84 unités de largeur sur 412 — un cinquième de l'écran en blanc.
	if Layout.is_phone():
		var tight := Palette.card_style()
		tight.set_content_margin_all(10)
		_detail.add_theme_stylebox_override("panel", tight)
	body.add_child(_detail)

	_build_sections()
	Layout.form_changed.connect(func(_f): _apply_form())
	_apply_form()

func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	# Sur téléphone la fenêtre est en plein écran : sa barre de titre système, donc son
	# bouton de fermeture, n'existent pas. Ce retour est le seul moyen d'en sortir.
	_back = Button.new()
	_back.theme_type_variation = "GhostButton"
	_back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_back.pressed.connect(_on_back)
	header.add_child(_back)

	_heading = Label.new()
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_heading.add_theme_font_size_override("font_size", 18)
	_heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(_heading)
	return header

func _build_sections() -> void:
	for index in range(SECTIONS.size()):
		var section_name := str(SECTIONS[index]["name"])

		var menu_button := Button.new()
		menu_button.text = section_name
		menu_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		menu_button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		menu_button.pressed.connect(_select.bind(index))
		_menu.add_child(menu_button)
		_menu_buttons.append(menu_button)

		var list_button := Button.new()
		list_button.text = section_name
		list_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		list_button.theme_type_variation = "GhostButton"
		list_button.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)
		list_button.pressed.connect(_select.bind(index))
		_phone_list.add_child(list_button)

		# Chevron ancré au bord droit plutôt que collé au libellé : glissé dans le
		# texte du bouton, il aurait suivi la longueur du nom de section.
		var chevron := Label.new()
		chevron.text = "›"
		chevron.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		chevron.offset_left = -28
		chevron.offset_right = -12
		chevron.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		chevron.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chevron.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
		list_button.add_child(chevron)

		var section: Control = load(str(SECTIONS[index]["script"])).new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if SECTIONS[index].get("scroll", false):
			_detail.add_child(_wrap_scroll(section))
		else:
			section.size_flags_vertical = Control.SIZE_EXPAND_FILL
			_detail.add_child(section)
		_sections.append(section)

## Enferme une section de formulaire dans un conteneur défilant.
##
## Le réglage du planning en compte désormais assez — durée, jour de début, repas par
## jour, puis une ou deux semaines de cases à cocher — pour dépasser un écran de
## téléphone. Il n'y avait alors aucun moyen d'atteindre le bas : rien ne défilait, et
## rien ne le disait.
##
## La section elle-même perd son extension verticale : dans un ScrollContainer, elle
## serait ramenée à la hauteur visible, et il n'y aurait plus rien à faire défiler.
func _wrap_scroll(section: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Zone morte : un contact doit franchir quelques unités avant de devenir un
	# défilement, sinon viser une pastille du bout du doigt fait glisser la page.
	scroll.scroll_deadzone = 8
	section.size_flags_vertical = Control.SIZE_FILL
	Layout.scroll_body(scroll).add_child(section)
	# L'écran du compte se saisit au clavier : ses champs seraient sinon recouverts.
	scroll.add_child(KeyboardInsetScript.new())
	return scroll

## Ouvre directement la section nommée — au retour d'un changement de thème, qui a
## reconstruit l'interface et donc refermé cette fenêtre.
func open_section(section_name: String) -> void:
	for index in range(SECTIONS.size()):
		if str(SECTIONS[index]["name"]) == section_name:
			_select(index)
			return

func _select(index: int) -> void:
	_current = index
	if Layout.is_phone():
		_phone_detail = index
	_apply_form()
	# La section choisie apparaît en fondu, comme un onglet de l'écran principal (2.0.9).
	MotionScript.fade_in(_detail)

## Sur téléphone, le retour remonte d'abord de la section vers la liste, et ne referme
## la fenêtre que depuis la liste — la hiérarchie attendue. Sur ordinateur il n'y a pas
## de niveau intermédiaire : il referme directement.
func _on_back() -> void:
	if Layout.is_phone() and _phone_detail >= 0:
		_phone_detail = -1
		_apply_form()
		MotionScript.fade_in(_phone_list)
		return
	queue_free()

func _apply_form() -> void:
	var phone := Layout.is_phone()
	var showing_list := phone and _phone_detail < 0

	_menu.visible = not phone
	_phone_list.visible = showing_list
	_detail.visible = not showing_list

	# Sur ordinateur, la barre de titre porte déjà le nom et la fermeture : cet en-tête
	# ne sert que sur téléphone.
	_back.visible = phone
	_back.text = "←  Fermer" if showing_list else "←  Paramètres"
	# Uniquement au-dessus de la liste : chaque section porte déjà son propre titre,
	# l'afficher aussi dans l'en-tête le répétait deux fois à l'écran.
	_heading.visible = showing_list
	_heading.text = "Paramètres"

	for index in range(_sections.size()):
		# La visibilité porte sur ce que `_detail` contient : la section elle-même, ou le
		# conteneur défilant qui l'enferme. Masquer la section à l'intérieur d'un
		# conteneur visible laisserait une zone vide à la place de l'écran demandé.
		var holder: Control = _sections[index]
		if holder.get_parent() != _detail:
			holder = holder.get_parent().get_parent()
		holder.visible = index == _current
		_menu_buttons[index].theme_type_variation = "" if index == _current else "GhostButton"

## Le geste « retour » d'Android suit la même hiérarchie que le bouton.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()
