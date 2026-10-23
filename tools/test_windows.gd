extends SceneTree
## Ouvre chaque fenêtre secondaire et vérifie qu'elle se construit et qu'on peut en sortir.
## godot --headless --path . --script res://tools/test_windows.gd
##
## Raison d'être : deux fois de suite, un `func _notification` inséré au milieu de
## `_ready()` a envoyé toute la construction de l'interface dans le gestionnaire de
## notifications. Résultat côté téléphone : plantage à l'ouverture des Paramètres.
## Rien ne le détectait — le lancement à blanc de l'application n'ouvre aucune
## fenêtre secondaire, et les tests headless existants ne touchent pas à l'UI.
##
## Trois invariants sont vérifiés, correspondant chacun à un défaut déjà rencontré :
##  1. la fenêtre construit bien son contenu depuis `_ready()` ;
##  2. elle offre une sortie explicite — en plein écran sur téléphone, la barre de
##     titre système n'existe pas, et sans bouton on entre sans pouvoir ressortir ;
##  3. rien ne dépasse de l'écran d'un téléphone. « Partager des recettes » rangeait ses
##     deux colonnes côte à côte, soit près de 600 unités de large : sur un écran de
##     412, le QR, l'état et les deux boutons étaient dehors, et aucun geste ne
##     permettait de les ramener. Un bouton hors champ n'existe pas, et rien ne le dit.

## Gabarit de test : téléphone, le format où la place manque. Les fenêtres s'y mettent
## en plein écran (`Layout.fit_window`), c'est donc l'écran lui-même qui les borne.
const PHONE := Vector2i(412, 915)

const WINDOWS := [
	"res://ui/settings/SettingsWindow.gd",
	"res://ui/components/PickerPopup.gd",
	"res://ui/components/TextPromptPopup.gd",
	"res://ui/recipes/SharePopup.gd",
	# Ouverte sans code : elle doit le dire plutôt que d'afficher un carré vide.
	"res://ui/recipes/ShareCodePopup.gd",
	"res://ui/recipes/ImportPopup.gd",
	"res://ui/recipes/RecipePopup.gd",
	"res://ui/recipes/RecipeDetailPopup.gd",
	"res://ui/breakfast/BreakfastPopup.gd",
	"res://ui/ingredients/IngredientPopup.gd",
	"res://ui/settings/StaplePopup.gd",
	# Sans appareil photo — le cas de cette suite, qui tourne sans écran — l'écran de
	# prise de vue doit se construire quand même et l'annoncer, plutôt que de rester
	# noir devant un bouton inerte.
	"res://ui/components/CameraCapturePopup.gd",
]

## Libellés acceptés comme sortie de la fenêtre.
const EXIT_LABELS := ["retour", "annuler", "fermer", "✕", "×"]

var _fails := 0

func _initialize() -> void:
	await process_frame
	root.size = PHONE
	await process_frame
	await process_frame

	for path in WINDOWS:
		var window: Window = load(path).new()
		root.add_child(window)
		await process_frame
		await process_frame

		var name: String = path.get_file().get_basename()
		var descendants := _count_descendants(window)
		# Un `_ready()` amputé laisse la fenêtre quasiment vide.
		_check("%s : contenu construit (%d nœuds)" % [name, descendants], descendants >= 3)
		_check("%s : sortie explicite" % name, _has_exit(window))

		var stray := _offscreen(window)
		_check("%s : rien ne dépasse de l'écran%s" % [name,
			"" if stray.is_empty() else " (%s)" % ", ".join(stray)], stray.is_empty())

		window.queue_free()
		await process_frame

	await _test_text_prompt()
	await _test_dialogs_fit()
	await _test_settings_scroll()
	_test_title_bar_theme()

	print("")
	print("Toutes les fenêtres sont saines." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## Contrat de la saisie libre : c'est elle qui alimente `custom_label`, le champ qui
## permet de poser un repas sans recette (« Restaurant », « Restes ») dans le planning.
func _test_text_prompt() -> void:
	print("--- Saisie libre ---")
	var prompt = load("res://ui/components/TextPromptPopup.gd").new()
	prompt.setup("Plat libre", "Nom du plat.", "Restes")
	root.add_child(prompt)
	await process_frame

	_check("valeur initiale reprise dans le champ", prompt._field.text == "Restes")

	var received := []
	prompt.submitted.connect(func(text): received.append(text))

	# Valider à vide viderait la case sans le dire : la suppression a sa propre entrée.
	prompt._field.text = "   "
	prompt._submit()
	_check("saisie vide refusée", received.is_empty())

	prompt._field.text = "  Chez mes parents  "
	prompt._submit()
	_check("texte transmis et détouré",
		received.size() == 1 and received[0] == "Chez mes parents")
	await process_frame

## Les boîtes de dialogue tiennent elles aussi dans l'écran.
##
## Elles échappent au balayage ci-dessus : ce sont des fenêtres du système, ouvertes à la
## demande depuis un onglet, et non des écrans qu'on peut instancier d'une ligne. L'une
## d'elles — « Planning complet » — était dimensionnée en dur à 420 unités de large, pour
## un écran qui en fait 412 : elle débordait des deux côtés, son bouton avec elle. Le
## chiffre passait inaperçu sur un poste de développement, où toute fenêtre est plus
## large que cela.
func _test_dialogs_fit() -> void:
	print("--- Les dialogues tiennent dans l'écran ---")
	var tab: Control = load("res://ui/planning/PlanningTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame

	# Le message le plus long de l'onglet, et celui que le rapport signalait.
	for body in [
		"Les 28 cases du planning sont déjà prises.\nVide une case pour y placer cette recette.",
		"Aucune recette de remplacement disponible pour cette case\n"
		+ "(contraintes trop strictes : saison, transport, doublons).",
	]:
		tab._popup_info("Essai", body)
		await process_frame
		await process_frame
		var dialog: AcceptDialog = null
		for child in tab.get_children():
			if child is AcceptDialog:
				dialog = child
		if dialog == null:
			_check("le dialogue s'ouvre", false)
			continue
		_check("largeur %d ≤ écran %d" % [dialog.size.x, PHONE.x], dialog.size.x <= PHONE.x)
		# Borné des DEUX côtés. « Tient dans l'écran » est vrai d'un dialogue de 59
		# unités de large — c'est précisément ce que donnait `popup_centered(taille)`
		# une fois le repli du texte activé, un mot par ligne sur quinze lignes. Une
		# boîte trop étroite est illisible tout autant qu'une boîte qui déborde.
		_check("  et occupe la largeur offerte (%d)" % dialog.size.x,
			dialog.size.x >= int(PHONE.x * 0.7))
		_check("  hauteur %d ≤ écran %d" % [dialog.size.y, PHONE.y], dialog.size.y <= PHONE.y)
		# Une boîte plus large que l'écran est aussi une boîte dont le bord gauche est
		# négatif : c'est par là qu'on s'en aperçoit sur l'appareil.
		_check("  posée entièrement dans l'écran", dialog.position.x >= 0)
		dialog.queue_free()
		await process_frame
	tab.queue_free()
	await process_frame

## Les écrans de réglages qui sont des FORMULAIRES doivent pouvoir défiler.
##
## Rien ne le signale quand ils ne le peuvent pas : le contenu excédentaire est
## simplement coupé au bas de l'écran, et l'absence de barre ne se distingue pas d'un
## écran qui tient tout entier. Le réglage du planning s'est allongé jusqu'à dépasser un
## téléphone sans que personne ne s'en aperçoive — c'est cette mesure-là qui manquait.
func _test_settings_scroll() -> void:
	print("--- Les réglages défilent sur téléphone ---")
	# La configuration la PLUS chargée, celle qui pose le problème : deux repas par jour
	# et le marqueur de transport actif, qui déplie ses semaines de cases à cocher. Un
	# écran mesuré dans sa version la plus courte ne dit rien de sa version longue.
	var store = root.get_node("/root/DataStore")
	store.set_plan_shape(4, 5, 2)
	store.set_transport_marker_enabled(true)
	var window: Window = load("res://ui/settings/SettingsWindow.gd").new()
	root.add_child(window)
	await process_frame
	await process_frame

	for index in range(window.SECTIONS.size()):
		var section_name := str(window.SECTIONS[index]["name"])
		window._select(index)
		for _i in range(3):
			await process_frame
		# La carte blanche doit tenir ENTRE LES MARGES de la fenêtre, et non simplement
		# dans l'écran : c'est là qu'elle vit. La comparer à la largeur brute laissait
		# passer un débordement d'une unité — exactement celui qui se voyait à l'écran.
		#
		# Sa largeur minimale est celle du plus large de ses contenus, et une CheckBox ne
		# replie pas son texte : une phrase de libellé un peu longue imposait 384 unités
		# à toute la carte.
		# La place offerte à la carte : la largeur de la FENÊTRE moins les marges qu'elle
		# déclare. Ni supposée — la fenêtre code 12 là où `Layout` annonce 10 —, ni prise
		# sur le parent de la carte : celui-ci s'élargit AVEC le débordement, et mesurer
		# dessus revenait à comparer la carte à elle-même. Un débordement d'une unité y
		# passait donc inaperçu, et c'est celui qui se voyait à l'écran.
		var card: Control = window._detail
		var frame: MarginContainer = null
		for child in window.get_children():
			if child is MarginContainer:
				frame = child
				break
		var available := float(PHONE.x)
		if frame != null:
			available -= float(frame.get_theme_constant("margin_left")
				+ frame.get_theme_constant("margin_right"))
		_check("%s : la carte tient entre les marges (%.0f ≤ %.0f)"
			% [section_name, card.get_combined_minimum_size().x, available],
			card.get_combined_minimum_size().x <= available)

		var scroll := _find_scroll(window._sections[index])
		_check("%s : un conteneur défilant l'englobe ou lui appartient" % section_name,
			scroll != null)
		if scroll == null:
			continue
		# Le contenu doit pouvoir DÉPASSER, sans quoi le conteneur ne servirait à rien :
		# une section écrasée à la hauteur visible ne défile pas davantage qu'une
		# section sans conteneur.
		_check("  et son contenu n'est pas écrasé à la hauteur visible",
			scroll.get_v_scroll_bar().max_value > 0.0)
	window.queue_free()
	await process_frame

## Premier ScrollContainer trouvé en remontant depuis la section, puis en la parcourant :
## certaines sections portent leur propre liste, d'autres sont enfermées par la fenêtre.
func _find_scroll(section: Control) -> ScrollContainer:
	var node: Node = section
	while node != null:
		if node is ScrollContainer:
			return node
		node = node.get_parent()
	return _find_scroll_below(section)

func _find_scroll_below(node: Node) -> ScrollContainer:
	for child in node.get_children():
		if child is ScrollContainer:
			return child
		var found := _find_scroll_below(child)
		if found != null:
			return found
	return null

## Contrôles visibles qui débordent de la fenêtre.
##
## Le contenu d'un ScrollContainer est explicitement exclu : y déborder est sa raison
## d'être, et la liste des 73 recettes à partager mesure légitimement dix écrans de
## haut. C'est le conteneur lui-même qui doit tenir, pas ce qu'il transporte.
func _offscreen(window: Window) -> Array:
	var stray: Array = []
	_collect_offscreen(window, Rect2(Vector2.ZERO, Vector2(window.size)), stray)
	return stray

func _collect_offscreen(node: Node, bounds: Rect2, stray: Array) -> void:
	for child in node.get_children():
		var control := child as Control
		if control != null and control.is_visible_in_tree():
			var rect := control.get_global_rect()
			# Seuls les contrôles PORTEURS sont retenus : un conteneur qui déborde le
			# signale déjà par ceux qu'il contient, et les nommer tous noierait la cause
			# sous ses conséquences.
			if (control is Button or control is Label or control is LineEdit) \
				and not bounds.encloses(rect) and rect.size.x > 0.0:
				stray.append(_describe(control))
		if not (child is ScrollContainer):
			_collect_offscreen(child, bounds, stray)

func _describe(control: Control) -> String:
	if control is Button:
		return "« %s »" % (control as Button).text
	if control is Label:
		return "« %s »" % (control as Label).text.substr(0, 24)
	return control.get_class()

func _count_descendants(node: Node) -> int:
	var total := node.get_child_count()
	for child in node.get_children():
		total += _count_descendants(child)
	return total

## Cherche un bouton dont le libellé permet de refermer, ou le gestionnaire du geste
## « retour » d'Android.
func _has_exit(window: Window) -> bool:
	if window.has_method("_notification"):
		return true
	return _find_exit_button(window)

func _find_exit_button(node: Node) -> bool:
	if node is Button:
		var label := (node as Button).text.to_lower()
		for token in EXIT_LABELS:
			if label.contains(token):
				return true
	for child in node.get_children():
		if _find_exit_button(child):
			return true
	return false

## La barre de titre des sous-fenêtres est dessinée AU-DESSUS de la zone client,
## hors du rectangle de la fenêtre. Un fond sans marge d'expansion supérieure ne peint
## donc que la zone client, et la bande de titre reste transparente : titre et croix se
## retrouvent tracés à même le contenu situé derrière, illisibles. Le défaut se voyait
## à l'œil mais rien ne l'empêchait de revenir.
func _test_title_bar_theme() -> void:
	print("--- Barre de titre des sous-fenêtres ---")
	# Récupéré à l'exécution : les identifiants d'autoload ne sont pas résolus à la
	# compilation d'un script lancé par --script.
	var palette := root.get_node_or_null("/root/Palette")
	if palette == null:
		_check("autoload Palette disponible", false)
		return
	var theme: Theme = palette.ui_theme
	var height: int = theme.get_constant("title_height", "Window")

	for item in ["embedded_border", "embedded_unfocused_border"]:
		# Les deux : une fenêtre sans le focus utilise la seconde, et n'en définir
		# qu'une laissait la moitié des cas non peints.
		var has: bool = theme.has_stylebox(item, "Window")
		_check("%s défini" % item, has)
		if not has:
			continue
		var box: StyleBox = theme.get_stylebox(item, "Window")
		_check("%s : fond opaque" % item,
			box is StyleBoxFlat and (box as StyleBoxFlat).bg_color.a > 0.99)
		_check("%s : couvre la bande de titre" % item,
			box.expand_margin_top >= height)
		# La barre de titre a la couleur de l'en-tête de l'application : sans liseré
		# clair, la popup s'y fondait.
		_check("%s : cadré d'un liseré blanc" % item,
			box is StyleBoxFlat and (box as StyleBoxFlat).border_width_left > 0
			and (box as StyleBoxFlat).border_width_top > 0
			and (box as StyleBoxFlat).border_color.is_equal_approx(Color.WHITE))

	_check("le titre contraste avec son fond",
		theme.get_color("title_color", "Window").get_luminance() > 0.7)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
