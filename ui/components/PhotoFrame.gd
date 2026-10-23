class_name PhotoFrame
extends PanelContainer
## Cadre à coins arrondis pour une photo de recette.
##
## Les photos arrivent dans toutes les proportions — portrait au téléphone, paysage
## depuis un appareil. Partout où l'application en montre une, la place disponible a
## une forme imposée : un carré dans les listes, une bande au-dessus d'un nom. La
## photo est donc recadrée au centre et découpée par le cadre, jamais déformée.
##
## `clip_contents` fait le travail de découpe : sans lui, une image en portrait
## déborderait de son cadre et recouvrirait ses voisins, le `TextureRect` dessinant
## au-delà de la taille que le conteneur lui alloue.

## Vignette carrée, pour les listes et les pastilles.
##
## Les drapeaux de taille sont posés ici, et non chez l'appelant : `side` est une taille
## MINIMALE, et les drapeaux par défaut laissaient le conteneur étirer le cadre. Dans une
## rangée de 56 unités de haut — la hauteur tactile des cases du calendrier — un carré de
## 40 devenait donc un rectangle de 40 × 56, la photo étant recadrée sur cette forme. Le
## défaut ne se voyait pas dans la bibliothèque, où la rangée fait justement la hauteur du
## carré : la promesse d'un carré doit être tenue par la fonction qui la fait.
static func square(texture: Texture2D, side: int) -> PhotoFrame:
	var frame := _make(texture, Vector2(side, side), 6)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return frame

## Bande de largeur libre et de hauteur imposée, pour coiffer un nom de recette.
static func banner(texture: Texture2D, height: int, radius := 8) -> PhotoFrame:
	var frame := _make(texture, Vector2(0, height), radius)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return frame

static func _make(texture: Texture2D, minimum: Vector2, radius: int) -> PhotoFrame:
	var frame := PhotoFrame.new()
	frame.custom_minimum_size = minimum
	frame.clip_contents = true
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Palette.BORDER
	style.set_corner_radius_all(radius)
	# Marges à zéro : celles du thème encadreraient la photo d'une bande de fond, et
	# la rogneraient d'autant.
	style.set_content_margin_all(0)
	frame.add_theme_stylebox_override("panel", style)

	var image := TextureRect.new()
	image.texture = texture
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(image)
	return frame
