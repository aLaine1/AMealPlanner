extends SceneTree
## Saisie d'une recette au clavier (2.0.11) : saison, suggestions, enchaînement des lignes.
## godot --headless --path . --script res://tools/test_recipe_keyboard.gd
##
## Les touches sont remises directement aux contrôles (`_input`, `gui_input`) plutôt qu'au
## viewport : c'est la logique de navigation qui est vérifiée, pas l'acheminement des
## événements par le moteur.

var _fails := 0
var _popup: Window

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(1280, 800)
	await process_frame
	var palette := root.get_node("/root/Palette")

	print("--- Saison : lisible et réglable au clavier ---")
	var theme: Theme = palette.ui_theme
	_check("texte lisible quand le champ a le focus",
		theme.has_color("font_focus_color", "OptionButton")
		and theme.get_color("font_focus_color", "OptionButton") == palette.TEXT_PRIMARY)

	_popup = load("res://ui/recipes/RecipePopup.gd").new()
	_popup.recipe = null
	_popup.editable = true
	root.add_child(_popup)
	for _i in range(4):
		await process_frame

	var season: OptionButton = _popup._season
	# ← / → et non plus ↑ / ↓ (2.0.13) : ceux-ci passent désormais d'un champ à l'autre.
	season.select(0)
	season.gui_input.emit(_key(KEY_RIGHT))
	_check("→ passe à la valeur suivante", season.selected == 1)
	season.gui_input.emit(_key(KEY_RIGHT))
	season.gui_input.emit(_key(KEY_RIGHT))
	_check("…et s'arrête à la dernière, sans boucler", season.selected == season.item_count - 1)
	season.gui_input.emit(_key(KEY_LEFT))
	_check("← revient en arrière", season.selected == season.item_count - 2)
	season.select(0)
	season.gui_input.emit(_key(KEY_DOWN))
	_check("↓ ne change plus la valeur", season.selected == 0)
	_check("la liste ne s'est pas ouverte", not season.get_popup().visible)

	print("--- Saison, liste ouverte : Tab la parcourt et revient en haut (2.0.12) ---")
	var menu: PopupMenu = season.get_popup()
	season.select(0)
	season.show_popup()
	await process_frame
	_check("(préparation) liste ouverte", menu.visible)
	menu.set_focused_item(0)
	# Par la fenêtre RACINE, comme au clavier : le menu est une sous-fenêtre, rattachée à
	# elle et non au formulaire qui l'a ouvert — c'est donc elle qui lui achemine la touche.
	root.push_input(_key(KEY_TAB))
	await process_frame
	_check("Tab descend d'une ligne", menu.get_focused_item() == 1)
	for _i in range(menu.item_count - 1):
		root.push_input(_key(KEY_TAB))
		await process_frame
	_check("un Tab de plus après la dernière ligne revient en haut", menu.get_focused_item() == 0)
	root.push_input(_key(KEY_TAB, true))
	await process_frame
	_check("Maj+Tab depuis le haut repart du bas",
		menu.get_focused_item() == menu.item_count - 1)
	_check("la liste est restée ouverte", menu.visible)
	menu.hide()
	await process_frame

	print("--- Suggestions : Tab les parcourt ---")
	var row: Dictionary = _popup._rows[0]
	var name_edit: LineEdit = row["name"]
	name_edit.grab_focus()
	await process_frame
	_check("(préparation) le champ ingrédient a le focus", name_edit.has_focus())
	name_edit.text = "o"
	name_edit._on_text_changed("o")
	await process_frame
	var open: bool = name_edit._panel != null and name_edit._panel.visible \
		and name_edit._filtered.size() >= 2
	_check("(préparation) suggestions ouvertes", open)
	if open:
		name_edit._input(_key(KEY_TAB))
		_check("Tab sélectionne la première suggestion", name_edit._sel == 0)
		name_edit._input(_key(KEY_TAB))
		_check("Tab descend à la suivante", name_edit._sel == 1)
		name_edit._input(_key(KEY_TAB, true))
		_check("Maj+Tab remonte", name_edit._sel == 0)
		# En boucle (2.0.12) : depuis le haut, Maj+Tab repart du bas ; depuis le bas, Tab
		# revient en haut.
		name_edit._input(_key(KEY_TAB, true))
		_check("Maj+Tab depuis le haut repart du bas",
			name_edit._sel == name_edit._filtered.size() - 1)
		name_edit._input(_key(KEY_TAB))
		_check("Tab depuis le bas revient en haut", name_edit._sel == 0)
		# Les flèches, elles, s'arrêtent aux bords.
		name_edit._input(_key(KEY_UP))
		_check("↑ en haut reste en haut", name_edit._sel == 0)
		_check("le focus est resté sur l'ingrédient", name_edit.has_focus())
		var expected: String = name_edit._filtered[0]
		name_edit._input(_key(KEY_ENTER))
		_check("Entrée retient la suggestion", name_edit.text == expected)
		_check("…et ferme la liste", not name_edit._panel.visible)

	print("--- Quantité puis unité ---")
	var qty_edit: LineEdit = row["qty"]
	var unit_edit: LineEdit = row["unit"]
	qty_edit.text = "200"
	qty_edit.text_submitted.emit("200")
	await process_frame
	_check("Entrée dans la quantité passe à l'unité", unit_edit.has_focus())

	print("--- Après l'unité : une ligne neuve ---")
	unit_edit.text = "g"
	unit_edit.text_submitted.emit("g")
	await process_frame
	_check("Entrée crée une ligne", _popup._rows.size() == 2)
	_check("…et place le focus sur son ingrédient", _popup._rows[1]["name"].has_focus())

	# Tab, liste d'unités fermée : même effet qu'Entrée.
	var second: Dictionary = _popup._rows[1]
	second["name"].text = "Sel"
	second["unit"].grab_focus()
	await process_frame
	second["unit"].gui_input.emit(_key(KEY_TAB))
	await process_frame
	_check("Tab sur l'unité crée aussi une ligne", _popup._rows.size() == 3)
	_check("…focus sur le nouvel ingrédient", _popup._rows[2]["name"].has_focus())

	print("--- Ligne du milieu : on passe à la suivante ---")
	row["unit"].grab_focus()
	await process_frame
	row["unit"].text_submitted.emit("g")
	await process_frame
	_check("pas de ligne ajoutée au milieu", _popup._rows.size() == 3)
	_check("focus sur l'ingrédient de la ligne suivante", _popup._rows[1]["name"].has_focus())

	print("--- Ligne sans ingrédient : on sort vers les étapes ---")
	var last: Dictionary = _popup._rows[2]
	last["unit"].grab_focus()
	await process_frame
	last["unit"].text_submitted.emit("")
	await process_frame
	_check("pas de ligne vide de plus", _popup._rows.size() == 3)
	_check("focus sur les étapes", _popup._steps.has_focus())

	print("--- Par l'acheminement réel du moteur ---")
	# Les touches passent ici par la fenêtre, comme au clavier : c'est l'ordre de traitement
	# du moteur — `_input`, puis le contrôle qui a le focus, puis la navigation par Tab —
	# qui décide si la suggestion, la ligne neuve ou le champ suivant l'emporte.
	var real: Dictionary = _popup._rows[1]
	real["name"].text = "Poivre"
	real["unit"].grab_focus()
	await process_frame
	var before: int = _popup._rows.size()
	_popup.push_input(_key(KEY_TAB))
	await process_frame
	_check("Tab sur l'unité, liste fermée : ligne suivante (pas le bouton X)",
		_popup._rows[2]["name"].has_focus() and _popup._rows.size() == before)
	var live: LineEdit = _popup._rows[2]["name"]
	live.text = "o"
	live._on_text_changed("o")
	await process_frame
	if live._panel != null and live._panel.visible:
		_popup.push_input(_key(KEY_TAB))
		await process_frame
		_check("Tab, suggestions ouvertes : parcourt la liste, garde le focus",
			live.has_focus() and live._sel == 0)
		_popup.push_input(_key(KEY_ESCAPE))
		await process_frame
		_popup.push_input(_key(KEY_TAB))
		await process_frame
		_check("Tab, liste refermée : passe à la quantité", _popup._rows[2]["qty"].has_focus())
	else:
		_check("(préparation) suggestions ouvertes par l'acheminement réel", false)
	live.text = ""

	print("--- Catégorie (2.0.13) ---")
	_check("libellé sans « (type de plat) »", _find_label("Catégorie") != null
		and _find_label("Catégorie (type de plat)") == null)
	var category: LineEdit = _popup._category
	_check("les catégories existantes sont proposées",
		category.has_method("is_popup_open") and not category.suggestions.is_empty())
	var known: String = category.suggestions[0]
	_check("tapée sans accents ni majuscules, reprend l'orthographe existante",
		_popup._canonical_category(_plain(known)) == known)
	_check("une catégorie nouvelle reste telle quelle",
		_popup._canonical_category("Gratins du dimanche") == "Gratins du dimanche")

	print("--- ↑ / ↓ : d'un champ à l'autre (2.0.13) ---")
	_popup._name.grab_focus()
	await process_frame
	_popup.push_input(_key(KEY_DOWN))
	await process_frame
	_check("↓ depuis le nom : la saison", season.has_focus())
	_popup.push_input(_key(KEY_DOWN))
	await process_frame
	_check("↓ depuis la saison : la catégorie", category.has_focus())
	_popup.push_input(_key(KEY_UP))
	await process_frame
	_check("↑ depuis la catégorie : la saison", season.has_focus())
	_popup.push_input(_key(KEY_UP))
	await process_frame
	_check("↑ depuis la saison : le nom", _popup._name.has_focus())

	# Suggestions ouvertes : les flèches restent dans la liste.
	category.grab_focus()
	category.text = known.substr(0, 1)
	category._on_text_changed(category.text)
	await process_frame
	if category.is_popup_open():
		_popup.push_input(_key(KEY_DOWN))
		await process_frame
		_check("suggestions ouvertes : ↓ parcourt la liste, sans quitter le champ",
			category.has_focus() and category._sel == 0)
		category._hide()
	else:
		_check("(préparation) suggestions de catégorie ouvertes", false)
	category.text = ""

	# Lignes d'ingrédients : une grille — ↓ depuis une quantité mène à celle d'en dessous.
	var top: Dictionary = _popup._rows[0]
	var below: Dictionary = _popup._rows[1]
	top["qty"].grab_focus()
	await process_frame
	_popup.push_input(_key(KEY_DOWN))
	await process_frame
	_check("↓ depuis une quantité : la quantité de la ligne suivante", below["qty"].has_focus())
	_popup.push_input(_key(KEY_UP))
	await process_frame
	_check("↑ y revient", top["qty"].has_focus())

	# Étapes : les flèches changent de ligne, et ne quittent le champ qu'aux bords.
	var steps: TextEdit = _popup._steps
	steps.text = "Éplucher\nCuire\nServir"
	steps.grab_focus()
	steps.set_caret_line(1)
	await process_frame
	_popup.push_input(_key(KEY_UP))
	await process_frame
	_check("Étapes, ligne du milieu : ↑ reste dans le texte", steps.has_focus())
	steps.set_caret_line(0)
	_popup.push_input(_key(KEY_UP))
	await process_frame
	_check("Étapes, première ligne : ↑ remonte au champ précédent", not steps.has_focus())
	steps.text = ""

	print("--- En lecture, rien ne bouge ---")
	_popup.editable = false
	_popup._apply_editable()
	row["unit"].text_submitted.emit("g")
	await process_frame
	_check("aucune ligne ajoutée hors édition", _popup._rows.size() == 3)

	_popup.queue_free()
	await process_frame
	print("")
	print("Saisie au clavier conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## Le repli que fait `TextFold`, en plus simple — de quoi fabriquer une saisie sans accents
## ni majuscules d'une catégorie connue.
func _plain(text: String) -> String:
	var out := text.to_lower()
	for pair in [["é", "e"], ["è", "e"], ["ê", "e"], ["à", "a"], ["â", "a"], ["î", "i"],
			["ô", "o"], ["û", "u"], ["ù", "u"], ["ç", "c"], ["ï", "i"], ["ë", "e"]]:
		out = out.replace(pair[0], pair[1])
	return out

func _find_label(text: String) -> Label:
	for node in _popup.find_children("*", "Label", true, false):
		if (node as Label).text == text:
			return node
	return null

func _key(code: Key, shift := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.shift_pressed = shift
	return event

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [ok] %s" % label)
	else:
		print("  [ÉCHEC] %s" % label)
		_fails += 1
