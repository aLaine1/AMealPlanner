extends SceneTree
## Gestes tactiles : cases du calendrier, et cibles à cocher des listes (`TouchTap`).
## godot --headless --path . --script res://tools/test_touch_drag.gd
##
## Ces trois gestes partagent un seul contact et se sont déjà pris le pas l'un à
## l'autre : la case consommait l'événement, donc la liste ne défilait pas ; puis, une
## fois le défilement rendu possible, tout balayage qui s'achevait sur une case en
## ouvrait le menu. Rien de tout cela ne se voit sur ordinateur, où la souris a un
## bouton droit et une molette — c'est-à-dire là où l'application est développée.

const DragAutoScrollScript := preload("res://ui/components/DragAutoScroll.gd")
## Chargée à l'exécution, et non préchargée ni appelée par son `class_name` : lancé en
## `--script`, le moteur ne compte les autoloads parmi les identifiants connus qu'une
## fois la scène principale en place. `MealCell` référence `Layout` et `Palette` : à la
## compilation du présent script, elle ne compilerait pas.
var _cell_script: GDScript = null

## Le format n'est pas forcé sur l'autoload : on redimensionne la fenêtre, et `Layout`
## en déduit le format comme il le fait sur un appareil. C'est aussi ce qui rend le
## mode téléphone testable sans appareil.
const PHONE_WIDTH := 412
const DESKTOP_WIDTH := 1280

var _fails := 0

func _initialize() -> void:
	await process_frame
	_cell_script = load("res://ui/planning/MealCell.gd")

	await _test_desktop()
	await _test_phone()
	_test_auto_scroll()
	await _test_scroll_frozen()
	await _test_tap_vs_swipe()
	await _test_touch_item_list()
	await _test_settings_pills()

	print("")
	print("Gestes tactiles conformes." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _test_desktop() -> void:
	print("--- Souris (bureau) ---")
	await _set_width(DESKTOP_WIDTH)
	var cell := _make_cell("Gratin")
	_check("la case consomme l'événement", cell.mouse_filter == Control.MOUSE_FILTER_STOP)
	_check("déplacement immédiat, sans appui long", cell.can_be_dragged())
	cell.queue_free()

func _test_phone() -> void:
	print("--- Doigt (téléphone) ---")
	# Case née en format bureau puis passée au téléphone : c'est le cas réel, une même
	# case voyageant entre la grille et la liste sans jamais être reconstruite.
	var cell := _make_cell("Gratin")
	await _set_width(PHONE_WIDTH)
	_check("la case laisse passer l'événement au défilement",
		cell.mouse_filter == Control.MOUSE_FILTER_PASS)
	_check("pas de déplacement sans appui long", not cell.can_be_dragged())

	# Balayage : appui puis glissement franc. Ni prise, ni menu au relâchement.
	var menus := [0]
	cell.context_requested.connect(func(_c, _p): menus[0] += 1)
	cell._gui_input(_press(Vector2(20, 20)))
	cell._gui_input(_motion(Vector2(20, 90)))
	await _wait_hold()
	_check("un balayage ne soulève pas la case", not cell.can_be_dragged())
	cell._gui_input(_release(Vector2(20, 90)))
	_check("un balayage n'ouvre pas le menu", menus[0] == 0)

	# Appui bref : le menu, et rien d'autre.
	cell._gui_input(_press(Vector2(20, 20)))
	cell._gui_input(_release(Vector2(22, 21)))
	_check("un appui bref ouvre le menu", menus[0] == 1)
	_check("un appui bref ne soulève pas la case", not cell.can_be_dragged())

	# Appui long : la case se saisit, et le relâchement n'ouvre pas le menu par-dessus.
	cell._gui_input(_press(Vector2(20, 20)))
	await _wait_hold()
	_check("un appui long soulève la case", cell.can_be_dragged())
	cell._gui_input(_release(Vector2(20, 20)))
	_check("la case reposée n'ouvre pas le menu", menus[0] == 1)
	_check("la case reposée n'est plus saisie", not cell.can_be_dragged())
	cell.queue_free()

	# Une case vide n'a rien à déplacer : l'appui long y reste un appui.
	var empty := _make_cell("")
	var empty_menus := [0]
	empty.context_requested.connect(func(_c, _p): empty_menus[0] += 1)
	empty._gui_input(_press(Vector2(20, 20)))
	await _wait_hold()
	_check("une case vide ne se soulève pas", not empty.can_be_dragged())
	empty._gui_input(_release(Vector2(20, 20)))
	_check("une case vide garde son menu", empty_menus[0] == 1)
	empty.queue_free()

func _test_auto_scroll() -> void:
	print("--- Défilement automatique pendant un déplacement ---")
	var rect := Rect2(Vector2(0, 100), Vector2(400, 600))
	_check("pointeur au centre : immobile",
		is_zero_approx(DragAutoScrollScript.scroll_step(rect, Vector2(200, 400), 0.016)))
	_check("pointeur hors du conteneur : immobile",
		is_zero_approx(DragAutoScrollScript.scroll_step(rect, Vector2(200, 900), 0.016)))
	_check("bord haut : défile vers le haut",
		DragAutoScrollScript.scroll_step(rect, Vector2(200, 105), 0.016) < 0.0)
	_check("bord bas : défile vers le bas",
		DragAutoScrollScript.scroll_step(rect, Vector2(200, 695), 0.016) > 0.0)
	# Plus on approche du bord, plus cela défile vite : sans cela, il faudrait viser
	# le pixel du bord pour obtenir un défilement utilisable.
	var near := absf(DragAutoScrollScript.scroll_step(rect, Vector2(200, 102), 0.016))
	var far := absf(DragAutoScrollScript.scroll_step(rect, Vector2(200, 150), 0.016))
	_check("la vitesse croît vers le bord", near > far)
	# Conteneur court : les deux bandes ne doivent pas se recouvrir, sinon le sens du
	# défilement au milieu deviendrait arbitraire.
	var short := Rect2(Vector2.ZERO, Vector2(400, 120))
	_check("conteneur court : le milieu reste immobile",
		is_zero_approx(DragAutoScrollScript.scroll_step(short, Vector2(200, 60), 0.016)))

## Le geste complet, dans un vrai ScrollContainer et par le vrai chemin d'entrée du
## moteur — les sections ci-dessus appellent `_gui_input` directement et ne peuvent donc
## rien dire de ce que le CONTENEUR fait du même contact.
##
## C'est là que se jouait le défaut de la 1.7.0 : la case étant en `MOUSE_FILTER_PASS`,
## l'événement remontait jusqu'au ScrollContainer, qui panoramiquait pendant que la case
## se déplaçait. Les deux mouvements s'annulaient et la case ne changeait jamais de
## voisins.
##
## `emulate_touch_from_mouse` n'est pas un artifice de confort : c'est lui qui rend
## `DisplayServer.is_touchscreen_available()` vrai, et donc qui active le panoramique au
## doigt du ScrollContainer. Sans lui, la régression serait tout simplement invisible
## hors d'un appareil.
func _test_scroll_frozen() -> void:
	print("--- Déplacement dans une liste défilante ---")
	await _set_width(PHONE_WIDTH)
	var was_emulating := Input.is_emulating_touch_from_mouse()
	Input.set_emulate_touch_from_mouse(true)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2.ZERO
	scroll.size = Vector2(PHONE_WIDTH, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	scroll.add_child(DragAutoScrollScript.new())
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	var cells: Array[Control] = []
	for index in range(14):
		var cell: Control = _cell_script.new()
		column.add_child(cell)
		cell.custom_minimum_size = Vector2(0, 120)   # de quoi déborder largement
		cell.set_recipe_name("Recette %d" % index)
		cells.append(cell)
	await process_frame
	await process_frame

	# Relevé et non supposé : un ScrollContainer naît en PASS et non en STOP, et c'est
	# cette valeur-là que le gel doit lui rendre.
	var idle_filter := scroll.mouse_filter

	# Le balayage doit rester intact : le gel ne vaut que pendant un déplacement, et un
	# conteneur gelé en permanence serait un remède pire que le mal.
	scroll.scroll_vertical = 0
	await _touch(Vector2(200, 200), true)
	await _swipe(Vector2(200, 200), Vector2(200, 100))
	await _touch(Vector2(200, 100), false)
	_check("un balayage fait toujours défiler la liste", scroll.scroll_vertical > 0)

	# Le même geste, précédé d'un appui long : la case part, la liste ne bouge plus.
	scroll.scroll_vertical = 0
	await _touch(Vector2(200, 200), true)
	await _wait_hold()
	var held: Control = null
	for cell in cells:
		if cell.can_be_dragged():
			held = cell
	_check("l'appui long a soulevé une case", held != null)
	var carried: String = held.recipe_name if held != null else ""
	await _swipe(Vector2(200, 200), Vector2(200, 100))
	_check("un déplacement est bien en cours", root.gui_is_dragging())
	_check("la liste ne défile plus sous le doigt", scroll.scroll_vertical == 0)
	_check("le conteneur est gelé",
		scroll.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	await _touch(Vector2(200, 100), false)
	await process_frame
	await process_frame
	_check("le dépôt met fin au déplacement", not root.gui_is_dragging())
	_check("le conteneur retrouve son défilement",
		scroll.mouse_filter == idle_filter)
	if held != null:
		_check("le dépôt a bien échangé les deux repas", held.recipe_name != carried)

	scroll.queue_free()
	Input.set_emulate_touch_from_mouse(was_emulating)
	await process_frame

## Le défaut le plus tenace de l'interface tactile, revenu trois fois : un élément de
## liste qui consomme l'événement empêche tout défilement, et un élément qui s'active au
## relâchement sans regarder le trajet se déclenche à chaque balayage. `TouchTap` tient
## les deux bouts, et c'est bien leur RÉUNION qui est vérifiée ici — dans un vrai
## ScrollContainer, par le vrai chemin d'entrée du moteur.
func _test_tap_vs_swipe() -> void:
	print("--- Cocher sans empêcher de défiler ---")
	await _set_width(PHONE_WIDTH)
	var was_emulating := Input.is_emulating_touch_from_mouse()
	Input.set_emulate_touch_from_mouse(true)

	var tap_script: GDScript = load("res://ui/components/TouchTap.gd")
	var scroll := ScrollContainer.new()
	scroll.position = Vector2.ZERO
	scroll.size = Vector2(PHONE_WIDTH, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	var taps := [0]
	for index in range(20):
		var row := MarginContainer.new()
		row.custom_minimum_size = Vector2(0, 60)
		column.add_child(row)
		var check := CheckBox.new()
		check.text = "Recette %d" % index
		# Hors d'atteinte du pointeur : un CheckBox actif se cocherait pour son propre
		# compte, y compris au terme d'un balayage.
		check.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(check)
		tap_script.connect_tap(row, func():
			check.button_pressed = not check.button_pressed
			taps[0] += 1)
	await process_frame
	await process_frame

	_check("la ligne laisse passer l'événement au défilement",
		column.get_child(0).mouse_filter == Control.MOUSE_FILTER_PASS)

	# Balayage : la liste défile, et rien ne se coche au passage.
	scroll.scroll_vertical = 0
	await _touch(Vector2(200, 200), true)
	await _swipe(Vector2(200, 200), Vector2(200, 100))
	await _touch(Vector2(200, 100), false)
	_check("un balayage fait défiler la liste", scroll.scroll_vertical > 0)
	_check("un balayage ne coche rien", taps[0] == 0)

	# Toucher franc, sans glissement : la ligne bascule.
	scroll.scroll_vertical = 0
	await _touch(Vector2(200, 200), true)
	await _touch(Vector2(200, 200), false)
	_check("un toucher coche la ligne", taps[0] == 1)
	_check("et ne fait pas défiler la liste", scroll.scroll_vertical == 0)

	scroll.queue_free()
	Input.set_emulate_touch_from_mouse(was_emulating)
	await process_frame

	# Les deux gardes de TouchTap se recouvrent en usage réel : le trajet annule le
	# toucher dès le premier mouvement, et la position de relâchement le recoupe. Cette
	# seconde règle est donc éprouvée à part, sur `handle()` directement — sans quoi on
	# pourrait la supprimer sans qu'aucune vérification ne bronche.
	print("--- Règle du relâchement (logique seule) ---")
	var direct := [0]
	var count := func(): direct[0] += 1

	tap_script.handle(_press(Vector2(10, 10)), count)
	tap_script.handle(_release(Vector2(10, 50)), count)
	_check("relâchement loin de l'appui : aucun toucher", direct[0] == 0)

	tap_script.handle(_press(Vector2(10, 10)), count)
	tap_script.handle(_release(Vector2(12, 13)), count)
	_check("relâchement sur place : un toucher", direct[0] == 1)

	# Un relâchement sans appui préalable — le doigt est entré dans la liste en glissant
	# depuis un autre contrôle — ne doit rien déclencher.
	tap_script.handle(_release(Vector2(10, 10)), count)
	_check("relâchement sans appui : aucun toucher", direct[0] == 1)

## `TouchItemList` remplace `ItemList` dans les trois listes des Paramètres.
##
## `ItemList` n'offre pour défiler que sa barre — quelques unités de large — et la
## molette : au doigt, tout balayage parti d'une ligne la SÉLECTIONNE au lieu de faire
## défiler, et les 142 ingrédients étaient inatteignables au-delà du premier écran.
## Ce test vérifie le remplacement sur les deux points qui comptent : il défile, et il
## sélectionne quand on le touche vraiment.
func _test_touch_item_list() -> void:
	print("--- Liste des Paramètres : défiler et sélectionner ---")
	await _set_width(PHONE_WIDTH)
	var was_emulating := Input.is_emulating_touch_from_mouse()
	Input.set_emulate_touch_from_mouse(true)

	var list_script: GDScript = load("res://ui/components/TouchItemList.gd")
	var list: ScrollContainer = list_script.new()
	list.position = Vector2.ZERO
	list.size = Vector2(PHONE_WIDTH, 300)
	root.add_child(list)
	var chosen := [-1]
	list.item_selected.connect(func(index): chosen[0] = index)
	for index in range(20):
		list.add_item("Ingrédient %d" % index)
	await process_frame
	await process_frame

	# Balayage : la liste défile, et rien n'est sélectionné au passage.
	list.scroll_vertical = 0
	await _touch(Vector2(200, 200), true)
	await _swipe(Vector2(200, 200), Vector2(200, 80))
	await _touch(Vector2(200, 80), false)
	_check("un balayage fait défiler la liste", list.scroll_vertical > 0)
	_check("un balayage ne sélectionne rien", chosen[0] == -1)

	# Toucher franc : la ligne sous le doigt est retenue.
	list.scroll_vertical = 0
	await process_frame
	await _touch(Vector2(200, 100), true)
	await _touch(Vector2(200, 100), false)
	_check("un toucher sélectionne une ligne", chosen[0] >= 0)
	_check("  et la sélection est lisible", list.get_selected_items() == [chosen[0]])

	# `select()` rétablit une sélection sans réémettre : les appelants s'en servent après
	# reconstruction, et l'émission relancerait leur propre rafraîchissement.
	chosen[0] = -1
	list.select(4)
	_check("select() ne réémet pas", chosen[0] == -1)
	_check("  mais change bien la sélection", list.get_selected_items() == [4])
	_check("le libellé est relisible", list.get_item_text(4) == "Ingrédient 4")

	list.clear()
	_check("clear() vide la liste", list.get_item_count() == 0)
	_check("  et oublie la sélection", list.get_selected_items().is_empty())

	list.queue_free()
	Input.set_emulate_touch_from_mouse(was_emulating)
	await process_frame

## Les pastilles des Paramètres, dans un conteneur défilant.
##
## L'écran du planning en aligne vingt-sept : durée, jour des courses, repas par jour, puis
## une semaine de cases à cocher par repas. Un `Button` traite le clic pour son propre
## compte et consomme l'événement — presque tout balayage part donc d'une pastille, et la
## page refusait de défiler. C'est le défaut le plus tenace de cette interface, revenu ici
## pour la cinquième fois : listes de courses, cartes de la bibliothèque, cases du
## calendrier, sélecteur de recette, et maintenant les réglages.
func _test_settings_pills() -> void:
	print("--- Pastilles des Paramètres : défiler et choisir ---")
	await _set_width(PHONE_WIDTH)
	var was_emulating := Input.is_emulating_touch_from_mouse()
	Input.set_emulate_touch_from_mouse(true)

	var store = root.get_node("/root/DataStore")
	store.set_plan_shape(2, 5, 2)
	store.set_transport_marker_enabled(true)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2.ZERO
	scroll.size = Vector2(PHONE_WIDTH, 360)   # volontairement court : il faut déborder
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var section: Control = load("res://ui/settings/PlanningSettingsTab.gd").new()
	section.size_flags_vertical = Control.SIZE_FILL
	# `Layout` par le chemin de nœud : lancée en `--script`, cette suite est compilée avant
	# que le moteur ne compte les autoloads parmi les identifiants connus.
	var layout = root.get_node("/root/Layout")
	layout.scroll_body(scroll).add_child(section)
	for _i in range(5):
		await process_frame

	var weeks_before: int = store.plan_weeks()
	var pill: Button = section._weeks_buttons[4]
	var spot: Vector2 = pill.get_global_rect().get_center()
	_check("la pastille est bien dans l'écran (%s)" % str(spot), spot.y < 360.0)

	# Balayage parti d'une pastille : la page défile, et rien n'est choisi au passage.
	scroll.scroll_vertical = 0
	await _touch(spot, true)
	await _swipe(spot, spot - Vector2(0, 120))
	await _touch(spot - Vector2(0, 120), false)
	_check("un balayage parti d'une pastille fait défiler (%d)" % scroll.scroll_vertical,
		scroll.scroll_vertical > 0)
	_check("  et ne change pas le réglage", store.plan_weeks() == weeks_before)

	# Toucher franc : le réglage change.
	scroll.scroll_vertical = 0
	for _i in range(3):
		await process_frame
	spot = section._weeks_buttons[4].get_global_rect().get_center()
	await _touch(spot, true)
	await _touch(spot, false)
	_check("un toucher franc choisit 4 semaines", store.plan_weeks() == 4)

	store.set_plan_shape(2, 5, 1)
	store.set_transport_marker_enabled(false)
	scroll.queue_free()
	Input.set_emulate_touch_from_mouse(was_emulating)
	await process_frame

func _touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.position = at
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame
	await process_frame

## Une image par pas : le panoramique du conteneur comme le déplacement de la case se
## jouent au fil des images, et un saut unique ne dirait rien de leur course commune.
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

func _set_width(width: int) -> void:
	root.size = Vector2i(width, 915)
	await process_frame
	await process_frame

## Au-delà de _cell_script.HOLD_MS : c'est bien le minuteur réel qui est vérifié.
func _wait_hold() -> void:
	await create_timer(_cell_script.HOLD_MS / 1000.0 + 0.15).timeout

func _make_cell(recipe_name: String) -> Control:
	var cell: Control = _cell_script.new()
	root.add_child(cell)
	cell.set_recipe_name(recipe_name)
	return cell

func _press(at: Vector2) -> InputEventMouseButton:
	return _button(at, true)

func _release(at: Vector2) -> InputEventMouseButton:
	return _button(at, false)

func _button(at: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	return event

func _motion(at: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	return event

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [ok] %s" % label)
	else:
		print("  [ÉCHEC] %s" % label)
		_fails += 1
