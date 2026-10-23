extends SceneTree
## Vérifie que l'interface se remet à jour quand des données arrivent d'un autre
## appareil, et qu'une écriture locale demande bien un envoi.
## godot --headless --path . --script res://tools/test_reactivity.gd
##
## Raison d'être : les onglets lisaient la base UNE SEULE FOIS, dans `_ready()`. Une
## synchronisation mettait donc à jour la base et le cache sans que rien ne change à
## l'écran — il fallait redémarrer l'application pour voir arriver la liste de courses
## modifiée sur l'autre appareil. Rien ne le détectait : les tests portaient sur la
## base et le moteur de sync, jamais sur ce que l'interface en fait.

var _fails := 0

func _initialize() -> void:
	await process_frame
	await process_frame

	var store := root.get_node_or_null("/root/DataStore")
	if store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return

	var sections := 0
	sections += await _test_shopping_reload(store)
	sections += await _test_local_change_signal(store)
	sections += await _test_plan_restored(store)
	sections += await _test_shape_and_recipes_together(store)
	_check("les 4 sections ont bien tourné", sections == 4)

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

## Simule l'arrivée d'articles venus d'un autre appareil : on écrit en base « dans le
## dos » de l'onglet, puis on émet le signal que produit une synchronisation.
func _test_shopping_reload(store) -> int:
	print("--- Liste de courses : rechargement après synchronisation ---")
	var db = store.local_database()
	db._db.query("DELETE FROM shopping_items;")

	# Chargé à l'exécution et non par son class_name : le script du test se compile
	# avant que les autoloads existent, et ShoppingTab référence Layout.
	var tab = load("res://ui/shopping/ShoppingTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame
	_check("liste vide au départ", tab._items.is_empty())

	db.upsert_shopping_item("venu-dailleurs||kg", "Panais", "Fruits et Légumes",
		2.0, "kg", false)
	store.refresh_after_sync()      # ce que fait SyncEngine après un pull
	await process_frame

	_check("l'article distant apparaît sans redémarrage",
		tab._items.size() == 1 and str(tab._items[0]["nom"]) == "Panais")

	# Un article coché ailleurs doit aussi se refléter, pas seulement les ajouts.
	db.set_shopping_item_checked("venu-dailleurs||kg", true)
	store.refresh_after_sync()
	await process_frame
	_check("l'état coché distant se reflète",
		tab._items.size() == 1 and tab._items[0]["checked"] == true)

	tab.queue_free()
	db._db.query("DELETE FROM shopping_items;")
	await process_frame
	return 1

## Une écriture locale doit demander un envoi ; des données reçues, non — sans quoi
## chaque pull relancerait une synchronisation, indéfiniment.
func _test_local_change_signal(store) -> int:
	print("--- Signalement des écritures locales ---")
	var emitted := []
	store.local_change.connect(func(): emitted.append(1))

	var recipe = load("res://models/Recipe.gd").new()
	recipe.nom = "ZZZ Réactivité"
	recipe.saison = "toute"
	var rid: String = store.add_recipe(recipe)
	_check("une écriture locale demande un envoi", emitted.size() >= 1)

	emitted.clear()
	store.refresh_after_sync()
	_check("des données reçues n'en demandent pas", emitted.is_empty())

	# Une sauvegarde qui ne change rien ne doit rien déclencher : ces méthodes sont
	# appelées à chaque enregistrement, y compris quand l'état est identique.
	var names: Array[String] = []
	for i in range(14):
		names.append("")
	store.save_plan_names(names)
	emitted.clear()
	store.save_plan_names(names)
	_check("une sauvegarde sans changement ne demande rien", emitted.is_empty())

	store.delete_recipe_by_id(rid)
	return 1

## Le planning doit revenir tel quel à l'ouverture, sans bouton à presser.
##
## Il s'ouvrait sur 14 cases vides : non seulement le planning semblait perdu, mais la
## première modification l'effaçait pour de bon — la sauvegarde écrit les 14 positions,
## y compris celles restées vides.
func _test_plan_restored(store) -> int:
	print("--- Planning restauré à l'ouverture ---")
	var recipes: Array = store.get_all_recipe_objects()
	var names: Array[String] = []
	for i in range(14):
		names.append("")
	names[0] = recipes[0].nom
	names[5] = recipes[1].nom
	names[9] = "Restaurant"          # plat libre : doit revenir aussi
	store.save_plan_names(names)

	var tab = load("res://ui/planning/PlanningTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame

	_check("case 0 restaurée", tab._cells[0].recipe_name == recipes[0].nom)
	_check("case 5 restaurée", tab._cells[5].recipe_name == recipes[1].nom)
	_check("plat libre restauré", tab._cells[9].recipe_name == "Restaurant")
	_check("cases vides restées vides", tab._cells[1].recipe_name == "")

	# Le piège d'origine : modifier une case ne doit pas emporter les autres.
	tab._cells[1].set_recipe_name(recipes[2].nom)
	tab._on_cell_changed()
	var stored: Array = store.load_plan_names()
	_check("modifier une case préserve les autres",
		stored[0] == recipes[0].nom and stored[5] == recipes[1].nom and stored[9] == "Restaurant")

	# --- La bibliothèque reste atteignable sur téléphone ---
	#
	# Elle y était simplement MASQUÉE : créer, modifier, partager ou importer une
	# recette y était donc impossible, et depuis les photos, l'appareil photo aussi —
	# alors que c'est l'appareil qu'on a en main devant le plat. Le défaut a traversé
	# plusieurs versions sans se voir, chaque écran pris isolément fonctionnant.
	var layout = root.get_node("/root/Layout")
	var panel_home = tab._recipe_panel_home

	layout.form = layout.Form.PHONE
	tab._apply_form()
	_check("téléphone : un bouton mène à la bibliothèque",
		tab._recipe_sheet_btn != null and tab._recipe_sheet_btn.is_visible_in_tree())
	_check("téléphone : elle n'encombre pas le calendrier", not tab._recipe_panel.visible)

	tab._open_recipe_sheet()
	await process_frame
	_check("la feuille accueille la bibliothèque",
		tab._recipe_panel.get_parent() != panel_home and tab._recipe_panel.visible)
	# Le MÊME nœud voyage : la liste ne doit pas se vider en changeant de parent.
	_check("la liste survit au déplacement", tab._recipe_list._cards.size() > 0)

	tab._recipe_sheet._dismiss()
	await process_frame
	_check("fermée, elle regagne son conteneur", tab._recipe_panel.get_parent() == panel_home)
	_check("la liste est toujours là", tab._recipe_list._cards.size() > 0)

	# --- La liste doit défiler au doigt ---
	#
	# Les cartes étaient en MOUSE_FILTER_STOP et démarraient un glisser-déposer : le
	# geste de défilement était capturé par la carte, qui tentait de la déplacer, et la
	# liste refusait de bouger. Le glisser-déposer n'a de toute façon aucun sens sur
	# téléphone, où le calendrier n'est jamais visible en même temps que la
	# bibliothèque.
	var card = tab._recipe_list._cards[0]
	_check("téléphone : la carte laisse passer le geste au défilement",
		card.mouse_filter == Control.MOUSE_FILTER_PASS)
	_check("téléphone : aucun glisser-déposer depuis la carte",
		card._get_drag_data(Vector2.ZERO) == null)

	layout.form = layout.Form.DESKTOP
	tab._apply_form()
	_check("ordinateur : elle reprend sa place à côté du calendrier",
		tab._recipe_panel.visible and tab._recipe_panel.get_parent() == panel_home)
	# `is_visible_in_tree` et non `visible` : depuis la 1.7.10 le bouton vit dans une
	# rangée — séparateur compris — que le format montre ou cache d'un bloc. Lui-même reste
	# donc « visible », mais hors de portée. C'est l'accessibilité qui est en jeu, pas un
	# drapeau.
	_check("ordinateur : le bouton disparaît", not tab._recipe_sheet_btn.is_visible_in_tree())
	_check("ordinateur : elle retrouve sa largeur de panneau",
		tab._recipe_panel.custom_minimum_size.x >= layout.SIDE_PANEL_MIN)

	tab.queue_free()
	await process_frame
	var empty: Array[String] = []
	for i in range(14):
		empty.append("")
	store.save_plan_names(empty)
	return 1

## Une même synchronisation apporte une nouvelle forme de planning ET des recettes.
##
## L'onglet reconstruisait alors son calendrier et s'arrêtait là : la bibliothèque gardait
## la liste d'avant. Relevé sur la version web, où CHAQUE connexion part du jeu d'exemple à
## un repas par jour — une recette créée la veille n'y apparaissait plus. Même piège au
## premier passage d'un appareil neuf chez un foyer à deux repas.
func _test_shape_and_recipes_together(store) -> int:
	print("--- Forme du planning et recettes reçues ensemble ---")
	var db = store.local_database()
	var meals_before: int = store.plan_meals_per_day()

	var tab = load("res://ui/planning/PlanningTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame

	# Écrit « dans le dos » de l'onglet, comme le fait un pull.
	db.set_setting(LocalDatabase.SETTING_PLAN_MEALS_PER_DAY, str(3 - meals_before))
	var r := Recipe.new()
	r.nom = "Venue d'ailleurs Zzz"
	r.saison = "hiver"
	db.insert_recipe(r)
	store.refresh_after_sync()
	await process_frame

	_check("le calendrier a pris la nouvelle forme",
		tab._known_shape == tab._shape_signature())
	_check("la recette reçue est dans la bibliothèque",
		tab._all_recipe_names.has("Venue d'ailleurs Zzz"))

	tab.queue_free()
	await process_frame
	db.set_setting(LocalDatabase.SETTING_PLAN_MEALS_PER_DAY, str(meals_before))
	var added = store.get_recipe_by_name("Venue d'ailleurs Zzz")
	if added != null:
		store.delete_recipe_by_id(added.id)
	store.refresh_after_sync()
	return 1

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
