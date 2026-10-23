extends SceneTree
## Encodeur QR : témoins de non-régression et invariants de structure.
## godot --headless --path . --script res://tools/test_qr.gd
##
## Les témoins ont été figés après comparaison bit à bit avec la bibliothèque de
## référence `qrcode` — 72 matrices identiques. C'est indispensable ici : un QR mal
## formé ressemble trait pour trait à un QR valide, et se contenterait de ne pas se
## laisser lire. Pour revérifier contre la référence : tools/verify_qr.sh

const QrCode := preload("res://services/QrCode.gd")
const Golden := preload("res://tools/QrGolden.gd")

var _fails := 0

func _initialize() -> void:
	var qr = QrCode.new()

	print("--- Témoins de référence ---")
	for entry in Golden.GOLDEN:
		var matrix: Array = qr.encode(str(entry["text"]), -1)
		var label: String = str(entry["text"]).substr(0, 22)
		if matrix.is_empty():
			_check("%s : encodée" % label, false)
			continue
		_check("%s : taille %d" % [label, int(entry["size"])],
			matrix.size() == int(entry["size"]))
		_check("%s : matrice inchangée" % label, _digest(matrix) == str(entry["sha"]))

	print("--- Structure ---")
	var m: Array = qr.encode("AMEAL1:vérification", -1)
	_check("matrice carrée", m.size() == m[0].size())
	# Un motif de repérage occupe les trois coins sauf en bas à droite ; sans eux
	# aucun lecteur ne trouve le code.
	_check("repère haut-gauche", _is_finder(m, 0, 0))
	_check("repère haut-droit", _is_finder(m, m.size() - 7, 0))
	_check("repère bas-gauche", _is_finder(m, 0, m.size() - 7))
	_check("module sombre présent", m[m.size() - 8][8] == true)
	# La ligne de synchronisation alterne strictement : c'est elle qui donne l'échelle.
	var timing_ok := true
	for i in range(8, m.size() - 8):
		if m[6][i] != (i % 2 == 0):
			timing_ok = false
	_check("ligne de synchronisation alternée", timing_ok)

	print("--- Capacité ---")
	_check("une charge de 988 o passe", not qr.encode("x".repeat(988), -1).is_empty())
	# Au-delà de la version 40, l'encodeur doit refuser plutôt que produire un code
	# tronqué qui se lirait mal.
	_check("une charge démesurée est refusée", qr.encode("x".repeat(40000), -1).is_empty())

	print("--- Les masques donnent des matrices distinctes ---")
	var seen := {}
	for mask in range(8):
		seen[_digest(qr.encode("AMEAL1:masques", mask))] = true
	_check("8 masques, 8 résultats", seen.size() == 8)

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _digest(matrix: Array) -> String:
	var flat := ""
	for row in matrix:
		for value in row:
			flat += "1" if value else "0"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(flat.to_utf8_buffer())
	return context.finish().hex_encode().substr(0, 16)

func _is_finder(matrix: Array, x: int, y: int) -> bool:
	for dy in range(7):
		for dx in range(7):
			var edge: bool = dx == 0 or dx == 6 or dy == 0 or dy == 6
			var core: bool = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4
			if matrix[y + dy][x + dx] != (edge or core):
				return false
	return true

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
