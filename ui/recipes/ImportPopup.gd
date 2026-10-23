class_name ImportPopup
extends Window
## Import de recettes partagées : on colle un code, on vérifie, on importe.
##
## L'aperçu avant import n'est pas décoratif : un code venu d'ailleurs peut contenir
## dix recettes qu'on ne veut pas toutes. On montre ce qui va entrer avant d'écrire
## quoi que ce soit.

const Share := preload("res://services/RecipeShare.gd")

signal imported(count: int)

var _field: TextEdit
var _preview: Label
var _import_btn: Button
var _entries: Array = []

func _ready() -> void:
	title = "Importer des recettes"
	Layout.fit_window(self, Vector2i(620, 520), Vector2i(480, 420))
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

	var back := Button.new()
	back.text = "←  Fermer"
	back.theme_type_variation = "GhostButton"
	back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	back.pressed.connect(queue_free)
	header.add_child(back)

	var heading := Label.new()
	heading.text = "Importer des recettes"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(heading)

	_field = TextEdit.new()
	_field.placeholder_text = "Colle ici le code reçu (il commence par %s)" % Share.PREFIX
	_field.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_field.text_changed.connect(_analyse)
	root.add_child(_field)

	var paste := Button.new()
	paste.text = "Coller depuis le presse-papier"
	paste.theme_type_variation = "OutlineButton"
	paste.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	paste.pressed.connect(func():
		_field.text = DisplayServer.clipboard_get()
		_analyse())
	root.add_child(paste)

	_preview = Label.new()
	_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview.custom_minimum_size = Vector2(0, 70)
	root.add_child(_preview)

	_import_btn = Button.new()
	_import_btn.text = "Importer"
	_import_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_import_btn.pressed.connect(_on_import)
	root.add_child(_import_btn)

	_analyse()

func _analyse() -> void:
	_entries = []
	_import_btn.disabled = true
	var code := _field.text.strip_edges()
	if code == "":
		_preview.text = ""
		_preview.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		return

	# Code de référence : le contenu est allé se déposer sur le compte de l'émetteur,
	# il faut aller le chercher. Le destinataire n'a besoin d'aucun compte pour cela,
	# seulement du réseau.
	if Share.is_token_code(code):
		_preview.text = "Récupération du partage…"
		_preview.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		var fetched: Dictionary = await Session.fetch_share(Share.extract_token(code))
		if not fetched["ok"]:
			_preview.text = str(fetched["error"])
			_preview.add_theme_color_override("font_color", Palette.ERROR)
			return
		# Le champ peut avoir changé pendant l'aller-retour réseau : ce qui revient ne
		# concerne alors plus ce que l'écran affiche.
		if _field.text.strip_edges() != code:
			return
		code = str(fetched["payload"])

	var result: Dictionary = Share.unpack(code)
	if not result["ok"]:
		_preview.text = str(result["error"])
		_preview.add_theme_color_override("font_color", Palette.ERROR)
		return

	_entries = result["recipes"]
	var names := []
	for entry in _entries:
		names.append(str(entry.get("n", "")))
	_preview.text = "%d recette(s) : %s" % [names.size(), ", ".join(names)]
	_preview.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	_import_btn.disabled = false

func _on_import() -> void:
	if _entries.is_empty():
		return
	var report: Dictionary = Share.import_recipes(DataStore, _entries)
	var message := "%d recette(s) importée(s)." % int(report["imported"])
	if int(report["renamed"]) > 0:
		# Rien n'est écrasé : le destinataire compare puis supprime ce qu'il veut.
		message += " %d portaient un nom déjà pris et ont été renommées." % int(report["renamed"])
	_preview.text = message
	_preview.add_theme_color_override("font_color", Palette.SUCCESS)
	_field.text = ""
	_entries = []
	_import_btn.disabled = true
	imported.emit(int(report["imported"]))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
