class_name ShareCodePopup
extends Window
## Le code d'un partage déposé : le QR à faire lire, et le même code en texte.
##
## Une fenêtre à part, et non un panneau de l'écran de sélection. Trois raisons :
##  * le QR doit être GRAND pour qu'un autre téléphone le lise, et l'écran de sélection
##    est tout entier occupé par sa liste de recettes ;
##  * ce code n'existe qu'après le dépôt — jusque-là le panneau réservait sa place pour
##    ne rien montrer, et « Copier le code » y proposait de copier le vide ;
##  * une fenêtre se referme, ce qui ramène à la sélection sans rien avoir à défaire.
##
## Usage : var p = ShareCodePopup.new(); p.code = "..."; add_child(p); p.popup_centered()

const Share := preload("res://services/RecipeShare.gd")
const QrCode := preload("res://services/QrCode.gd")

var code := ""   ## à renseigner AVANT l'entrée dans l'arbre

var _qr: QrView
var _status: Label

func _ready() -> void:
	title = "Code de partage"
	Layout.fit_window(self, Vector2i(520, 640), Vector2i(420, 520))
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
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 14)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)

	# En plein écran sur téléphone, la barre de titre système — donc sa croix — n'existe
	# pas : ce bouton est la seule sortie.
	var back := Button.new()
	back.text = "←  Fermer"
	back.theme_type_variation = "GhostButton"
	back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	back.pressed.connect(queue_free)
	header.add_child(back)

	var heading := Label.new()
	heading.text = "Code de partage"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(heading)

	_qr = QrView.new()
	_qr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_qr.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_qr.custom_minimum_size = Vector2(280, 280)
	root.add_child(_qr)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	root.add_child(_status)

	# Sous le QR, jamais au-dessus : c'est le code affiché qu'il copie, et l'ordre à
	# l'écran dit lequel des deux chemins on emprunte quand le scan n'aboutit pas.
	var copy_btn := Button.new()
	copy_btn.text = "Copier le code"
	copy_btn.theme_type_variation = "OutlineButton"
	copy_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	copy_btn.pressed.connect(_on_copy)
	root.add_child(copy_btn)

	# Une fenêtre ouverte sans code ne doit pas rester muette devant un carré vide.
	if code == "":
		copy_btn.disabled = true
		_qr.visible = false
		_status.text = "Aucun code à afficher."
		return

	var encoder = QrCode.new()
	_qr.set_matrix(encoder.encode(code, -1))
	_status.text = "Fais lire ce code par l'appareil photo de l'autre téléphone, puis " \
		+ "colle le texte obtenu dans « Importer une recette ». Valable %d jours." % Share.SHARE_DAYS

func _on_copy() -> void:
	if code == "":
		return
	DisplayServer.clipboard_set(code)
	_status.text = "Code copié (%d caractères)." % code.length()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
