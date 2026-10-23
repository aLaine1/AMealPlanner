class_name ShoppingStoreList
extends Control
## « Mode magasin » : la liste de courses telle qu'on l'utilise un caddie à la main.
##
## Vue distincte de `ShoppingGrid`, et non une version élargie de celle-ci. La grille
## est un tableur — sélection de cellule, navigation au clavier, copier/coller de
## plage, édition en place. Rien de tout cela n'a de sens au doigt, et l'élargir aurait
## produit un mauvais tableur plutôt qu'une bonne liste. Les deux vues partagent le
## même tableau `items`, donc la même source de vérité et la même persistance.
##
## Partis pris, tirés de l'usage réel (on parcourt les rayons dans l'ordre) :
##  * **une seule liste continue**, regroupée par rayon, plutôt que des onglets par
##    rayon — en magasin on descend la liste, on ne va pas la chercher onglet par onglet ;
##  * **le toucher bref agit sur ce qu'il touche** (2.0.4) : la case coche ou décoche, le
##    nom ouvre l'éditeur du nom, la quantité celui de la quantité. La ligne entière
##    cochait, et l'édition demandait un appui long : à l'usage, l'appui long se déclenchait
##    mal et l'on cochait en voulant corriger. La case reste large à viser — toute la bande
##    gauche de la ligne, marge comprise ;
##  * **l'appui long, où qu'il soit sur la ligne, propose de retirer l'article** — un
##    bouton « Supprimer » posé sur la ligne, à confirmer d'un second toucher : un retrait
##    ne doit pas pouvoir partir d'un seul geste raté ;
##  * **l'édition se fait DANS la ligne** (2.0.5) : le texte touché devient un champ à la
##    même place, sans cadre ni fenêtre par-dessus — voir `_edit_in_row`. La quantité et
##    l'unité s'y éditent comme une seule chaîne, celle que la ligne affiche déjà
##    (« 500 g »), plutôt qu'un nombre à part avec l'unité figée ;
##  * **rayons repliables** : on replie un rayon terminé pour raccourcir la liste au
##    fur et à mesure. L'état replié est mémorisé sur l'appareil, et volontairement
##    pas synchronisé.

const AutocompleteEditScript := preload("res://ui/components/AutocompleteEdit.gd")
const TouchTapScript := preload("res://ui/components/TouchTap.gd")
const KeyboardInsetScript := preload("res://ui/components/KeyboardInset.gd")
const MotionScript := preload("res://ui/components/Motion.gd")
const HapticsScript := preload("res://ui/components/Haptics.gd")

signal changed

var items: Array = []          ## tableau partagé avec ShoppingTab / ShoppingGrid
var aisles: Array = []         ## ordre d'affichage des rayons

var _list: VBoxContainer
var _progress: Label
var _hide_checked := false
var _make_item := Callable()
## { rayon: true } pour les rayons repliés. Mémorisé entre deux lancements.
var _collapsed := {}
var _check_on: Texture2D
var _check_off: Texture2D
## Champ d'édition ouvert dans une ligne, et la fonction qui le referme (`accept` : garder
## la saisie ou non). Un seul à la fois : tout toucher hors du champ le referme d'abord.
## Durée du glissement d'un article coché vers le bas de son rayon (2.0.10). Un peu plus
## qu'un fondu : c'est un déplacement, et l'œil doit avoir le temps de le suivre.
const MOVE_DURATION := 0.22
## Désactivable pour les tests qui enchaînent les gestes sur une liste immobile.
var animate_moves := true
## Article en train d'arriver à sa nouvelle place, pendant la reconstruction qui l'y pose.
var _arriving = null

var _inline_field: LineEdit = null
var _inline_finish := Callable()
## Vrai dès que le clavier virtuel s'est montré pour le champ ouvert : sa fermeture vaut
## alors validation (cf. `_process`).
var _keyboard_seen := false

const Icons := preload("res://ui/shopping/ShoppingIcons.gd")


## `make_item` fabrique une ligne vierge — même fabrique que la grille de bureau, pour
## que les identifiants internes restent tirés d'une seule source.
func setup(items_ref: Array, aisle_order: Array, make_item := Callable()) -> void:
	items = items_ref
	aisles = aisle_order
	if make_item.is_valid():
		_make_item = make_item

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# La coche est dessinée à la taille de la cible tactile : elle sert à la fois
	# d'indicateur et de repère visuel pour la zone à toucher.
	_check_on = Icons.check(true, 30)
	_check_off = Icons.check(false, 30)
	_load_collapsed()
	set_process(false)   # ne tourne que pendant une saisie dans une ligne

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	root.add_child(bar)

	_progress = Label.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_progress.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	bar.add_child(_progress)

	var filter := Button.new()
	filter.text = "Masquer les cochés"
	filter.toggle_mode = true
	filter.theme_type_variation = "GhostButton"
	filter.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	filter.toggled.connect(func(on):
		_hide_checked = on
		filter.text = "Afficher tout" if on else "Masquer les cochés"
		rebuild())
	bar.add_child(filter)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	# Le champ d'ajout clôt son rayon : sans cela, le clavier s'ouvre par-dessus lui.
	scroll.add_child(KeyboardInsetScript.new())

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	Layout.scroll_body(scroll).add_child(_list)

func rebuild() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		# Retiré tout de suite, pas seulement libéré en fin d'image : les rangs des nouvelles
		# lignes doivent être ceux qu'on voit — c'est sur eux que `_toggle` replace l'ancienne
		# ligne qui s'efface.
		_list.remove_child(child)
		child.queue_free()

	var total := 0
	var done := 0
	for item in items:
		if str(item.get("nom", "")).strip_edges() == "":
			continue   # ligne de saisie de la grille : pas un article
		total += 1
		if item["checked"]:
			done += 1

	for aisle in aisles:
		var rows := items.filter(func(i):
			return i["aisle"] == aisle \
				and str(i.get("nom", "")).strip_edges() != "" \
				and not (_hide_checked and i["checked"]))
		if rows.is_empty():
			continue
		var checked_here := rows.filter(func(i): return i["checked"]).size()
		_add_aisle_header(aisle, checked_here, rows.size())
		if _collapsed.get(aisle, false):
			continue
		for item in ShoppingListService.display_order(rows):
			_add_row(item)
		# Ajout de dernière minute, au pied du rayon où l'on se trouve : le rayon est
		# alors donné par l'endroit où l'on écrit, sans avoir à le choisir ni à le
		# deviner du nom saisi.
		_list.add_child(_make_add_row(aisle))

	if _list.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "Aucun article.\nUtilise « Générer la liste » depuis le planning."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		empty.custom_minimum_size = Vector2(0, 120)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_list.add_child(empty)

	_progress.text = "%d / %d articles" % [done, total] if total > 0 else ""

func _add_aisle_header(aisle: String, checked_count: int, total: int) -> void:
	var collapsed: bool = _collapsed.get(aisle, false)

	var header := PanelContainer.new()
	# Même hauteur de cible que les articles : on replie un rayon aussi souvent qu'on
	# coche, souvent en marchant.
	header.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.PRIMARY
	style.set_corner_radius_all(Palette.RADIUS)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	header.add_theme_stylebox_override("panel", style)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(box)

	var chevron := Label.new()
	chevron.text = "▸" if collapsed else "▾"
	chevron.add_theme_color_override("font_color", Color.WHITE)
	chevron.add_theme_font_size_override("font_size", 16)
	chevron.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chevron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(chevron)

	var label := Label.new()
	# Cochés / total plutôt que le seul total : un rayon replié reste ainsi lisible,
	# on sait s'il est terminé sans avoir à le rouvrir.
	label.text = "%s  (%d/%d)" % [aisle, checked_count, total]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_font_size_override("font_size", 16)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)

	_connect_tap(header, func(): _toggle_aisle(aisle))
	_list.add_child(header)

func _toggle_aisle(aisle: String) -> void:
	_collapsed[aisle] = not _collapsed.get(aisle, false)
	_save_collapsed()
	rebuild()

func _load_collapsed() -> void:
	var raw := DataStore.get_ui_preference("shopping_collapsed", "{}")
	var parsed = JSON.parse_string(raw)
	_collapsed = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _save_collapsed() -> void:
	DataStore.set_ui_preference("shopping_collapsed", JSON.stringify(_collapsed))

func _add_row(item: Dictionary) -> void:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)

	var style := StyleBoxFlat.new()
	style.bg_color = Palette.SURFACE if not item["checked"] else Palette.CELL_HOVER
	style.set_corner_radius_all(Palette.RADIUS)
	style.content_margin_left = 10
	style.content_margin_right = 12
	row.add_theme_stylebox_override("panel", style)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	row.add_child(box)

	var check := TextureRect.new()
	check.texture = _check_on if item["checked"] else _check_off
	check.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	check.custom_minimum_size = Vector2(Layout.TOUCH_TARGET, Layout.TOUCH_TARGET)
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(check)

	var name_label := Label.new()
	name_label.text = str(item["nom"])
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 17)
	# Pas de rature : Label ne la gère pas nativement, et l'atténuation se lit aussi
	# bien d'un coup d'œil rapide, bras chargés.
	name_label.add_theme_color_override("font_color",
		Palette.TEXT_SECONDARY if item["checked"] else Palette.TEXT_PRIMARY)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var qty := Label.new()
	qty.text = _format_quantity(item)
	qty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	qty.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(qty)

	# Un SEUL geste suivi sur la ligne (pas un par zone) : `TouchTap` distingue tap/appui
	# long/glissement via un état PARTAGÉ entre tous les contrôles qui l'écoutent, sur les
	# MÊMES événements — deux contrôles imbriqués qui l'écoutent chacun de leur côté
	# réagiraient donc CHACUN au même geste (testé : tapoter le nom bascule l'article ET
	# rouvre son éditeur). `check`, `name_label` et `qty` restent en `MOUSE_FILTER_IGNORE` —
	# la ligne seule reçoit l'événement, et retrouve la zone touchée par leur position,
	# décidée à l'appui plutôt qu'au relâchement (un glissement démarré sur le nom peut
	# finir ailleurs).
	# Tableau à une case, pas une String nue : une String capturée par une lambda est
	# recopiée à CHAQUE appel (valeur figée à la création du sous-lambda, cf. `taps` dans
	# test_touch_drag.gd) — l'écrire à l'appui ne se voyait donc plus au relâchement, deux
	# appels séparés de la MÊME closure. Un `Array` est capturé par RÉFÉRENCE : une seule
	# case, partagée, qui traverse les deux appels.
	var held_zone := [""]
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			# La position de l'ÉVÉNEMENT, pas `get_global_mouse_position()` : la seconde
			# suit le curseur système RÉEL, que rien ne déplace pour un événement construit
			# à la main — un test qui pousse ses propres événements ne verrait jamais rien
			# d'autre que la zone vide, quoi qu'il vise.
			held_zone[0] = _zone_at(row, check, qty,
				row.get_global_transform_with_canvas() * event.position)
		TouchTapScript.handle(event,
			func(): _dispatch_tap(item, held_zone[0], name_label, qty),
			func(): _offer_delete(item, row)))
	row.set_meta("item", item)
	if _arriving != null and is_same(item, _arriving):
		_grow_in(row)
	else:
		_list.add_child(row)

## Zone touchée par un point en coordonnées d'ÉCRAN, découpée sur la seule abscisse : la
## ligne est partagée en trois bandes contiguës, sans trou entre elles — un toucher qui
## tombe entre la case et le nom compte pour l'un ou l'autre plutôt que pour rien.
##
##  * « check » : tout ce qui est à gauche de la fin de la case, marge comprise ;
##  * « qty » : la quantité, élargie à une cible tactile au bord droit — « 1 » seul fait
##    une dizaine de pixels, et une quantité vide aucun ;
##  * « name » : tout le reste, entre les deux.
func _zone_at(row: Control, check: Control, qty_label: Control, global_pos: Vector2) -> String:
	if global_pos.x <= check.get_global_rect().end.x:
		return "check"
	var qty_start := minf(qty_label.get_global_rect().position.x,
		row.get_global_rect().end.x - Layout.TOUCH_TARGET)
	if global_pos.x >= qty_start:
		return "qty"
	return "name"

func _dispatch_tap(item: Dictionary, zone: String, name_label: Label, qty_label: Label) -> void:
	match zone:
		"check": _toggle(item)
		"name": _edit_name(item, name_label)
		"qty": _edit_quantity(item, qty_label)

## Bouton « Supprimer » posé à droite de la ligne tenue. Un toucher ailleurs le referme
## sans rien retirer.
func _offer_delete(item: Dictionary, row: Control) -> void:
	var done := [false]   # tableau à une case : cf. `held_zone` dans `_add_row`
	var button := Button.new()
	button.text = "Supprimer"
	button.theme_type_variation = "DangerButton"
	button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	var close := _open_floating(row.get_global_rect(), button, true, done)
	button.pressed.connect(func():
		if done[0]:
			return
		close.call()
		_delete(item))

func _delete(item: Dictionary) -> void:
	for i in range(items.size()):
		# Par identité, pas par valeur : deux articles peuvent se ressembler champ pour champ.
		if is_same(items[i], item):
			items.remove_at(i)
			break
	rebuild()
	changed.emit()

func _edit_name(item: Dictionary, name_label: Label) -> void:
	_edit_in_row(name_label, str(item.get("nom", "")), func(text: String):
		var name := text.strip_edges()
		if name == "":
			return   # un article garde toujours un nom ; le vider n'est pas une édition
		item["nom"] = name
		rebuild()
		changed.emit())

## Le champ porte la chaîne AFFICHÉE en entier (« 500 g », pas seulement « 500 ») : la
## quantité et l'unité ne font qu'une seule édition, comme demandé (1.10.5) — auparavant
## l'unité restait figée, éditable seulement depuis la grille de bureau.
func _edit_quantity(item: Dictionary, qty_label: Label) -> void:
	_edit_in_row(qty_label, _format_quantity(item), func(text: String):
		var parsed := ShoppingListService.parse_quantity_and_unit(text)
		item["quantite"] = parsed["quantite"]
		item["unite"] = parsed["unite"]
		rebuild()
		changed.emit())

## Vrai tant qu'un champ est ouvert dans une ligne : `ShoppingTab` diffère alors le
## rechargement venu de la sync, qui détruirait la ligne et la frappe en cours.
func is_editing() -> bool:
	return is_instance_valid(_inline_field)

## Remplace `label` par un champ À SA PLACE dans la ligne (2.0.5) : même police, même
## alignement, souligné pour se lire comme modifiable. Le petit cadre flottant des 1.10.5
## à 2.0.4 se posait sur le texte, mais restait une fenêtre par-dessus la liste.
##
## Dans la ligne, le champ est aussi DANS la zone défilante : `KeyboardInset` le remonte
## au-dessus du clavier comme le champ « + Ajouter dans XXX », sans rien de plus.
##
## Valide sur Entrée/« OK » du clavier, sur un toucher ailleurs, ET sur la fermeture du
## clavier (2.0.6) — un champ en place se comporte comme la grille de bureau, qui garde la
## saisie quand on la quitte. Ce toucher ne fait rien d'autre que valider (cf. `_input`) :
## il ne coche pas au passage la case qu'il vise. Une saisie inchangée ne réécrit rien.
func _edit_in_row(label: Label, initial_text: String, on_submit: Callable) -> void:
	if is_editing():
		_inline_finish.call(true)

	var field := LineEdit.new()
	field.text = initial_text
	field.alignment = label.horizontal_alignment
	field.size_flags_horizontal = label.size_flags_horizontal
	field.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# La quantité tient souvent en un caractère : de quoi taper « 500 g » sans défiler.
	field.custom_minimum_size.x = maxf(label.size.x, 96.0)
	field.add_theme_font_size_override("font_size", label.get_theme_font_size("font_size"))
	field.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	var underline := StyleBoxFlat.new()
	underline.bg_color = Color.TRANSPARENT
	underline.border_color = Palette.PRIMARY_INK
	underline.border_width_bottom = 2
	underline.content_margin_top = 4
	underline.content_margin_bottom = 4
	field.add_theme_stylebox_override("normal", underline)
	# Le soulignement suffit à montrer le champ actif : l'anneau de focus du thème
	# l'entourerait d'un cadre, ce qu'on vient précisément de retirer.
	field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var box := label.get_parent()
	var index := label.get_index()
	label.hide()
	box.add_child(field)
	box.move_child(field, index)

	var done := [false]   # tableau à une case : cf. `held_zone` dans `_add_row`
	var finish := func(accept: bool):
		if done[0]:
			return
		done[0] = true
		_inline_field = null
		_inline_finish = Callable()
		set_process(false)
		var text := field.text
		field.queue_free()
		label.show()
		if accept and text != initial_text:
			on_submit.call(text)
	_inline_field = field
	_inline_finish = finish
	_keyboard_seen = false
	set_process(true)

	field.text_submitted.connect(func(_text: String): finish.call(true))
	# Vérifié AVANT d'appeler `finish`, pas dedans : libérer le champ lui fait perdre le
	# focus, ce qui redéclenche CE MÊME signal — à ce moment la ligne est peut-être déjà
	# en cours de libération (`rebuild`), et le seul fait d'appeler une lambda qui la
	# capture (même pour n'y rien faire) fait échouer Godot.
	field.focus_exited.connect(func():
		if not done[0]:
			finish.call(true))

	field.grab_focus()
	field.select_all()

## Un toucher hors du champ ouvert le valide, et s'arrête là. Intercepté ici, avant que
## la ligne visée ne le reçoive : sans quoi le même toucher validerait ET cocherait (ou
## rouvrirait un autre champ), deux effets pour un geste qui voulait juste « sortir ».
## Toucher DANS le champ reste libre — placer le curseur, sélectionner un mot.
func _input(event: InputEvent) -> void:
	if not is_editing() or not (event is InputEventMouseButton) or not event.pressed:
		return
	var local: Vector2 = _inline_field.get_global_transform_with_canvas().affine_inverse() \
		* event.position
	if Rect2(Vector2.ZERO, _inline_field.size).has_point(local):
		return
	_inline_finish.call(true)
	get_viewport().set_input_as_handled()

## Clavier replié pendant une saisie (2.0.6) : on valide, comme « OK ». Replier le clavier
## — par le bouton Retour, le plus souvent — laissait le champ ouvert, sans clavier pour
## le terminer ; le Retour suivant changeait alors d'onglet au lieu de clore la saisie.
##
## Seulement APRÈS avoir vu le clavier ouvert : il met quelques images à se déplier après
## la prise de focus, et sa hauteur nulle à ce moment-là n'est pas une fermeture. Sur
## ordinateur, la hauteur reste nulle : rien ne se déclenche.
func _process(_delta: float) -> void:
	if not is_editing():
		set_process(false)
		return
	if Layout.keyboard_height() > 0.0:
		_keyboard_seen = true
	elif _keyboard_seen:
		_inline_finish.call(true)

## Onglet quitté pendant une saisie (bouton Retour d'Android, notamment) : on la garde,
## comme pour un toucher ailleurs.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() and is_editing():
		_inline_finish.call(true)

## Petit cadre flottant ancré sur `anchor_rect` (coordonnées d'écran), qui porte `content` —
## aujourd'hui le seul bouton de suppression. Renvoie la fonction qui le referme ; `done[0]`
## passe à true dès qu'il est refermé, par elle ou par un toucher ailleurs — l'appelant le
## consulte AVANT de l'appeler.
##
## `align_right` choisit le bord du cadre à faire coïncider avec celui de l'ancre.
##
## Se ferme à la première interaction ailleurs : un attrape-clic plein écran couvre
## « ailleurs ».
func _open_floating(anchor_rect: Rect2, content: Control, align_right: bool,
		done: Array) -> Callable:
	var host: Node = get_window()
	if host == null:
		host = get_tree().root

	var catcher := Control.new()
	# Nommé pour être retrouvable — le test de ce fichier le dissout ainsi pour vérifier
	# le rejet SANS passer par un vrai geste une deuxième fois.
	catcher.name = "InlineEditCatcher"
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(catcher)

	var panel := PanelContainer.new()
	# Sans ce thème, un `PanelContainer` posé directement sur la fenêtre (pas sous
	# `MainWindow`, seul nœud à porter `Palette.ui_theme` dans cette branche de l'arbre)
	# retombe sur le thème par défaut de Godot — fond gris, texte blanc, rien à voir avec
	# l'app. Toutes les autres popups le posent pour la même raison (`TextPromptPopup`,
	# `AutocompleteEdit`…).
	panel.theme = Palette.ui_theme
	panel.z_index = 1000
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.SURFACE
	sb.border_color = Palette.PRIMARY_INK
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(Palette.RADIUS)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(content)
	host.add_child(panel)

	# Un cadre pas encore posé n'a pas de taille combinée fiable.
	panel.reset_size()
	var panel_size := panel.get_combined_minimum_size()
	var target_x := (anchor_rect.end.x - panel_size.x) if align_right else anchor_rect.position.x
	var target_y := anchor_rect.position.y + anchor_rect.size.y / 2.0 - panel_size.y / 2.0
	var screen_width := get_tree().root.get_visible_rect().size.x
	panel.position = Vector2(clampf(target_x, 0.0, screen_width - panel_size.x), target_y)

	var close := func():
		if done[0]:
			return
		done[0] = true
		catcher.queue_free()
		MotionScript.pop_out(panel, func(): panel.queue_free())

	catcher.gui_input.connect(func(event: InputEvent):
		if not done[0] and event is InputEventMouseButton and event.pressed:
			close.call())

	MotionScript.pop_in(panel)
	return close

## Le toucher qui n'est pas un défilement vit désormais dans `TouchTap` : le même besoin
## est apparu sur les cases à cocher du partage, et deux copies de ce raisonnement
## auraient divergé à la première correction.
func _connect_tap(control: Control, on_tap: Callable, on_hold := Callable()) -> void:
	TouchTapScript.connect_tap(control, on_tap, on_hold)

## Ligne de saisie close le rayon : « + Ajouter dans Frais ».
func _make_add_row(aisle: String) -> Control:
	var field := AutocompleteEditScript.new()
	field.placeholder_text = "+ Ajouter dans %s" % aisle
	field.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	# Les ingrédients connus se proposent d'eux-mêmes : taper « den » suffit à obtenir
	# « dentifrice », sans avoir à l'écrire en entier au doigt.
	field.suggestions = DataStore.get_all_ingredient_names()
	field.text_submitted.connect(func(text): _on_add_submitted(text, aisle))
	# Un balayage qui part du champ fait défiler la liste ; seul un toucher franc ouvre le
	# clavier (2.0.10, cf. `TouchTap.wrap_field`).
	return TouchTapScript.wrap_field(field)

## Ajoute l'article saisi dans `aisle`, ou signale qu'il est déjà là.
##
## Le rayon est déduit de l'ingrédient reconnu : c'est ce qui permet de ne taper qu'un
## nom. Un nom inconnu tombe dans le rayon de repli, plutôt que d'obliger à choisir un
## rayon pour un article qu'on ajoute en marchant.
func _on_add_submitted(text: String, aisle: String) -> void:
	var name := text.strip_edges()
	if name == "":
		return

	var existing = _find_item(name)
	if existing != null:
		# Ni doublon, ni ajout silencieux : l'article est remis à prendre, ce qui est
		# le geste attendu quand on le redemande.
		existing["checked"] = false
		rebuild()
		_progress.text = "%s était déjà dans la liste." % name
		changed.emit()
		return

	var target := aisle if aisles.has(aisle) else DataStore.fallback_aisle()
	if not _make_item.is_valid():
		return
	var item: Dictionary = _make_item.call(target)
	item["nom"] = name
	item["quantite"] = 1.0
	item["checked"] = false
	items.append(item)

	# La reconstruction remplace les champs : inutile de vider celui-ci.
	rebuild()
	changed.emit()

func _find_item(name: String):
	var needle := TextFold.fold(name)
	for item in items:
		if TextFold.fold(str(item.get("nom", ""))) == needle:
			return item
	return null

func _toggle(item: Dictionary) -> void:
	item["checked"] = not item["checked"]
	HapticsScript.tick()
	# Reconstruction complète, là où la mise à jour sur place suffisait : l'article
	# coché doit descendre en bas de son rayon, ce qui déplace aussi ceux d'en dessous.
	#
	# Ce déplacement est animé (2.0.10) plutôt que subi : la ligne s'efface à sa place en
	# se refermant pendant qu'elle se déploie à la nouvelle. Les deux hauteurs se
	# compensent exactement — les articles d'en dessous ne sautent pas, seuls ceux qui
	# séparent l'ancienne place de la nouvelle glissent d'une ligne.
	var old_row := _row_of(item)
	var old_index := -1
	var height := 0.0
	if animate_moves and old_row != null:
		var holder: Control = old_row if old_row.get_parent() == _list else old_row.get_parent()
		old_index = holder.get_index()
		height = old_row.size.y
		# Sauvée de la reconstruction : c'est elle qui s'efface à l'ancienne place.
		old_row.get_parent().remove_child(old_row)
		_arriving = item
	rebuild()
	_arriving = null
	if old_index >= 0:
		_collapse_at(old_row, old_index, height, item)
	changed.emit()

## La ligne affichée pour `item` — posée directement dans la liste, ou encore dans le
## logement qui la fait arriver.
func _row_of(item: Dictionary) -> Control:
	for child in _list.get_children():
		var row: Control = child
		if not child.has_meta("item") and child.get_child_count() > 0:
			row = child.get_child(0)
		# L'ancienne ligne qui s'efface encore (`_collapse_at`) ne compte pas : elle ne
		# répond plus aux gestes, et ce n'est plus là qu'est l'article.
		if row.has_meta("item") and is_same(row.get_meta("item"), item) \
				and row.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return row
	return null

## Logement à hauteur animée : un `Control` simple, dont la taille minimale n'est que
## `custom_minimum_size` — un `PanelContainer` ne descendrait pas sous celle de son
## contenu. Il rogne ce qui dépasse, la ligne y garde donc sa taille pendant que lui
## grandit ou rétrécit.
func _slot(row: Control, height: float) -> Control:
	var slot := Control.new()
	slot.clip_contents = true
	slot.mouse_filter = Control.MOUSE_FILTER_PASS
	slot.add_child(row)
	row.set_anchors_preset(Control.PRESET_TOP_WIDE)
	row.offset_top = 0.0
	row.offset_bottom = height
	return slot

## Arrivée à la nouvelle place : le logement s'ouvre de zéro à la hauteur de la ligne, qui
## apparaît en fondu ; puis la ligne reprend sa place directe dans la liste.
func _grow_in(row: Control) -> void:
	var height := maxf(float(Layout.TOUCH_ROW), row.get_combined_minimum_size().y)
	var slot := _slot(row, height)
	slot.custom_minimum_size = Vector2(0, 0)
	_list.add_child(slot)
	row.modulate.a = 0.0
	var tween := slot.create_tween().set_parallel(true)
	tween.tween_property(slot, "custom_minimum_size:y", height, MOVE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(row, "modulate:a", 1.0, MOVE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(func():
		# La ligne a pu partir entre-temps — recochée, ou la liste reconstruite.
		if not is_instance_valid(slot) or not is_instance_valid(row) \
				or row.get_parent() != slot or slot.get_parent() != _list:
			return
		var index := slot.get_index()
		slot.remove_child(row)
		row.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_list.add_child(row)
		_list.move_child(row, index)
		_list.remove_child(slot)
		slot.queue_free())

## Départ de l'ancienne place : l'ancienne ligne s'y efface pendant que son logement se
## referme. `index` est son rang dans la liste d'AVANT ; si l'article est remonté (décoché),
## il s'est inséré au-dessus, et ce rang a glissé d'un cran.
func _collapse_at(row: Control, index: int, height: float, item: Dictionary) -> void:
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var arrived := _row_of(item)
	if arrived != null:
		var arrived_index: int = arrived.get_parent().get_index() \
			if arrived.get_parent() != _list else arrived.get_index()
		if arrived_index <= index:
			index += 1
	var slot := _slot(row, height)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.custom_minimum_size = Vector2(0, height)
	_list.add_child(slot)
	_list.move_child(slot, mini(index, _list.get_child_count() - 1))
	var tween := slot.create_tween().set_parallel(true)
	tween.tween_property(slot, "custom_minimum_size:y", 0.0, MOVE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(row, "modulate:a", 0.0, MOVE_DURATION * 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func():
		if is_instance_valid(slot):
			if slot.get_parent() != null:
				slot.get_parent().remove_child(slot)
			slot.queue_free())

func _format_quantity(item: Dictionary) -> String:
	var quantity := float(item.get("quantite", 0))
	if quantity <= 0:
		return str(item.get("unite", ""))
	var number := "%d" % int(quantity) if is_equal_approx(quantity, roundf(quantity)) \
		else String.num(quantity, 2)
	var unit := str(item.get("unite", ""))
	return "%s %s" % [number, unit] if unit != "" else number
