class_name PlanningSettingsTab
extends MarginContainer
## Réglages du planning : marqueur « ne se transporte pas » et cases qui lui sont
## réservées.
##
## Certains plats supportent mal d'être emportés en gamelle. On les place donc les
## soirs qui ne sont pas suivis d'une journée de travail, puisque leurs restes n'auront
## pas à partir au bureau. Quels soirs exactement dépend du rythme de chacun, d'où ce
## réglage — et tout le monde n'emporte pas son repas, d'où l'interrupteur.
##
## Désactivé, la notion disparaît partout : plus de case dans le formulaire de recette,
## plus de cases teintées dans le planning, plus de contrainte à la génération.

const TouchTapScript := preload("res://ui/components/TouchTap.gd")

const WEEKDAYS := ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"]

var _toggle: CheckBox
var _grid_box: VBoxContainer
var _slots: Array[int] = []
var _weeks_buttons := {}   ## nombre de semaines -> Button
var _start_buttons := {}   ## jour de la semaine -> Button
var _weekday_buttons := {} ## Vector2i(jour, repas) -> Button (repas réservés)
## Nombre de repas pour lequel la grille des repas réservés a été bâtie : elle compte une
## semaine par repas, il faut donc la refaire quand ce nombre change.
var _grid_meals := -1
var _grid_rows: VBoxContainer
var _meals_buttons := {}   ## nombre de repas -> Button

func _ready() -> void:
	_build_ui()
	_reload()
	DataStore.data_changed.connect(_reload)

## Un `MarginContainer`, et non un `Control` portant une marge ancrée à l'intérieur.
##
## Un `Control` nu ne DISPOSE pas ses enfants et ne remonte pas leur taille minimale : la
## section valait donc zéro de haut, et le conteneur défilant des Paramètres, n'ayant
## rien à faire dépasser, ne défilait pas. C'est le même piège que celui des cases du
## calendrier en 1.7.12, où un enveloppeur du même genre décalait le contenu vers le bas.
func _build_ui() -> void:
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		add_theme_constant_override(m, 12)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "Planning"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	root.add_child(title)

	root.add_child(_build_weeks_row())
	root.add_child(_build_week_start_row())
	root.add_child(_build_meals_row())

	var separator := HSeparator.new()
	root.add_child(separator)

	_toggle = CheckBox.new()
	# Libellé court, et ce n'est pas une coquetterie : une CheckBox ne replie pas son
	# texte, sa largeur minimale est donc celle de sa phrase entière. « Distinguer les
	# plats qui ne se transportent pas » réclamait 384 unités et imposait cette largeur à
	# toute la carte, qui débordait alors de l'écran — quand rien d'autre sur cet écran
	# n'a besoin de plus de 145. Le sens est porté par la légende « Repas réservés » qui
	# suit immédiatement.
	_toggle.text = "Plats non transportables"
	_toggle.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_toggle.tooltip_text = "Certains plats supportent mal d'être emportés en gamelle. " \
		+ "On leur réserve les soirs qui ne sont pas suivis d'une journée de travail."
	_toggle.toggled.connect(_on_toggled)
	root.add_child(_toggle)


	_grid_box = VBoxContainer.new()
	_grid_box.add_theme_constant_override("separation", 6)
	root.add_child(_grid_box)

	var caption := Label.new()
	caption.text = "Repas réservés"
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	_grid_box.add_child(caption)

	_grid_rows = VBoxContainer.new()
	_grid_rows.add_theme_constant_override("separation", 8)
	_grid_box.add_child(_grid_rows)


## Durée couverte par le planning : de 1 à 4 semaines.
##
## Réduire la durée n'efface RIEN : les jours qui sortent du planning restent en base et
## reviennent tels quels si on rallonge à nouveau. Ce n'est plus écrit à l'écran — une phrase
## d'aide sous chaque réglage occupait plus de place qu'elle n'en éclairait.
func _build_weeks_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var caption := Label.new()
	caption.text = "Durée du planning"
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	box.add_child(caption)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	box.add_child(row)

	for weeks in range(LocalDatabase.PLAN_WEEKS_MIN, LocalDatabase.PLAN_WEEKS_MAX + 1):
		var button := Button.new()
		button.text = "%d semaine%s" % [weeks, "s" if weeks > 1 else ""]
		button.toggle_mode = true
		button.theme_type_variation = "PillButton"
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		row.add_child(TouchTapScript.wrap_button(button, func(): _on_weeks_chosen(weeks)))
		_weeks_buttons[weeks] = button

	return box

## Jour où commence le planning — celui des courses.
##
## Le calendrier ne change pas de forme pour autant : ses colonnes restent lundi → dimanche,
## c'est un calendrier. Seul le masque se déplace, et le nombre de lignes avec lui : un planning
## qui commence un lundi tient sur autant de lignes que de semaines, un autre en occupe une de
## plus.
func _build_week_start_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var caption := Label.new()
	caption.text = "Jour des courses"
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	box.add_child(caption)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	box.add_child(row)

	for weekday in range(7):
		var button := Button.new()
		button.text = WEEKDAYS[weekday]
		button.toggle_mode = true
		button.theme_type_variation = "PillButton"
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		button.tooltip_text = "Le planning commencera un %s" % \
			DataStore.WEEKDAY_LONG[weekday].to_lower()
		row.add_child(TouchTapScript.wrap_button(button,
			func(): _on_week_start_chosen(weekday)))
		_start_buttons[weekday] = button
	return box

func _on_week_start_chosen(weekday: int) -> void:
	if weekday == DataStore.plan_week_start():
		return
	DataStore.set_plan_shape(DataStore.plan_weeks(), weekday, DataStore.plan_meals_per_day())
	_reload()

func _on_weeks_chosen(weeks: int) -> void:
	if weeks == DataStore.plan_weeks():
		return
	# Le jour de début et le nombre de repas ne bougent pas : ils viendront aux étapes 3 et 4.
	DataStore.set_plan_shape(weeks, DataStore.plan_week_start(), DataStore.plan_meals_per_day())
	_reload()

## Un ou deux repas cuisinés par jour.
##
## Passer à deux DIVISE chaque journée du calendrier en deux repas. Aucun repas déjà enregistré
## ne bouge : le jour garde son numéro et le second repas s'ajoute à côté, vide. C'est ce que
## la coordonnée `meal_slot` permet.
func _build_meals_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var caption := Label.new()
	caption.text = "Repas cuisinés par jour"
	caption.add_theme_font_size_override("font_size", 13)
	caption.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	box.add_child(caption)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	box.add_child(row)

	for meals in [1, 2]:
		var button := Button.new()
		button.text = "Un repas" if meals == 1 else "Deux repas"
		button.toggle_mode = true
		button.theme_type_variation = "PillButton"
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		row.add_child(TouchTapScript.wrap_button(button, func(): _on_meals_chosen(meals)))
		_meals_buttons[meals] = button

	return box

func _on_meals_chosen(meals: int) -> void:
	if meals == DataStore.plan_meals_per_day():
		return
	DataStore.set_plan_shape(DataStore.plan_weeks(), DataStore.plan_week_start(), meals)
	_reload()

## Repas réservés : un choix par JOUR DE LA SEMAINE, valable chaque semaine — et par REPAS
## dès qu'il y en a deux.
##
## C'était une grille reprenant la forme du calendrier, où l'on cochait des dates. Mais un
## rythme de travail est hebdomadaire : désigner « le vendredi » a un sens durable, désigner
## « le sixième jour du planning » n'en a aucun dès que la durée ou le jour de début change — et
## rallonger le planning laissait les semaines ajoutées sans aucun repas réservé.
##
## Une semaine par repas depuis la 1.9.0. Le rang était auparavant imposé — toujours le dernier
## repas de la journée —, si bien qu'un foyer cuisinant deux fois par jour ne pouvait réserver
## que l'un des deux, et jamais celui qu'il voulait.
func _rebuild_slot_grid(meals: int) -> void:
	for child in _grid_rows.get_children():
		_grid_rows.remove_child(child)
		child.queue_free()
	_weekday_buttons.clear()
	_grid_meals = meals

	for meal in range(meals):
		# Le nom du repas n'apparaît que s'il y a un choix à faire : avec un seul repas par
		# jour, une étiquette « 1er repas » au-dessus d'une unique semaine ne distinguerait
		# rien de rien.
		if meals > 1:
			var caption := Label.new()
			caption.text = DataStore.MEAL_NAMES[meal]
			caption.add_theme_font_size_override("font_size", 12)
			caption.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
			_grid_rows.add_child(caption)
		_grid_rows.add_child(_build_week_row(meal))

func _build_week_row(meal: int) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	for weekday in range(7):
		var button := Button.new()
		button.text = WEEKDAYS[weekday]
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		button.tooltip_text = "Réserver le %s du %s aux plats qui ne se transportent pas" % \
			[DataStore.MEAL_NAMES[meal].to_lower(), DataStore.WEEKDAY_LONG[weekday].to_lower()]
		var mark := Vector2i(weekday, meal)
		row.add_child(TouchTapScript.wrap_button(button, func(): _on_weekday_toggled(mark)))
		_weekday_buttons[mark] = button
	return row

# =====================================================================

## Cet écran ne se reconstruit plus quand la durée du planning change : les soirs réservés se
## désignent par jour de la semaine, et sept jours il y en a, quelle que soit la durée.
func _reload() -> void:
	var current_weeks := DataStore.plan_weeks()
	for weeks in _weeks_buttons:
		_weeks_buttons[weeks].set_pressed_no_signal(weeks == current_weeks)
	var current_start := DataStore.plan_week_start()
	for weekday in _start_buttons:
		_start_buttons[weekday].set_pressed_no_signal(weekday == current_start)
	var current_meals := DataStore.plan_meals_per_day()
	for meals in _meals_buttons:
		_meals_buttons[meals].set_pressed_no_signal(meals == current_meals)

	var enabled := DataStore.is_transport_marker_enabled()
	_toggle.set_pressed_no_signal(enabled)
	_grid_box.visible = enabled
	_slots = DataStore.get_transport_slots()

	if _grid_meals != current_meals:
		_rebuild_slot_grid(current_meals)

	var marked := {}
	for mark in DataStore.get_transport_weekdays():
		marked[mark] = true
	for mark in _weekday_buttons:
		var button: Button = _weekday_buttons[mark]
		var reserved: bool = marked.has(mark)
		button.set_pressed_no_signal(reserved)
		# Réservé : pastille pleine. Sinon : contour visible — un fond transparent rendait les
		# jours libres indiscernables du fond.
		button.theme_type_variation = "PillButton" if reserved else "OutlineButton"

func _on_toggled(enabled: bool) -> void:
	DataStore.set_transport_marker_enabled(enabled)

func _on_weekday_toggled(mark: Vector2i) -> void:
	var marks: Array = DataStore.get_transport_weekdays()
	var found := marks.find(mark)
	if found >= 0:
		marks.remove_at(found)
	else:
		marks.append(mark)
	# Aucun repas réservé revient à ne poser aucune contrainte : la génération place alors les
	# plats marqués n'importe où. On laisse faire — c'est cohérent, et l'interrupteur reste le
	# moyen franc de désactiver le mécanisme.
	DataStore.set_transport_weekdays(marks)
	_reload()
