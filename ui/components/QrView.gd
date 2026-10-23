class_name QrView
extends Control
## Affiche une matrice QR. Dessin direct plutôt qu'une texture : le code doit rester
## net à n'importe quelle taille, et une texture redimensionnée se brouille — un QR
## flou ne se laisse pas lire.

var _matrix: Array = []

## Marge blanche obligatoire autour du code (« quiet zone »). Sans elle, beaucoup de
## lecteurs échouent, surtout sur un écran posé sur un fond sombre.
const QUIET_MODULES := 4

func set_matrix(matrix: Array) -> void:
	_matrix = matrix
	queue_redraw()

func _draw() -> void:
	if _matrix.is_empty():
		return
	var modules: int = _matrix.size() + QUIET_MODULES * 2
	# Taille de module entière : au pixel fractionnaire, les bords bavent et le
	# contraste se dégrade juste assez pour gêner la lecture.
	var scale := maxi(1, int(minf(size.x, size.y) / float(modules)))
	var side := modules * scale
	var origin := Vector2(int((size.x - side) / 2.0), int((size.y - side) / 2.0))

	draw_rect(Rect2(origin, Vector2(side, side)), Color.WHITE)
	for row in range(_matrix.size()):
		for column in range(_matrix.size()):
			if not _matrix[row][column]:
				continue
			var position := origin + Vector2(
				(column + QUIET_MODULES) * scale, (row + QUIET_MODULES) * scale)
			draw_rect(Rect2(position, Vector2(scale, scale)), Color.BLACK)
