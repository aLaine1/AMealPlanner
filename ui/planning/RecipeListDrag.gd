class_name RecipeListDrag
extends ScrollContainer
## Bibliothèque de recettes : liste de cartes (avatar coloré à initiale + nom), chaque carte
## étant elle-même une source de drag vers une MealCell. Remplace l'ancien ItemList tout en
## conservant une API compatible (clear/add_item/get_item_text/item_selected) pour ne pas
## avoir à modifier PlanningTab.gd au-delà de ses appels existants.

## Préchargé plutôt qu'appelé par son class_name : la classe interne _RecipeCard est
## résolue avant que le cache de classes globales ne soit garanti à jour.
const RecipeRow := preload("res://ui/components/RecipeRow.gd")

signal item_selected(index: int)
## Émis par un clic franc ou un toucher franc, SANS glissement : c'est la demande
## d'ouvrir la recette.
##
## Distinct de `item_selected`, qui part dès l'ENFONCEMENT sur ordinateur pour que le
## glisser-déposer s'enchaîne. Les confondre ferait ouvrir la recette à chaque
## glissement vers le calendrier — le geste principal du panneau sur grand écran.
signal item_activated(index: int)

var _box: VBoxContainer
var _cards: Array = []  ## Array[_RecipeCard]
var _selected_index: int = -1
## Suivi de l'appui tactile, pour distinguer un toucher d'un glissement de défilement.
var _press_origin := Vector2.ZERO
var _press_active := false

## Déplacement au-delà duquel un contact n'est plus un toucher mais un glissement.
const TAP_SLOP := 8.0

func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 6)
	Layout.scroll_body(self).add_child(_box)

func clear() -> void:
	for c in _cards:
		c.queue_free()
	_cards.clear()
	_selected_index = -1

func add_item(text: String) -> void:
	var card := _RecipeCard.new()
	card.setup(text)
	var idx := _cards.size()
	card.gui_input.connect(_on_card_input.bind(idx))
	_box.add_child(card)
	_cards.append(card)

func get_item_text(idx: int) -> String:
	if idx < 0 or idx >= _cards.size():
		return ""
	return _cards[idx].recipe_name

## Sur ordinateur, la sélection se fait à l'enfoncement — le glisser-déposer démarre
## dans la foulée. Au doigt il n'y a pas de glisser-déposer, et sélectionner à
## l'enfoncement mangeait le geste de défilement : la carte le capturait pour tenter un
## déplacement, si bien que la liste refusait de défiler. On attend donc le
## relâchement, et seulement si le doigt n'a pas glissé.
func _on_card_input(event: InputEvent, idx: int) -> void:
	if not Layout.is_phone():
		if event is InputEventMouseMotion:
			if _press_active and event.position.distance_to(_press_origin) > TAP_SLOP:
				_press_active = false   # devenu un glissement : plus un clic
			return
		if not (event is InputEventMouseButton):
			return
		var click := event as InputEventMouseButton
		if click.button_index != MOUSE_BUTTON_LEFT:
			return
		if click.pressed:
			# La SÉLECTION reste à l'enfoncement : c'est elle qui met la carte en
			# évidence et qui présélectionne la recette au partage, et le glissement
			# doit pouvoir démarrer dans la foulée.
			_press_origin = click.position
			_press_active = true
			_select(idx)
			return
		# L'OUVERTURE attend le relâchement sur place. Un glissement en cours n'est pas
		# un clic — sans cette garde, déposer une recette sur le calendrier ouvrirait
		# aussi sa fiche.
		if _press_active and not get_viewport().gui_is_dragging() \
				and click.position.distance_to(_press_origin) <= TAP_SLOP:
			item_activated.emit(idx)
		_press_active = false
		return

	if event is InputEventMouseMotion:
		if _press_active and event.position.distance_to(_press_origin) > TAP_SLOP:
			_press_active = false   # devenu un défilement : plus un toucher
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		_press_origin = button.position
		_press_active = true
		return
	if _press_active and button.position.distance_to(_press_origin) <= TAP_SLOP:
		_select(idx)
		item_activated.emit(idx)
	_press_active = false

func _select(idx: int) -> void:
	if _selected_index >= 0 and _selected_index < _cards.size():
		_cards[_selected_index].set_selected(false)
	_selected_index = idx
	if idx >= 0 and idx < _cards.size():
		_cards[idx].set_selected(true)
	item_selected.emit(idx)

## Carte de recette : avatar rond (couleur = catégorie principale, initiale du nom) + nom.
## Reste la source de drag native (comportement identique à l'ancien ItemList).
class _RecipeCard:
	extends PanelContainer

	var recipe_name: String = ""

	func setup(recipe_display_name: String) -> void:
		recipe_name = recipe_display_name
		# PASS et non STOP au doigt : en STOP la carte consomme l'événement et le
		# ScrollContainer parent ne voit jamais le glissement, donc la liste ne défile
		# pas. Même raison que pour les lignes de la liste de courses.
		mouse_filter = Control.MOUSE_FILTER_PASS if Layout.is_phone() \
			else Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(0, 44)
		_refresh_style(false)

		# Le contenu vient de `RecipeRow`, partagé avec le sélecteur de recette du
		# calendrier : les deux listes montrent la même chose, elles la composent au
		# même endroit.
		add_child(RecipeRow.build(recipe_name, 28))

	func set_selected(selected: bool) -> void:
		_refresh_style(selected)

	func _refresh_style(selected: bool) -> void:
		var sb := Palette.card_style()
		sb.set_content_margin_all(8)
		sb.shadow_size = 4
		if selected:
			sb.bg_color = Palette.CELL_HOVER
		add_theme_stylebox_override("panel", sb)

	func _get_drag_data(_at_position: Vector2) -> Variant:
		# Pas de glisser-déposer au doigt : le calendrier n'y est pas visible en même
		# temps que la bibliothèque, et le geste ne servirait qu'à empêcher la liste de
		# défiler. Sur téléphone, une case se remplit par son menu.
		if Layout.is_phone() or recipe_name.strip_edges() == "":
			return null
		var preview := Label.new()
		preview.text = recipe_name
		preview.add_theme_color_override("font_color", Palette.PRIMARY_INK)
		set_drag_preview(preview)
		return {"kind": "recipe", "name": recipe_name, "from_cell": null}
