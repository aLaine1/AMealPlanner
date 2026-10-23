extends SceneTree
## Deux repas par jour : une journée reste UNE case.
## godot --headless --path . --script res://tools/test_day_grouping.gd
##
## En scindant les journées, la 1.8.0 a posé quatorze cartes identiques là où il y avait
## quatorze jours. Rien ne disait plus où finissait une journée : l'œil ne voyait qu'une
## suite de repas, dont il fallait recompter les paires pour savoir lequel était le soir.
##
## Ce qui se vérifie ici est un ÉCART, et non une apparence : ce qui sépare midi du soir
## doit rester nettement moindre que ce qui sépare deux jours. C'est la seule formulation
## de « visuellement dans la même case » qu'une machine puisse contrôler, et c'est aussi
## la propriété qui se perdrait sans bruit à la première retouche de mise en page.

const Photo := preload("res://services/RecipePhoto.gd")

const DESKTOP := Vector2i(1280, 860)
const PHONE := Vector2i(412, 915)

var _fails := 0
var _store: Node = null

func _initialize() -> void:
	await process_frame
	_store = root.get_node("/root/DataStore")

	await _test_grid_gaps()
	await _test_phone_rows()
	await _test_single_meal_unchanged()
	await _test_name_over_photo()
	await _test_phone_scroll()

	print("")
	print("Journées groupées." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## Renvoie null si l'écran ne se construit pas — l'appelant s'arrête alors, l'échec
## ayant déjà été compté.
func _open(size: Vector2i, meals: int) -> Control:
	root.size = size
	await process_frame
	_store.set_plan_shape(2, 5, meals)
	var tab: Control = load("res://ui/planning/PlanningTab.gd").new()
	# Ancrage explicite : un Control ajouté à la racine d'une fenêtre reste de taille
	# NULLE sans lui. Les mesures relatives — écarts entre cases — y survivaient, mais le
	# ScrollContainer faisait 220 × 0, et aucun geste ne pouvait l'atteindre.
	if tab == null:
		# Un écran qui ne compile plus renvoie null, et TOUTES les épreuves qui suivent
		# étaient alors sautées en silence : la suite s'affichait verte sur un onglet
		# inexistant. Une suite muette doit échouer, pas réussir.
		_check("l'onglet Calendrier se construit", false)
		return null
	tab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(tab)
	await process_frame
	await process_frame
	return tab

## Sur la grille, l'écart entre les deux repas d'un jour contre l'écart entre deux jours
## d'une même colonne.
func _test_grid_gaps() -> void:
	print("--- Grille : l'écart dit ce qui va ensemble ---")
	var tab := await _open(DESKTOP, 2)
	if tab == null:
		return
	var cells: Array = tab._cells
	_check("28 cases pour 14 jours", cells.size() == 28)
	if cells.size() < 28:
		tab.queue_free()
		return

	# Cases 0 et 1 : midi et soir du même jour. Cases 1 et 15 : deux jours consécutifs
	# d'une même colonne (sept jours d'écart, donc la ligne du dessous).
	var midi: Rect2 = cells[0].get_global_rect()
	var soir: Rect2 = cells[1].get_global_rect()
	var meal_gap := soir.position.y - midi.end.y
	var next_week: Rect2 = cells[15].get_global_rect()
	var day_gap := next_week.position.y - soir.end.y

	_check("midi est au-dessus du soir", soir.position.y > midi.position.y)
	_check("les deux repas se touchent presque (%.0f)" % meal_gap, meal_gap <= 2.0)
	_check("deux jours restent nettement écartés (%.0f)" % day_gap, day_gap >= 6.0)
	_check("l'écart d'un jour est le plus grand des deux", day_gap > meal_gap)

	# Un seul cadre porte les deux moitiés — c'est LUI qui est la case.
	var frame: Node = cells[0].get_parent().get_parent().get_parent()
	_check("les deux moitiés partagent un cadre",
		frame is PanelContainer and frame == cells[1].get_parent().get_parent().get_parent())
	_check("les moitiés renoncent à leur propre cadre",
		cells[0].grouped and cells[1].grouped)
	# Mais la JOURNÉE, elle, en garde un. L'ombre seule ne suffisait pas : un blanc cassé
	# posé sur une page crème n'a pas de bord, et quatorze journées sans bord font une
	# colonne continue — l'inverse de ce que le regroupement cherche à montrer.
	var day_style: StyleBox = (frame as PanelContainer).get_theme_stylebox("panel")
	_check("la journée garde un contour",
		day_style is StyleBoxFlat and day_style.border_width_top >= 1)
	tab.queue_free()
	await process_frame

## Sur téléphone, une LIGNE par jour : le jour nommé une fois, chaque moitié disant
## lequel des deux repas elle porte.
func _test_phone_rows() -> void:
	print("--- Téléphone : une ligne par jour ---")
	var tab := await _open(PHONE, 2)
	if tab == null:
		return
	var cells: Array = tab._cells
	if cells.size() < 4:
		_check("cases construites", false)
		tab.queue_free()
		return
	var frame_a = cells[0].get_parent().get_parent().get_parent()
	var frame_b = cells[1].get_parent().get_parent().get_parent()
	var frame_c = cells[2].get_parent().get_parent().get_parent()
	_check("midi et soir dans le même cadre", frame_a == frame_b)
	_check("le jour suivant en a un autre", frame_a != frame_c)

	# La colonne de gauche ne porte QUE le jour, une fois par jour. « Midi » et « Soir »
	# y occupaient quarante unités dans chaque cadre pour redire ce que l'ordre dit déjà,
	# sur un écran qui en compte 412.
	var texts := []
	for label in tab._day_labels:
		texts.append(label.text)
	var days: Array = _store.plan_day_labels()
	_check("une étiquette par jour", texts.size() == days.size(), str(texts.size()))
	_check("et c'est le jour qu'elle nomme", texts == days, str(texts.slice(0, 3)))
	var meal_names := 0
	for name in _store.MEAL_NAMES:
		if texts.has(name):
			meal_names += 1
	_check("aucun nom de repas dans la colonne", meal_names == 0)

	# La marque des soirs réservés doit survivre à la disparition des étiquettes de
	# repas : elle était portée par le RANG de l'étiquette, qui ne veut plus rien dire
	# dès que la colonne compte une ligne par jour et non par repas.
	var reserved: Array[int] = [1]      # le soir du premier jour
	tab._transport_slots = reserved
	tab._apply_transport_slots()
	# Par le nœud d'autoload : les couleurs sont celles du thème actif (2.0.7), des
	# variables qu'un script lancé par --script ne peut pas résoudre à la compilation.
	var palette := root.get_node("/root/Palette")
	_check("le jour d'un soir réservé est mis en avant",
		tab._day_labels[0].get_theme_color("font_color") == palette.PRIMARY_INK)
	_check("les autres jours restent neutres",
		tab._day_labels[1].get_theme_color("font_color") == palette.TEXT_SECONDARY)
	tab.queue_free()
	await process_frame

## Le mode un repas par jour ne doit rien avoir changé : c'est celui de tous les comptes
## existants, et le seul dont on sache qu'il convenait.
func _test_single_meal_unchanged() -> void:
	print("--- Un repas par jour : intact ---")
	var tab := await _open(PHONE, 1)
	if tab == null:
		return
	var cells: Array = tab._cells
	_check("14 cases", cells.size() == 14)
	if cells.is_empty():
		tab.queue_free()
		return
	_check("aucune case n'est groupée", not cells[0].grouped)
	_check("ni compacte", not cells[0].compact)
	var labels := []
	for label in tab._day_labels:
		labels.append(label.text)
	_check("la colonne porte les jours", labels == _store.plan_slot_labels(), str(labels.slice(0, 3)))
	tab.queue_free()
	await process_frame

## Le nom sur la photo, et le voile qui le rend lisible.
func _test_name_over_photo() -> void:
	print("--- Le nom se pose sur la photo ---")
	var cell = load("res://ui/planning/MealCell.gd").new()
	cell.compact = true
	root.add_child(cell)
	await process_frame

	# Sans photo, rien à voiler : un fond blanc sur le fond de la case ne ferait qu'un
	# rectangle plus clair au milieu, sans rien signifier.
	cell.set_recipe_name("")
	_check("case vide : aucun voile",
		cell._label_panel.get_theme_stylebox("panel") is StyleBoxEmpty)

	var with_photo := _recipe_with_photo()
	cell.set_recipe_name(with_photo)
	await process_frame
	_check("la photo passe en fond, sous le nom",
		cell._photo != null and cell._photo.get_parent() == cell
		and cell.get_child(0) == cell._photo)
	var sb: StyleBox = cell._label_panel.get_theme_stylebox("panel")
	_check("le nom reçoit un voile clair", sb is StyleBoxFlat and sb.bg_color.a > 0.5)
	_check("et le voile laisse deviner l'image", sb is StyleBoxFlat and sb.bg_color.a < 1.0)
	# Le voile épouse le nom : étiré, il masquerait la photo qu'il est censé laisser voir.
	_check("le voile n'occupe pas toute la hauteur",
		cell._label_panel.size_flags_vertical == Control.SIZE_SHRINK_CENTER)
	# Et il est bien AU MILIEU. Dans une boîte verticale, le drapeau ci-dessus n'y
	# suffit pas : la boîte empile depuis le haut, et le nom se posait au sommet de la
	# case avec la photo tout en dessous. Vérifié en géométrie, seul terrain où la
	# différence existe.
	cell.custom_minimum_size = Vector2(180, 120)
	cell._box.vertical = true
	cell.size = Vector2(180, 120)
	for _i in range(3):
		await process_frame
	var veil: Rect2 = cell._label_panel.get_global_rect()
	var cell_rect: Rect2 = cell.get_global_rect()
	var above := veil.position.y - cell_rect.position.y
	var below := cell_rect.end.y - veil.end.y
	_check("le nom est centré sur la photo (%.0f au-dessus, %.0f en dessous)"
		% [above, below], absf(above - below) <= 2.0)

	# Retour à une recette sans photo : le voile doit partir avec elle.
	cell.set_recipe_name("")
	_check("plus de photo, plus de voile",
		cell._label_panel.get_theme_stylebox("panel") is StyleBoxEmpty)
	cell.queue_free()
	await process_frame

## Le jeu d'essai n'embarque aucune photo — elles pèsent, et les tests partent d'une base
## vierge. On en fabrique donc une : c'est la PRÉSENCE d'une photo qui décide de tout ce
## qui est vérifié ici.
## Le calendrier doit encore DÉFILER au doigt une fois les journées encadrées.
##
## Le geste passe par le vrai chemin d'entrée du moteur, dans la vraie arborescence de
## l'onglet. C'est tout l'enjeu : la suite tactile existante monte ses cases dans une
## simple colonne, forme que l'application n'a plus. Elle restait donc verte pendant que
## le cadre de journée — un `PanelContainer`, donc `MOUSE_FILTER_STOP` par défaut —
## avalait le contact avant qu'il n'atteigne le conteneur.
##
## `emulate_touch_from_mouse` rend `is_touchscreen_available()` vrai, et c'est lui qui
## active le panoramique au doigt : sans cela, la régression serait invisible hors d'un
## appareil.
func _test_phone_scroll() -> void:
	print("--- Le calendrier défile encore au doigt ---")
	var was_emulating := Input.is_emulating_touch_from_mouse()
	Input.set_emulate_touch_from_mouse(true)
	var tab := await _open(PHONE, 2)
	if tab == null:
		return
	# Un planning rempli : une liste vide n'a rien à faire défiler.
	var recipes: Array = _store.get_all_recipe_objects()
	for index in range(tab._cells.size()):
		tab._cells[index].set_recipe_name(str(recipes[index % recipes.size()].nom))
	for _i in range(3):
		await process_frame

	var scroll: ScrollContainer = tab._list_view
	_check("il y a de quoi défiler",
		scroll.get_v_scroll_bar().max_value > scroll.size.y, "%d pour %d"
		% [scroll.get_v_scroll_bar().max_value, scroll.size.y])

	# Le balayage part d'une CASE, et non d'un interstice : sur un écran de téléphone les
	# cases occupent presque toute la surface, c'est de là que part tout geste réel.
	var start: Vector2 = tab._cells[1].get_global_rect().get_center()
	scroll.scroll_vertical = 0
	await _touch(start, true)
	await _swipe(start, start - Vector2(0, 160))
	await _touch(start - Vector2(0, 160), false)
	_check("un balayage parti d'une case fait défiler (%d)" % scroll.scroll_vertical,
		scroll.scroll_vertical > 0)

	# Et le cadre ne doit pas non plus intercepter le toucher qui ouvre le menu.
	# La liste est ramenée en haut d'abord : après le balayage ci-dessus, la première
	# case est sortie de l'écran et la viser reviendrait à viser le vide.
	scroll.scroll_vertical = 0
	for _i in range(3):
		await process_frame
	var menus := []
	tab._cells[0].context_requested.connect(func(_c, _p): menus.append(1))
	var spot: Vector2 = tab._cells[0].get_global_rect().get_center()
	await _touch(spot, true)
	await _touch(spot, false)
	_check("un toucher franc ouvre encore le menu de la case", menus.size() == 1)

	tab.queue_free()
	Input.set_emulate_touch_from_mouse(was_emulating)
	await process_frame

func _touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.position = at
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame
	await process_frame

## Une image par pas : le panoramique se joue au fil des images, un saut unique ne dirait
## rien de sa course.
func _swipe(from: Vector2, to: Vector2) -> void:
	var previous := from
	for step in range(1, 7):
		var point := from.lerp(to, float(step) / 6.0)
		var event := InputEventScreenDrag.new()
		event.position = point
		event.relative = point - previous
		previous = point
		Input.parse_input_event(event)
		await process_frame

func _recipe_with_photo() -> String:
	for recipe in _store.get_all_recipe_objects():
		if _store.get_photo_thumb(recipe.id) != null:
			return recipe.nom
	var image := Image.create(320, 240, false, Image.FORMAT_RGB8)
	image.fill(Color(0.9, 0.85, 0.6))
	var prepared: Dictionary = Photo.from_image(image, Rect2i(0, 0, 320, 240))
	var target = _store.get_all_recipe_objects()[0]
	_store.set_recipe_photo(target.id, prepared.image, prepared.thumb)
	return target.nom

func _check(label: String, ok: bool, detail := "") -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s%s" % ["OK" if ok else "ÉCHEC", label,
		"" if detail == "" or ok else "  → " + detail])
