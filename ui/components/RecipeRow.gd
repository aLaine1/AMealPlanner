class_name RecipeRow
extends RefCounted
## Contenu d'une ligne de recette : photo (ou pastille colorée à initiale) puis nom.
##
## Extrait de la bibliothèque parce qu'un SECOND endroit en avait besoin — le sélecteur
## de recette du calendrier, seule liste de l'application à ne ressembler à aucune autre.
## Le recopier aurait figé l'écart : deux listes qui affichent la même chose doivent la
## composer au même endroit, faute de quoi la première photo ajoutée à l'une manquera
## toujours à l'autre.
##
## Ne fabrique QUE le contenu, pas le cadre : la bibliothèque a besoin d'un
## `PanelContainer` qui soit source de glisser-déposer, le sélecteur d'une ligne qui
## laisse passer le geste de défilement. Le fond, la sélection et les gestes restent donc
## l'affaire de l'appelant — c'est là qu'ils diffèrent, et seulement là.

const PhotoFrameScript := preload("res://ui/components/PhotoFrame.gd")

## `side` : côté du carré de tête, en unités. La pastille et la photo l'occupent toutes
## deux, si bien que les lignes restent alignées qu'une recette soit illustrée ou non.
static func build(recipe_name: String, side: int = 28, font_size: int = 0) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var recipe: Recipe = DataStore.get_recipe_by_name(recipe_name)
	var cat_color: Color = Palette.TEXT_SECONDARY
	if recipe != null and not recipe.categories.is_empty():
		cat_color = Palette.category_color(recipe.categories[0])

	var photo: Texture2D = DataStore.get_photo_thumb(recipe.id) if recipe != null else null
	if photo != null:
		row.add_child(PhotoFrameScript.square(photo, side))
	else:
		row.add_child(_avatar(recipe_name, side, cat_color))

	var label := Label.new()
	label.text = recipe_name
	label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font_size > 0:
		label.add_theme_font_size_override("font_size", font_size)
	row.add_child(label)
	return row

## Pastille ronde à l'initiale, tenant la place de la photo absente.
static func _avatar(recipe_name: String, side: int, cat_color: Color) -> Control:
	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(side, side)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var radius := side / 2.0
	avatar.draw.connect(func(): avatar.draw_circle(Vector2(radius, radius), radius, cat_color))

	var initial := Label.new()
	initial.text = recipe_name.substr(0, 1).to_upper() if recipe_name != "" else "?"
	# L'encre suit la teinte : blanche sur les catégories sombres, foncée sur les claires.
	# Toujours blanche, l'initiale disparaissait sur les teintes pâles.
	initial.add_theme_color_override("font_color", Palette.ink_on(cat_color))
	initial.add_theme_font_size_override("font_size", maxi(11, int(side * 0.46)))
	initial.set_anchors_preset(Control.PRESET_FULL_RECT)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar.add_child(initial)
	return avatar
