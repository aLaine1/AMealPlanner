class_name RecipePopup
extends Window
## Fiche d'une recette : consultation, puis édition à la demande.
## Champs : nom, saison, catégorie, transport, lignes d'ingrédients dynamiques, étapes.
## Usage : var p = RecipePopup.new(); p.recipe = <Recipe|null>; p.editable = false;
##         add_child(p); p.saved.connect(...); p.popup_centered()
##
## Une recette existante s'ouvre en LECTURE : on vient bien plus souvent la consulter — que
## contient-elle, comment se prépare-t-elle — que la corriger. « Modifier » fait basculer la
## page entière en édition. Une création s'ouvre directement en édition, n'ayant rien à
## consulter.

signal saved
## Demande de suppression, portée par l'écran appelant : c'est lui qui tient la liste et
## qui sait ce qu'il faut rafraîchir ensuite.
signal delete_requested(recipe_id: String)
## Demande de placer cette recette dans la première case libre du planning.
signal add_to_plan_requested(recipe_name: String)

## Préchargé plutôt qu'appelé par son class_name : le cache de classes globales de
## Godot n'est pas garanti à jour, notamment au premier lancement après mise à jour.
const RecipePhotoScript := preload("res://services/RecipePhoto.gd")
const KeyboardInsetScript := preload("res://ui/components/KeyboardInset.gd")
const OptionKeysScript := preload("res://ui/components/OptionKeys.gd")
const ArrowNavigationScript := preload("res://ui/components/ArrowNavigation.gd")

## Bornes du curseur des parts. Un foyer de plus de douze couverts relève du banquet, et
## une recette pour zéro personne n'a pas de sens : le zéro « non renseigné » des recettes
## d'avant la 1.8 se lit désormais comme la taille du foyer.
const SERVINGS_MIN := 1
const SERVINGS_MAX := 12
const CameraCapturePopupScript := preload("res://ui/components/CameraCapturePopup.gd")
const PhotoCropPopupScript := preload("res://ui/components/PhotoCropPopup.gd")

## Plateformes où `CameraServer` est implémenté. Ailleurs, l'écran de prise de vue
## n'aurait rien à montrer.
const CAMERA_PLATFORMS := ["Android", "iOS", "Linux", "macOS"]

const SEASONS := [["Été", "ete"], ["Hiver", "hiver"], ["Toute", "toute"]]
const COMMON_UNITS := ["g", "kg", "ml", "l", "c.à.s", "c.à.c", "pièce", "tranche", "pincée", "verre", "boîte"]

var recipe: Recipe = null  ## null = création
## Faux = page en lecture seule. Vrai par défaut, pour que la création reste directe.
var editable := true

var _header_title: Label
var _edit_btn: Button
var _delete_btn: Button
var _plan_btn: Button
var _cancel_btn: Button
var _save_btn: Button
## Racine du formulaire, parcourue pour verrouiller ou déverrouiller la page d'un bloc.
var _form: VBoxContainer

var _name: LineEdit
var _season: OptionButton
var _category: LineEdit   ## AutocompleteEdit : catégories existantes proposées
## Curseur des parts. Deux rôles selon le mode, et c'est voulu : en ÉDITION il déclare pour
## combien de personnes la recette est écrite, sans toucher aux quantités saisies ; en
## LECTURE il met ces quantités à l'échelle, à l'écran seulement — la recette n'est pas
## réécrite, et la liste de courses continue de compter d'après le foyer.
var _servings: HSlider
var _servings_label: Label
var _add_btn: Button
## Parts de référence : celles pour lesquelles les quantités affichées sont écrites. C'est
## d'elles que part la règle de trois de la lecture.
var _base_servings := 1
var _nobox: CheckBox
var _steps: TextEdit
var _rows_box: VBoxContainer
var _rows: Array = []  ## [{root, name, qty, unit}]
var _error: Label
var _ing_suggestions: Array[String] = []

var _photo_preview: TextureRect
var _photo_clear_btn: Button
## Photo choisie pendant la saisie, `{image, thumb}` en base64. Elle n'est écrite qu'à
## l'enregistrement : à la création, la recette n'a pas encore d'identifiant auquel la
## rattacher, et l'abandon du formulaire ne doit rien laisser derrière lui.
var _pending_photo := {}
## L'utilisateur a demandé le retrait de la photo existante.
var _photo_removed := false
## Version web : rappel JavaScript du sélecteur de fichiers. Gardé ici, sans quoi Godot le
## libère avant que le navigateur ne l'appelle et le choix tombe dans le vide.
var _web_photo_callback: JavaScriptObject = null

func _ready() -> void:
	title = recipe.nom if recipe != null else "Ajouter une recette"
	Layout.fit_window(self, Vector2i(560, 720), Vector2i(560, 640))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)
	_ing_suggestions = DataStore.get_all_ingredient_names()
	_build()
	_fill_from_recipe()
	# Après le remplissage : celui-ci crée les lignes d'ingrédients, qui doivent être
	# verrouillées comme le reste.
	_apply_editable()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 16)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	margin.add_child(outer)
	outer.add_child(_build_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	# Formulaire long, saisi de bout en bout au doigt : les derniers champs tomberaient
	# tous derrière le clavier.
	scroll.add_child(KeyboardInsetScript.new())
	# Zone morte : un contact doit franchir quelques unités avant de devenir un
	# défilement. Sans elle, la moindre hésitation du doigt en visant un champ faisait
	# glisser la page sous lui — d'autant plus depuis que les champs laissent passer le
	# geste. Même ordre de grandeur que le « touch slop » employé ailleurs.
	scroll.scroll_deadzone = 8
	# Le champ qui prend le focus au clavier est amené à l'écran : la ligne d'ingrédient que
	# crée Entrée naît au bas du formulaire, souvent sous le bord (2.0.11).
	scroll.follow_focus = true

	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 8)
	Layout.scroll_body(scroll).add_child(form)
	_form = form

	# Nom
	form.add_child(_mk_label("Nom de la recette *"))
	_name = LineEdit.new()
	_name.placeholder_text = "Ex: Spaghetti à la carbonara"
	form.add_child(_name)

	# Saison
	form.add_child(_mk_label("Saison préférée"))
	_season = OptionButton.new()
	for s in SEASONS:
		_season.add_item(s[0])
	OptionKeysScript.attach(_season)
	form.add_child(_season)

	# Catégorie : les existantes sont proposées dès la première lettre, comme les
	# ingrédients (2.0.13) — on retrouve « Légumineuses » sans l'écrire en entier, et une
	# catégorie nouvelle se tape simplement en entier.
	form.add_child(_mk_label("Catégorie"))
	_category = AutocompleteEdit.new()
	_category.suggestions = DataStore.get_all_recipe_categories()
	_category.placeholder_text = "Ex: " + ", ".join(DataStore.get_all_recipe_categories().slice(0, 4))
	form.add_child(_category)

	# Marqueur de transport
	_nobox = CheckBox.new()
	# Libellé d'origine : « Recette NoBox (à cuisiner soi-même) » — une explication
	# erronée, reprise du plan de refonte. Il s'agit en réalité des plats qui se
	# transportent mal, qu'on réserve donc aux soirs sans gamelle le lendemain.
	_nobox.text = "Ne se transporte pas"
	_nobox.tooltip_text = "Le plat supporte mal d'être emporté en gamelle : il sera " \
		+ "réservé aux soirs qui ne sont pas suivis d'une journée de travail."
	# Masqué quand le mécanisme est désactivé : la notion doit alors disparaître
	# entièrement, pas seulement rester sans effet.
	_nobox.visible = DataStore.is_transport_marker_enabled()
	form.add_child(_nobox)

	# Photo
	form.add_child(_mk_label("Photo"))
	# HFlowContainer : en rangée fixe, l'aperçu de 200 et sa colonne de boutons exigeaient
	# 360 unités de large. Le formulaire imposait donc ce minimum à toute la fenêtre, qui
	# débordait de l'écran — sur un téléphone de 360, le conteneur de marges mesurait 410
	# et le bord droit disparaissait, emportant la marge du bouton de pied et de la barre
	# de défilement. La colonne de boutons passe maintenant sous l'aperçu quand la place
	# manque, au lieu d'élargir la page.
	var photo_row := HFlowContainer.new()
	photo_row.add_theme_constant_override("h_separation", 10)
	photo_row.add_theme_constant_override("v_separation", 8)
	form.add_child(photo_row)

	# Carré, et montrant la VIGNETTE : c'est elle qu'on vient de cadrer. Un cadre
	# rectangulaire affichant l'image entière la recoupait une seconde fois, si bien
	# que le cadrage choisi n'était jamais celui qu'on voyait ici.
	_photo_preview = TextureRect.new()
	# Plus petit sur téléphone : à 200, l'aperçu et ses boutons ne cohabitent sur aucune
	# ligne d'écran étroit, et la photo n'a pas à occuper le tiers de la page.
	var side := 160.0 if Layout.is_phone() else 200.0
	_photo_preview.custom_minimum_size = Vector2(side, side)
	_photo_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_photo_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_photo_preview.clip_contents = true
	photo_row.add_child(_photo_preview)

	# Colonne serrée contre la photo : sans expansion, elle se contente de la largeur
	# de ses libellés au lieu de pousser jusqu'au bord.
	var photo_buttons := VBoxContainer.new()
	photo_buttons.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	photo_buttons.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	photo_buttons.add_theme_constant_override("separation", 6)
	photo_row.add_child(photo_buttons)

	var choose := Button.new()
	choose.text = "Choisir une image…"
	choose.theme_type_variation = "OutlineButton"
	choose.pressed.connect(_on_choose_photo)
	photo_buttons.add_child(choose)

	# Décidé par la plateforme et non en interrogeant `CameraServer.feeds()` : le
	# recensement des appareils est désactivé par défaut, et l'activer ici pour une
	# simple question allumerait la caméra à chaque ouverture du formulaire.
	if CAMERA_PLATFORMS.has(OS.get_name()):
		var shoot := Button.new()
		shoot.text = "Prendre une photo"
		shoot.theme_type_variation = "OutlineButton"
		shoot.pressed.connect(_on_take_photo)
		photo_buttons.add_child(shoot)

	_photo_clear_btn = Button.new()
	_photo_clear_btn.text = "Retirer"
	_photo_clear_btn.theme_type_variation = "GhostButton"
	_photo_clear_btn.pressed.connect(_on_clear_photo)
	photo_buttons.add_child(_photo_clear_btn)

	# Ingrédients
	var ing_header := HBoxContainer.new()
	form.add_child(ing_header)
	var ing_title := _mk_label("Ingrédients")
	ing_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ing_header.add_child(ing_title)
	# Le curseur des parts se tient ENTRE le titre et l'ajout, c'est-à-dire contre les
	# quantités qu'il commande. Il remplace un champ de saisie relégué en haut du
	# formulaire, à trois écrans des ingrédients : on y tapait un nombre sans voir sur quoi
	# il agissait, et en lecture il ne servait à rien du tout.
	ing_header.add_theme_constant_override("separation", 8)
	_servings = HSlider.new()
	_servings.min_value = SERVINGS_MIN
	_servings.max_value = SERVINGS_MAX
	_servings.step = 1
	_servings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_servings.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_servings.custom_minimum_size = Vector2(80, Layout.TOUCH_TARGET)
	_servings.value_changed.connect(_on_servings_changed)
	ing_header.add_child(_servings)

	_servings_label = Label.new()
	_servings_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_servings_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	ing_header.add_child(_servings_label)

	var add_btn := Button.new()
	add_btn.text = "+ Ajouter"
	add_btn.pressed.connect(func(): _add_row())
	ing_header.add_child(add_btn)
	_add_btn = add_btn

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 4)
	form.add_child(_rows_box)

	# ↑ / ↓ d'un champ à l'autre, lignes d'ingrédients comprises (2.0.13).
	form.add_child(ArrowNavigationScript.new())

	# Étapes
	form.add_child(_mk_label("Étapes de la recette"))
	_steps = TextEdit.new()
	_steps.custom_minimum_size = Vector2(0, 140)
	_steps.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	form.add_child(_steps)

	# Erreur + boutons (hors scroll, toujours visibles)
	_error = _mk_label("")
	_error.add_theme_color_override("font_color", Palette.ERROR)
	_error.visible = false
	outer.add_child(_error)

	# Pied : en lecture, une seule action large ; en édition, Annuler et Sauvegarder.
	# Les deux jeux occupent la même rangée, l'un cachant l'autre — la hauteur du pied ne
	# bouge donc pas quand on passe en édition, et le formulaire ne saute pas.
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	outer.add_child(buttons)

	# Pleine largeur et haut comme une cible tactile : c'est l'action qu'on vient chercher
	# en consultant une recette — la placer au menu.
	_plan_btn = Button.new()
	_plan_btn.text = "Ajouter au planning"
	_plan_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_plan_btn.pressed.connect(_on_add_to_plan)
	buttons.add_child(_plan_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "Annuler"
	_cancel_btn.theme_type_variation = "GhostButton"
	_cancel_btn.pressed.connect(_on_cancel)
	buttons.add_child(_cancel_btn)
	_save_btn = Button.new()
	_save_btn.text = "Sauvegarder"
	_save_btn.pressed.connect(_on_save)
	buttons.add_child(_save_btn)

## En-tête : sortie à gauche, actions de la fiche à droite.
##
## Le bouton de fermeture n'existe que sur téléphone, où la fenêtre est en plein écran et
## n'a donc ni barre de titre ni croix — même traitement que les autres fenêtres.
func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	if Layout.is_phone():
		var back := Button.new()
		back.text = "←  Fermer"
		back.theme_type_variation = "GhostButton"
		back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		back.pressed.connect(queue_free)
		header.add_child(back)

	# Le nom en toutes lettres, sur ordinateur seulement. Sur téléphone, la place de
	# l'en-tête va aux trois boutons, et le nom est de toute façon le premier champ de la
	# page, juste en dessous.
	#
	# C'est ce libellé qui, en s'étendant, repousse « Modifier » et « Supprimer » contre la
	# marge de droite. Masqué sur téléphone, il ne poussait plus rien et les deux boutons
	# restaient collés au bouton de fermeture, loin du bord : une entretoise invisible
	# prend donc le relais.
	_header_title = Label.new()
	_header_title.visible = not Layout.is_phone()
	_header_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_header_title.add_theme_font_size_override("font_size", 18)
	_header_title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	header.add_child(_header_title)

	if Layout.is_phone():
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		header.add_child(spacer)

	_edit_btn = Button.new()
	_edit_btn.text = "Modifier"
	_edit_btn.theme_type_variation = "OutlineButton"
	_edit_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_edit_btn.pressed.connect(_on_start_editing)
	header.add_child(_edit_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Supprimer"
	_delete_btn.theme_type_variation = "DangerButton"
	_delete_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_delete_btn.pressed.connect(_on_delete)
	header.add_child(_delete_btn)
	return header

# ===== Lecture / édition =====

## Verrouille ou déverrouille la page entière, et échange les actions.
##
## Les deux boutons de l'en-tête disparaissent en édition : « Modifier » n'a plus de sens
## une fois la page ouverte, et « Supprimer » au milieu d'une saisie effacerait sans un mot
## ce qu'on venait d'écrire. On repasse par « Annuler ».
func _apply_editable() -> void:
	_set_editable(_form, editable)
	var existing := recipe != null
	_header_title.text = recipe.nom if existing and not editable \
		else ("Modifier la recette" if existing else "Nouvelle recette")
	_edit_btn.visible = existing and not editable
	_delete_btn.visible = existing and not editable
	_plan_btn.visible = existing and not editable
	_cancel_btn.visible = editable
	_save_btn.visible = editable
	# Différé : la hauteur dépend du repli du texte, donc de la largeur du champ, qui n'est
	# connue qu'après la mise en page.
	_fit_steps_height.call_deferred()

## En lecture, le pavé d'étapes prend la hauteur de son texte.
##
## Il ne reçoit plus le toucher — c'est le but — et ne peut donc plus défiler pour son
## propre compte : à hauteur fixe, la fin d'une recette longue serait devenue illisible.
## C'est désormais la page qui défile, ce qui est de toute façon le geste attendu.
func _fit_steps_height() -> void:
	if not is_instance_valid(_steps):
		return
	if editable:
		_steps.custom_minimum_size.y = 140
		return
	var lines := 0
	for index in range(_steps.get_line_count()):
		lines += 1 + _steps.get_line_wrap_count(index)
	_steps.custom_minimum_size.y = maxf(140.0,
		lines * _steps.get_line_height() + 24.0)

## Parcours récursif : les lignes d'ingrédients naissent après la construction, et une
## liste de champs tenue à la main aurait oublié les prochaines.
func _set_editable(node: Node, flag: bool) -> void:
	for child in node.get_children():
		if child is LineEdit or child is TextEdit:
			# `editable` et non `disabled` : le texte garde ses couleurs normales, donc
			# se lit. Grisé, un champ de consultation serait moins lisible que le papier.
			child.editable = flag
		elif child is OptionButton or child is CheckBox:
			# Ceux-ci n'ont pas de mode « lecture » : seul `disabled` les verrouille, et il
			# éteint leur libellé. Or la saison et le marqueur de transport sont des
			# INFORMATIONS de la fiche — la saison apparaissait comme une case vide. On
			# leur rend donc l'encre du texte normal le temps de la consultation.
			child.disabled = not flag
			if flag:
				child.remove_theme_color_override("font_disabled_color")
			else:
				child.add_theme_color_override("font_disabled_color", Palette.TEXT_PRIMARY)
		elif child is BaseButton:
			child.disabled = not flag
		_apply_touch_filter(child, flag)
		_set_editable(child, flag)

## Qui reçoit le geste tactile, et qui le laisse passer au défilement.
##
## En LECTURE, plus rien ne le reçoit : `editable = false` ne change pas le filtre d'entrée
## d'un champ, qui continuait donc de capter l'amorce du mouvement — une page de
## consultation devenait pénible à faire défiler alors qu'il n'y a rien d'autre à y faire.
##
## En ÉDITION, les champs passent en `MOUSE_FILTER_PASS` : ils reçoivent le toucher — donc
## le focus et le curseur — mais le laissent AUSSI remonter au ScrollContainer, si bien
## qu'un balayage parti d'un champ fait défiler la page au lieu de ne rien faire. C'est le
## même remède que pour les listes ; la différence est qu'ici le champ doit garder le
## toucher, on ne peut donc pas lui retirer l'événement.
func _apply_touch_filter(control: Node, flag: bool) -> void:
	if control is LineEdit or control is TextEdit:
		control.mouse_filter = Control.MOUSE_FILTER_PASS if flag \
			else Control.MOUSE_FILTER_IGNORE
	elif control is BaseButton:
		control.mouse_filter = Control.MOUSE_FILTER_STOP if flag \
			else Control.MOUSE_FILTER_IGNORE

## Le passage en édition RECHARGE la fiche.
##
## Sans cela, les quantités mises à l'échelle par le curseur en mode lecture seraient celles
## qu'on s'apprête à modifier — puis à enregistrer. Consulter une recette « pour 8 » et
## cliquer sur Modifier aurait réécrit la recette pour huit sans que personne ne l'ait
## demandé, et de façon irréversible.
func _on_start_editing() -> void:
	editable = true
	if recipe != null:
		_fill_from_recipe()
	_apply_editable()

func _on_cancel() -> void:
	# Une création s'annule en fermant ; une modification revient à la consultation, la
	# fiche restant ce qu'on était venu voir.
	if recipe == null:
		queue_free()
		return
	editable = false
	_fill_from_recipe()
	_apply_editable()

func _on_delete() -> void:
	if recipe != null:
		delete_requested.emit(recipe.id)
	queue_free()

func _on_add_to_plan() -> void:
	if recipe != null:
		add_to_plan_requested.emit(recipe.nom)

## Renvoie la ligne créée — `_advance_from_row` y place le focus.
func _add_row(nom := "", qty := "", unit := "") -> Dictionary:
	# HFlowContainer et non HBoxContainer : le thème donne 85 unités de largeur minimale à
	# tout champ de saisie, et trois champs plus le bouton de retrait en réclamaient 311.
	# Le formulaire imposait ce minimum à la fenêtre entière, qui débordait donc d'un écran
	# étroit — la marge de droite disparaissait, bouton de pied et barre de défilement
	# compris. La quantité et l'unité passent maintenant sous le nom quand la place manque,
	# et la ligne tient sur un seul niveau dès qu'il y en a.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)

	var name_edit := AutocompleteEdit.new()
	name_edit.placeholder_text = "Ingrédient"
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.suggestions = _ing_suggestions
	name_edit.text = nom
	row.add_child(name_edit)

	var qty_edit := LineEdit.new()
	qty_edit.placeholder_text = "Qté"
	qty_edit.custom_minimum_size = Vector2(60, 0)
	qty_edit.text = qty
	row.add_child(qty_edit)

	var unit_edit := AutocompleteEdit.new()
	unit_edit.placeholder_text = "Unité"
	unit_edit.custom_minimum_size = Vector2(80, 0)
	unit_edit.suggestions = COMMON_UNITS
	unit_edit.text = unit
	row.add_child(unit_edit)

	# `base` : la quantité TELLE QU'ÉCRITE dans la recette. Le curseur des parts s'en sert
	# comme point de départ en lecture ; repartir de ce qui est affiché ferait dériver le
	# nombre à chaque mouvement, l'arrondi de chaque étape s'ajoutant au précédent.
	var entry := {"root": row, "name": name_edit, "qty": qty_edit, "unit": unit_edit,
		"base": _parse_float(qty)}
	var remove := Button.new()
	remove.text = "X"
	remove.pressed.connect(func(): _remove_row(entry))
	row.add_child(remove)

	# Saisie d'une traite au clavier (2.0.11) : ingrédient, Tab, quantité, Entrée ou Tab,
	# unité, Entrée ou Tab — et l'on est sur l'ingrédient suivant. Les suggestions ouvertes
	# gardent la main sur Entrée et Tab (`AutocompleteEdit._input`, qui passe avant) : le
	# premier Entrée retient l'unité surlignée, le second seulement passe à la suite.
	qty_edit.text_submitted.connect(func(_t): unit_edit.grab_focus())
	unit_edit.text_submitted.connect(func(_t): _advance_from_row(entry))
	unit_edit.gui_input.connect(func(event: InputEvent):
		if event is InputEventKey and event.pressed and event.keycode == KEY_TAB \
				and not event.shift_pressed:
			unit_edit.accept_event()
			_advance_from_row(entry))

	_rows.append(entry)
	_rows_box.add_child(row)
	return entry

## Après l'unité d'une ligne : l'ingrédient de la ligne suivante, ou d'une ligne neuve si
## c'était la dernière. Une ligne sans ingrédient clôt la liste — on passe aux étapes, au
## lieu d'empiler des lignes vides au fil des Entrée.
func _advance_from_row(entry: Dictionary) -> void:
	if not editable:
		return
	if str(entry["name"].text).strip_edges() == "":
		_steps.grab_focus()
		return
	var index := _rows.find(entry)
	if index >= 0 and index < _rows.size() - 1:
		_rows[index + 1]["name"].grab_focus()
		return
	_add_row()["name"].grab_focus()

func _remove_row(entry: Dictionary) -> void:
	_rows.erase(entry)
	entry["root"].queue_free()
	if _rows.is_empty():
		_add_row()

## Rejoué à l'annulation d'une modification : les lignes déjà présentes sont donc retirées
## d'abord, sans quoi celles de la recette s'ajouteraient à celles qu'on vient d'éditer.
func _fill_from_recipe() -> void:
	for entry in _rows:
		entry["root"].queue_free()
	_rows.clear()
	_pending_photo = {}
	_photo_removed = false
	_refresh_photo_preview()
	if recipe == null:
		# Création : le curseur part de la taille du foyer, réponse la plus probable et
		# seule que l'application connaisse déjà.
		_base_servings = clampi(DataStore.household_servings(), SERVINGS_MIN, SERVINGS_MAX)
		_servings.set_value_no_signal(_base_servings)
		_update_servings_label()
		_add_row()
		return
	_name.text = recipe.nom
	# Une recette d'avant la 1.8 ne dit pas pour combien de parts elle est écrite : on la
	# lit alors « pour le foyer », ce qui est exactement ce que le zéro signifiait.
	_base_servings = recipe.servings if recipe.servings > 0 else DataStore.household_servings()
	_servings.set_value_no_signal(clampi(_base_servings, SERVINGS_MIN, SERVINGS_MAX))
	_update_servings_label()
	_select_season(recipe.saison)
	_nobox.button_pressed = recipe.nobox
	_category.text = recipe.categories[0] if not recipe.categories.is_empty() else ""
	_steps.text = recipe.etapes
	if recipe.ingredients.is_empty():
		_add_row()
	else:
		for ing in recipe.ingredients:
			# `_format_qty` et non `str()` : celui-ci écrit « 200.0 » là où la mise à
			# l'échelle du curseur écrit « 400 ». Le même nombre s'affichait donc de deux
			# façons selon qu'on avait touché au curseur ou non.
			_add_row(ing.nom, _format_qty(ing.quantite), ing.unite)

func _on_save() -> void:
	var name := _name.text.strip_edges()
	if name == "":
		_show_error("Le nom de la recette est obligatoire.")
		return

	var ings: Array[Ingredient] = []
	for entry in _rows:
		var iname: String = entry["name"].text.strip_edges()
		if iname == "":
			continue
		var ing := Ingredient.new()
		ing.nom = iname
		ing.quantite = _parse_float(entry["qty"].text)
		ing.unite = entry["unit"].text.strip_edges()
		ings.append(ing)

	if ings.is_empty():
		_show_error("Ajoutez au moins un ingrédient.")
		return

	var r := Recipe.new()
	r.nom = name
	r.saison = SEASONS[_season.selected][1] if _season.selected >= 0 else "toute"
	r.nobox = _nobox.button_pressed
	r.etapes = _steps.text
	# La valeur du curseur, et non les quantités affichées : en lecture celles-ci ont pu être
	# mises à l'échelle, et `_on_start_editing` les a justement ramenées à leur écriture.
	r.servings = int(_servings.value)
	var cat := _canonical_category(_category.text.strip_edges())
	r.categories = ([cat] as Array[String]) if cat != "" else ([] as Array[String])
	r.ingredients = ings

	if recipe != null:
		r.id = recipe.id
		DataStore.update_recipe(r)
		_apply_photo(r.id)
	else:
		_apply_photo(DataStore.add_recipe(r))
	saved.emit()
	queue_free()

## Une catégorie déjà connue, tapée sans ses accents ni ses majuscules (« legumes »), prend
## l'orthographe existante (« Légumes ») plutôt que de créer sa quasi-jumelle — que la
## fusion des homonymes devrait ensuite résorber, et qui aurait entre-temps sa propre
## couleur de pastille.
func _canonical_category(typed: String) -> String:
	if typed == "":
		return ""
	var needle := TextFold.fold(typed)
	for existing in DataStore.get_all_recipe_categories():
		if TextFold.fold(existing) == needle:
			return existing
	return typed

# ===== Photo =====

## Sélecteur natif du système quand il existe — sur Android, le `FileDialog` de Godot
## explore un système de fichiers auquel l'application n'a pas accès et reviendrait
## vide. Ailleurs, le dialogue interne reste le repli.
func _on_choose_photo() -> void:
	if OS.has_feature("web"):
		_choose_photo_web()
		return
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show(
			"Choisir une photo", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			["*.png,*.jpg,*.jpeg,*.webp ; Images"], _on_native_photo_selected)
		return
	_open_internal_file_dialog()

## Rappel du sélecteur natif : `(status, files, filter_index)`. Un simple abandon
## renvoie `status = false`, qui n'est pas une erreur à signaler.
func _on_native_photo_selected(status: bool, files: PackedStringArray, _filter: int) -> void:
	if not status or files.is_empty():
		return
	_on_photo_selected(files[0])

## Version web : le dialogue interne de Godot n'y explorerait que le système de fichiers
## virtuel de la page, vide. On passe par le sélecteur du navigateur, dont le fichier
## revient en base64 — le seul format qu'un rappel JavaScript transporte sans perte.
##
## `click()` n'ouvre le sélecteur que dans la foulée d'un geste de l'utilisateur ; Godot ne
## traite le clic qu'à l'image suivante, ce qui reste dans le délai toléré par les navigateurs.
func _choose_photo_web() -> void:
	JavaScriptBridge.eval("""
		window.amealPickImage = window.amealPickImage || function (done) {
			var input = document.createElement('input');
			input.type = 'file';
			input.accept = 'image/png,image/jpeg,image/webp';
			input.onchange = function () {
				var file = input.files && input.files[0];
				if (!file) return;
				var reader = new FileReader();
				reader.onload = function () { done(String(reader.result).split(',')[1] || ''); };
				reader.readAsDataURL(file);
			};
			input.click();
		};
	""", true)
	_web_photo_callback = JavaScriptBridge.create_callback(_on_web_photo_read)
	# Non typé : `amealPickImage` n'existe que côté JavaScript, l'analyseur ne la connaît pas.
	var window = JavaScriptBridge.get_interface("window")
	window.amealPickImage(_web_photo_callback)

func _on_web_photo_read(args: Array) -> void:
	var bytes := Marshalls.base64_to_raw(str(args[0]) if not args.is_empty() else "")
	if bytes.is_empty():
		_show_error("Fichier vide ou illisible.")
		return
	var read: Dictionary = RecipePhotoScript.read_bytes(bytes)
	if not read.ok:
		_show_error(read.error)
		return
	_offer_crop(read.image)

func _on_take_photo() -> void:
	var popup := CameraCapturePopupScript.new()
	popup.captured.connect(_on_photo_captured)
	add_child(popup)
	popup.popup_centered()

## L'image de l'appareil photo rejoint le traitement du fichier choisi : même écran de
## cadrage, même réduction, même format, même poids.
func _on_photo_captured(image: Image) -> void:
	_offer_crop(image)

## Interpose l'écran de cadrage entre l'image obtenue et son enregistrement.
##
## La vignette est carrée alors qu'une photo ne l'est presque jamais : la prendre au
## centre sans rien demander manquait le sujet une fois sur deux. L'image entière est
## conservée quoi qu'il arrive — ce cadre ne choisit que la vignette.
func _offer_crop(image: Image) -> void:
	var popup := PhotoCropPopupScript.new()
	popup.source = image
	popup.confirmed_crop.connect(func(rect: Rect2i): _store_photo(image, rect))
	add_child(popup)
	popup.popup_centered()

func _store_photo(image: Image, thumb_rect: Rect2i) -> void:
	var prepared: Dictionary = RecipePhotoScript.from_image(image, thumb_rect)
	if not prepared.ok:
		_show_error(prepared.error)
		return
	_pending_photo = prepared
	_photo_removed = false
	_error.visible = false
	_refresh_photo_preview()

func _open_internal_file_dialog() -> void:
	var dialog := FileDialog.new()
	dialog.title = "Choisir une photo"
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# ACCESS_FILESYSTEM et non ACCESS_RESOURCES : la photo vient des dossiers de
	# l'utilisateur, pas de ceux de l'application.
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp", "Images")
	dialog.theme = Palette.ui_theme
	Layout.fit_window(dialog, Vector2i(720, 520), Vector2i(480, 400))
	dialog.file_selected.connect(_on_photo_selected)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

func _on_photo_selected(path: String) -> void:
	var read: Dictionary = RecipePhotoScript.read_source(path)
	if not read.ok:
		_show_error(read.error)
		return
	_offer_crop(read.image)

func _on_clear_photo() -> void:
	_pending_photo = {}
	_photo_removed = true
	_refresh_photo_preview()

func _refresh_photo_preview() -> void:
	# La vignette, et non l'image pleine : ce cadre montre exactement ce que le cadrage
	# a retenu, tel qu'il apparaîtra dans les listes.
	var texture: Texture2D = null
	if not _pending_photo.is_empty():
		texture = RecipePhotoScript.decode(_pending_photo["thumb"])
	elif not _photo_removed and recipe != null:
		texture = DataStore.get_photo_thumb(recipe.id)

	_photo_preview.texture = texture
	_photo_clear_btn.disabled = texture == null

## Écrit la photo une fois la recette enregistrée, donc une fois son identifiant connu.
func _apply_photo(recipe_id: String) -> void:
	if not _pending_photo.is_empty():
		DataStore.set_recipe_photo(recipe_id, _pending_photo["image"], _pending_photo["thumb"])
	elif _photo_removed:
		DataStore.clear_recipe_photo(recipe_id)

## Le curseur a bougé.
##
## En édition il ne fait que déclarer un nombre de parts : les quantités saisies ne bougent
## pas, elles sont la recette telle qu'on l'écrit. En lecture, elles suivent — à l'écran
## seulement.
func _on_servings_changed(_value: float) -> void:
	_update_servings_label()
	if editable:
		return
	var factor := float(_servings.value) / float(maxi(_base_servings, 1))
	for entry in _rows:
		entry["qty"].text = _format_qty(float(entry.get("base", 0.0)) * factor)

func _update_servings_label() -> void:
	if _servings_label == null:
		return
	var count := int(_servings.value)
	_servings_label.text = "%d part%s" % [count, "s" if count > 1 else ""]

## Deux décimales au plus, et pas de zéro inutile : une quantité mise à l'échelle tombe
## rarement rond, mais « 133.33333 g » ne se lit pas.
func _format_qty(quantity: float) -> String:
	if quantity <= 0.0:
		return ""
	if is_equal_approx(quantity, roundf(quantity)):
		return "%d" % int(roundf(quantity))
	return String.num(quantity, 2).trim_suffix("0").trim_suffix(".")

func _parse_float(s: String) -> float:
	var t := s.strip_edges().replace(",", ".")
	return t.to_float() if t.is_valid_float() else 0.0

func _show_error(msg: String) -> void:
	_error.text = msg
	_error.visible = true

func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _select_season(key: String) -> void:
	for i in range(SEASONS.size()):
		if SEASONS[i][1] == key:
			_season.select(i)
			return
