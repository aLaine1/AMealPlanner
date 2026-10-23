class_name CategoryFilter
extends VBoxContainer
## Barre de recherche + filtre par catégorie repliable.
##
## Le composant **englobe** le champ de recherche plutôt que de se poser à côté : le
## bouton de bascule doit être sur la même ligne que le champ, et les pilules
## immédiatement dessous. Deux nœuds séparés obligeraient chaque écran à refaire ce
## montage, et à le refaire à l'identique.
##
##     _search = LineEdit.new()
##     _filter = CategoryFilter.new()
##     _filter.setup(_search)
##     panel.add_child(_filter)
##     _filter.changed.connect(_on_search_changed)
##     _filter.set_options(DataStore.get_all_recipe_categories())
##
## Les écrans appliquent ensuite `matches()` en plus de leur filtre textuel.
##
## Sélection **multiple**, en union : cocher « Pâtes » et « Riz » montre les deux. Une
## intersection ne servirait à rien ici, une recette n'ayant qu'une catégorie.

signal changed(search_text: String)

## Replier la barre efface la sélection : un filtre actif mais invisible laisserait
## croire à une liste vide ou tronquée, sans rien à l'écran pour l'expliquer.
var _selected := {}
var _options: Array[String] = []

var _search: LineEdit
var _toggle: Button
var _pills: HFlowContainer

## `search_field` est reparenté dans le composant : l'écran appelant le crée (avec son
## propre texte d'invite) mais ne l'ajoute pas lui-même à son arborescence.
func setup(search_field: LineEdit) -> void:
	_search = search_field
	add_theme_constant_override("separation", 8)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)

	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _search.get_parent() != null:
		_search.get_parent().remove_child(_search)
	row.add_child(_search)
	_search.text_changed.connect(func(_t): _emit())

	_toggle = Button.new()
	_toggle.theme_type_variation = "OutlineButton"
	_toggle.toggle_mode = true
	_toggle.tooltip_text = "Filtrer par catégorie"
	_toggle.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET if Layout.is_phone() else 0)
	_toggle.toggled.connect(_on_toggled)
	row.add_child(_toggle)

	_pills = HFlowContainer.new()
	_pills.add_theme_constant_override("h_separation", 6)
	_pills.add_theme_constant_override("v_separation", 6)
	_pills.visible = false
	add_child(_pills)

	_refresh_toggle()

## Catégories proposées, dans l'ordre où elles sont fournies — les catégories de recettes
## arrivent triées par nom, mais les rayons portent l'ordre du parcours en magasin, qu'un
## tri alphabétique détruirait.
##
## Appelée à chaque rechargement des données : une catégorie peut naître ou disparaître au
## fil des recettes. Les sélections portant sur une catégorie disparue sont abandonnées,
## sinon elles continueraient de filtrer une liste sans plus offrir de moyen de les
## décocher.
func set_options(values: Array) -> void:
	var fresh: Array[String] = []
	for v in values:
		var name := str(v).strip_edges()
		if name != "" and not fresh.has(name):
			fresh.append(name)
	if fresh == _options:
		return
	_options = fresh

	var dropped := false
	for name in _selected.keys():
		if not _options.has(name):
			_selected.erase(name)
			dropped = true

	_rebuild_pills()
	_refresh_toggle()
	if dropped:
		_emit()

## Vrai si l'article passe le filtre : aucune catégorie cochée, ou l'une des siennes
## l'est. Les écrans dont l'article n'a qu'une catégorie passent un tableau d'un élément.
func matches(values: Array) -> bool:
	if _selected.is_empty():
		return true
	for v in values:
		if _selected.has(str(v)):
			return true
	return false

## Texte de recherche courant — les écrans le lisent au lieu de garder leur propre
## référence au champ.
func search_text() -> String:
	return _search.text if _search != null else ""

func _on_toggled(pressed: bool) -> void:
	_pills.visible = pressed
	if not pressed and not _selected.is_empty():
		_selected.clear()
		_sync_pills()
		_refresh_toggle()
		_emit()
		return
	_refresh_toggle()

func _rebuild_pills() -> void:
	for child in _pills.get_children():
		_pills.remove_child(child)
		child.queue_free()
	for name in _options:
		var pill := Button.new()
		pill.text = name
		pill.theme_type_variation = "PillButton"
		pill.toggle_mode = true
		pill.button_pressed = _selected.has(name)
		if Layout.is_phone():
			pill.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		pill.toggled.connect(_on_pill_toggled.bind(name))
		_pills.add_child(pill)

func _sync_pills() -> void:
	for child in _pills.get_children():
		if child is Button:
			child.set_pressed_no_signal(_selected.has(child.text))

func _on_pill_toggled(pressed: bool, name: String) -> void:
	if pressed:
		_selected[name] = true
	else:
		_selected.erase(name)
	_refresh_toggle()
	_emit()

## Le bouton porte le nombre de catégories cochées : une fois la barre repliée, c'est
## le seul endroit où le filtre reste visible.
func _refresh_toggle() -> void:
	if _toggle == null:
		return
	_toggle.disabled = _options.is_empty()
	_toggle.text = "Filtrer" if _selected.is_empty() else "Filtrer (%d)" % _selected.size()

func _emit() -> void:
	changed.emit(search_text())
