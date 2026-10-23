extends RefCounted
## Encodeur QR code en GDScript pur — mode octet, correction de niveau M.
##
## Godot n'en fournit pas, et ajouter une extension native pour cela seul aurait
## alourdi l'export Android. L'encodage tient en quelques centaines de lignes ; c'est
## la LECTURE d'un QR qui serait coûteuse (caméra + décodeur), et on n'en a pas besoin :
## l'appareil photo du téléphone lit le code et affiche le texte, qu'on colle ensuite
## dans l'application.
##
## Les tables normatives viennent de QrTables.gd, généré depuis une bibliothèque de
## référence. La sortie est comparée bit à bit à cette même référence par test_qr.gd —
## un QR mal formé se voit à l'œil comme un QR valide, seule la comparaison le dit.
##
## Chargé par preload : cf. services/Uuid.gd.

const Tables := preload("res://services/QrTables.gd")

## Correction de niveau M : ~15 % de redondance. Compromis usuel entre densité du code
## et tolérance aux reflets ou aux écrans un peu sales.
const EC_LEVEL_M_BITS := 0b00

## Polynôme générateur du corps de Galois GF(256) utilisé par la norme.
const GF_PRIMITIVE := 0x11D

var _exp: PackedInt32Array   ## table des puissances de 2 dans GF(256)
var _log: PackedInt32Array   ## table inverse

func _init() -> void:
	_build_galois_tables()

# =====================================================================
# API
# =====================================================================

## Encode `text` et renvoie la matrice de modules : tableau de lignes, chaque ligne
## étant un tableau de bool (true = module noir). Renvoie [] si le texte est trop long.
##
## `forced_mask` : -1 pour choisir automatiquement le masque le moins pénalisé (le
## comportement normal) ; 0..7 pour l'imposer, ce dont se sert le test de comparaison.
func encode(text: String, forced_mask: int = -1) -> Array:
	var data := text.to_utf8_buffer()
	var version := _pick_version(data.size())
	if version < 0:
		return []

	var codewords := _build_codewords(data, version)
	var matrix := _build_matrix(version)
	var reserved := _reserved_mask(version)
	_place_codewords(matrix, reserved, codewords, version)

	var mask := forced_mask
	if mask < 0:
		mask = _pick_mask(matrix, reserved, version)
	_apply_mask(matrix, reserved, mask)
	_place_format(matrix, mask)
	if version >= 7:
		_place_version(matrix, version)
	return matrix

## Plus petite version capable de contenir `byte_count` octets, ou -1 si aucune.
func _pick_version(byte_count: int) -> int:
	for version in range(1, Tables.DATA_CAPACITY.size()):
		# En-tête : 4 bits de mode + indicateur de longueur (8 bits jusqu'à la
		# version 9, 16 au-delà). Arrondi à l'octet supérieur.
		var header_bits := 4 + (8 if version <= 9 else 16)
		var needed := byte_count + int(ceil(header_bits / 8.0))
		if needed <= int(Tables.DATA_CAPACITY[version]):
			return version
	return -1

# =====================================================================
# Corps de Galois et correction d'erreur
# =====================================================================

func _build_galois_tables() -> void:
	_exp.resize(512)
	_log.resize(256)
	var value := 1
	for i in range(255):
		_exp[i] = value
		_log[value] = i
		value <<= 1
		if value & 0x100:
			value ^= GF_PRIMITIVE
	for i in range(255, 512):
		_exp[i] = _exp[i - 255]

func _gf_mul(a: int, b: int) -> int:
	if a == 0 or b == 0:
		return 0
	return _exp[_log[a] + _log[b]]

## Polynôme générateur de degré `degree`, pour la correction de Reed-Solomon.
func _generator_poly(degree: int) -> PackedInt32Array:
	var poly := PackedInt32Array([1])
	for i in range(degree):
		var next := PackedInt32Array()
		next.resize(poly.size() + 1)
		for j in range(poly.size()):
			next[j] ^= _gf_mul(poly[j], 1)
			next[j + 1] ^= _gf_mul(poly[j], _exp[i])
		poly = next
	return poly

func _error_codewords(block: PackedByteArray, count: int) -> PackedByteArray:
	var generator := _generator_poly(count)
	var remainder := PackedInt32Array()
	remainder.resize(block.size() + count)
	for i in range(block.size()):
		remainder[i] = block[i]

	for i in range(block.size()):
		var factor := remainder[i]
		if factor == 0:
			continue
		for j in range(generator.size()):
			remainder[i + j] ^= _gf_mul(generator[j], factor)

	var out := PackedByteArray()
	for i in range(count):
		out.append(remainder[block.size() + i])
	return out

# =====================================================================
# Flux binaire et entrelacement
# =====================================================================

func _build_codewords(data: PackedByteArray, version: int) -> PackedByteArray:
	var bits: Array[int] = []
	_append_bits(bits, 0b0100, 4)                              # mode octet
	_append_bits(bits, data.size(), 8 if version <= 9 else 16) # longueur
	for byte in data:
		_append_bits(bits, byte, 8)

	var capacity := int(Tables.DATA_CAPACITY[version]) * 8
	# Terminateur : jusqu'à 4 bits nuls, tronqué si la capacité est atteinte.
	for i in range(mini(4, capacity - bits.size())):
		bits.append(0)
	while bits.size() % 8 != 0:
		bits.append(0)

	var payload := PackedByteArray()
	for i in range(0, bits.size(), 8):
		var byte := 0
		for j in range(8):
			byte = (byte << 1) | bits[i + j]
		payload.append(byte)
	# Remplissage normatif : alternance 0xEC / 0x11 jusqu'à saturation.
	var pad := [0xEC, 0x11]
	var index := 0
	while payload.size() < int(Tables.DATA_CAPACITY[version]):
		payload.append(pad[index % 2])
		index += 1

	return _interleave(payload, version)

func _append_bits(bits: Array[int], value: int, count: int) -> void:
	for i in range(count - 1, -1, -1):
		bits.append((value >> i) & 1)

## Découpe en blocs, calcule la correction de chaque bloc, puis entrelace : la norme
## répartit les codewords de tous les blocs pour qu'une salissure locale n'efface
## jamais un bloc entier.
func _interleave(payload: PackedByteArray, version: int) -> PackedByteArray:
	var spec: Array = Tables.RS_BLOCKS_M[version]
	var data_blocks: Array = []
	var ec_blocks: Array = []
	var offset := 0
	for entry in spec:
		var total: int = entry[0]
		var data_count: int = entry[1]
		var block := payload.slice(offset, offset + data_count)
		offset += data_count
		data_blocks.append(block)
		ec_blocks.append(_error_codewords(block, total - data_count))

	var out := PackedByteArray()
	var longest := 0
	for block in data_blocks:
		longest = maxi(longest, block.size())
	for i in range(longest):
		for block in data_blocks:
			if i < block.size():
				out.append(block[i])

	longest = 0
	for block in ec_blocks:
		longest = maxi(longest, block.size())
	for i in range(longest):
		for block in ec_blocks:
			if i < block.size():
				out.append(block[i])
	return out

# =====================================================================
# Construction de la matrice
# =====================================================================

func _size_for(version: int) -> int:
	return version * 4 + 17

func _blank(version: int) -> Array:
	var size := _size_for(version)
	var matrix: Array = []
	for y in range(size):
		var row: Array = []
		row.resize(size)
		row.fill(false)
		matrix.append(row)
	return matrix

func _build_matrix(version: int) -> Array:
	var matrix := _blank(version)
	var size := _size_for(version)

	for origin in [[0, 0], [size - 7, 0], [0, size - 7]]:
		_draw_finder(matrix, origin[0], origin[1])

	# Motifs de synchronisation, une ligne et une colonne alternées.
	for i in range(8, size - 8):
		matrix[6][i] = (i % 2 == 0)
		matrix[i][6] = (i % 2 == 0)

	for row in Tables.ALIGNMENT_POSITIONS[version]:
		for column in Tables.ALIGNMENT_POSITIONS[version]:
			if _overlaps_finder(int(row), int(column), size):
				continue
			_draw_alignment(matrix, int(row), int(column))

	matrix[size - 8][8] = true   # module sombre, toujours noir
	return matrix

func _draw_finder(matrix: Array, x: int, y: int) -> void:
	for dy in range(7):
		for dx in range(7):
			var edge: bool = dx == 0 or dx == 6 or dy == 0 or dy == 6
			var core: bool = dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4
			matrix[y + dy][x + dx] = edge or core

func _draw_alignment(matrix: Array, row: int, column: int) -> void:
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var ring: bool = absi(dx) == 2 or absi(dy) == 2
			matrix[row + dy][column + dx] = ring or (dx == 0 and dy == 0)

func _overlaps_finder(row: int, column: int, size: int) -> bool:
	return (row < 8 and column < 8) \
		or (row < 8 and column > size - 9) \
		or (row > size - 9 and column < 8)

## Modules réservés aux motifs fixes : ni porteurs de données, ni masqués.
func _reserved_mask(version: int) -> Array:
	var reserved := _blank(version)
	var size := _size_for(version)

	for origin in [[0, 0], [size - 8, 0], [0, size - 8]]:
		for dy in range(9):
			for dx in range(9):
				var x: int = origin[0] + dx
				var y: int = origin[1] + dy
				if x < size and y < size:
					reserved[y][x] = true

	for i in range(size):
		reserved[6][i] = true
		reserved[i][6] = true

	for row in Tables.ALIGNMENT_POSITIONS[version]:
		for column in Tables.ALIGNMENT_POSITIONS[version]:
			if _overlaps_finder(int(row), int(column), size):
				continue
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					reserved[int(row) + dy][int(column) + dx] = true

	if version >= 7:
		for i in range(6):
			for j in range(3):
				reserved[size - 11 + j][i] = true
				reserved[i][size - 11 + j] = true
	return reserved

## Parcours en zigzag, de bas en haut puis de haut en bas, par colonnes de deux.
func _place_codewords(matrix: Array, reserved: Array, codewords: PackedByteArray,
		version: int) -> void:
	var size := _size_for(version)
	var bit_index := 0
	var total_bits := codewords.size() * 8
	var upward := true
	var column := size - 1

	while column > 0:
		if column == 6:
			column -= 1   # la colonne de synchronisation ne porte pas de données
		for i in range(size):
			var row: int = (size - 1 - i) if upward else i
			for offset in range(2):
				var x := column - offset
				if reserved[row][x]:
					continue
				var bit := false
				if bit_index < total_bits:
					bit = (codewords[bit_index >> 3] >> (7 - (bit_index & 7))) & 1 == 1
				matrix[row][x] = bit
				bit_index += 1
		upward = not upward
		column -= 2

# =====================================================================
# Masques
# =====================================================================

func _mask_applies(mask: int, row: int, column: int) -> bool:
	match mask:
		0: return (row + column) % 2 == 0
		1: return row % 2 == 0
		2: return column % 3 == 0
		3: return (row + column) % 3 == 0
		4: return (int(row / 2.0) + int(column / 3.0)) % 2 == 0
		5: return (row * column) % 2 + (row * column) % 3 == 0
		6: return ((row * column) % 2 + (row * column) % 3) % 2 == 0
		_: return ((row + column) % 2 + (row * column) % 3) % 2 == 0

func _apply_mask(matrix: Array, reserved: Array, mask: int) -> void:
	for row in range(matrix.size()):
		for column in range(matrix.size()):
			if reserved[row][column]:
				continue
			if _mask_applies(mask, row, column):
				matrix[row][column] = not matrix[row][column]

## Choisit le masque le moins pénalisé, selon les quatre règles de la norme.
func _pick_mask(matrix: Array, reserved: Array, version: int) -> int:
	var best := 0
	var best_score := -1
	for mask in range(8):
		var candidate := _duplicate(matrix)
		_apply_mask(candidate, reserved, mask)
		_place_format(candidate, mask)
		if version >= 7:
			_place_version(candidate, version)
		var score := _penalty(candidate)
		if best_score < 0 or score < best_score:
			best_score = score
			best = mask
	return best

func _duplicate(matrix: Array) -> Array:
	var out: Array = []
	for row in matrix:
		out.append(row.duplicate())
	return out

func _penalty(matrix: Array) -> int:
	var size := matrix.size()
	var score := 0

	# Règle 1 : séries de 5 modules identiques ou plus, en ligne puis en colonne.
	for axis in range(2):
		for i in range(size):
			var run := 1
			for j in range(1, size):
				var current: bool = matrix[i][j] if axis == 0 else matrix[j][i]
				var previous: bool = matrix[i][j - 1] if axis == 0 else matrix[j - 1][i]
				if current == previous:
					run += 1
				else:
					if run >= 5:
						score += 3 + (run - 5)
					run = 1
			if run >= 5:
				score += 3 + (run - 5)

	# Règle 2 : blocs 2x2 uniformes.
	for row in range(size - 1):
		for column in range(size - 1):
			var value: bool = matrix[row][column]
			if value == matrix[row][column + 1] \
					and value == matrix[row + 1][column] \
					and value == matrix[row + 1][column + 1]:
				score += 3

	# Règle 3 : motifs ressemblant à un motif de repérage.
	var pattern_a := [true, false, true, true, true, false, true, false, false, false, false]
	var pattern_b := [false, false, false, false, true, false, true, true, true, false, true]
	for i in range(size):
		for j in range(size - 10):
			var horizontal: Array = []
			var vertical: Array = []
			for k in range(11):
				horizontal.append(matrix[i][j + k])
				vertical.append(matrix[j + k][i])
			if horizontal == pattern_a or horizontal == pattern_b:
				score += 40
			if vertical == pattern_a or vertical == pattern_b:
				score += 40

	# Règle 4 : déséquilibre entre modules noirs et blancs.
	var dark := 0
	for row in matrix:
		for value in row:
			if value:
				dark += 1
	var ratio := int(abs(dark * 100.0 / (size * size) - 50) / 5.0)
	score += ratio * 10
	return score

# =====================================================================
# Informations de format et de version
# =====================================================================

func _place_format(matrix: Array, mask: int) -> void:
	var size := matrix.size()
	var value := (EC_LEVEL_M_BITS << 3) | mask
	var bits := value << 10
	# Code BCH(15,5) imposé par la norme.
	for i in range(4, -1, -1):
		if bits & (1 << (i + 10)):
			bits ^= 0b10100110111 << i
	bits = ((value << 10) | bits) ^ 0b101010000010010

	for i in range(15):
		var bit: bool = (bits >> i) & 1 == 1
		if i < 6:
			matrix[i][8] = bit
		elif i == 6:
			matrix[7][8] = bit
		elif i == 7:
			matrix[8][8] = bit
		elif i == 8:
			matrix[8][7] = bit
		else:
			matrix[8][14 - i] = bit

		if i < 8:
			matrix[8][size - 1 - i] = bit
		else:
			matrix[size - 15 + i][8] = bit

func _place_version(matrix: Array, version: int) -> void:
	var size := matrix.size()
	var bits := version << 12
	# Code BCH(18,6).
	for i in range(5, -1, -1):
		if bits & (1 << (i + 12)):
			bits ^= 0b1111100100101 << i
	bits = (version << 12) | bits

	for i in range(18):
		var bit: bool = (bits >> i) & 1 == 1
		var row := int(i / 3.0)
		var column := i % 3
		matrix[size - 11 + column][row] = bit
		matrix[row][size - 11 + column] = bit
