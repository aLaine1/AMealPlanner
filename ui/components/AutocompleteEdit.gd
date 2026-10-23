class_name AutocompleteEdit
extends LineEdit
## Champ de saisie avec autocomplétion. Portage de widgets.AutocompleteEntry.
##
## - Suggestions filtrées dès 1 caractère, tri "commence par" puis "contient",
##   tolérant aux accents (épinard trouvé en tapant "epin").
## - Navigation clavier (↑/↓/Entrée/Échap), sélection à la souris.
## - La popup de suggestions est parentée à la fenêtre (get_window) pour ne pas être
##   rognée par un ScrollContainer parent.
##
## Usage : var e = AutocompleteEdit.new(); e.suggestions = [...]; add_child(e)

const OptionKeysScript := preload("res://ui/components/OptionKeys.gd")

const MAX_ITEMS := 8
const ITEM_HEIGHT := 28
const MAX_POPUP_HEIGHT := 220
## Écart entre le champ et sa popup.
const POPUP_GAP := 2.0

var suggestions: Array = []  ## non typé : accepte Array[String] comme Array littéral

var _panel: PanelContainer
var _list: ItemList
var _filtered: Array[String] = []
var _sel: int = -1
var _mouse_in_popup := false

func _ready() -> void:
	text_changed.connect(_on_text_changed)
	focus_exited.connect(_on_focus_exited)
	tree_exiting.connect(func(): if is_instance_valid(_panel): _panel.queue_free())
	_build_popup()

func _build_popup() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.z_index = 1000
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.SURFACE
	sb.border_color = Palette.SECONDARY
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	_panel.add_theme_stylebox_override("panel", sb)

	_list = ItemList.new()
	_list.mouse_filter = Control.MOUSE_FILTER_STOP
	_list.item_clicked.connect(func(idx, _pos, _btn): _accept(idx))
	_panel.add_child(_list)
	_panel.mouse_entered.connect(func(): _mouse_in_popup = true)
	_panel.mouse_exited.connect(func(): _mouse_in_popup = false)

	# Parent = la fenêtre englobante (évite le clipping du ScrollContainer).
	var host: Node = get_window()
	if host == null:
		host = get_tree().root
	# Rattachement DIFFÉRÉ : un nœud ne peut pas recevoir d'enfant pendant qu'il monte
	# les siens, et c'est précisément le cas ici — ce champ naît en cascade depuis le
	# `_ready()` d'un onglet, lui-même monté dans la fenêtre visée. L'ajout échouait donc
	# à la construction de la liste de courses, et la popup n'entrait jamais dans l'arbre :
	# le champ d'ajout de dernière minute ne proposait aucune suggestion, sans que rien
	# ne le signale hors d'une erreur en console.
	_attach_popup.call_deferred(host)

## Le champ peut avoir disparu entre-temps — une popup refermée, un onglet reconstruit —
## auquel cas `tree_exiting` a déjà demandé la libération du panneau.
func _attach_popup(host: Node) -> void:
	if not is_instance_valid(host) or not is_instance_valid(_panel):
		return
	if _panel.is_queued_for_deletion() or _panel.get_parent() != null:
		return
	host.add_child(_panel)

# ===== Filtrage (pur, testable) =====

static func _fold(s: String) -> String:
	return TextFold.fold(s)

## Renvoie les suggestions correspondant à `query` : "commence par" d'abord, puis "contient".
static func filter_suggestions(query: String, suggestions_in: Array, max_items: int) -> Array[String]:
	var q := _fold(query.strip_edges())
	var out: Array[String] = []
	if q == "":
		return out
	var starts: Array[String] = []
	var contains: Array[String] = []
	for s in suggestions_in:
		var sf := _fold(str(s))
		if sf.begins_with(q):
			starts.append(str(s))
		elif sf.contains(q):
			contains.append(str(s))
	for s in starts:
		out.append(s)
	for s in contains:
		out.append(s)
	return out.slice(0, max_items)

# ===== Affichage =====

func _on_text_changed(t: String) -> void:
	_filtered = filter_suggestions(t, suggestions, MAX_ITEMS)
	if _filtered.is_empty():
		_hide()
	else:
		_show()

func _show() -> void:
	_list.clear()
	for s in _filtered:
		_list.add_item(s)
	var h: int = min(_filtered.size() * ITEM_HEIGHT + 8, MAX_POPUP_HEIGHT)
	_list.custom_minimum_size = Vector2(size.x, h)
	_panel.reset_size()
	_panel.position = popup_origin(Rect2(global_position, size),
		_panel.get_combined_minimum_size(), Layout.usable_bottom())
	_panel.visible = true
	_sel = -1

## Coin haut-gauche de la popup : sous le champ si elle y tient, au-dessus sinon.
##
## Au doigt, le clavier occupe la moitié basse de l'écran et le champ le surplombe :
## une popup posée dessous tomberait derrière le clavier, et les suggestions — la
## raison d'être de ce champ sur téléphone, où l'on n'écrit pas volontiers un nom en
## entier — resteraient invisibles.
##
## Séparé du reste pour être vérifiable sans écran ni clavier.
static func popup_origin(field: Rect2, popup_size: Vector2, usable_bottom: float) -> Vector2:
	var below := field.end.y + POPUP_GAP
	if below + popup_size.y <= usable_bottom:
		return Vector2(field.position.x, below)
	# Jamais au-dessus du bord haut : une popup qui déborderait par le haut serait
	# rognée du côté des premières suggestions, celles qui comptent.
	return Vector2(field.position.x, maxf(field.position.y - popup_size.y - POPUP_GAP, 0.0))

func _hide() -> void:
	if _panel:
		_panel.visible = false
	_sel = -1
	_mouse_in_popup = false

func _on_focus_exited() -> void:
	# Laisser le temps à un éventuel clic sur la popup d'être traité.
	await get_tree().create_timer(0.12).timeout
	if not _mouse_in_popup:
		_hide()

func _accept(idx: int) -> void:
	if idx < 0 or idx >= _filtered.size():
		return
	text = _filtered[idx]
	caret_column = text.length()
	_hide()
	grab_focus()

# ===== Navigation clavier (via _input pour ne pas casser la saisie) =====

func _input(event: InputEvent) -> void:
	if not has_focus() or _panel == null or not _panel.visible:
		return
	if not (event is InputEventKey and event.pressed):
		return
	var handled := true
	match event.keycode:
		KEY_DOWN:
			_move_selection(1)
		KEY_UP:
			_move_selection(-1)
		# Tant que les suggestions sont ouvertes, Tab les parcourt comme ↓ (et Maj+Tab
		# comme ↑) au lieu de quitter le champ (2.0.11) : c'est la touche qu'on a sous les
		# doigts en remplissant un formulaire, et le focus partait sans rien choisir. Liste
		# fermée — suggestion retenue par Entrée, ou Échap —, Tab reprend son rôle.
		#
		# Arrivé en bas, un Tab de plus revient en haut (2.0.12) : on parcourt la liste en
		# boucle sans changer de touche. Les flèches, elles, s'arrêtent aux bords.
		KEY_TAB:
			_cycle_selection(-1 if event.shift_pressed else 1)
		KEY_ENTER, KEY_KP_ENTER:
			if _sel >= 0:
				_accept(_sel)
			else:
				handled = false
		KEY_ESCAPE:
			_hide()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()

func _cycle_selection(step: int) -> void:
	if _filtered.is_empty():
		return
	_sel = OptionKeysScript.wrap_index(_sel, step, _filtered.size())
	_list.select(_sel)
	_list.ensure_current_is_visible()

func _move_selection(delta: int) -> void:
	if _filtered.is_empty():
		return
	_sel = clampi(_sel + delta, 0, _filtered.size() - 1)
	_list.select(_sel)
	_list.ensure_current_is_visible()

## Vrai tant que les suggestions sont affichées : ↑ / ↓ et Tab y parcourent alors la liste,
## et `ArrowNavigation` ne doit pas les détourner vers le champ voisin.
func is_popup_open() -> bool:
	return _panel != null and _panel.visible

## Met à jour la liste de suggestions (ex. après ajout d'un ingrédient).
func set_suggestions(list: Array) -> void:
	suggestions = list
