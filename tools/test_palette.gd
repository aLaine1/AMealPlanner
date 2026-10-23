extends SceneTree
## Invariants des couleurs de catégorie.
## godot --headless --path . --script res://tools/test_palette.gd
##
## Une palette se dégrade en silence : ajouter une teinte « qui va bien » peut la
## coller à une voisine sans que rien ne le signale, et le défaut ne se voit qu'au
## moment où deux recettes de catégories différentes se retrouvent côte à côte. Ces
## écarts sont donc mesurés, pas relus.
##
## ΔE = distance euclidienne dans OKLab ×100. La palette a été construite pour un
## minimum de 11,5 en vision normale et 6,1 en daltonisme simulé (Machado 2009) ;
## on vérifie qu'on n'est pas passé en dessous.

const MIN_NORMAL := 11.0
const MIN_CVD := 6.0
## Minimum courant pour un texte de la taille d'une initiale de pastille.
const MIN_INK_CONTRAST := 4.5
## Écart minimal entre deux fonds d'état d'une case (survol, réservée, normale, page).
const MIN_STATE := 4.0

## Machado–Oliveira–Fernandes 2009, sévérité 1.0, en RGB linéaire.
const PROTAN := [[0.152286, 1.052583, -0.204868],
	[0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
const DEUTAN := [[0.367322, 0.860646, -0.227968],
	[0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]

var _fails := 0

func _initialize() -> void:
	await process_frame
	var palette = root.get_node_or_null("/root/Palette")
	if palette == null:
		print("  [ÉCHEC] autoload Palette indisponible")
		quit(1)
		return

	print("--- Écart entre teintes ---")
	var colors: Array = palette.CATEGORY_PALETTE
	_check("dix teintes", colors.size() == 10)

	var worst_normal := INF
	var worst_cvd := INF
	var worst_pair := ""
	for i in range(colors.size()):
		for j in range(i + 1, colors.size()):
			var normal := _delta_e(colors[i], colors[j], [])
			var cvd: float = minf(_delta_e(colors[i], colors[j], PROTAN),
				_delta_e(colors[i], colors[j], DEUTAN))
			if normal < worst_normal:
				worst_normal = normal
				worst_pair = "%s / %s" % [colors[i].to_html(false), colors[j].to_html(false)]
			worst_cvd = minf(worst_cvd, cvd)
	print("  pire paire : %s (ΔE %.1f normale, %.1f daltonisme)" % [worst_pair, worst_normal, worst_cvd])
	_check("écart en vision normale >= %.0f" % MIN_NORMAL, worst_normal >= MIN_NORMAL)
	_check("écart en daltonisme >= %.0f" % MIN_CVD, worst_cvd >= MIN_CVD)

	print("--- Catégories connues ---")
	var seen := {}
	for name in palette.CATEGORY_COLORS:
		seen[palette.category_color(name).to_html(false)] = true
	_check("chacune sa propre teinte", seen.size() == palette.CATEGORY_COLORS.size())
	# Le repli neutre ne doit pas empiéter sur la palette : il signale une absence.
	_check("catégorie vide = repli neutre",
		palette.category_color("") == palette.TEXT_SECONDARY)

	print("--- Catégories libres ---")
	# Dérivée du nom : elle ne doit dépendre ni du moment, ni des autres catégories.
	var first: Color = palette.category_color("Gratin dauphinois")
	_check("stable d'un appel à l'autre", palette.category_color("Gratin dauphinois") == first)
	_check("insensible à la casse", palette.category_color("gratin dauphinois") == first)
	_check("insensible aux accents et espaces",
		palette.category_color("  Gratin Dauphinöis  ") != Color.TRANSPARENT)
	_check("prise dans la palette", palette.CATEGORY_PALETTE.has(first))

	# Les fonds d'ÉTAT d'une case, mesurés comme les teintes de catégorie. Ils ne
	# l'étaient pas, et l'écart s'est refermé sans bruit : le fond d'une case réservée
	# était à 0,74 ΔE du vert de survol, soit la même couleur à l'œil, là où deux
	# catégories s'imposent 11. Survoler une case réservée ne se voyait donc pas, et une
	# case réservée ressemblait à une case survolée.
	print("--- États d'une case ---")
	# Les trois fonds que peut prendre UNE MÊME case, et eux seuls. Le fond de page en
	# est exclu à dessein : une case ne l'affleure jamais: elle est toujours posée sur
	# un cadre qui porte son propre contour, et c'est ce contour qui l'en sépare.
	var states := {
		"survol": palette.CELL_HOVER,
		"réservée": palette.CELL_NOBOX,
		"normale": palette.SURFACE,
	}
	var keys: Array = states.keys()
	var worst_state := INF
	var worst_states := ""
	for i in range(keys.size()):
		for j in range(i + 1, keys.size()):
			var d := _delta_e(states[keys[i]], states[keys[j]], [])
			if d < worst_state:
				worst_state = d
				worst_states = "%s / %s" % [keys[i], keys[j]]
	print("  pire paire : %s (ΔE %.2f)" % [worst_states, worst_state])
	# Seuil volontairement plus bas que celui des catégories : ces fonds se lisent sur de
	# grandes surfaces contiguës, où l'œil repère un écart bien moindre qu'entre deux
	# pastilles de dix unités. Mais il reste très au-dessus de « la même couleur ».
	_check("états distinguables (ΔE >= %.0f)" % MIN_STATE, worst_state >= MIN_STATE)
	# Le texte des cases est le même partout : il doit rester lisible sur chacun.
	for name in states:
		_check("texte lisible sur case %s" % name,
			palette._contrast(states[name], palette.TEXT_PRIMARY) >= MIN_INK_CONTRAST)
	# Le contour d'une case réservée doit se détacher de son propre fond, sans quoi il
	# n'y a plus de contour du tout.
	_check("le contour d'une case réservée se voit sur son fond",
		_delta_e(palette.CELL_NOBOX_BORDER, palette.CELL_NOBOX, []) >= MIN_STATE)

	# Les barres de défilement sont visibles sur presque tous les écrans, et n'étaient
	# habillées nulle part : Godot y appliquait son gris ardoise par défaut. Rien ne le
	# signalait — un thème incomplet ne produit pas d'erreur, il produit du gris.
	print("--- Tout descend de la charte ---")
	var theme: Theme = palette.ui_theme
	for bar in ["VScrollBar", "HScrollBar"]:
		for part in ["scroll", "grabber", "grabber_highlight", "grabber_pressed"]:
			_check("%s / %s habillé" % [bar, part], theme.has_stylebox(part, bar))
	_check("le curseur des parts aussi", theme.has_stylebox("slider", "HSlider")
		and theme.has_stylebox("grabber_area", "HSlider"))
	# Et la teinte employée vient bien du schéma, au lieu d'être choisie à côté.
	var grabber := theme.get_stylebox("grabber", "VScrollBar") as StyleBoxFlat
	_check("la teinte du curseur est celle de la charte",
		grabber != null and grabber.bg_color.to_html(false)
			== palette.M3_OUTLINE_VARIANT.to_html(false))

	print("--- Chaque thème de couleur (2.0.7) ---")
	# Les invariants ci-dessus, et ceux dont dépend la bascule, mesurés sur CHAQUE thème :
	# un thème ajouté « qui va bien » peut rendre un écran illisible sans que rien ne le
	# signale avant qu'on l'ouvre dans ce thème-là.
	_check("quatre thèmes", palette.SCHEMES.size() == 4)
	for id in palette.SCHEMES:
		palette._apply_scheme(id)
		var tag := "%s :" % id
		var cell := {"survol": palette.CELL_HOVER, "réservée": palette.CELL_NOBOX,
			"normale": palette.CELL_BG}
		var worst := INF
		for a in cell:
			for b in cell:
				if a < b:
					worst = minf(worst, _delta_e(cell[a], cell[b], []))
		_check("%s états de case distinguables (ΔE %.1f)" % [tag, worst], worst >= MIN_STATE)
		_check("%s contour de case réservée visible" % tag,
			_delta_e(palette.CELL_NOBOX_BORDER, palette.CELL_NOBOX, []) >= MIN_STATE)
		for name in cell:
			_check("%s texte lisible sur case %s" % [tag, name],
				palette._contrast(cell[name], palette.TEXT_PRIMARY) >= MIN_INK_CONTRAST)
		# Encre blanche sur le primaire : en-tête, boutons pleins, onglet actif.
		_check("%s blanc lisible sur le primaire" % tag,
			palette._contrast(palette.PRIMARY, Color.WHITE) >= MIN_INK_CONTRAST)
		# Le secondaire ne porte du blanc qu'au survol et sur l'onglet survolé : seuil
		# des grands textes et éléments d'interface. Le vert d'origine est à 4,0.
		_check("%s blanc lisible sur le secondaire" % tag,
			palette._contrast(palette.SECONDARY, Color.WHITE) >= 3.0)
		_check("%s encre primaire lisible sur la surface" % tag,
			palette._contrast(palette.PRIMARY_INK, palette.SURFACE) >= MIN_INK_CONTRAST)
		_check("%s encre primaire lisible au survol" % tag,
			palette._contrast(palette.PRIMARY_INK, palette.CELL_HOVER) >= MIN_INK_CONTRAST)
		for bg in [["surface", palette.SURFACE], ["page", palette.BACKGROUND]]:
			_check("%s texte lisible sur la %s" % [tag, bg[0]],
				palette._contrast(palette.TEXT_PRIMARY, bg[1]) >= MIN_INK_CONTRAST)
			_check("%s texte secondaire lisible sur la %s" % [tag, bg[0]],
				palette._contrast(palette.TEXT_SECONDARY, bg[1]) >= MIN_INK_CONTRAST)
		# La case ordinaire doit se détacher de la carte qui la porte — par son ombre sur
		# fond clair (case et carte y sont du même blanc), par sa teinte sur fond sombre.
		_check("%s case ordinaire visible sur sa carte" % tag,
			palette.CELL_BG == palette.SURFACE and palette._relative_luminance(palette.SURFACE) > 0.5
			or _delta_e(palette.CELL_BG, palette.SURFACE, []) >= MIN_STATE)
		_check("%s erreur lisible sur la surface" % tag,
			palette._contrast(palette.ERROR, palette.SURFACE) >= MIN_INK_CONTRAST)
	palette._apply_scheme(palette.DEFAULT_SCHEME)

	print("--- Focus clavier, dans chaque thème (2.0.12) ---")
	# Le texte d'un bouton atteint par Tab devenait blanc (couleur non définie), et son
	# cadre prenait l'accent — vert d'eau dans le thème orange, sans rapport avec le reste.
	for id in palette.SCHEMES:
		palette._apply_scheme(id)
		var focus_theme: Theme = palette.make_theme()
		for variant in ["Button", "GhostButton", "OutlineButton", "DangerButton",
				"HeaderButton", "SegmentButton", "PillButton", "OptionButton", "CheckBox"]:
			_check("%s : %s garde sa couleur de texte au focus" % [id, variant],
				focus_theme.has_color("font_focus_color", variant)
				and focus_theme.get_color("font_focus_color", variant)
					== focus_theme.get_color("font_color", variant))
		for variant in ["Button", "OutlineButton", "OptionButton", "PillButton", "SegmentButton"]:
			var ring := focus_theme.get_stylebox("focus", variant) as StyleBoxFlat
			_check("%s : cadre de focus de %s aux couleurs du thème" % [id, variant],
				ring != null and ring.border_color == palette.PRIMARY_INK)
			# Décalé hors du contrôle : sur un bouton plein du même primaire, sinon invisible.
			_check("%s : cadre de focus de %s tracé autour, pas dessus" % [id, variant],
				ring != null and ring.expand_margin_left > 0.0)
	palette._apply_scheme(palette.DEFAULT_SCHEME)

	print("--- Changer de thème ---")
	var store := root.get_node("/root/DataStore")
	var emitted := [0]
	palette.scheme_changed.connect(func(): emitted[0] += 1)
	var before_theme: Theme = palette.ui_theme
	palette.set_scheme("bleu")
	_check("thème actif changé", palette.scheme == "bleu"
		and palette.PRIMARY == Color(palette.SCHEMES["bleu"]["PRIMARY"]))
	_check("mémorisé sur l'appareil",
		store.get_ui_preference(palette.SCHEME_PREFERENCE, "") == "bleu")
	_check("signalé pour reconstruire l'interface", emitted[0] == 1)
	var button := palette.ui_theme.get_stylebox("normal", "Button") as StyleBoxFlat
	_check("thème Godot reconstruit dans les nouvelles couleurs",
		palette.ui_theme != before_theme and button != null
		and button.bg_color == palette.PRIMARY)
	palette.set_scheme("bleu")
	_check("re-choisir le même thème ne reconstruit rien", emitted[0] == 1)
	palette.set_scheme("violet")
	_check("thème inconnu ignoré", palette.scheme == "bleu" and emitted[0] == 1)

	print("--- Paramètres > Apparence ---")
	var tab = load("res://ui/settings/AppearanceTab.gd").new()
	root.add_child(tab)
	await process_frame
	_check("une vignette par thème", tab.swatches.size() == palette.SCHEMES.size())
	var orange: Control = tab.swatches["orange"]
	orange.gui_input.emit(_press(Vector2(10, 10)))
	orange.gui_input.emit(_release(Vector2(10, 10)))
	_check("toucher une vignette choisit son thème", palette.scheme == "orange")
	tab.queue_free()
	palette.set_scheme(palette.DEFAULT_SCHEME)
	_check("retour au thème par défaut", palette.scheme == "vert"
		and store.get_ui_preference(palette.SCHEME_PREFERENCE, "") == "vert")

	print("--- Lisibilité de l'encre ---")
	var worst_ink := INF
	for color in colors:
		worst_ink = minf(worst_ink, palette._contrast(color, palette.ink_on(color)))
	print("  pire contraste encre/pastille : %.2f" % worst_ink)
	_check("initiale lisible sur toutes les teintes", worst_ink >= MIN_INK_CONTRAST)

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _press(at: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	return event

func _release(at: Vector2) -> InputEventMouseButton:
	var event := _press(at)
	event.pressed = false
	return event

## Distance OKLab ×100, éventuellement après simulation d'un daltonisme.
func _delta_e(a: Color, b: Color, matrix: Array) -> float:
	var la := _oklab(a, matrix)
	var lb := _oklab(b, matrix)
	return 100.0 * Vector3(la[0] - lb[0], la[1] - lb[1], la[2] - lb[2]).length()

func _oklab(color: Color, matrix: Array) -> Array:
	var r := _srgb_to_linear(color.r)
	var g := _srgb_to_linear(color.g)
	var b := _srgb_to_linear(color.b)
	if not matrix.is_empty():
		var sr: float = clampf(matrix[0][0] * r + matrix[0][1] * g + matrix[0][2] * b, 0.0, 1.0)
		var sg: float = clampf(matrix[1][0] * r + matrix[1][1] * g + matrix[1][2] * b, 0.0, 1.0)
		var sb: float = clampf(matrix[2][0] * r + matrix[2][1] * g + matrix[2][2] * b, 0.0, 1.0)
		r = sr
		g = sg
		b = sb
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return [
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
	]

func _srgb_to_linear(channel: float) -> float:
	return channel / 12.92 if channel <= 0.04045 else pow((channel + 0.055) / 1.055, 2.4)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
