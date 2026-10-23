extends SceneTree
## Bouton Retour d'Android : ce qu'il défait, et dans quel ordre.
## godot --headless --path . --script res://tools/test_go_back.gd
##
## Rien de tout cela ne s'observe sur le poste de dev — le geste n'existe que sur
## téléphone, et son défaut d'origine (quitter l'application à tout coup) ne se voyait
## qu'après avoir perdu ce qu'on était en train de saisir.
##
## L'invariant le plus coûteux est celui de la feuille latérale : elle EMPRUNTE le
## panneau de la bibliothèque à son conteneur de bureau et doit le lui rendre en
## partant. Fermée par un chemin qui l'ignore, elle l'emporte, et l'onglet Calendrier
## se retrouve sans bibliothèque jusqu'au redémarrage.

const PHONE_WIDTH := 412

var _fails := 0
var _main: Control = null

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(PHONE_WIDTH, 915)
	_main = load("res://ui/MainWindow.tscn").instantiate()
	root.add_child(_main)
	await process_frame
	await process_frame

	await _test_closes_window()
	await _test_returns_home()
	await _test_ends_text_input()
	await _test_panel_sheet()
	await _test_quit_needs_confirmation()

	print("")
	print("Bouton Retour conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _test_closes_window() -> void:
	print("--- Une fenêtre ouverte se referme d'abord ---")
	var window: Window = load("res://ui/components/PickerPopup.gd").new()
	window.setup("Choisir une recette", ["Couscous", "Galettes"], "", false)
	_main.add_child(window)
	window.popup_centered()
	await process_frame
	_back()
	await process_frame
	await process_frame
	_check("la fenêtre est refermée", not is_instance_valid(window) or not window.visible)

func _test_returns_home() -> void:
	print("--- Sans fenêtre, retour à l'onglet d'accueil ---")
	var tabs := _find_tabs(_main)
	if tabs == null:
		_check("barre d'onglets trouvée", false)
		return
	tabs.current_tab = 2
	await process_frame
	_back()
	await process_frame
	_check("l'onglet d'accueil est rétabli", tabs.current_tab == 0)

## Le premier Retour, Android le garde pour replier le clavier ; le champ, lui, garde le
## focus. Le Retour suivant doit clore cette saisie — pas changer d'onglet sous les doigts.
func _test_ends_text_input() -> void:
	print("--- Une saisie restée ouverte se termine avant de quitter l'onglet ---")
	var tabs := _find_tabs(_main)
	if tabs == null:
		_check("barre d'onglets trouvée", false)
		return
	tabs.current_tab = 2
	await process_frame
	var field := LineEdit.new()
	tabs.get_current_tab_control().add_child(field)
	await process_frame
	field.grab_focus()
	await process_frame
	_check("(préparation) le champ a le focus", field.has_focus())
	_back()
	await process_frame
	await process_frame
	_check("la saisie est terminée", not field.has_focus())
	_check("on reste sur l'onglet", tabs.current_tab == 2)
	_back()
	await process_frame
	await process_frame
	_check("le Retour suivant ramène à l'accueil", tabs.current_tab == 0)
	field.queue_free()
	await process_frame

func _test_panel_sheet() -> void:
	print("--- La feuille rend le panneau qu'elle a emprunté ---")
	var planning := _main.find_child("Calendrier", true, false)
	if planning == null:
		_check("onglet Calendrier trouvé", false)
		return
	var panel: Control = planning._recipe_panel
	var home: Control = planning._recipe_panel_home
	planning._open_recipe_sheet()
	await process_frame
	_check("le panneau a quitté son conteneur", panel.get_parent() != home)
	_back()
	await process_frame
	await process_frame
	_check("le panneau est rendu à son conteneur", panel.get_parent() == home)
	_check("le panneau est vivant", is_instance_valid(panel))

func _test_quit_needs_confirmation() -> void:
	print("--- Sur l'accueil, quitter demande un second appui ---")
	_back()
	await process_frame
	await process_frame
	# Toujours en vie deux images plus tard : le premier appui n'a pas quitté.
	_check("le premier appui ne quitte pas", true)
	_check("un message l'annonce", _has_text(_main, "Appuyer à nouveau"))

	# Le délai passé, l'appui suivant redemande confirmation au lieu de quitter : sans
	# expiration, un retour d'aujourd'hui vaudrait encore confirmation demain.
	await create_timer(_main.QUIT_CONFIRM_MS / 1000.0 + 0.3).timeout
	_back()
	await process_frame
	await process_frame
	_check("hors délai, la confirmation est redemandée", _has_text(_main, "Appuyer à nouveau"))

## Exactement ce que le moteur fait à la réception du geste système : la notification
## est distribuée en PARCOURANT l'arbre. La notifier directement au seul MainWindow
## serait plus simple, et laisserait passer tout ce que ce parcours interdit — ajouter
## un nœud, notamment, ce dont le message de sortie a besoin.
func _back() -> void:
	root.propagate_notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)

func _find_tabs(node: Node) -> TabContainer:
	if node is TabContainer:
		return node
	for child in node.get_children():
		var found := _find_tabs(child)
		if found != null:
			return found
	return null

func _has_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for child in node.get_children():
		if _has_text(child, needle):
			return true
	return false

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [ok] %s" % label)
	else:
		print("  [ÉCHEC] %s" % label)
		_fails += 1
