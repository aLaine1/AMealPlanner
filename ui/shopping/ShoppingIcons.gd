extends RefCounted
## Icônes de la liste de courses, dessinées en code plutôt que chargées comme assets.
##
## Extrait de ShoppingGrid pour être partagé avec la vue magasin, qui a besoin des
## mêmes coches à une taille bien plus grande (cible tactile). Générées à la volée :
## elles suivent la palette, et une taille arbitraire évite tout crénelage.
##
## Chargé par preload (pas de class_name) : cf. services/Uuid.gd.

## Case à cocher carrée. `size` en pixels de texture.
static func check(checked: bool, size: int = 22) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var border := maxi(2, int(round(size * 0.14)))
	for i in range(1, size - 1):
		for j in range(1, size - 1):
			var edge: bool = i < border or i >= size - border or j < border or j >= size - border
			if checked:
				img.set_pixel(i, j, Palette.PRIMARY)
			elif edge:
				img.set_pixel(i, j, Palette.BORDER)
	if checked:
		var u := float(size) / 22.0   # les points de la coche sont définis sur une base de 22
		_segment(img, Vector2(6, 11) * u, Vector2(10, 15) * u, maxi(1, int(u)))
		_segment(img, Vector2(10, 15) * u, Vector2(16, 6) * u, maxi(1, int(u)))
	return ImageTexture.create_from_image(img)

## Croix de suppression.
static func cross(size: int = 22) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var inset := maxi(3, int(round(size * 0.27)))
	for i in range(inset, size - inset):
		for o in [-1, 0, 1]:
			var a := clampi(i + o, 0, size - 1)
			img.set_pixel(a, i, Palette.ERROR)
			img.set_pixel(a, size - 1 - i, Palette.ERROR)
	return ImageTexture.create_from_image(img)

static func _segment(img: Image, a: Vector2, b: Vector2, thickness: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var steps := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) * 2
	for k in range(steps + 1):
		var t := float(k) / maxf(1.0, float(steps))
		var p := a.lerp(b, t)
		for ox in range(thickness + 1):
			for oy in range(thickness + 1):
				img.set_pixel(clampi(int(p.x) + ox, 0, w - 1), clampi(int(p.y) + oy, 0, h - 1), Color.WHITE)
