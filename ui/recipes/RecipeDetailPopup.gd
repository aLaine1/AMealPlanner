class_name RecipeDetailPopup
extends Window
## Popup de consultation d'une recette (lecture seule) : liste d'ingrédients ou étapes.
## Reprend le gabarit visuel des autres popups (fond crème, marge 16, carte, bouton en bas
## à droite) au lieu de l'AcceptDialog brut du moteur.
## Usage : var p := RecipeDetailPopup.new(); p.recipe_name = "..."
##         p.detail_mode = RecipeDetailPopup.DetailMode.STEPS  (« mode » est déjà pris par Window)
##         add_child(p); p.popup_centered()

const PhotoFrameScript := preload("res://ui/components/PhotoFrame.gd")

enum DetailMode { INGREDIENTS, STEPS }

var recipe_name: String = ""
var detail_mode: DetailMode = DetailMode.INGREDIENTS

func _ready() -> void:
	title = "Ingrédients" if detail_mode == DetailMode.INGREDIENTS else "Étapes"
	Layout.fit_window(self, Vector2i(460, 520), Vector2i(420, 380))
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

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	margin.add_child(outer)

	# La photo coiffe les deux modes : on consulte les ingrédients ou les étapes avec le
	# plat sous les yeux, et c'est le seul écran assez grand pour la montrer en entier.
	var recipe_for_photo: Recipe = DataStore.get_recipe_by_name(recipe_name)
	if recipe_for_photo != null:
		var photo := DataStore.get_photo(recipe_for_photo.id)
		if photo != null:
			outer.add_child(PhotoFrameScript.banner(photo, 150, Palette.RADIUS_CARD))

	outer.add_child(_build_header())

	# Carte de contenu (même stylebox que les panneaux de l'application)
	var card := PanelContainer.new()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(card)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	Layout.scroll_body(scroll).add_child(content)

	if detail_mode == DetailMode.INGREDIENTS:
		_fill_ingredients(content)
	else:
		_fill_steps(content)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	outer.add_child(buttons)
	var close := Button.new()
	close.text = "Fermer"
	close.pressed.connect(queue_free)
	buttons.add_child(close)

## En-tête : pastille de couleur de catégorie + nom de la recette + sous-titre.
func _build_header() -> Control:
	var recipe := DataStore.get_recipe_by_name(recipe_name)
	var category := ""
	if recipe != null and not recipe.categories.is_empty():
		category = recipe.categories[0]

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)

	header.add_child(_mk_dot(12, Palette.category_color(category)))

	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 2)
	header.add_child(titles)

	var name_label := Label.new()
	name_label.text = recipe_name
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Palette.PRIMARY_INK)
	titles.add_child(name_label)

	var subtitle := Label.new()
	subtitle.text = "Ingrédients" if detail_mode == DetailMode.INGREDIENTS else "Étapes de préparation"
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	titles.add_child(subtitle)

	return header

func _fill_ingredients(content: VBoxContainer) -> void:
	var ings := DataStore.get_recipe_ingredients(recipe_name)
	if ings.is_empty():
		content.add_child(_mk_empty("(Aucun ingrédient renseigné)"))
		return
	for ing in ings:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)

		row.add_child(_mk_dot(6, Palette.SECONDARY))

		var name_label := Label.new()
		name_label.text = ing.nom
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
		row.add_child(name_label)

		var qty := ing.quantity_label()
		if qty != "":
			var qty_label := Label.new()
			qty_label.text = qty
			qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			qty_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
			row.add_child(qty_label)

		content.add_child(row)

func _fill_steps(content: VBoxContainer) -> void:
	var recipe := DataStore.get_recipe_by_name(recipe_name)
	var steps := _split_steps(recipe.etapes if recipe != null else "")
	if steps.is_empty():
		content.add_child(_mk_empty("(Aucune étape renseignée)"))
		return
	for i in range(steps.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(_mk_step_badge(i + 1))

		var text := Label.new()
		text.text = steps[i]
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
		row.add_child(text)

		content.add_child(row)

## Découpe les étapes en lignes non vides et retire une éventuelle puce/numérotation
## déjà saisie par l'utilisateur (on renumérote nous-mêmes).
func _split_steps(raw: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile("^\\s*(\\d+\\s*[\\.\\)\\-:]|[-–•*])\\s*")
	for line in raw.split("\n"):
		var clean := re.sub(line, "", false).strip_edges()
		if clean != "":
			out.append(clean)
	return out

func _mk_dot(radius: int, color: Color) -> Control:
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(radius * 2, radius * 2)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func(): dot.draw_circle(Vector2(radius, radius), radius, color))
	return dot

func _mk_step_badge(number: int) -> Control:
	var badge := Control.new()
	badge.custom_minimum_size = Vector2(22, 22)
	badge.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.draw.connect(func(): badge.draw_circle(Vector2(11, 11), 11, Palette.PRIMARY))

	var label := Label.new()
	label.text = str(number)
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color.WHITE)
	badge.add_child(label)

	return badge

func _mk_empty(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	return label
