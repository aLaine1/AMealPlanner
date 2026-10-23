extends SceneTree
## Le sélecteur de recette au toucher : défilement, filtre, lignes illustrées.
## godot --headless --path . --script res://tools/test_picker.gd
##
## Cette liste-ci était la seule de l'application restée en boutons. Un `Button` traite
## le clic pour son propre compte et consomme l'événement : le `ScrollContainer` ne
## voyait jamais le glissement, et la liste refusait de défiler au doigt. Le remède est
## connu — il a déjà été appliqué à la liste de courses, aux cartes de la bibliothèque
## et aux cases du calendrier —, et c'est précisément pour cela qu'il faut le vérifier
## ici : rien ne signale une liste qu'on a oublié de convertir.

const PHONE_WIDTH := 412

var _fails := 0

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(PHONE_WIDTH, 915)
	await process_frame

	var store = root.get_node("/root/DataStore")
	var names: Array = store.get_all_recipe_names()

	await _test_scrollable(names)
	await _test_filter(names)
	await _test_plain_mode()

	print("")
	print("Sélecteur conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _open(names: Array, rich: bool) -> Window:
	var picker = load("res://ui/components/PickerPopup.gd").new()
	picker.recipe_entries = rich
	picker.setup("Choisir une recette", names, str(names[0]) if not names.is_empty() else "", true)
	root.add_child(picker)
	await process_frame
	await process_frame
	return picker

## Une ligne ne doit RIEN consommer : sans quoi le conteneur ne défile pas.
func _test_scrollable(names: Array) -> void:
	print("--- La liste défile au doigt ---")
	var picker := await _open(names, true)
	var rows := _rows(picker)
	_check("la liste est peuplée", rows.size() == names.size())
	if rows.is_empty():
		picker.queue_free()
		return

	var blocking := 0
	var buttons := 0
	for row in rows:
		if row.mouse_filter == Control.MOUSE_FILTER_STOP:
			blocking += 1
		if row is Button:
			buttons += 1
	# Le compte, et non le premier venu : c'est une ligne oubliée au milieu de la liste
	# qui rendrait le défilement capricieux plutôt qu'impossible — bien plus difficile à
	# diagnostiquer depuis un téléphone.
	_check("aucune ligne ne consomme le geste", blocking == 0)
	_check("aucune ligne n'est un bouton", buttons == 0)

	# Le choix ne part qu'au relâchement SUR PLACE : un balayage amorcé sur une ligne
	# remplirait sinon la case au passage, en cherchant simplement à lire la suite.
	var chosen := []
	picker.chosen.connect(func(n): chosen.append(n))
	_swipe(rows[0])
	_check("un balayage ne choisit rien", chosen.is_empty())
	_tap(rows[0])
	_check("un toucher franc choisit", chosen == [str(names[0])])
	picker.queue_free()
	await process_frame

func _test_filter(names: Array) -> void:
	print("--- Filtre par catégorie et recherche ---")
	var picker := await _open(names, true)
	_check("le filtre par catégorie est présent", picker._filter != null)
	if picker._filter == null:
		picker.queue_free()
		return
	# Les lignes portent la photo ou la pastille de catégorie : le sélecteur montre la
	# même chose que la bibliothèque, ce qui est tout l'objet de l'homogénéisation.
	var first: Control = _rows(picker)[0]
	_check("la ligne porte un contenu illustré",
		first.get_child_count() > 0 and first.get_child(0).get_child_count() >= 2)

	var store = root.get_node("/root/DataStore")
	var categories: Array = store.get_all_recipe_categories()
	if not categories.is_empty():
		var wanted := str(categories[0])
		picker._filter._selected = {wanted: true}
		picker._refresh()
		await process_frame
		var shown := _rows(picker).size()
		var expected := 0
		for n in names:
			var r = store.get_recipe_by_name(n)
			if r != null and r.categories.has(wanted):
				expected += 1
		_check("une catégorie cochée restreint la liste (%d)" % shown, shown == expected)

		# Le point qui manquait : les deux filtres s'appliquent ENSEMBLE. Le texte seul
		# aurait repeuplé la liste et fait réapparaître les recettes exclues.
		picker._search.text = "zzzz-introuvable"
		picker._refresh()
		await process_frame
		_check("la recherche ne passe pas outre la catégorie", _rows(picker).size() == 0)
	picker.queue_free()
	await process_frame

## Les petits déjeuners n'ont ni photo ni catégorie : le sélecteur doit rester la simple
## liste de libellés qu'il était, sans barre de filtre vide en haut de l'écran.
func _test_plain_mode() -> void:
	print("--- Mode simple (petits déjeuners) ---")
	var picker := await _open(["Tartines", "Porridge"], false)
	_check("pas de filtre par catégorie", picker._filter == null)
	_check("les deux entrées sont là", _rows(picker).size() == 2)
	_check("les lignes ne consomment toujours rien",
		_rows(picker)[0].mouse_filter != Control.MOUSE_FILTER_STOP)
	picker.queue_free()
	await process_frame

func _rows(picker: Window) -> Array:
	var rows := []
	for child in picker._list.get_children():
		if child is PanelContainer:
			rows.append(child)
	return rows

func _tap(row: Control) -> void:
	_press(row, Vector2(10, 10), true)
	_press(row, Vector2(10, 10), false)

func _swipe(row: Control) -> void:
	_press(row, Vector2(10, 10), true)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(10, 90)
	row.gui_input.emit(motion)
	_press(row, Vector2(10, 90), false)

func _press(row: Control, at: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.position = at
	row.gui_input.emit(event)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
