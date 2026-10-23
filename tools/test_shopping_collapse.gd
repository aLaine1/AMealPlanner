extends SceneTree
## Vérifie le repli des rayons de la liste de courses (mode magasin).
## godot --headless --path . --script res://tools/test_shopping_collapse.gd

const AISLES := ["Frais", "Fruits et Légumes", "Divers"]
const TouchTapScript := preload("res://ui/components/TouchTap.gd")
const MotionScript := preload("res://ui/components/Motion.gd")
const HapticsScript := preload("res://ui/components/Haptics.gd")

var _fails := 0

func _initialize() -> void:
	var store = load("res://autoload/DataStore.gd").new()
	store._db = LocalDatabase.new()
	store._db.open()
	store._refresh_cache()
	root.add_child(store)
	store.name = "DataStore"   # ShoppingStoreList y accède par le nom d'autoload

	var saved: String = store.get_ui_preference("shopping_collapsed", "{}")

	var items := [
		{"nom": "Beurre", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": true},
		{"nom": "Lait", "quantite": 1.0, "unite": "l", "aisle": "Frais", "checked": false},
		{"nom": "Tomate", "quantite": 3.0, "unite": "", "aisle": "Fruits et Légumes", "checked": false},
	]

	var list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	list.animate_moves = false   # gestes enchaînés : liste immobile (cf. _test_move_animation)
	list.setup(items, AISLES)
	root.add_child(list)
	await process_frame
	list.rebuild()
	await process_frame

	print("--- État déplié ---")
	# 2 en-têtes + 3 articles + 1 champ d'ajout par rayon déplié.
	_check("2 en-têtes + 3 articles + 2 champs d'ajout", _count_rows(list) == 7)
	_check("en-tête déplié : chevron ▾", _header_text(list, "Frais").begins_with("▾"))
	# Cochés/total et non le seul total : un rayon replié doit rester lisible.
	_check("en-tête : cochés/total", _header_text(list, "Frais").contains("(1/2)"))

	print("--- Rayon replié ---")
	list._toggle_aisle("Frais")
	await process_frame
	# Frais replié : son article ET son champ d'ajout disparaissent avec lui.
	_check("les articles du rayon disparaissent", _count_rows(list) == 4)
	_check("l'en-tête reste visible", _header_text(list, "Frais") != "")
	_check("chevron ▸", _header_text(list, "Frais").begins_with("▸"))
	_check("le compte reste affiché", _header_text(list, "Frais").contains("(1/2)"))
	_check("l'autre rayon n'est pas touché", _header_text(list, "Fruits et Légumes").begins_with("▾"))

	print("--- Mémorisation ---")
	var stored: String = store.get_ui_preference("shopping_collapsed", "{}")
	var parsed = JSON.parse_string(stored)
	_check("état enregistré", typeof(parsed) == TYPE_DICTIONARY and parsed.get("Frais", false))
	# Préférence d'affichage locale : replier un rayon en magasin ne doit pas changer
	# l'écran du PC resté à la maison.
	_check("rangé hors des tables synchronisées", _is_outside_synced_tables(store._db))

	list._toggle_aisle("Frais")
	await process_frame
	_check("redéploiement", _count_rows(list) == 7)

	print("--- Ordre d'affichage ---")
	# « Échalote » vérifie le repli d'accents : comparés par code Unicode, les
	# accentués se rangeaient tous APRÈS « Zeste », en fin de rayon.
	var ordered := [
		{"nom": "Zeste", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
		{"nom": "Échalote", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
		{"nom": "Ail", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": true},
		{"nom": "Beurre", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
	]
	var sorted_list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	sorted_list.animate_moves = false   # gestes enchaînés : liste immobile (cf. _test_move_animation)
	sorted_list.setup(ordered, ["Frais"])
	root.add_child(sorted_list)
	await process_frame
	sorted_list.rebuild()
	await process_frame
	_check("alphabétique, accents à leur place, cochés en bas",
		_row_names(sorted_list) == ["Beurre", "Échalote", "Zeste", "Ail"])

	sorted_list._toggle(ordered[1])   # Échalote
	await process_frame
	_check("cocher pousse l'article en bas de son rayon",
		_row_names(sorted_list) == ["Beurre", "Zeste", "Ail", "Échalote"])

	print("--- Ajout de dernière minute ---")
	# La vue magasin ne savait que cocher : un article oublié devait attendre le PC.
	var quick := [
		{"_uid": 1, "nom": "Beurre", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": true},
	]
	var uid := 100
	var quick_list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	quick_list.animate_moves = false   # gestes enchaînés : liste immobile (cf. _test_move_animation)
	quick_list.setup(quick, AISLES, func(a):
		uid += 1
		return {"_uid": uid, "nom": "", "quantite": 1.0, "unite": "", "aisle": a, "checked": false})
	root.add_child(quick_list)
	await process_frame
	quick_list.rebuild()
	await process_frame

	# Un ingrédient connu apporte son rayon : c'est ce qui permet de ne taper qu'un nom.
	quick_list._on_add_submitted("tomate", "Fruits et Légumes")
	await process_frame
	var added = quick[quick.size() - 1]
	_check("article ajouté", quick.size() == 2 and str(added["nom"]) == "tomate")
	# Le rayon vient du groupe au pied duquel on a écrit, pas du nom saisi.
	_check("rangé dans le rayon où l'on a écrit",
		str(added["aisle"]) == "Fruits et Légumes")
	_check("ajouté comme restant à prendre", not added["checked"])

	# Un nom inconnu ne doit pas bloquer l'ajout ni inventer un rayon.
	quick_list._on_add_submitted("ZZZ truc oublié", "Divers")
	await process_frame
	_check("nom inconnu accepté", quick.size() == 3)
	_check("rangé dans son rayon quel que soit le nom", str(quick[2]["aisle"]) == "Divers")
	# Un rayon inconnu de la vue ne doit pas créer un groupe fantôme.
	quick_list._on_add_submitted("ZZZ rayon absent", "Rayon qui n'existe pas")
	_check("rayon inconnu ramené au repli",
		str(quick[3]["aisle"]) == store.fallback_aisle())

	# Redemander un article déjà là ne doit pas créer de doublon : il redevient à prendre.
	quick_list._on_add_submitted("Beurre", "Frais")
	await process_frame
	_check("pas de doublon", quick.size() == 4)
	_check("l'article redemandé est remis à prendre", not quick[0]["checked"])

	quick_list._on_add_submitted("   ", "Frais")
	_check("saisie vide ignorée", quick.size() == 4)

	print("--- Toucher bref : agit sur ce qu'il touche (2.0.4) ---")
	# `list` est encore le jeu du tout début du fichier ({"nom": "Beurre", …}, {"nom":
	# "Lait", …}, {"nom": "Tomate", …}) — redéplié plus haut, donc dans l'état connu.
	await process_frame

	var lait: Dictionary = items[1]   # {"nom": "Lait", "quantite": 1.0, "unite": "l", ...}, non coché
	var row := _find_row(list, "Lait")
	_check("ligne « Lait » trouvée", row != null)
	var check_icon: Control = row.get_child(0).get_child(0)
	var name_label: Label = row.get_child(0).get_child(1)
	var qty_label: Label = row.get_child(0).get_child(2)

	print("  sur la case : bascule, avec une vibration")
	var before := bool(lait["checked"])
	var ticks_before: int = HapticsScript.ticks
	_tap(row, check_icon.global_position + check_icon.size / 2)
	await process_frame
	_check("coché par un tap sur la case", bool(lait["checked"]) != before)
	_check("…qui fait vibrer une fois", HapticsScript.ticks == ticks_before + 1)
	_check("…sans ouvrir d'éditeur", _last_field(list) == null)

	# `_toggle` reconstruit toute la liste (l'article coché descend en bas de son rayon) :
	# la ligne et ses enfants d'avant sont libérés, il faut les retrouver après CHAQUE tap
	# qui bascule — pas seulement le premier.
	row = _find_row(list, "Lait")
	# La marge à gauche de la case compte pour la case : c'est la cible la plus facile.
	_tap(row, row.global_position + Vector2(2, row.size.y / 2))
	await process_frame
	_check("décoché par un tap dans la marge gauche", bool(lait["checked"]) == before)
	row = _find_row(list, "Lait")
	name_label = row.get_child(0).get_child(1)
	qty_label = row.get_child(0).get_child(2)

	print("  sur le nom : l'édite dans la ligne, ne bascule pas")
	var emitted := [0]
	list.changed.connect(func(): emitted[0] += 1)
	_tap(row, name_label.global_position + name_label.size / 2)
	await process_frame
	_check("pas basculé par un tap sur le nom", bool(lait["checked"]) == before)
	var name_field := _last_field(list)
	_check("champ du nom ouvert", name_field != null)
	if name_field != null:
		_check("pré-rempli avec le nom", name_field.text == "Lait")
		# Pas de cadre par-dessus la liste (2.0.5) : le champ prend la place du texte.
		_check("posé DANS la ligne, à la place du nom",
			name_field.get_parent() == name_label.get_parent()
			and name_field.get_index() == 1 and not name_label.visible)
		_check("aucun cadre flottant", _floating_panel(list) == null)
		_check("même taille de police que le nom",
			name_field.get_theme_font_size("font_size") == name_label.get_theme_font_size("font_size"))
		# Inchangé puis quitté : rien n'est réécrit.
		_tap_outside(list)
		await process_frame
		_check("quitté sans modification : rien d'émis", emitted[0] == 0)
		_check("le nom réapparaît", is_instance_valid(name_label) and name_label.visible)
	await process_frame

	print("  modifié puis quitté par un toucher ailleurs : gardé")
	row = _find_row(list, "Lait")
	name_label = row.get_child(0).get_child(1)
	_tap(row, name_label.global_position + name_label.size / 2)
	await process_frame
	name_field = _last_field(list)
	if name_field != null:
		name_field.text = "Lait demi-écrémé"
		_tap_outside(list)
		await process_frame
	_check("nom gardé en quittant", str(lait["nom"]) == "Lait demi-écrémé")
	_check("…et signalé pour sauvegarde", emitted[0] == 1)
	_check("le toucher qui valide ne coche rien au passage", bool(lait["checked"]) == before)
	lait["nom"] = "Lait"
	list.rebuild()
	await process_frame
	row = _find_row(list, "Lait")
	name_label = row.get_child(0).get_child(1)
	qty_label = row.get_child(0).get_child(2)

	print("  pendant l'édition, la sync ne recharge pas la liste")
	_tap(row, name_label.global_position + name_label.size / 2)
	await process_frame
	_check("la liste se dit en cours d'édition", list.is_editing())
	_tap_outside(list)
	await process_frame
	_check("…puis plus", not list.is_editing())

	print("  sur la quantité : ouvre SON champ, pas celui du nom")
	_tap(row, qty_label.global_position + qty_label.size / 2)
	await process_frame
	var qty_field := _last_field(list)
	_check("éditeur de quantité ouvert", qty_field != null)
	if qty_field != null:
		# Quantité ET unité dans le MÊME champ (1.10.5) : « 1 l », pas « 1 ».
		_check("pré-rempli avec quantité + unité réunies", qty_field.text == "1 l")
		# Édite la chaîne réunie ; « 500 g » doit répartir 500 en quantité et g en unité.
		_check("posé à la place de la quantité",
			qty_field.get_index() == 2 and not qty_label.visible)
		qty_field.text = "500 g"
		qty_field.emit_signal("text_submitted", "500 g")
		await process_frame
		_check("quantité mise à jour", is_equal_approx(float(lait["quantite"]), 500.0))
		_check("unité mise à jour", str(lait["unite"]) == "g")
	_check("pas basculé par un tap sur la quantité", bool(lait["checked"]) == before)

	# « 1 » seul fait une dizaine de pixels : la cible de la quantité s'étend jusqu'au bord.
	row = _find_row(list, "Lait")
	_tap(row, row.global_position + Vector2(row.size.x - 3, row.size.y / 2))
	await process_frame
	_check("le bord droit de la ligne vise la quantité",
		_last_field(list) != null and _last_field(list).text == "500 g")
	_tap_outside(list)
	await process_frame

	print("--- Appui long : propose de retirer l'article, où qu'il soit ---")
	var spots := ["la case", "le nom", "la quantité"]   # dans l'ordre des enfants de la ligne
	for spot in spots:
		row = _find_row(list, "Lait")
		var target: Control = row.get_child(0).get_child(spots.find(spot))
		await _hold(row, target.global_position + target.size / 2)
		await process_frame
		_check("sur %s : ni bascule, ni éditeur" % spot,
			bool(lait["checked"]) == before and _last_field(list) == null)
		_check("sur %s : bouton Supprimer proposé" % spot, _delete_button(list) != null)
		_dismiss_floating(list)
		await create_timer(MotionScript.POP_DURATION + 0.15).timeout
		_check("sur %s : refermé par un tap ailleurs, article conservé" % spot,
			_delete_button(list) == null and _find_row(list, "Lait") != null)

	emitted[0] = 0
	row = _find_row(list, "Lait")
	await _hold(row, row.global_position + row.size / 2)
	await process_frame
	var delete_button := _delete_button(list)
	if delete_button != null:
		delete_button.pressed.emit()
		await create_timer(MotionScript.POP_DURATION + 0.15).timeout
	_check("Supprimer retire l'article", not items.has(lait) and _find_row(list, "Lait") == null)
	_check("…et le signale pour sauvegarde", emitted[0] == 1)
	_check("les autres articles restent", items.size() == 2)
	# L'article du test suivant : remis à l'identique dans le jeu, la liste le réaffiche.
	lait = {"nom": "Lait", "quantite": 1.0, "unite": "l", "aisle": "Frais", "checked": false}
	items.insert(1, lait)
	list.rebuild()
	await process_frame

	print("--- Le champ reste au-dessus du clavier virtuel ---")
	# Dans la ligne, le champ est dans la zone défilante : c'est `KeyboardInset`, déjà
	# éprouvé par test_keyboard.gd pour le champ d'ajout, qui le remonte. Il suffit donc
	# qu'il le prenne en charge.
	row = _find_row(list, "Lait")
	name_label = row.get_child(0).get_child(1)
	_tap(row, name_label.global_position + name_label.size / 2)
	await process_frame
	var field := _last_field(list)
	var inset = _find_inset(list)
	_check("éditeur ouvert", field != null)
	_check("suivi par le KeyboardInset de la liste",
		field != null and inset != null and inset._accepts(field))
	_tap_outside(list)
	await process_frame

	print("--- Clavier replié pendant la saisie : validé, comme « OK » (2.0.6) ---")
	# Le clavier n'existe que sur l'appareil : on impose sa hauteur, comme test_keyboard.gd.
	var layout := root.get_node("/root/Layout")
	emitted[0] = 0
	row = _find_row(list, "Lait")
	name_label = row.get_child(0).get_child(1)
	_tap(row, name_label.global_position + name_label.size / 2)
	await process_frame
	await process_frame
	# Clavier pas encore déplié (il met quelques images après la prise de focus) : une
	# hauteur nulle à ce moment n'est pas une fermeture.
	_check("le champ reste ouvert tant que le clavier ne s'est pas montré", list.is_editing())
	field = _last_field(list)
	if field != null:
		field.text = "Lait entier"
	layout.forced_keyboard_height = 300.0
	await process_frame
	await process_frame
	_check("clavier ouvert : le champ reste ouvert", list.is_editing())
	layout.forced_keyboard_height = 0.0
	await process_frame
	await process_frame
	_check("clavier replié : la saisie est close", not list.is_editing())
	_check("…et gardée", str(lait["nom"]) == "Lait entier" and emitted[0] == 1)
	layout.forced_keyboard_height = -1.0
	lait["nom"] = "Lait"
	list.rebuild()
	await process_frame

	await _test_move_animation(store)
	await _test_add_field_scroll()

	quick_list.queue_free()
	store.set_ui_preference("shopping_collapsed", saved)
	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

## Cocher fait glisser l'article vers le bas de son rayon (2.0.10) au lieu de le téléporter.
func _test_move_animation(_store) -> void:
	print("--- Cocher : l'article glisse vers le bas ---")
	var items := [
		{"nom": "Ail", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
		{"nom": "Beurre", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
		{"nom": "Crème", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false},
	]
	var list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	list.setup(items, AISLES)
	root.add_child(list)
	await process_frame
	list.rebuild()
	await process_frame
	await process_frame
	var emitted := [0]
	list.changed.connect(func(): emitted[0] += 1)
	var bottom_before: float = list._list.get_combined_minimum_size().y

	list._toggle(items[0])   # Ail coché : passe après Beurre et Crème
	_check("état et sauvegarde immédiats, sans attendre l'animation",
		items[0]["checked"] and emitted[0] == 1)
	await process_frame
	var ghost: Control = null
	var arriving: Control = null
	for child in list._list.get_children():
		if not child.has_meta("item") and child.get_child_count() > 0 \
				and child.get_child(0).has_meta("item"):
			if child.get_child(0).mouse_filter == Control.MOUSE_FILTER_IGNORE:
				ghost = child
			else:
				arriving = child
	_check("l'ancienne place se referme", ghost != null and ghost.get_index() == 1)
	_check("la nouvelle s'ouvre, en bas du rayon", arriving != null
		and arriving.get_index() > list._list.get_child(2).get_index())
	await create_timer(list.MOVE_DURATION * 0.5).timeout
	if ghost != null and arriving != null:
		# Les deux hauteurs se compensent : rien de ce qui suit ne saute.
		_check("hauteurs compensées en cours de route", absf(ghost.custom_minimum_size.y
			+ arriving.custom_minimum_size.y - float(_touch_row())) < 6.0)
	await create_timer(list.MOVE_DURATION + 0.2).timeout
	_check("ordre final : Beurre, Crème, Ail", _row_names(list) == ["Beurre", "Crème", "Ail"])
	_check("plus de logement : la ligne est rendue à la liste",
		list._row_of(items[0]) != null and list._row_of(items[0]).get_parent() == list._list)
	_check("hauteur de la liste inchangée",
		absf(list._list.get_combined_minimum_size().y - bottom_before) < 1.0)

	# Recocher pendant le glissement : pas de ligne fantôme qui traîne, ni d'article perdu.
	list._toggle(items[1])
	await process_frame
	list._toggle(items[1])
	await create_timer(list.MOVE_DURATION * 2 + 0.2).timeout
	_check("recocher en plein glissement : chaque article une seule fois",
		_row_names(list) == ["Beurre", "Crème", "Ail"])
	list.queue_free()
	await process_frame

func _touch_row() -> int:
	return root.get_node("/root/Layout").TOUCH_ROW

## Un balayage qui part du champ « + Ajouter » fait défiler la liste, sans ouvrir le clavier.
func _test_add_field_scroll() -> void:
	print("--- Champ d'ajout : un balayage ne l'active pas ---")
	var items := [{"nom": "Ail", "quantite": 1.0, "unite": "", "aisle": "Frais", "checked": false}]
	var list = load("res://ui/shopping/ShoppingStoreList.gd").new()
	list.animate_moves = false
	list.setup(items, AISLES)
	root.add_child(list)
	await process_frame
	list.rebuild()
	await process_frame
	var holder: Control = null
	for child in list._list.get_children():
		if child is MarginContainer and child.get_child_count() > 0 and child.get_child(0) is LineEdit:
			holder = child
	_check("(préparation) format téléphone : champ enveloppé", holder != null)
	if holder == null:
		list.queue_free()
		return
	var field: LineEdit = holder.get_child(0)
	_check("le champ n'intercepte rien tant qu'il n'a pas le focus",
		field.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	# Balayage : appui, glissement bien au-delà du seuil, relâchement ailleurs.
	holder.gui_input.emit(_press(Vector2(10, 10)))
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(10, 60)
	holder.gui_input.emit(drag)
	holder.gui_input.emit(_release(Vector2(10, 60)))
	await process_frame
	_check("balayage : pas de focus, pas de clavier", not field.has_focus())
	# Toucher franc : le champ prend le focus et reprend ses événements.
	holder.gui_input.emit(_press(Vector2(10, 10)))
	holder.gui_input.emit(_release(Vector2(10, 10)))
	await process_frame
	_check("toucher franc : le champ prend le focus", field.has_focus())
	_check("…et reçoit de nouveau les gestes (curseur)", field.mouse_filter == Control.MOUSE_FILTER_STOP)
	field.release_focus()
	await process_frame
	_check("focus perdu : il les rend", field.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	list.queue_free()
	await process_frame

func _count_rows(list) -> int:
	return list._list.get_child_count()

## Noms des articles dans l'ordre affiché, en-têtes de rayon exclus (reconnaissables
## à leur chevron, qui est leur premier Label).
func _row_names(list) -> Array:
	var names := []
	for child in list._list.get_children():
		var text := _leading_label(child)
		if text == "" or text.begins_with("▾") or text.begins_with("▸"):
			continue
		names.append(text)
	return names

func _leading_label(node) -> String:
	if node is Label:
		return (node as Label).text
	for child in node.get_children():
		var found := _leading_label(child)
		if found != "":
			return found
	return ""

## La ligne (PanelContainer) dont le nom affiché est `name` — pas l'en-tête de rayon, qui
## commence par un chevron et échoue donc au même test que `_row_names` applique.
func _find_row(list, item_name: String) -> Control:
	for child in list._list.get_children():
		if _leading_label(child) == item_name:
			return child
	return null

## `global_pos` est en coordonnées d'ÉCRAN (celles de `Control.global_position`, pratiques
## à viser depuis un test) ; `InputEvent.position` attend les coordonnées LOCALES du
## contrôle qui reçoit l'événement — c'est ce que porte un événement du moteur réel, et
## `ShoppingStoreList._zone_at` s'appuie dessus pour retrouver le nom ou la quantité tenus.
func _local(control: Control, global_pos: Vector2) -> Vector2:
	return control.get_global_transform_with_canvas().affine_inverse() * global_pos

## Toucher franc : appui puis relâchement au même point, sans attendre — sous `HOLD_MS`,
## `TouchTap.handle` le lit comme un tap.
func _tap(control: Control, global_pos: Vector2) -> void:
	var at := _local(control, global_pos)
	control.gui_input.emit(_press(at))
	control.gui_input.emit(_release(at))

## Appui long : le relâchement doit arriver après `HOLD_MS`, en temps RÉEL — `TouchTap`
## lit l'horloge murale (`Time.get_ticks_msec()`), pas une horloge de test à avancer.
func _hold(control: Control, global_pos: Vector2) -> void:
	var at := _local(control, global_pos)
	control.gui_input.emit(_press(at))
	await create_timer(TouchTapScript.HOLD_MS / 1000.0 + 0.35).timeout
	control.gui_input.emit(_release(at))

## Le champ d'édition ouvert dans une ligne, ou null.
func _last_field(list) -> LineEdit:
	return list._inline_field if list.is_editing() else null

## Un cadre flottant posé sur la fenêtre — l'ancien éditeur (un champ) ou le bouton de
## suppression —, ou null. La liste de suggestions d'`AutocompleteEdit` est aussi un
## `PanelContainer` sur la fenêtre, mais porte une `ItemList` : elle n'est pas comptée.
func _floating_panel(list) -> PanelContainer:
	var host: Node = list.get_window()
	if host == null:
		host = list.get_tree().root
	for child in host.get_children():
		if child is PanelContainer and not child.is_queued_for_deletion() \
				and child.get_child_count() > 0 \
				and (child.get_child(0) is LineEdit or child.get_child(0) is Button):
			return child
	return null

## Comparé au script chargé À L'EXÉCUTION, comme dans test_keyboard.gd : nommer la classe
## `KeyboardInset` ici la ferait compiler avec ce test, avant que l'autoload `Layout`
## qu'elle utilise n'existe — et la suite entière ne compilerait plus.
func _find_inset(node: Node):
	for child in node.get_children():
		if child.get_script() == load("res://ui/components/KeyboardInset.gd"):
			return child
		var found = _find_inset(child)
		if found != null:
			return found
	return null

## Toucher loin de tout champ : `ShoppingStoreList._input` le reçoit avant les lignes.
func _tap_outside(list) -> void:
	list._input(_press(Vector2(-1000, -1000)))
	list._input(_release(Vector2(-1000, -1000)))

## Le bouton « Supprimer » proposé par l'appui long, s'il est ouvert.
func _delete_button(list) -> Button:
	var host: Node = list.get_window()
	if host == null:
		host = list.get_tree().root
	for child in host.get_children():
		if child is PanelContainer and child.get_child_count() > 0 \
				and child.get_child(0) is Button and child.is_visible_in_tree() \
				and not child.is_queued_for_deletion():
			return child.get_child(0)
	return null

## Simule le tap ailleurs qui referme le bouton de suppression — l'attrape-clic plein écran
## que `_open_floating` nomme "InlineEditCatcher" pour le retrouver d'ici sans dépendre de
## l'ordre des enfants de la fenêtre.
func _dismiss_floating(list) -> void:
	var host: Node = list.get_window()
	if host == null:
		host = list.get_tree().root
	var catcher := host.get_node_or_null("InlineEditCatcher")
	if catcher != null:
		catcher.gui_input.emit(_press(Vector2(5, 5)))

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

func _header_text(list, aisle: String) -> String:
	for child in list._list.get_children():
		var label := _first_label(child)
		if label != "" and label.contains(aisle):
			return label
	return ""

## Concatène chevron et libellé de l'en-tête (deux Labels frères).
func _first_label(node: Node) -> String:
	var parts := ""
	if node is Label:
		return (node as Label).text
	for child in node.get_children():
		parts += _first_label(child)
	return parts

func _is_outside_synced_tables(db) -> bool:
	for table in LocalDatabase.SYNCED_TABLES:
		db._db.query("SELECT COUNT(*) AS n FROM %s;" % table)
		# La préférence vit dans `meta`, jamais dans une table poussée au serveur.
		if table == "meta":
			return false
	db._db.query_with_bindings(
		"SELECT COUNT(*) AS n FROM meta WHERE key = ?;", ["ui/shopping_collapsed"])
	return int(db._db.query_result[0]["n"]) == 1

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
