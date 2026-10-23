extends SceneTree
## La fiche d'une recette : consultation, passage en édition, ajout au planning.
## godot --headless --path . --script res://tools/test_recipe_card.gd
##
## Une recette s'ouvre en LECTURE, ce qui n'est pas un détail d'affichage : c'est le seul
## garde-fou contre une modification involontaire, la fiche étant désormais ce qui s'ouvre
## au moindre clic sur la liste. Un champ resté modifiable par mégarde, et l'on corrige une
## recette en croyant la lire.
##
## Rien de tout cela ne se voit à l'exécution : la page a la même apparence dans les deux
## modes, aux boutons près.

const PHONE_WIDTH := 412

var _fails := 0

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(PHONE_WIDTH, 915)
	await process_frame

	var tab: Control = load("res://ui/planning/PlanningTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame

	var store = root.get_node("/root/DataStore")
	var recipes: Array = store.get_all_recipe_objects()

	await _test_read_then_edit(tab, recipes[0])
	await _test_add_to_plan(tab, recipes[1])
	await _test_delete_request(tab, recipes[2])
	_test_creation_starts_editable(tab)

	print("")
	print("Fiche recette conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _open(tab: Control, recipe, editable: bool) -> Window:
	tab._open_recipe_popup(recipe, editable)
	await process_frame
	await process_frame
	var found: Window = null
	for child in tab.get_children():
		if child is Window and child.has_method("_apply_editable"):
			found = child
	return found

func _test_read_then_edit(tab: Control, recipe) -> void:
	print("--- Ouverte en lecture, puis en édition ---")
	var popup := await _open(tab, recipe, false)
	if popup == null:
		_check("la fiche s'ouvre", false)
		return

	_check("le nom n'est pas modifiable", not popup._name.editable)
	_check("les étapes non plus", not popup._steps.editable)
	# Les lignes d'ingrédients naissent au remplissage, APRÈS la construction : c'est
	# précisément celles qu'une liste de champs tenue à la main aurait oubliées.
	var rows_locked := true
	for entry in popup._rows:
		if entry["name"].editable:
			rows_locked = false
	_check("les ingrédients non plus", rows_locked)
	_check("la saison est verrouillée", popup._season.disabled)
	# Le point qui compte au doigt : `editable = false` ne change pas le FILTRE d'entrée
	# d'un champ. Il continuait donc de capter l'amorce du geste, et une page qu'on ne peut
	# que lire devenait pénible à faire défiler.
	_check("le nom ne capte plus le geste",
		popup._name.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("les étapes non plus",
		popup._steps.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("les champs d'ingrédient non plus",
		popup._rows[0]["name"].mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("ni les boutons verrouillés",
		popup._rows[0]["root"].get_child(3).mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("« Modifier » est offert", popup._edit_btn.visible)
	_check("« Supprimer » aussi", popup._delete_btn.visible)
	_check("« Ajouter au planning » est là", popup._plan_btn.visible)
	_check("« Sauvegarder » ne l'est pas", not popup._save_btn.visible)

	popup._on_start_editing()
	_check("après « Modifier » : le nom se saisit", popup._name.editable)
	_check("  les ingrédients aussi", popup._rows[0]["name"].editable)
	_check("  « Sauvegarder » apparaît", popup._save_btn.visible)
	_check("  « Annuler » aussi", popup._cancel_btn.visible)
	# L'ajout au planning disparaît : on est en train d'écrire, pas de choisir un repas.
	_check("  « Ajouter au planning » disparaît", not popup._plan_btn.visible)
	_check("  « Modifier » disparaît", not popup._edit_btn.visible)
	# « Supprimer » aussi : effacer au milieu d'une saisie emporterait sans un mot ce
	# qu'on vient d'écrire.
	_check("  « Supprimer » disparaît", not popup._delete_btn.visible)
	# En édition le champ doit garder le toucher — sans quoi on ne pourrait plus y écrire —
	# mais le laisser AUSSI remonter au conteneur, pour qu'un balayage parti d'un champ
	# fasse défiler la page.
	_check("  le champ laisse passer le geste au défilement",
		popup._name.mouse_filter == Control.MOUSE_FILTER_PASS)
	_check("  les boutons reprennent le toucher",
		popup._rows[0]["root"].get_child(3).mouse_filter == Control.MOUSE_FILTER_STOP)

	# Annuler revient à la consultation, la fiche restant ce qu'on était venu voir.
	var rows_before: int = popup._rows.size()
	popup._on_cancel()
	await process_frame
	_check("« Annuler » revient à la lecture", not popup._name.editable)
	_check("  et ne duplique pas les ingrédients", popup._rows.size() == rows_before)
	popup.queue_free()
	await process_frame

func _test_add_to_plan(tab: Control, recipe) -> void:
	print("--- Ajouter au planning ---")
	for cell in tab._cells:
		cell.set_recipe_name("")
	tab._on_cell_changed()

	var popup := await _open(tab, recipe, false)
	popup._on_add_to_plan()
	await process_frame
	_check("la première case libre est remplie", tab._cells[0].recipe_name == recipe.nom)
	_check("les suivantes restent vides", tab._cells[1].recipe_name == "")

	# Un second ajout descend d'une case : « la première LIBRE », et non « la première ».
	popup._on_add_to_plan()
	await process_frame
	_check("un second ajout prend la case suivante", tab._cells[1].recipe_name == recipe.nom)
	_check("  sans écraser la première", tab._cells[0].recipe_name == recipe.nom)

	# Planning complet : l'appel doit rester sans effet et sans plantage.
	for cell in tab._cells:
		cell.set_recipe_name(recipe.nom)
	popup._on_add_to_plan()
	await process_frame
	_check("planning complet : rien ne casse", tab._cells[13].recipe_name == recipe.nom)
	popup.queue_free()
	await process_frame

func _test_delete_request(tab: Control, recipe) -> void:
	print("--- Suppression demandée depuis la fiche ---")
	var popup := await _open(tab, recipe, false)
	var asked := []
	popup.delete_requested.connect(func(id): asked.append(id))
	popup._on_delete()
	await process_frame
	# La fiche demande, elle ne supprime pas : la confirmation appartient à l'écran qui
	# tient la liste, une boîte de dialogue portée par une fenêtre qui se referme
	# partirait avec elle.
	_check("la fiche transmet l'identifiant", asked == [recipe.id])
	_check("la recette existe toujours",
		root.get_node("/root/DataStore").get_recipe_by_id(recipe.id) != null)

func _test_creation_starts_editable(tab: Control) -> void:
	print("--- Une création s'ouvre en édition ---")
	tab._open_recipe_popup(null, true)
	var popup: Window = null
	for child in tab.get_children():
		if child is Window and child.has_method("_apply_editable"):
			popup = child
	if popup == null:
		_check("la fiche de création s'ouvre", false)
		return
	_check("le nom se saisit d'emblée", popup._name.editable)
	_check("« Sauvegarder » est offert", popup._save_btn.visible)
	# Rien à consulter, rien à supprimer, rien à mettre au planning.
	_check("aucun « Ajouter au planning »", not popup._plan_btn.visible)
	_check("aucun « Supprimer »", not popup._delete_btn.visible)
	popup.queue_free()

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
