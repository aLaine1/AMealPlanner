extends SceneTree
## La barre de navigation doit tenir sur N'IMPORTE QUEL écran de téléphone.
## godot --headless --path . --script res://tools/test_tabs.gd
##
## Les trois onglets tenaient sur l'appareil de test et pas sur un autre : la barre
## repliait le troisième derrière une flèche. Ce n'est pas une affaire de chance mais de
## largeur LOGIQUE, qui dépend de la densité de l'écran et non de sa taille — deux
## téléphones de même diagonale n'offrent pas le même nombre d'unités.
##
## Relevé à l'origine, à 320 unités : 216 de barre disponible pour 330 d'onglets, dont
## 108 de remplissage pur (18 unités de marge de chaque côté de chaque onglet).
##
## Rien de tout cela ne se voit sur le poste de développement, où la fenêtre est large.

const WIDTHS := [320, 360, 412]
const DESKTOP_WIDTH := 1280

var _fails := 0

func _initialize() -> void:
	await process_frame
	for width in WIDTHS:
		await _check_width(width, true)
	await _check_width(DESKTOP_WIDTH, false)

	print("")
	print("Barre d'onglets conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## La taille de la fenêtre est posée AVANT d'instancier la scène : un Control ajouté à
## une fenêtre déjà dimensionnée ne reçoit aucune notification de redimensionnement et
## resterait de taille nulle — toute mesure prise dessus serait alors une fiction.
func _check_width(width: int, phone: bool) -> void:
	root.size = Vector2i(width, 915)
	await process_frame
	var main: Control = load("res://ui/MainWindow.tscn").instantiate()
	root.add_child(main)
	for _i in range(4):
		await process_frame

	var tabs: TabContainer = main._main_tabs
	var bar := tabs.get_tab_bar()
	var count := bar.get_tab_count()
	var total := 0.0
	var titles := []
	for index in range(count):
		total += bar.get_tab_rect(index).size.x
		titles.append(bar.get_tab_title(index))

	var label := "%s %d" % ["téléphone" if phone else "bureau", width]
	_check("%s : les %d onglets tiennent (%.0f pour %.0f)" % [label, count, total, bar.size.x],
		total <= bar.size.x + 0.5)
	# Le plafond de largeur est le filet de sécurité, pas le régime normal : s'il entre en
	# action, c'est qu'un libellé est coupé, et l'utilisateur lit « Cou » pour « Courses ».
	_check("%s : aucun libellé n'est coupé" % label, bar.max_tab_width == 0)
	# Les libellés restent ENTIERS en tout format : la seule réduction des marges d'onglet
	# leur laisse la place. Le vérifier, c'est empêcher qu'on les raccourcisse à nouveau
	# « par sécurité » sans avoir remesuré.
	_check("%s : libellé complet" % label, titles[2] == "Liste de course")

	main.queue_free()
	await process_frame

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
