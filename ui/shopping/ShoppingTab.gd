class_name ShoppingTab
extends Control
## Onglet "Liste de course". Deux vues sur les MÊMES articles, choisies selon la
## taille de l'écran :
##
## - **Bureau** : `ShoppingGrid`, un tableur éditable, un rayon à la fois (6 onglets).
##   Édition instantanée, Tab/flèches, copier/couper/coller de plage, ligne vide auto.
## - **Téléphone** : `ShoppingStoreList`, le mode magasin — une liste continue groupée
##   par rayon, lignes entièrement tactiles, sans édition.
##
## C'est l'usage mobile principal de l'application (cf. plan, Phase 3) : la liste de
## courses est la raison d'être du portage Android, pas un à-côté.
##
## "Générer la liste" (re)construit depuis planning + petits déj + articles de base.

## Rayons du foyer, dans l'ordre de parcours. Relus à chaque changement de données :
## la liste est modifiable et synchronisée entre appareils.
var _aisles: Array[String] = []

var _service := ShoppingListService.new()
var _items: Array = []
var _uid: int = 0
var _current: String = ""
## Bande de sélection du rayon : deux flèches encadrant les boutons de rayon.
## Remplace un TabBar, dont les flèches de défilement étaient minuscules et toutes
## deux collées à droite — celle de gauche se trouvait donc après les rayons qu'elle
## servait à remonter.
var _aisle_strip: HBoxContainer
var _aisle_buttons: Array[Button] = []
var _aisle_prev: Button
var _aisle_next: Button
var _aisle_scroll: ScrollContainer
var _grid: ShoppingGrid
var _store: ShoppingStoreList
var _desktop_view: Control      ## conteneur onglets + grille
var _actions: HFlowContainer
var _title: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_aisles = DataStore.get_aisle_names()
	_current = _aisles[0] if not _aisles.is_empty() else DataStore.fallback_aisle()
	_build_ui()
	_load()
	_grid.aisle = _current
	_grid.rebuild()
	_update_tabs()
	Layout.form_changed.connect(func(_f): _apply_form())
	_apply_form()
	# Sans cette connexion, les articles reçus d'un autre appareil restaient invisibles
	# jusqu'au redémarrage : la base et le cache étaient à jour, mais `_items` — la
	# copie de travail de cet onglet — ne l'était jamais.
	DataStore.data_changed.connect(_on_store_changed)

## Reconstruit la barre d'onglets après ajout, suppression ou réordonnancement d'un
## rayon — depuis l'éditeur ou depuis un autre appareil.
func _rebuild_aisle_tabs() -> void:
	if _aisle_strip == null:
		return
	for child in _aisle_strip.get_children():
		child.queue_free()
	_aisle_buttons.clear()

	for index in range(_aisles.size()):
		var button := Button.new()
		button.text = _aisles[index]
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		button.pressed.connect(_select_aisle.bind(index))
		_aisle_strip.add_child(button)
		_aisle_buttons.append(button)

	if not _aisles.has(_current):
		_current = _aisles[0] if not _aisles.is_empty() else DataStore.fallback_aisle()
	if _grid != null:
		_grid.aisle = _current
	_refresh_aisle_buttons()
	if _aisle_scroll != null:
		_aisle_scroll.scroll_horizontal = 0

## Recharge les articles depuis la base après une synchronisation.
func _on_store_changed() -> void:
	var refreshed := DataStore.get_aisle_names()
	if refreshed != _aisles:
		_aisles = refreshed
		_rebuild_aisle_tabs()
		_store.setup(_items, _aisles, func(a): return _new_item("", 1.0, "", a, false))
	# Recharger pendant une saisie ferait perdre la frappe en cours : on repousse au
	# prochain rafraîchissement, qui viendra de toute façon.
	if (_grid != null and _grid._editing) or (_store != null and _store.is_editing()):
		return
	var previous_aisle := _current
	_load()
	_current = previous_aisle
	_refresh_view()
	_update_tabs()

## Bascule bureau / magasin. Les deux vues restent instanciées et partagent `_items` :
## basculer ne coûte qu'un changement de visibilité, et rien n'est à resynchroniser.
func _apply_form() -> void:
	var phone := Layout.is_phone()
	_desktop_view.visible = not phone
	_store.visible = phone
	_title.visible = not phone          # sur téléphone la barre d'onglets suffit à situer
	_actions.alignment = HFlowContainer.ALIGNMENT_END if phone else HFlowContainer.ALIGNMENT_BEGIN
	if phone:
		_store.rebuild()
	else:
		_grid.rebuild()

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	# HFlowContainer : sur écran étroit les boutons se replient au lieu de déborder.
	var header := HFlowContainer.new()
	header.add_theme_constant_override("h_separation", 8)
	root.add_child(header)

	_title = Label.new()
	_title.text = "Liste de Courses"
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(_title)

	_actions = HFlowContainer.new()
	_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_actions.add_theme_constant_override("h_separation", 8)
	header.add_child(_actions)

	var gen_btn := Button.new()
	gen_btn.text = "Générer la liste"
	gen_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	gen_btn.pressed.connect(_on_generate)
	_actions.add_child(gen_btn)

	var uncheck_btn := Button.new()
	uncheck_btn.text = "Décocher tout"
	uncheck_btn.theme_type_variation = "OutlineButton"
	uncheck_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	uncheck_btn.pressed.connect(_on_uncheck_all)
	_actions.add_child(uncheck_btn)

	# ===== Vue magasin (téléphone) =====
	_store = ShoppingStoreList.new()
	_store.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_store.setup(_items, _aisles, func(a): return _new_item("", 1.0, "", a, false))
	_store.changed.connect(_on_grid_changed)
	root.add_child(_store)

	# ===== Vue bureau : largeur limitée, alignée à gauche =====
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)
	_desktop_view = content

	var col := VBoxContainer.new()
	# Proportion plutôt que largeur fixe : la liste occupe les trois quarts de la
	# fenêtre et suit son redimensionnement, au lieu de rester figée à 660 px en
	# laissant la moitié de l'écran vide.
	col.custom_minimum_size = Vector2(560, 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_stretch_ratio = 3.0
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	content.add_child(col)

	var page_spacer := Control.new()
	page_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_spacer.size_flags_stretch_ratio = 1.0
	content.add_child(page_spacer)

	col.add_child(_build_aisle_strip())

	var card := PanelContainer.new()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(card)

	_grid = ShoppingGrid.new()
	card.add_child(_grid)
	_grid.setup(_items, func(a): return _new_item("", 1.0, "", a, false))
	_grid.changed.connect(_on_grid_changed)

## Rangée de sélection du rayon : ◀ | rayons | ▶.
##
## Les flèches changent de rayon plutôt que de faire défiler la bande — c'est ce
## qu'elles ont l'air de faire, et c'est plus utile. Celle de gauche est placée avant
## les rayons, dans le sens du geste.
func _build_aisle_strip() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_aisle_prev = _make_arrow("◀", "Rayon précédent")
	_aisle_prev.pressed.connect(func(): _step_aisle(-1))
	row.add_child(_aisle_prev)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Barre masquée mais défilement possible : ce sont les flèches qui naviguent, et
	# une barre grise sous les rayons n'apportait rien.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	row.add_child(scroll)
	_aisle_scroll = scroll

	_aisle_strip = HBoxContainer.new()
	_aisle_strip.add_theme_constant_override("separation", 6)
	scroll.add_child(_aisle_strip)

	_aisle_next = _make_arrow("▶", "Rayon suivant")
	_aisle_next.pressed.connect(func(): _step_aisle(1))
	row.add_child(_aisle_next)

	_rebuild_aisle_tabs()
	return row

func _make_arrow(glyph: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = glyph
	button.tooltip_text = tooltip
	# Cible franche : les flèches d'origine faisaient une dizaine de pixels.
	button.custom_minimum_size = Vector2(Layout.TOUCH_TARGET, Layout.TOUCH_TARGET)
	button.theme_type_variation = "OutlineButton"
	return button

## Passe au rayon précédent ou suivant, sans boucler : arrivé au bout, la flèche
## correspondante se désactive plutôt que de repartir de l'autre côté.
func _step_aisle(offset: int) -> void:
	var index := _aisles.find(_current) + offset
	if index < 0 or index >= _aisles.size():
		return
	_select_aisle(index)

func _select_aisle(index: int) -> void:
	if index < 0 or index >= _aisles.size():
		return
	_current = _aisles[index]
	_grid.aisle = _current
	_grid.rebuild()
	_refresh_aisle_buttons()
	# Amener le rayon choisi dans le champ de vision, avec beaucoup de rayons. Fait
	# ici et non dans _refresh_aisle_buttons : appelé pendant la reconstruction, avant
	# que la mise en page soit calculée, le défilement partait de travers et rognait
	# le premier rayon.
	if _aisle_scroll != null and index < _aisle_buttons.size():
		_aisle_scroll.ensure_control_visible(_aisle_buttons[index])

func _refresh_aisle_buttons() -> void:
	var index := _aisles.find(_current)
	for i in range(_aisle_buttons.size()):
		# Sélectionné : pilule pleine. Autres : pilule discrète.
		_aisle_buttons[i].theme_type_variation = "" if i == index else "GhostButton"
	if _aisle_prev != null:
		_aisle_prev.disabled = index <= 0
		_aisle_next.disabled = index < 0 or index >= _aisles.size() - 1



## Undo/redo global (appelé par MainWindow quand cet onglet est visible).
func undo() -> void:
	if _grid:
		_grid.undo()

func redo() -> void:
	if _grid:
		_grid.redo()

func _on_grid_changed() -> void:
	_save()
	_update_tabs()

# ===== Données =====

func _on_generate() -> void:
	if _grid:
		_grid.push_undo()
	var plan: MealPlan = AppState.current_meal_plan
	var extra := AppState.get_breakfast_ingredients()
	extra.append_array(DataStore.get_all_staples())  # articles de base éditables (F4)
	# Les recettes écrites pour un autre nombre de parts sont mises à l'échelle du foyer. Les
	# petits déjeuners et les articles de base ne le sont pas : ils sont saisis pour le foyer
	# tel qu'il est, pas pour un nombre de parts.
	var shopping := _service.get_shopping_list_for_plan(plan, extra,
		DataStore.household_servings())
	_items.clear()
	for aisle in shopping.keys():
		var target: String = aisle if _aisles.has(aisle) else DataStore.fallback_aisle()
		for ing in shopping[aisle]:
			_items.append(_new_item(ing.nom, ing.quantite, ing.unite, target, false))
	_save()
	_refresh_view()
	_update_tabs()

func _on_uncheck_all() -> void:
	if _grid:
		_grid.push_undo()
	for item in _items:
		item["checked"] = false
	_save()
	_refresh_view()

func _refresh_view() -> void:
	if Layout.is_phone():
		_store.rebuild()
	else:
		_grid.rebuild()

func _new_item(nom: String, quantite: float, unite: String, aisle: String, checked: bool) -> Dictionary:
	_uid += 1
	return {"_uid": _uid, "nom": nom, "quantite": quantite, "unite": unite,
		"aisle": aisle if aisle != "" else "Autres", "checked": checked}

func _update_tabs() -> void:
	var counts := {}
	for a in _aisles:
		counts[a] = 0
	for item in _items:
		if counts.has(item["aisle"]):
			counts[item["aisle"]] += 1
	for i in range(mini(_aisle_buttons.size(), _aisles.size())):
		_aisle_buttons[i].text = "%s (%d)" % [_aisles[i], counts[_aisles[i]]]

# ===== Persistance =====

## Écriture différentielle en base : seuls les articles réellement modifiés voient
## leur updated_at bouger, de sorte que cocher un article en magasin n'écrase pas les
## articles cochés au même moment sur un autre appareil.
func _save() -> void:
	DataStore.save_shopping_items(_items)

func _load() -> void:
	_items.clear()
	for it in DataStore.load_shopping_items():
		var aisle := str(it.get("aisle", DataStore.fallback_aisle()))
		if not _aisles.has(aisle):
			aisle = DataStore.fallback_aisle()
		_items.append(_new_item(str(it.get("nom", "")), float(it.get("quantite", 0)),
			str(it.get("unite", "")), aisle, bool(it.get("checked", false))))
