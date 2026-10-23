class_name AppearanceTab
extends MarginContainer
## Choix du thème de couleur (2.0.7).
##
## Une vignette par thème, peinte dans SES couleurs et non dans celles du thème actif :
## on choisit sur pièce, sans avoir à essayer chacun. Le choix est propre à l'appareil.
##
## Choisir reconstruit toute l'interface (`Palette.scheme_changed`, cf. `MainWindow`) :
## chaque écran lit ses couleurs à sa construction. Cette fenêtre est donc refermée puis
## rouverte sur cette même section — `MainWindow` s'en charge.

const TouchTapScript := preload("res://ui/components/TouchTap.gd")

## Hauteur d'une vignette : de quoi y lire l'en-tête et ses pastilles au premier coup d'œil.
const SWATCH_HEIGHT := 88

## Vignettes par identifiant de thème — exposées pour les tests.
var swatches := {}

func _ready() -> void:
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		add_theme_constant_override(m, 12)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "Apparence"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	root.add_child(title)

	# Deux colonnes : quatre vignettes sur une seule ligne n'auraient plus la largeur d'y
	# écrire leur nom sur un téléphone.
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	root.add_child(grid)

	for id in Palette.SCHEMES:
		var swatch := _make_swatch(id)
		swatches[id] = swatch
		grid.add_child(swatch)

## Une vignette : l'en-tête du thème (son primaire, son nom en blanc), sous lequel ses
## fonds et son accent. Le thème actif porte un cadre épais et une coche.
func _make_swatch(id: String) -> Control:
	var roles: Dictionary = Palette.SCHEMES[id]
	var active: bool = id == Palette.scheme

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, SWATCH_HEIGHT)
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(roles["BACKGROUND"])
	frame.set_corner_radius_all(Palette.RADIUS)
	frame.set_border_width_all(3 if active else 1)
	frame.border_color = Palette.PRIMARY_INK if active else Palette.BORDER
	# Le contenu épouse le cadre : l'en-tête de la vignette rejoint ses bords, comme celui
	# de l'application rejoint ceux de l'écran.
	frame.set_content_margin_all(3 if active else 1)
	card.add_theme_stylebox_override("panel", frame)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)

	var header := PanelContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(roles["PRIMARY"])
	header_style.corner_radius_top_left = Palette.RADIUS - 2
	header_style.corner_radius_top_right = Palette.RADIUS - 2
	header_style.content_margin_left = 10
	header_style.content_margin_right = 10
	header_style.content_margin_top = 6
	header_style.content_margin_bottom = 6
	header.add_theme_stylebox_override("panel", header_style)
	box.add_child(header)

	var name_label := Label.new()
	name_label.text = ("✓  " if active else "") + str(roles["name"])
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(name_label)

	var dots := HBoxContainer.new()
	dots.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dots.alignment = BoxContainer.ALIGNMENT_CENTER
	dots.add_theme_constant_override("separation", 8)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(dots)
	for role in ["SURFACE", "SECONDARY_CONTAINER", "SECONDARY", "TERTIARY"]:
		dots.add_child(_dot(Color(roles[role]), Color(roles["OUTLINE_VARIANT"])))

	TouchTapScript.connect_tap(card, func(): Palette.set_scheme(id))
	return card

## Pastille ronde, cerclée du contour discret du thème : sans lui, celle de la surface
## disparaîtrait dans le fond de la vignette.
func _dot(color: Color, ring: Color) -> Control:
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(22, 22)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.draw.connect(func():
		dot.draw_circle(Vector2(11, 11), 11, ring)
		dot.draw_circle(Vector2(11, 11), 10, color))
	return dot
