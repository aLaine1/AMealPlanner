class_name PlanningTab
extends Control
## Onglet "Calendrier" : planning 2 semaines (14 cases), génération aléatoire,
## drag & drop, toggle saison, recherche, sauvegarde/chargement local.
## Portage de planning_tab.MealPlannerApp.

const PanelSheetScript := preload("res://ui/components/PanelSheet.gd")
const DragAutoScrollScript := preload("res://ui/components/DragAutoScroll.gd")

const WEEKDAYS := ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]

## Jours de la semaine dans l'ordre des colonnes de la grille.
##
## En 1.7 les colonnes commençaient lundi et un masque désactivait les cases hors des quinze
## jours — la grille était donc un calendrier lundi-dimanche sur lequel le planning était
## posé. L'ordre est conservé tel quel tant que le jour de début est celui d'avant ; l'étape 2
## remplacera le masque par une grille de `semaines` lignes commençant au jour choisi.
func _column_weekdays() -> Array[int]:
	var days: Array[int] = []
	for col in range(7):
		days.append(col)
	return days
## Cases réservées aux plats qui ne se transportent pas. Lues dans les réglages du
## foyer, et relues quand ils changent — y compris depuis un autre appareil.
var _transport_slots: Array[int] = []
## Libellés de jour de la vue liste : leur couleur signale les cases réservées.
var _day_labels: Array[Label] = []

## Les libellés de la vue liste étaient écrits à la main — quatorze chaînes qui disaient à
## elles seules que le planning commence un samedi et dure quinze jours. Ils sont désormais
## CALCULÉS depuis les réglages du foyer (`DataStore.plan_day_labels`), et reproduisent la
## même suite tant que ces réglages valent leurs défauts. Voir 0_plan_1.8.0.md, étape 1.

const CELL_MIN := Vector2(64, 48)

var _cells: Array[MealCell] = []
var _recipe_list: RecipeListDrag
var _search: LineEdit
var _filter: CategoryFilter
var _recipe_count: Label
var _recipe_share_btn: Button
var _selected_recipe: Recipe = null
var _all_recipe_names: Array[String] = []
var _service: MealPlanningService

## Les 14 cases sont déplacées entre deux mises en page selon la taille de l'écran :
## grille 3x7 sur bureau, liste verticale sur téléphone. Ce sont les MÊMES nœuds qui
## voyagent d'un conteneur à l'autre — dupliquer les cases obligerait à synchroniser
## deux états, et le drag & drop comme l'undo perdraient leur référence.
var _grid_view: Control
var _list_view: Control
var _grid_slots: Array[Control] = []
var _list_slots: Array[Control] = []
var _recipe_panel: Control
## Emplacement de bureau du panneau, pour l'y ramener en quittant le format téléphone.
var _recipe_panel_home: Control
## Bouton d'accès à la bibliothèque, téléphone seulement.
var _recipe_sheet_btn: Button
var _recipe_sheet: Window
var _title: Label
var _controls_row: HFlowContainer
var _controls_buttons: HFlowContainer
var _season_row: HBoxContainer
## Bas de l'onglet, sur téléphone : séparateur + accès à la bibliothèque.
var _sheet_row: VBoxContainer
## Conteneur des deux vues du calendrier (grille et liste), reconstruites ensemble quand la
## forme du planning change.
var _calendar_host: VBoxContainer
## Forme à laquelle l'écran correspond, pour détecter un changement venu de la
## synchronisation — celle-ci n'émet que `data_changed`.
var _known_shape := ""

var _undo_stack: Array = []
var _redo_stack: Array = []
var _prev_names: Array = []
var _last_commit_frame := -1

func _ready() -> void:
	_transport_slots = DataStore.get_transport_slots()
	_service = MealPlanningService.new(DataStore)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_reload_recipe_list()
	_known_shape = _shape_signature()
	# Restaurer AVANT de synchroniser l'état applicatif : sans cela l'onglet s'ouvrait
	# sur 14 cases vides, et la première modification écrasait le planning enregistré
	# — _save_to_disk() écrit les 14 positions, y compris les vides.
	_restore_plan()
	_sync_plan_from_cells()
	_prev_names = _snapshot_names()
	DataStore.data_changed.connect(_on_store_changed)
	# La forme peut changer ici, par les réglages, ou ailleurs et arriver par la
	# synchronisation : dans les deux cas le calendrier doit se refaire.
	DataStore.plan_shape_changed.connect(rebuild_calendar)
	Layout.form_changed.connect(func(_f): _apply_form())
	_apply_form()

## Réapplique la mise en évidence des cases réservées, après changement du réglage
## ici ou sur un autre appareil.
func _apply_transport_slots() -> void:
	for index in range(_cells.size()):
		_cells[index].is_nobox = index in _transport_slots
		_cells[index].refresh_style()
	for label in _day_labels:
		_paint_slot_label(label)

## Recharge les 14 cases depuis la base.
func _restore_plan() -> void:
	var names := DataStore.load_plan_names()
	for i in range(_cells.size()):
		_cells[i].set_recipe_name(names[i] if i < names.size() else "")

## Après une synchronisation : la bibliothèque ET les 14 cases.
##
## Seule la bibliothèque était rechargée ; le planning reçu d'un autre appareil
## n'apparaissait donc jamais sans redémarrer. Les modifications locales sont
## enregistrées à chaque changement de case, il n'y a pas de saisie en cours à perdre.
func _on_store_changed() -> void:
	# La forme peut avoir changé sur l'AUTRE appareil : elle arrive alors par la
	# synchronisation, qui n'émet que `data_changed`. On la compare donc à celle qui est à
	# l'écran, faute de quoi le calendrier garderait ses quatorze cases devant un foyer qui en
	# compte vingt-huit.
	#
	# Le calendrier refait relit le planning et les cases réservées, pas la bibliothèque. Or la
	# même synchronisation apporte souvent les deux : premier passage sur un appareil neuf, et
	# CHAQUE connexion en version web, dont la base repart du jeu d'exemple à un repas par jour.
	# La liste restait alors celle du jeu d'exemple — les recettes du foyer en étaient absentes.
	if _shape_signature() != _known_shape:
		rebuild_calendar()
		_reload_recipe_list()
		return
	_reload_recipe_list()
	var slots := DataStore.get_transport_slots()
	if slots != _transport_slots:
		_transport_slots = slots
		_service.transport_slots = slots
		_apply_transport_slots()
	var names := DataStore.load_plan_names()
	if names.is_empty():
		return
	var changed := false
	for i in range(_cells.size()):
		var incoming: String = names[i] if i < names.size() else ""
		if _cells[i].recipe_name != incoming:
			_cells[i].set_recipe_name(incoming)
			changed = true
	if changed:
		_sync_plan_from_cells()
		_prev_names = _snapshot_names()   # l'annulation ne doit pas revenir sur un état distant

## Bascule grille (bureau) / liste (téléphone) en déplaçant les 14 cases d'un jeu
## d'emplacements à l'autre.
func _apply_form() -> void:
	var phone := Layout.is_phone()
	_grid_view.visible = not phone
	_list_view.visible = phone
	_title.visible = not phone          # l'espace vertical est la ressource rare
	_apply_recipe_panel_placement(phone)

	var slots := _list_slots if phone else _grid_slots
	for index in range(_cells.size()):
		var cell := _cells[index]
		var target := slots[index]
		if cell.get_parent() == target:
			continue
		if cell.get_parent() != null:
			cell.get_parent().remove_child(cell)
		target.add_child(cell)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for cell in _cells:
		cell.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW) if phone else CELL_MIN

	# Dans les deux cas les boutons occupent la largeur de leur ligne : sur bureau cela
	# repousse la saison à droite, sur téléphone cela laisse « Planifier » et « Tout
	# effacer » côte à côte et fait passer la saison à la ligne suivante.
	_controls_buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	# Titre
	_title = Label.new()
	_title.text = "Planning des Repas"
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	root.add_child(_title)

	# Zone principale : calendrier à gauche, liste de recettes à droite
	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 16)
	root.add_child(main)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 12)
	main.add_child(left)

	# Les deux vues du calendrier vivent dans un hôte dédié : changer le nombre de semaines
	# oblige à les RECONSTRUIRE, et un hôte évite d'avoir à replacer ensuite les commandes et
	# l'accès à la bibliothèque, qui suivent dans la colonne.
	_calendar_host = VBoxContainer.new()
	_calendar_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_calendar_host.add_theme_constant_override("separation", 12)
	left.add_child(_calendar_host)
	_build_calendar(_calendar_host)
	_build_calendar_list(_calendar_host)
	_build_controls(left)
	_build_sheet_access(left)

	_build_recipe_panel(main)

## Lignes de la grille : une par semaine de planning, plus une si le planning ne commence pas
## un lundi — la première semaine est alors à cheval sur deux lignes du calendrier.
func _calendar_rows() -> int:
	var extra := 0 if DataStore.plan_week_start() == 0 else 1
	return DataStore.plan_weeks() + extra

## Reconstruit les deux vues du calendrier après un changement de forme.
##
## Un simple rafraîchissement ne suffit pas : ce n'est pas le contenu des cases qui change mais
## leur NOMBRE. Les cases sont donc libérées et refaites, puis le planning est relu depuis la
## base — jamais depuis l'écran, dont les cases n'existent plus.
##
## Les piles d'annulation sont vidées : un instantané pris à quatorze cases n'a plus de sens
## devant vingt-huit, et le rétablir écrirait n'importe quoi.
func rebuild_calendar() -> void:
	if _calendar_host == null:
		return
	for child in _calendar_host.get_children():
		_calendar_host.remove_child(child)
		child.queue_free()
	_cells.clear()
	_grid_slots.clear()
	_list_slots.clear()
	_day_labels.clear()
	_grid_view = null
	_list_view = null

	_transport_slots = DataStore.get_transport_slots()
	_service = MealPlanningService.new(DataStore)
	_build_calendar(_calendar_host)
	_build_calendar_list(_calendar_host)
	_apply_form()
	_restore_plan()
	_sync_plan_from_cells()
	_undo_stack.clear()
	_redo_stack.clear()
	_prev_names = _snapshot_names()
	_known_shape = _shape_signature()

## Signature de la forme du planning : semaines, jour de début, repas par jour.
func _shape_signature() -> String:
	return "%d/%d/%d" % [DataStore.plan_weeks(), DataStore.plan_week_start(),
		DataStore.plan_meals_per_day()]

func _build_calendar(parent: Control) -> void:
	# Carte contenant une grille extensible : les cases remplissent l'espace et rétrécissent
	# si nécessaire (fenêtre min 900px → tient toujours sans défilement).
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	_grid_view = card

	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(grid)

	# En-têtes des jours, dans l'ordre du jour de début. Le tableau `WEEKDAYS` figeait un
	# début le lundi ; l'ordre vient maintenant du réglage, et se lit donc juste, quel que
	# soit le jour choisi.
	var column_days := _column_weekdays()
	for col in range(7):
		var head := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		# Vendredi et samedi plus soutenus : ce sont les colonnes du week-end, repère utile
		# pour situer une semaine d'un coup d'œil. Le vert secondaire tenait ce rôle face à
		# un « vert succès » qui n'appartenait à aucune charte ; les deux teintes sont
		# maintenant celles du schéma, et l'écart vient du primaire.
		sb.bg_color = Palette.PRIMARY if col in [4, 5] else Palette.SECONDARY
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(5)
		head.add_theme_stylebox_override("panel", sb)
		head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.custom_minimum_size = Vector2(CELL_MIN.x, 26)
		var lbl := Label.new()
		lbl.text = WEEKDAYS[column_days[col]]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_color_override("font_color", Color.WHITE)
		head.add_child(lbl)
		grid.add_child(head)

	# La grille est un CALENDRIER : ses colonnes sont toujours lundi → dimanche. N semaines de
	# planning commençant un autre jour que le lundi occupent donc N+1 lignes, dont la
	# première et la dernière sont partielles — c'est la raison du masque, et c'est pourquoi
	# deux semaines à partir d'un samedi en occupent trois.
	#
	# La case (ligne, colonne) porte le jour de planning `ligne * 7 + colonne - jour_de_début`,
	# active tant qu'il tombe dans le planning. Avec 2 semaines et un début samedi, cette
	# formule reproduit exactement le masque écrit à la main de la 1.7.
	var week_start := DataStore.plan_week_start()
	var day_count := DataStore.plan_day_count()
	var meals := DataStore.plan_meals_per_day()
	var pos := 0
	for week_row in range(_calendar_rows()):
		for col in range(7):
			var day_index := week_row * 7 + col - week_start
			var disabled: bool = day_index < 0 or day_index >= day_count
			if disabled:
				var placeholder := PanelContainer.new()
				var sbp := StyleBoxFlat.new()
				sbp.bg_color = Color(Palette.SECONDARY, 0.05)
				sbp.set_corner_radius_all(12)
				sbp.set_border_width_all(1)
				sbp.border_color = Color(Palette.SECONDARY, 0.3)
				placeholder.add_theme_stylebox_override("panel", sbp)
				placeholder.custom_minimum_size = CELL_MIN
				placeholder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
				var dash := Label.new()
				dash.text = "—"
				dash.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				dash.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				dash.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
				placeholder.add_child(dash)
				grid.add_child(placeholder)
			else:
				# Une case de calendrier porte UN jour, donc un ou deux repas. Divisée, elle
				# empile midi puis soir — l'ordre de la journée, celui de la vue liste et celui
				# des indices : le lecteur n'a pas à faire la conversion.
				#
				# Divisée, elle reste UNE case : le cadre ci-dessous porte le fond, les coins
				# et l'ombre, et les deux moitiés s'y posent à plat, séparées par un simple
				# trait. Deux cartes distinctes auraient dit deux jours — or l'écart entre
				# midi et soir n'est pas celui qui sépare samedi de dimanche, et c'est
				# exactement ce que la grille doit donner à lire.
				var day_box := VBoxContainer.new()
				day_box.add_theme_constant_override("separation", 0 if meals > 1 else 4)
				day_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				day_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
				day_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
				grid.add_child(_wrap_day(day_box, meals))

				for meal in range(meals):
					# Trait fin entre les deux repas : à peine une ligne, là où les jours sont
					# séparés par six unités de vide et le relief de deux cadres.
					if meal > 0:
						day_box.add_child(_meal_divider())
					# Emplacement fixe dans la grille : la case le quitte en mise en page
					# téléphone, mais la grille garde sa structure et se recompose telle
					# quelle au retour.
					var slot := MarginContainer.new()
					slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
					slot.custom_minimum_size = Vector2(CELL_MIN.x, CELL_MIN.y / meals)
					day_box.add_child(slot)
					_grid_slots.append(slot)

					var cell := MealCell.new()
					cell.position_index = pos
					cell.is_nobox = pos in _transport_slots
					cell.grouped = meals > 1
					cell.compact = meals > 1
					slot.add_child(cell)
					cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
					cell.custom_minimum_size = Vector2(CELL_MIN.x, CELL_MIN.y / meals)
					cell.cell_changed.connect(_on_cell_changed)
					cell.context_requested.connect(_on_cell_context)
					_cells.append(cell)
					pos += 1

## Cadre commun aux deux repas d'une journée. En mode un repas par jour il n'y a rien à
## réunir : la boîte est rendue telle quelle, et la case garde son propre cadre.
func _wrap_day(day_box: Control, meals: int) -> Control:
	if meals <= 1:
		return day_box
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.SURFACE
	sb.set_corner_radius_all(12)
	# Une unité, exactement la largeur du trait : les moitiés viennent buter contre le
	# contour sans le recouvrir. À zéro elles se posaient PAR-DESSUS — un fond de case,
	# et à plus forte raison une photo de fond, effaçait le cadre qu'on venait de
	# dessiner. Au-delà d'une unité, le fond du cadre reparaîtrait autour des moitiés et
	# ferait un second trait.
	sb.set_content_margin_all(1)
	# Contour : l'ombre seule ne délimitait pas assez la journée. Sur un fond crème, un
	# blanc cassé sans liseré se fond dans la page — les jours redevenaient une colonne
	# continue, ce que le regroupement était précisément censé éviter. Le trait fait donc
	# le tour de la JOURNÉE, celui du dedans séparant seulement ses deux repas.
	sb.set_border_width_all(1)
	sb.border_color = Palette.DAY_FRAME
	sb.shadow_size = 5
	sb.shadow_color = Color(0.1, 0.2, 0.1, 0.07)
	sb.shadow_offset = Vector2(0, 2)
	card.add_theme_stylebox_override("panel", sb)
	# Le cadre ne fait que dessiner : il ne doit intercepter aucun contact. Un
	# `PanelContainer` naît en `MOUSE_FILTER_STOP` et avalait donc le geste avant qu'il
	# n'atteigne ni la case, ni le conteneur défilant qui les porte — plus de défilement
	# au doigt, et plus de menu de case. `IGNORE` ne concerne que lui : ses enfants
	# restent testés normalement.
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Découpe : les moitiés ont des coins droits, le cadre des coins arrondis. Sans cela
	# leur fond dépasserait aux quatre angles.
	card.clip_contents = true
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(day_box)
	return card

## Séparateur entre midi et soir : un trait d'une unité, plus discret que tout ce qui
## sépare deux journées.
func _meal_divider() -> Control:
	var line := ColorRect.new()
	line.color = Palette.BORDER
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line

## Mise en page téléphone : les 14 repas empilés dans l'ordre chronologique.
##
## La grille 3x7 impose à elle seule près de 800 unités de largeur minimale, qu'un
## TabContainer répercute sur TOUS les onglets — c'est ce qui faisait déborder la liste
## de courses. Au-delà du calendrier lui-même, cette vue débloque donc l'écran mobile
## le plus important.
func _build_calendar_list(parent: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	_list_view = scroll
	# Une case saisie au doigt doit pouvoir rejoindre une position hors écran : sur
	# quatorze cases pour sept ou huit visibles, la moitié des échanges en dépend.
	scroll.add_child(DragAutoScrollScript.new())

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 6)
	Layout.scroll_body(scroll).add_child(column)

	var meals := DataStore.plan_meals_per_day()
	if meals > 1:
		_build_day_rows(column)
	else:
		_build_meal_rows(column)

## Un repas par jour : une ligne par jour, son nom à gauche.
func _build_meal_rows(column: VBoxContainer) -> void:
	var labels := DataStore.plan_slot_labels()
	for index in range(labels.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(row)
		row.add_child(_make_slot_label(labels[index], [index], 64))
		row.add_child(_make_list_slot())

## Deux repas par jour : une ligne par JOUR, les deux repas réunis dans un même cadre et
## séparés d'un trait. En les empilant comme quatorze lignes indépendantes, rien ne
## disait plus où finissait une journée — la liste devenait une suite de repas dont il
## fallait recompter les paires.
func _build_day_rows(column: VBoxContainer) -> void:
	var days := DataStore.plan_day_labels()
	var meals := DataStore.plan_meals_per_day()
	for day in range(days.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(row)

		# Le jour est nommé une fois, et rien d'autre ne l'est. Le nom des repas occupait
		# une colonne de quarante unités dans chaque cadre pour redire ce que l'ordre dit
		# déjà : le premier est en haut, le second en dessous. Sur un écran de 412, c'est
		# un dixième de la largeur rendu au nom des recettes.
		var slots: Array[int] = []
		for meal in range(meals):
			slots.append(day * meals + meal)
		row.add_child(_make_slot_label(days[day], slots, 56))

		var day_box := VBoxContainer.new()
		day_box.add_theme_constant_override("separation", 0)
		day_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		day_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_wrap_day(day_box, meals))

		for meal in range(meals):
			if meal > 0:
				day_box.add_child(_meal_divider())
			day_box.add_child(_make_list_slot())

## Étiquette de la colonne de gauche, avec les créneaux qu'elle couvre : un seul repas en
## mode simple, la journée entière en mode deux repas.
##
## Les créneaux sont portés par l'étiquette plutôt que déduits de son rang. Ce rang ne
## voulait plus rien dire dès que la colonne a cessé d'avoir une ligne par repas, et un
## indice faux ici colorierait le mauvais jour sans que rien ne le signale.
func _make_slot_label(text: String, slots: Array[int], width: int) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 13)
	label.set_meta("slots", slots)
	_day_labels.append(label)
	_paint_slot_label(label)
	return label

## Les cases réservées aux plats qui ne se transportent pas doivent rester repérables
## dans la colonne : en mode deux repas, la teinte de fond ne couvre qu'une moitié du
## cadre et se lit moins vite qu'un jour mis en avant.
func _paint_slot_label(label: Label) -> void:
	var slots: Array = label.get_meta("slots", [])
	var reserved := false
	for slot in slots:
		if slot in _transport_slots:
			reserved = true
	label.add_theme_color_override("font_color",
		Palette.PRIMARY_INK if reserved else Palette.TEXT_SECONDARY)

func _make_list_slot() -> MarginContainer:
	var slot := MarginContainer.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.custom_minimum_size = Vector2(0, Layout.TOUCH_ROW)
	_list_slots.append(slot)
	return slot

func _build_controls(parent: Control) -> void:
	# Rangée : boutons à gauche, sélecteur de saison nettement séparé à droite.
	# HFlowContainer et non HBoxContainer : sur écran étroit le sélecteur de saison
	# passe à la ligne au lieu d'être poussé hors de l'écran.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 24)
	row.add_theme_constant_override("v_separation", 8)
	parent.add_child(row)
	_controls_row = row

	var buttons := HFlowContainer.new()
	buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_theme_constant_override("h_separation", 8)
	buttons.add_theme_constant_override("v_separation", 8)
	row.add_child(buttons)
	_controls_buttons = buttons

	var generate_btn := _make_button("Planifier aléatoirement")
	generate_btn.pressed.connect(_on_generate)
	buttons.add_child(generate_btn)

	# « Sauvegarder » et « Charger le précédent » ont disparu : le planning est
	# enregistré à chaque modification et restauré à l'ouverture, comme la liste de
	# courses. Un bouton « Sauvegarder » sans effet laisserait croire qu'il faut y
	# penser — et donc qu'oublier de cliquer fait perdre son travail.
	var clear_btn := _make_button("Tout effacer", "OutlineButton")
	clear_btn.pressed.connect(_on_clear_all)
	buttons.add_child(clear_btn)

	# Le sélecteur de saison et l'accès à la bibliothèque partagent une ligne : seul, le
	# bouton laissait une bande vide à sa droite sur téléphone.
	_season_row = HBoxContainer.new()
	_season_row.add_theme_constant_override("separation", 12)
	row.add_child(_season_row)
	_season_row.add_child(_build_season_segmented())
	row.resized.connect(_fit_controls_buttons)

## Les deux boutons restent côte à côte tant que la ligne le permet.
##
## Un `HFlowContainer` ne réclame que la largeur de son plus large enfant, puisqu'il sait
## replier les autres. La rangée extérieure en concluait que la saison tenait à côté et
## comprimait les boutons, qui passaient l'un sous l'autre — constaté quand « Planifier
## aléatoirement » a perdu son émoticône (2.0.9) et donc la largeur qui, par hasard,
## repoussait la saison à la ligne. La largeur minimale est désormais celle des deux
## boutons réunis, bornée à la ligne : sur un écran trop étroit pour eux deux, ils se
## replient encore.
func _fit_controls_buttons() -> void:
	if _controls_row == null or _controls_buttons == null:
		return
	var needed := 0.0
	var visible_count := 0
	for child in _controls_buttons.get_children():
		if child is Control and child.visible:
			needed += child.get_combined_minimum_size().x
			visible_count += 1
	needed += _controls_buttons.get_theme_constant("h_separation") * maxi(0, visible_count - 1)
	_controls_buttons.custom_minimum_size.x = minf(needed, _controls_row.size.x)


## Accès à la bibliothèque, sur téléphone : au BAS de l'onglet, sous un séparateur.
##
## Il vivait au bord droit de la ligne de saison, en variante fantôme. Trois défauts :
## noyé parmi les commandes de planification alors qu'il mène ailleurs, à peine visible,
## et placé au milieu de l'écran là où le pouce atteint le plus facilement le bas. Le
## séparateur dit ce qu'il est : non pas une commande du calendrier, mais la sortie vers
## un autre écran — le seul chemin vers la création, la modification et la photo d'une
## recette.
func _build_sheet_access(parent: Control) -> void:
	_sheet_row = VBoxContainer.new()
	_sheet_row.add_theme_constant_override("separation", 10)
	_sheet_row.visible = false
	parent.add_child(_sheet_row)

	_sheet_row.add_child(HSeparator.new())

	_recipe_sheet_btn = _make_button("Liste des recettes", "OutlineButton")
	_recipe_sheet_btn.pressed.connect(_open_recipe_sheet)
	# Centré et non étiré : un bouton pleine largeur se confondrait avec une bannière, et
	# la cible est déjà largement suffisante. La largeur plancher évite qu'il paraisse
	# étroit au bas d'un écran vide.
	_recipe_sheet_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_recipe_sheet_btn.custom_minimum_size = Vector2(220, Layout.TOUCH_TARGET)
	_sheet_row.add_child(_recipe_sheet_btn)


## Sélecteur de saison : contrôle segmenté (Hiver / Mix / Été), sélection = plein vert.
func _build_season_segmented() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_theme_constant_override("separation", 4)

	var caption := Label.new()
	caption.text = "Saison"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 11)
	caption.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	box.add_child(caption)

	# Pilule : cadre arrondi contenant 3 segments jointifs.
	var pill := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.SURFACE
	sb.set_corner_radius_all(9)
	sb.set_border_width_all(1)
	sb.border_color = Palette.SECONDARY
	sb.set_content_margin_all(3)
	pill.add_theme_stylebox_override("panel", sb)
	box.add_child(pill)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 2)
	pill.add_child(hb)

	var group := ButtonGroup.new()
	for opt in [["Hiver", "hiver"], ["Mix", "mix"], ["Été", "ete"]]:
		var b := Button.new()
		b.text = opt[0]
		b.toggle_mode = true
		b.button_group = group
		b.theme_type_variation = "SegmentButton"
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.set_meta("season", opt[1])
		if opt[1] == AppState.current_season:
			b.button_pressed = true
		b.toggled.connect(func(on): if on: AppState.current_season = b.get_meta("season"))
		hb.add_child(b)
	return box

## Vide toutes les cases du calendrier.
func _on_clear_all() -> void:
	for cell in _cells:
		cell.set_recipe_name("")
	_on_cell_changed()

## Sur ordinateur la bibliothèque vit à droite du calendrier, dont elle est la source
## du glisser-déposer. Sur téléphone ce geste n'existe pas — on passe par le menu de la
## case — et elle n'a pas la place : elle se replie derrière un bouton, qui l'ouvre en
## feuille le temps qu'on s'en serve.
##
## Elle y était auparavant simplement MASQUÉE, ce qui rendait impossible depuis un
## téléphone de créer, modifier, partager ou importer une recette — et, depuis les
## photos, d'en attacher une, alors que c'est l'appareil qu'on a en main devant le plat.
func _apply_recipe_panel_placement(phone: bool) -> void:
	if _recipe_panel == null:
		return
	if _sheet_row != null:
		_sheet_row.visible = phone
	if _season_row != null:
		# La ligne ne porte plus que le sélecteur de saison : elle se contente de son
		# contenu et reste au bord droit, comme depuis toujours.
		_season_row.size_flags_horizontal = Control.SIZE_SHRINK_END
	# Rangée chez elle et masquée : la feuille l'empruntera à la demande. Si elle est
	# ouverte au moment d'un changement de format, on la referme — le panneau ne peut
	# pas être à deux endroits.
	if not phone and _recipe_sheet != null and is_instance_valid(_recipe_sheet):
		_recipe_sheet._dismiss()
		_recipe_sheet = null
	if _recipe_panel.get_parent() == _recipe_panel_home:
		_recipe_panel.visible = not phone
		_recipe_panel.custom_minimum_size = Vector2.ZERO if phone \
			else Vector2(Layout.side_panel_width(), 0)

func _open_recipe_sheet() -> void:
	if _recipe_sheet != null and is_instance_valid(_recipe_sheet):
		return
	_recipe_sheet = PanelSheetScript.present(
		self, _recipe_panel, _recipe_panel_home, "Mes recettes")

func _build_recipe_panel(parent: Control) -> void:
	# Largeur plancher → le panneau reste toujours visible, le calendrier rétrécit à sa
	# place. Au-delà d'une grande fenêtre elle grandit (cf. Layout.side_panel_width).
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(Layout.side_panel_width(), 0)
	Layout.viewport_resized.connect(_resize_recipe_panel)
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	_recipe_panel = card
	_recipe_panel_home = parent

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 8)
	card.add_child(panel)

	# En-tête : « Mes Recettes (28) » à gauche, « Ajouter » à droite. Le compteur suit son
	# titre — il le qualifie — et la place qu'il occupait au bord droit revient à l'action
	# la plus fréquente du panneau, seule à cet endroit donc trouvable sans lire.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	panel.add_child(header)
	var section := Label.new()
	section.text = "Mes Recettes"
	section.add_theme_font_size_override("font_size", 16)
	section.add_theme_color_override("font_color", Palette.PRIMARY_INK)
	header.add_child(section)
	_recipe_count = Label.new()
	_recipe_count.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	_recipe_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_recipe_count)

	var add_btn := _make_button("Ajouter")
	add_btn.pressed.connect(_on_add_recipe)
	header.add_child(add_btn)

	_search = LineEdit.new()
	_search.placeholder_text = "Rechercher..."
	_filter = CategoryFilter.new()
	_filter.setup(_search)
	_filter.changed.connect(_on_search_changed)
	panel.add_child(_filter)

	_recipe_list = RecipeListDrag.new()
	_recipe_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_recipe_list.item_selected.connect(_on_recipe_selected)
	# Un clic franc ou un toucher franc ouvre la fiche ; la sélection seule ne fait que
	# désigner la recette que « Partager » proposera.
	_recipe_list.item_activated.connect(_on_recipe_activated)
	panel.add_child(_recipe_list)

	# Barre d'actions : deux boutons seulement. « Ajouter » est monté dans l'en-tête, et
	# « Modifier » comme « Supprimer » ont rejoint la fiche de la recette — là où l'on voit
	# ce qu'on s'apprête à changer ou à effacer, plutôt que dans une barre agissant sur une
	# ligne surlignée quelque part dans la liste.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	panel.add_child(actions)

	_recipe_share_btn = _make_button("Partager", "OutlineButton")
	_recipe_share_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_share_btn.tooltip_text = "Envoyer des recettes par QR code ou par code texte"
	_recipe_share_btn.pressed.connect(_on_share_recipes)
	actions.add_child(_recipe_share_btn)

	var import_btn := _make_button("Importer", "OutlineButton")
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.tooltip_text = "Ajouter des recettes reçues d'un autre foyer"
	import_btn.pressed.connect(_on_import_recipes)
	actions.add_child(import_btn)

## Méthode nommée et non lambda : une lambda qui ne mentionne pas `self` n'a pas d'objet
## propre, et Godot ne la débranche donc JAMAIS — elle survit à l'onglet qui l'a posée et
## continue d'écrire dans une capture libérée. Le signal étant porté par un autoload, la
## connexion durerait autant que l'application.
func _resize_recipe_panel(_width: float) -> void:
	if _recipe_panel != null and is_instance_valid(_recipe_panel):
		_recipe_panel.custom_minimum_size.x = Layout.side_panel_width()

func _make_button(text: String, variation: String = "") -> Button:
	var b := Button.new()
	b.text = text
	if variation != "":
		b.theme_type_variation = variation
	return b

# ===== Données / liste =====

func _reload_recipe_list() -> void:
	_all_recipe_names = DataStore.get_all_recipe_names()
	if _filter != null:
		_filter.set_options(DataStore.get_all_recipe_categories())
	_on_search_changed(_search.text if _search else "")
	# Réinitialiser la sélection si la recette n'existe plus
	if _selected_recipe != null:
		_selected_recipe = DataStore.get_recipe_by_name(_selected_recipe.nom)

func _populate_recipe_list(names: Array) -> void:
	_recipe_list.clear()
	for n in names:
		_recipe_list.add_item(n)
	if _recipe_count != null:
		_recipe_count.text = "(%d)" % names.size()

func _on_search_changed(text: String) -> void:
	var needle := _fold(text)
	var filtered: Array[String] = []
	for n in _all_recipe_names:
		if needle != "" and not _fold(n).contains(needle):
			continue
		if _filter != null:
			var recipe := DataStore.get_recipe_by_name(n)
			if not _filter.matches(recipe.categories if recipe != null else []):
				continue
		filtered.append(n)
	_populate_recipe_list(filtered)

func _fold(s: String) -> String:
	return TextFold.fold(s)

## Rafraîchit la liste après modification de recettes (appelé depuis MainWindow).
func refresh_recipes() -> void:
	_reload_recipe_list()

# ===== CRUD recettes (éditeur intégré) =====

## La sélection ne fait que désigner la recette : elle met la carte en évidence et
## présélectionne le partage. C'est `item_activated` qui ouvre la fiche.
func _on_recipe_selected(idx: int) -> void:
	_selected_recipe = DataStore.get_recipe_by_name(_recipe_list.get_item_text(idx))

func _on_recipe_activated(idx: int) -> void:
	var chosen := DataStore.get_recipe_by_name(_recipe_list.get_item_text(idx))
	if chosen != null:
		_open_recipe_popup(chosen, false)

func _on_add_recipe() -> void:
	_open_recipe_popup(null, true)

## `editable` : une recette existante s'ouvre en lecture, une création en édition.
func _open_recipe_popup(r: Recipe, editable: bool) -> void:
	var popup := RecipePopup.new()
	popup.recipe = r
	popup.editable = editable
	popup.delete_requested.connect(_confirm_delete_recipe)
	popup.add_to_plan_requested.connect(_on_add_recipe_to_plan)
	add_child(popup)
	popup.popup_centered()

## La confirmation reste ici et non dans la fiche : la fiche se referme en demandant la
## suppression, et une boîte de dialogue portée par une fenêtre qui disparaît partirait
## avec elle.
func _confirm_delete_recipe(recipe_id: String) -> void:
	var target := DataStore.get_recipe_by_id(recipe_id)
	if target == null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.theme = Palette.ui_theme
	dlg.dialog_text = "Supprimer la recette '%s' ?" % target.nom
	dlg.title = "Confirmation"
	add_child(dlg)
	dlg.confirmed.connect(func():
		DataStore.delete_recipe_by_id(recipe_id)
		_selected_recipe = null
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

## Place la recette dans la PREMIÈRE case libre du planning, dans l'ordre des jours.
##
## Aucune règle de saison ni de transport ici : la génération aléatoire en tient compte
## parce qu'elle choisit à notre place, alors qu'un choix explicite doit être respecté.
func _on_add_recipe_to_plan(recipe_name: String) -> void:
	for cell in _cells:
		if cell.recipe_name.strip_edges() != "":
			continue
		cell.set_recipe_name(recipe_name)
		_on_cell_changed()
		return
	# Le nombre de cases est devenu un réglage en 1.8.0 : l'annoncer en toutes lettres
	# évite de démentir la grille que l'utilisateur a sous les yeux.
	_popup_info("Planning complet",
		"Les %d cases du planning sont déjà prises.\nVide une case pour y placer cette recette."
		% _cells.size())

# ===== Génération / synchro =====

func _on_generate() -> void:
	var plan := _service.generate_random_meal_plan(AppState.excluded_season())
	for i in range(_cells.size()):
		var r = plan.get_recipe_at(i)
		_cells[i].set_recipe_name(r.nom if r != null else "")
	AppState.set_plan(plan)
	_save_to_disk()
	_commit_change()

func _on_cell_changed() -> void:
	_sync_plan_from_cells()
	_save_to_disk()
	_commit_change()

# ===== Annuler / Rétablir (état = les 14 cases) =====

func _snapshot_names() -> Array:
	var out: Array = []
	for c in _cells:
		out.append(c.recipe_name)
	return out

func _commit_change() -> void:
	# Coalescence : plusieurs cell_changed dans la même frame (ex. échange par drag) = 1 entrée.
	var f := Engine.get_process_frames()
	if f == _last_commit_frame:
		_prev_names = _snapshot_names()
		return
	_last_commit_frame = f
	_undo_stack.append(_prev_names.duplicate())
	if _undo_stack.size() > 100:
		_undo_stack.pop_front()
	_redo_stack.clear()
	_prev_names = _snapshot_names()

func _apply_names(names: Array) -> void:
	for i in range(_cells.size()):
		_cells[i].set_recipe_name(str(names[i]) if i < names.size() else "")
	_sync_plan_from_cells()
	_save_to_disk()
	_prev_names = _snapshot_names()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(_snapshot_names())
	_apply_names(_undo_stack.pop_back())

func redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(_snapshot_names())
	_apply_names(_redo_stack.pop_back())

## Reconstruit le MealPlan courant à partir du texte des cases.
func _sync_plan_from_cells() -> void:
	var plan := MealPlan.new()
	# Ajusté au nombre de cases affichées, et non laissé à la taille de la 1.7 : c'est ce
	# planning qui alimente la liste de courses, qui ne doit compter ni plus ni moins que ce
	# que l'écran montre.
	plan.resize_positions(_cells.size())
	for i in range(_cells.size()):
		var name := _cells[i].recipe_name.strip_edges()
		plan.set_recipe(i, DataStore.get_recipe_by_name(name) if name != "" else null)
	AppState.set_plan(plan)

# ===== Sauvegarde / chargement local =====


func _save_to_disk() -> void:
	var names: Array[String] = []
	for c in _cells:
		names.append(c.recipe_name)
	# Persisté en base, par position et par ID de recette (plus par nom) : le planning
	# survit désormais au renommage d'une recette, et chaque case se synchronise
	# indépendamment des autres.
	DataStore.save_plan_names(names)


# ===== Menu contextuel =====

func _on_cell_context(cell: MealCell, screen_pos: Vector2) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	var filled := cell.recipe_name.strip_edges() != ""
	# En tête de menu : c'est l'action la plus courante sur mobile, où le panneau
	# « Mes Recettes » et son glisser-déposer ne sont pas disponibles.
	menu.add_item("Choisir une autre recette…" if filled else "Choisir une recette…", 5)
	# Saisie libre proposée dans les deux cas : une case déjà remplie par un plat écrit
	# à la main n'était sinon plus modifiable, il fallait la vider d'abord.
	menu.add_item("Saisir un plat libre…", 3)
	if filled:
		menu.add_item("Voir les ingrédients", 0)
		menu.add_item("Voir les étapes", 1)
		menu.add_item("Regénérer cette case", 4)
		menu.add_item("Supprimer", 2)
	else:
		menu.add_item("Regénérer cette case", 4)
	menu.id_pressed.connect(func(id): _handle_context(cell, id))
	menu.popup_hide.connect(func(): menu.queue_free())
	menu.position = Vector2i(screen_pos)
	menu.popup()

func _handle_context(cell: MealCell, id: int) -> void:
	match id:
		0:
			_show_ingredients(cell.recipe_name)
		1:
			_show_steps(cell.recipe_name)
		2:
			cell.set_recipe_name("")
			_on_cell_changed()
		3:
			_open_free_text_prompt(cell)
		4:
			_regenerate_cell(cell)
		5:
			_open_recipe_picker(cell)

## Partage : la recette sélectionnée est pré-cochée, mais l'écran permet d'en choisir
## d'autres — un QR tient jusqu'à une dizaine de recettes.
func _on_share_recipes() -> void:
	var popup := SharePopup.new()
	popup.preselected = _selected_recipe.nom if _selected_recipe != null else ""
	add_child(popup)
	popup.popup_centered()

func _on_import_recipes() -> void:
	var popup := ImportPopup.new()
	add_child(popup)
	popup.popup_centered()

## Saisie d'un plat qui ne correspond à aucune recette : « Restaurant », « Restes »…
##
## Le libellé n'entre pas dans la bibliothèque de recettes ; il est conservé tel quel
## dans `meal_plan_positions.custom_label`, qui existait déjà mais qu'aucun écran ne
## permettait de renseigner — le menu posait un « (à définir) » en dur.
func _open_free_text_prompt(cell: MealCell) -> void:
	var current := cell.recipe_name.strip_edges()
	# Un nom de recette connue n'est pas un plat libre : on repart d'un champ vide
	# plutôt que de proposer de le récrire à la main.
	var initial := current if current != "" and DataStore.get_recipe_by_name(current) == null else ""

	var prompt := TextPromptPopup.new()
	prompt.setup("Plat libre", "Nom du plat prévu pour cette case.", initial,
		"Restaurant, restes, chez des amis…")
	add_child(prompt)
	prompt.submitted.connect(func(text: String):
		cell.set_recipe_name(text)
		_on_cell_changed())
	prompt.popup_centered()

## Sélecteur de recette au toucher, ouvert depuis le menu d'une case.
func _open_recipe_picker(cell: MealCell) -> void:
	var picker := PickerPopup.new()
	# Lignes illustrées et filtre par catégorie, comme la bibliothèque : c'est la même
	# collection qu'on parcourt, il n'y a pas de raison qu'elle change d'aspect selon la
	# porte par laquelle on y entre.
	picker.recipe_entries = true
	picker.setup("Choisir une recette", _all_recipe_names, cell.recipe_name,
		cell.recipe_name.strip_edges() != "")
	add_child(picker)
	picker.chosen.connect(func(name: String):
		cell.set_recipe_name(name)
		_on_cell_changed())
	picker.cleared.connect(func():
		cell.set_recipe_name("")
		_on_cell_changed())
	picker.popup_centered()

## Regénère une seule case en respectant les mêmes contraintes que la génération globale
## (saison, anti-doublon, contrainte de transport selon la position). E4.
func _regenerate_cell(cell: MealCell) -> void:
	# Synchroniser le plan avec l'UI avant de remplacer (la case garde son ancien contenu,
	# donc l'ancienne recette est exclue → on obtient bien une recette différente).
	_sync_plan_from_cells()
	var plan: MealPlan = AppState.current_meal_plan
	var ok := _service.replace_recipe_in_plan(plan, cell.position_index, AppState.excluded_season())
	if ok:
		var r = plan.get_recipe_at(cell.position_index)
		cell.set_recipe_name(r.nom if r != null else "")
		_on_cell_changed()
	else:
		_popup_info("Regénération",
			"Aucune recette de remplacement disponible pour cette case\n(contraintes trop strictes : saison, transport, doublons).")

func _show_ingredients(recipe_name: String) -> void:
	_show_detail(recipe_name, RecipeDetailPopup.DetailMode.INGREDIENTS)

func _show_steps(recipe_name: String) -> void:
	_show_detail(recipe_name, RecipeDetailPopup.DetailMode.STEPS)

func _show_detail(recipe_name: String, detail_mode: RecipeDetailPopup.DetailMode) -> void:
	var popup := RecipeDetailPopup.new()
	popup.recipe_name = recipe_name
	popup.detail_mode = detail_mode
	add_child(popup)
	popup.popup_centered()

## Message sans autre issue que « OK ».
##
## La taille était fixée à 420x360, plus large que l'écran d'un téléphone de 412 : la
## boîte débordait des deux côtés, et son bouton avec elle. Elle se dimensionne
## maintenant comme celle du jeu d'exemple — une largeur plafonnée à ce que l'écran
## laisse, et une hauteur déduite du texte replié.
func _popup_info(title: String, body: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.theme = Palette.ui_theme
	dlg.title = title
	dlg.dialog_text = body
	# Sans repli, le dialogue pose son texte sur une seule ligne et se dimensionne dessus.
	dlg.dialog_autowrap = true
	add_child(dlg)
	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	# `min_size`, et NON la taille passée à `popup_centered` : celle-ci est purement et
	# simplement ignorée dès que le repli est actif. Mesuré — 59 unités de large sur 395
	# de haut, un mot par ligne — là où `min_size` donne bien 392 sur 95.
	dlg.min_size = Vector2i(int(_dialog_width()), 0)
	dlg.popup_centered()

## Largeur d'une boîte de dialogue : ce que l'écran laisse une fois les marges prises,
## sans dépasser une longueur de ligne confortable à lire sur grand écran.
func _dialog_width() -> float:
	var screen := get_viewport_rect().size.x
	return minf(screen - 2.0 * float(Layout.margin()), 460.0)
