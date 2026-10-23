extends SceneTree
## Cohabitation avec le clavier virtuel d'Android.
## godot --headless --path . --script res://tools/test_keyboard.gd
##
## Le clavier se pose PAR-DESSUS l'application, sans que la fenêtre ni le viewport ne
## rétrécissent : un champ situé dans la moitié basse de l'écran se remplissait à
## l'aveugle. Rien de tout cela n'existe sur ordinateur — c'est-à-dire là où
## l'application est écrite —, et un appareil ne dit pas POURQUOI il se trompe. Les
## trois calculs en cause sont donc séparés de tout écran et vérifiés ici.

## Chargés à l'exécution : lancé en `--script`, le moteur ne compte les autoloads parmi
## les identifiants connus qu'une fois la scène principale en place, et ces trois
## scripts référencent `Layout` ou `Palette`.
var _layout: GDScript = null
var _inset: GDScript = null
var _field: GDScript = null

var _fails := 0

func _initialize() -> void:
	await process_frame
	_layout = load("res://autoload/Layout.gd")
	_inset = load("res://ui/components/KeyboardInset.gd")
	_field = load("res://ui/components/AutocompleteEdit.gd")

	_test_units()
	_test_scroll_delta()
	_test_popup_origin()
	await _test_wiring()
	await _test_recipe_form(false)
	await _test_recipe_form(true)

	print("")
	print("Clavier virtuel conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## La hauteur rendue par le système est en PIXELS, quand tout le reste de l'interface
## se mesure en unités logiques. Confondre les deux ne se voit pas sur un écran à
## l'échelle 1 — tout poste de développement — et rend l'application inutilisable sur
## un écran dense, où elle se croirait recouverte de fond en comble.
func _test_units() -> void:
	print("--- Hauteur du clavier en unités ---")
	_check("clavier replié : zéro", is_zero_approx(_layout.keyboard_units(0.0, 2.75)))
	_check("échelle 1 (bureau) : inchangée",
		is_equal_approx(_layout.keyboard_units(900.0, 1.0), 900.0))
	# Redmi Note 10 Pro : ~440 dpi, donc une échelle de 2,75.
	_check("écran dense : 900 px valent ~327 unités",
		absf(_layout.keyboard_units(900.0, 2.75) - 327.27) < 0.1)
	_check("un clavier de 900 px n'engloutit pas un écran de 915 unités",
		_layout.keyboard_units(900.0, 2.75) < 400.0)

func _test_scroll_delta() -> void:
	print("--- Défilement pour dégager le champ ---")
	# Liste occupant tout l'écran d'un téléphone, clavier déplié sur les 330 du bas.
	var view := Rect2(Vector2(0, 100), Vector2(412, 815))
	var usable := 585.0

	_check("champ déjà visible : immobile",
		is_zero_approx(_inset.scroll_delta(view, Rect2(Vector2(0, 300), Vector2(400, 48)), usable)))
	var hidden := Rect2(Vector2(0, 700), Vector2(400, 48))
	var delta: float = _inset.scroll_delta(view, hidden, usable)
	_check("champ sous le clavier : la liste descend", delta > 0.0)
	_check("et il passe entièrement au-dessus du clavier",
		hidden.end.y - delta <= usable)
	_check("avec une respiration au-dessus des touches",
		hidden.end.y - delta < usable)

	# Sans clavier, seul le bas de la zone visible compte.
	_check("clavier replié : le bas de la liste suffit",
		is_zero_approx(_inset.scroll_delta(view, Rect2(Vector2(0, 800), Vector2(400, 48)), 915.0)))

	# Champ remonté au-dessus de la zone par un défilement précédent.
	_check("champ au-dessus de la zone : la liste remonte",
		_inset.scroll_delta(view, Rect2(Vector2(0, 40), Vector2(400, 48)), usable) < 0.0)

	# Pavé d'étapes plus haut que la place laissée par le clavier : c'est son DÉBUT
	# qu'il faut montrer, le curseur y étant, et non sa fin.
	var tall := Rect2(Vector2(0, 300), Vector2(400, 500))
	var tall_delta: float = _inset.scroll_delta(view, tall, usable)
	_check("champ plus haut que la place : son début reste visible",
		tall.position.y - tall_delta >= view.position.y)

func _test_popup_origin() -> void:
	print("--- Popup de suggestions face au clavier ---")
	var popup := Vector2(400, 120)
	var high := Rect2(Vector2(6, 200), Vector2(400, 48))
	_check("de la place dessous : la popup y reste",
		_field.popup_origin(high, popup, 585.0).y > high.end.y)

	# Le cas qui nous occupe : champ juste au-dessus du clavier.
	var low := Rect2(Vector2(6, 520), Vector2(400, 48))
	var origin: Vector2 = _field.popup_origin(low, popup, 585.0)
	_check("pas de place dessous : la popup passe au-dessus", origin.y < low.position.y)
	_check("et elle ne recouvre pas le champ", origin.y + popup.y <= low.position.y)
	_check("la popup reste alignée sur le champ", is_equal_approx(origin.x, low.position.x))

	# Écran entièrement mangé : mieux vaut rogner par le bas que par le haut, où se
	# trouvent les premières suggestions — celles qui comptent.
	var squeezed: Vector2 = _field.popup_origin(Rect2(Vector2(6, 40), Vector2(400, 48)),
		Vector2(400, 300), 200.0)
	_check("popup trop haute : elle ne déborde pas par le haut", squeezed.y >= 0.0)

## Le MONTAGE, et non plus le seul calcul.
##
## Les trois épreuves ci-dessus vérifiaient trois formules justes, dans un composant
## correctement branché nulle part : les trois appelants posaient l'inset AVANT le
## conteneur du contenu, et `add_child` déclenchant `_ready()` sur-le-champ, celui-ci ne
## trouvait rien à qui donner sa marge. Restait le défilement seul, qui traite tous les
## champs sauf le dernier — c'est-à-dire exactement celui qu'on visait. Le défaut a
## survécu à toute la 1.7 sous un test vert.
func _test_wiring() -> void:
	print("--- La marge basse atteint bien la liste ---")
	var host := Control.new()
	root.add_child(host)
	await process_frame

	var list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	var items := []
	var aisles: Array = root.get_node("/root/DataStore").get_aisle_names()
	for i in range(20):
		items.append({"nom": "Article %d" % i, "qty": "1", "aisle": aisles[i % aisles.size()],
			"checked": false})
	list.setup(items, aisles)
	host.add_child(list)
	list.rebuild()
	await process_frame

	var inset := _find_inset(list)
	_check("la liste de courses porte un inset", inset != null)
	if inset == null:
		return
	# Le clavier n'existe pas en headless : on lui impose la hauteur qu'il aurait sur le
	# Redmi, ~900 px pour une échelle de 2,75.
	inset._set_inset(327.0)
	await process_frame
	var body: MarginContainer = inset._find_body()
	_check("l'inset a trouvé le conteneur du contenu", body != null)
	if body != null:
		_check("une marge basse de la hauteur du clavier y est posée",
			body.get_theme_constant("margin_bottom") >= 327)
	inset._set_inset(0.0)
	await process_frame
	if body != null:
		_check("clavier replié : la marge est rendue",
			not body.has_theme_constant_override("margin_bottom"))

	# Les deux autres écrans montent le même composant, et l'ont monté de la même façon.
	for path in ["res://ui/recipes/RecipePopup.gd", "res://ui/breakfast/BreakfastPopup.gd"]:
		var window = load(path).new()
		host.add_child(window)
		await process_frame
		var other := _find_inset(window)
		_check("%s : inset présent" % path.get_file(), other != null)
		if other != null:
			other._set_inset(327.0)
			_check("  et il trouve son conteneur", other._find_body() != null)
		window.queue_free()
		await process_frame
	host.queue_free()
	await process_frame

## Le formulaire de recette, champ par champ, clavier déplié.
##
## Le seul écran dont on saisit TOUS les champs de bout en bout, et le plus long : les
## ingrédients s'y ajoutent les uns sous les autres, chacun poussant le suivant vers le
## clavier. Les épreuves précédentes vérifient une formule et un branchement ; celle-ci
## vérifie le résultat — le champ est-il visible, oui ou non.
func _test_recipe_form(creation: bool) -> void:
	print("--- Le formulaire de recette face au clavier (%s) ---"
		% ["modification", "création"][int(creation)])
	# Gabarit téléphone : sans lui la fenêtre d'essai fait 64 unités de haut, et la limite
	# du clavier tombe dans les négatifs. La mesure ne dirait alors rien de l'appareil.
	root.size = Vector2i(412, 915)
	await process_frame
	await process_frame
	var store = root.get_node("/root/DataStore")
	var popup: Window = load("res://ui/recipes/RecipePopup.gd").new()
	# La création part d'un formulaire COURT — une seule ligne d'ingrédient vide — puis
	# s'allonge sous les doigts. C'est un cas distinct, et c'est celui qu'on remplit
	# vraiment de bout en bout.
	popup.recipe = null if creation else store.get_all_recipe_objects()[0]
	popup.editable = true
	root.add_child(popup)
	for _i in range(4):
		await process_frame

	var inset := _find_inset(popup)
	if inset == null:
		_check("le formulaire porte un inset", false)
		return
	var scroll: ScrollContainer = inset.get_parent()

	# Le DERNIER champ du formulaire : celui qu'aucun défilement ne peut remonter tant
	# que la liste s'arrête à lui.
	if creation:
		# Trois ingrédients ajoutés à la main, comme on le fait en saisissant : chaque
		# ligne naît APRÈS la mise en page et pousse la suivante vers le bas.
		for _i in range(3):
			popup._add_row()
		popup._apply_editable()
		for _i in range(4):
			await process_frame

	var fields := _fields(scroll)
	_check("le formulaire a des champs (%d)" % fields.size(), fields.size() > 3)
	if fields.is_empty():
		popup.queue_free()
		return
	var last: Control = fields[fields.size() - 1]
	# Hauteur du clavier sur le Redmi (900 px pour une échelle de 2,75), que le système ne
	# rend pas en headless.
	var keyboard := 327.0

	# TOUS les champs, l'un après l'autre. Le dernier est le cas le plus dur, mais ce n'est
	# pas forcément le seul qui échoue — et un formulaire dont un champ sur vingt reste
	# caché est signalé comme « le clavier cache le champ », sans dire lequel.
	var layout_probe = root.get_node("/root/Layout")
	layout_probe.forced_keyboard_height = keyboard
	var hidden: Array[String] = []
	for index in range(fields.size()):
		var target: Control = fields[index]
		target.grab_focus()
		for _i in range(8):
			await process_frame
		var rect := target.get_global_rect()
		var limit: float = root.get_visible_rect().size.y - keyboard
		if rect.end.y > limit + 0.5:
			hidden.append("#%d %s bas=%.0f" % [index, target.get_class(), rect.end.y])
	layout_probe.forced_keyboard_height = -1.0
	for _i in range(6):
		await process_frame
	_check("aucun champ ne reste sous le clavier%s"
		% ("" if hidden.is_empty() else " — " + ", ".join(hidden)), hidden.is_empty())

	# On amène d'abord la liste à son terme, comme le ferait le doigt en descendant vers
	# le champ qu'on veut remplir.
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	for _i in range(3):
		await process_frame
	var before := scroll.scroll_vertical

	last.grab_focus()
	for _i in range(3):
		await process_frame
	# Le clavier se déplie : on impose sa hauteur à `Layout`, et c'est le chemin RÉEL de
	# l'application qui s'exécute ensuite — sa boucle, son délai de stabilisation, son
	# défilement. Poser la marge à la main aurait été un autre code que le sien : sa
	# boucle relit la hauteur du système à chaque image et l'aurait retirée aussitôt.
	var layout = root.get_node("/root/Layout")
	layout.forced_keyboard_height = keyboard
	for _i in range(10):
		await process_frame

	var usable: float = root.get_visible_rect().size.y - keyboard
	var field := last.get_global_rect()
	_check("le dernier champ passe au-dessus du clavier (bas=%.0f, limite=%.0f)"
		% [field.end.y, usable], field.end.y <= usable)
	_check("  et la liste a bien pu défiler plus loin (%d → %d)"
		% [before, scroll.scroll_vertical], scroll.scroll_vertical > before)
	_check("  le champ reste dans la zone visible",
		field.position.y >= scroll.get_global_rect().position.y - 1.0)

	# LE CAS DU PAVÉ D'ÉTAPES : un champ multi-lignes plus haut que la place laissée par le
	# clavier. Montrer son début ne suffit plus dès qu'on écrit — le curseur descend ligne
	# après ligne, et passe sous le clavier alors que le champ, lui, est bien visible.
	if popup._steps != null:
		popup._steps.text = ""
		for line in range(25):
			popup._steps.text += "Étape %d de la recette, écrite au doigt.\n" % line
		popup._steps.grab_focus()
		popup._steps.set_caret_line(popup._steps.get_line_count() - 1)
		for _i in range(8):
			await process_frame
		var limit: float = root.get_visible_rect().size.y - keyboard
		var caret: Vector2 = popup._steps.get_global_transform() \
			* popup._steps.get_caret_draw_pos()
		_check("en écrivant les étapes, le curseur reste visible (y=%.0f, limite=%.0f)"
			% [caret.y, limit], caret.y <= limit)

	# CE QUI DÉPLACE LE CHAMP APRÈS COUP. La remontée n'avait lieu qu'une fois, juste après
	# que la hauteur du clavier s'était stabilisée : tout ce qui survenait ensuite renvoyait
	# le champ sous le clavier sans recours. Ici, trois lignes d'ingrédient ajoutées le
	# clavier déjà déplié — le geste même de la saisie d'une recette.
	last.grab_focus()
	for _i in range(6):
		await process_frame
	for _i in range(3):
		popup._add_row()
	popup._apply_editable()
	for _i in range(8):
		await process_frame
	var moved := last.get_global_rect()
	_check("le champ reste visible après un ajout de ligne (bas=%.0f, limite=%.0f)"
		% [moved.end.y, usable], moved.end.y <= usable)

	layout.forced_keyboard_height = -1.0
	popup.queue_free()
	await process_frame

## Champs de saisie du formulaire, dans l'ordre où ils s'y présentent.
func _fields(node: Node, out: Array[Control] = []) -> Array[Control]:
	for child in node.get_children():
		if child is LineEdit or child is TextEdit:
			out.append(child)
		_fields(child, out)
	return out

func _find_inset(node: Node) -> Node:
	for child in node.get_children():
		if child.get_script() == _inset:
			return child
		var found := _find_inset(child)
		if found != null:
			return found
	return null

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [ok] %s" % label)
	else:
		print("  [ÉCHEC] %s" % label)
		_fails += 1
