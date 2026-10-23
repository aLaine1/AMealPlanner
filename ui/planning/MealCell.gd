class_name MealCell
extends PanelContainer
## Une case du calendrier : affiche un nom de recette, supporte le drag & drop natif
## (source ET cible) et un menu contextuel (clic droit). Remplace CTkDnDManager.

const PhotoFrameScript := preload("res://ui/components/PhotoFrame.gd")
const MotionScript := preload("res://ui/components/Motion.gd")

signal cell_changed
signal context_requested(cell: MealCell, screen_pos: Vector2)

## Déplacement au-delà duquel un contact n'est plus un appui mais un balayage.
## Même valeur que dans la liste de courses : c'est le même doigt.
const TAP_SLOP := 8.0
## Durée d'appui au terme de laquelle la case se soulève, prête à être déplacée.
const HOLD_MS := 450

var position_index: int = -1
var is_nobox: bool = false
var recipe_name: String = ""
## Vrai quand la case est l'une des deux moitiés d'une journée, posée dans le cadre
## commun que dessine le calendrier. Elle renonce alors à son ombre, à ses coins et à
## son agrandissement au survol : c'est le CADRE qui est la case, et deux cartes
## flottantes côte à côte diraient deux jours au lieu de deux repas.
var grouped := false
## Vrai quand la case ne dispose que d'une demi-journée, le mode « deux repas » lui
## ayant donné une jumelle. La photo passe alors EN FOND et le nom se pose dessus :
## empilés, ils réclamaient une hauteur double de celle qui reste. À poser avant l'ajout
## à l'arbre.
var compact := false

## Suivi de l'appui tactile en cours, pour départager balayage, appui bref et appui long.
var _press_active := false
var _press_origin := Vector2.ZERO
var _hold_timer: Timer = null
## Vrai entre l'appui long et le relâchement : seule fenêtre pendant laquelle la case
## accepte de partir en glisser-déposer au doigt.
var _lifted := false

## Stylebox du panneau, réutilisé d'un appel de `_apply_style` à l'autre — un `Tween` ne
## peut transitionner que les propriétés d'un objet qui EXISTAIT déjà avant, jamais celles
## d'un `StyleBoxFlat.new()` fraîchement posé (2.0.0 : avant, chaque appel en reposait un).
var _panel_sb: StyleBoxFlat
## Faux jusqu'à la toute première pose du style, dans `_ready()`. SANS cette distinction,
## cette première pose transitionnerait elle aussi — depuis le gris par défaut d'un
## `StyleBoxFlat` flambant neuf vers la couleur de la case — et CHAQUE case du calendrier
## clignoterait au montage ou à la reconstruction du planning, au lieu d'apparaître déjà
## dans la bonne teinte.
var _style_initialized := false
## Tué avant d'en relancer un : le survol entre/sort vite, et deux transitions en vol sur
## les mêmes propriétés se disputeraient la couleur d'arrivée.
var _style_tween: Tween

var _label: Label
## Cadre du nom : transparent d'ordinaire, fond translucide sur une photo de fond.
var _label_panel: PanelContainer
## Retrait du voile par rapport aux bords de la case. Nul hors du mode compact.
var _label_inset: MarginContainer
var _badge: Control
## Photo de la recette, reconstruite à chaque changement de recette ou de format.
var _photo: Control = null
## Vertical sur ordinateur (photo au-dessus du nom), horizontal sur téléphone (pastille
## à gauche) : une case de liste y est bien plus large que haute.
var _box: BoxContainer

func _ready() -> void:
	_apply_input_mode()
	custom_minimum_size = Vector2(120, 56)

	# La boîte est un enfant DIRECT du PanelContainer, et c'est ce qui compte : un
	# conteneur dispose ses enfants directs ET remonte leur taille minimale. Elle vivait
	# auparavant dans un Control intermédiaire, qui ne remonte rien : quand un nom passait
	# à deux lignes — « Croque-monsieur végétarien » sur un écran de 360 —, la boîte
	# grandissait à 49 tandis que la case restait à 56 avec un contenu de 40. La boîte
	# commençait donc à 8 et finissait à 57 : 12 unités au-dessus de la photo, 4 en
	# dessous, soit un contenu visiblement décalé vers le BAS et débordant d'une unité.
	# La case grandit maintenant avec son texte, et le contenu reste centré.
	_box = BoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override("separation", 4)
	add_child(_box)

	# Calque transparent pour le badge : le PanelContainer l'étire lui aussi au rectangle
	# intérieur, ce qui donne au badge un cadre stable où s'ancrer. Sa taille minimale
	# étant nulle, il ne pèse pas sur celle de la case — et la souris le traverse, pour
	# que le clic droit et le glisser-déposer restent l'affaire de la case.
	var content := Control.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(content)

	# Le nom vit dans un panneau : en mode compact, ce panneau reçoit un fond clair
	# translucide qui le détache de la photo. Un texte posé nu sur une image est
	# illisible dès que l'image est claire à cet endroit — et une photo de plat l'est
	# presque toujours quelque part.
	# Le retrait latéral du voile vit dans SON PROPRE conteneur, et non dans les marges
	# de la case : celles-ci sont portées par le cadre de la case, qui insère aussi la
	# photo — les élargir aurait rogné l'image au lieu de resserrer le voile.
	_label_inset = MarginContainer.new()
	_label_inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label_inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label_inset.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_label_inset)

	_label_panel = PanelContainer.new()
	_label_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_label_inset.add_child(_label_panel)

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	# Le nom de la recette est le texte le plus regardé de l'application, et les cases
	# de bureau ont la place : il passe au-dessus de la taille courante.
	_label.add_theme_font_size_override("font_size", 16)
	# Sans photo, le nom occupe toute la case comme auparavant ; avec, il se contente
	# de la place que la photo lui laisse.
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_label_panel.add_child(_label)

	_badge = Control.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.custom_minimum_size = Vector2(10, 10)
	_badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_badge.position = Vector2(-14, 6)
	_badge.draw.connect(func():
		_badge.draw_circle(Vector2(5, 5), 5, _badge.get_meta("color", Color.TRANSPARENT)))
	_badge.visible = false
	content.add_child(_badge)

	# Enfant non-Control : le PanelContainer ne le dispose pas, il ne gêne donc pas le
	# wrapper ci-dessus.
	_hold_timer = Timer.new()
	_hold_timer.one_shot = true
	_hold_timer.wait_time = HOLD_MS / 1000.0
	_hold_timer.timeout.connect(_on_hold_elapsed)
	add_child(_hold_timer)

	pivot_offset = custom_minimum_size / 2.0
	_apply_style(false)
	Layout.form_changed.connect(func(_f):
		_cancel_press()
		_apply_input_mode()
		_update_photo())
	_update_photo()

## Une case de bureau consomme l'événement ; une case de téléphone le laisse passer au
## ScrollContainer qui la porte.
##
## En `STOP`, le conteneur ne voyait jamais le glissement et un balayage commencé sur
## une case — c'est-à-dire presque partout, les cases occupant toute la largeur de la
## liste — ne faisait pas défiler le calendrier. Même remède que pour les lignes de la
## liste de courses et les cartes de la bibliothèque.
func _apply_input_mode() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS if Layout.is_phone() \
		else Control.MOUSE_FILTER_STOP

func set_recipe_name(value: String) -> void:
	recipe_name = value
	if _label:
		_label.text = value
	_update_badge()
	_update_photo()

## Photo de la recette posée dans la case : bandeau au-dessus du nom sur ordinateur,
## pastille à sa gauche sur téléphone, où les cases sont des lignes. En mode compact —
## deux repas par jour — elle passe en FOND, le nom par-dessus.
func _update_photo() -> void:
	if _box == null:
		return
	_box.vertical = not Layout.is_phone()
	if _photo != null:
		var holder := _photo.get_parent()
		if holder != null:
			holder.remove_child(_photo)
		_photo.queue_free()
		_photo = null

	var name := recipe_name.strip_edges()
	var recipe: Recipe = DataStore.get_recipe_by_name(name) if name != "" else null
	var texture: Texture2D = DataStore.get_photo_thumb(recipe.id) if recipe != null else null
	if texture == null:
		_apply_label_backdrop(false)
		return

	if compact:
		# Enfant DIRECT de la case, et placé en premier : un PanelContainer étire chacun
		# de ses enfants Control au rectangle intérieur, et les dessine dans l'ordre. La
		# photo occupe donc toute la case, sous la boîte du nom qui la suit.
		_photo = PhotoFrameScript.banner(texture, 0, 8)
		_photo.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(_photo)
		move_child(_photo, 0)
		_apply_label_backdrop(true)
		return

	_apply_label_backdrop(false)
	if Layout.is_phone():
		_photo = PhotoFrameScript.square(texture, Layout.TOUCH_TARGET - 8)
	else:
		# Hauteur minimale basse et expansion : la photo prend ce qui reste une fois le
		# nom placé, donc elle grandit avec la case au lieu d'en manger la hauteur.
		_photo = PhotoFrameScript.banner(texture, 28)
		_photo.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_child(_photo)
	_box.move_child(_photo, 0)

## Fond du nom. Sur une photo il faut un voile : assez opaque pour que le texte se lise
## d'un coup d'œil, assez transparent pour qu'on devine l'image dessous — c'est elle qui
## fait reconnaître le plat plus vite que son nom.
func _apply_label_backdrop(on_photo: bool) -> void:
	if _label_panel == null:
		return
	if not on_photo:
		_label_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		_label_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_box.alignment = BoxContainer.ALIGNMENT_BEGIN
		_set_inset(0)
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SURFACE, 0.78)
	sb.set_corner_radius_all(5)
	# Deux et un : le voile épouse le texte. À quatre et deux, ajoutés aux marges de la
	# case, le rectangle blanc venait buter contre le trait de la journée et prenait en
	# hauteur ce que la photo perdait.
	sb.content_margin_left = 2
	sb.content_margin_right = 2
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	_label_panel.add_theme_stylebox_override("panel", sb)
	# Et il se décolle des bords : un voile qui court d'un bord à l'autre de la case
	# masque la photo au lieu de se poser dessus.
	_set_inset(10)
	# Centré et non étiré : le voile épouse la hauteur du nom — une ou deux lignes — au
	# lieu de recouvrir la photo de haut en bas, ce qui reviendrait à la masquer.
	#
	# Les DEUX réglages sont nécessaires, et c'est le second qui manquait : dans une
	# boîte verticale, `SHRINK_CENTER` ne centre rien du tout. La boîte empile depuis le
	# haut et ne distribue l'espace restant qu'aux enfants marqués `EXPAND` ; le voile se
	# posait donc en haut de la case, la photo occupant tout le dessous. Le défaut ne se
	# voyait pas sur téléphone, où la boîte est horizontale et où le drapeau vertical
	# retrouve son sens.
	_label_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_box.alignment = BoxContainer.ALIGNMENT_CENTER

## Retrait latéral du voile. Zéro le laisse occuper toute la largeur de la case.
func _set_inset(pixels: int) -> void:
	if _label_inset == null:
		return
	for side in ["margin_left", "margin_right"]:
		if pixels <= 0:
			_label_inset.remove_theme_constant_override(side)
		else:
			_label_inset.add_theme_constant_override(side, pixels)

func _update_badge() -> void:
	if _badge == null:
		return
	var name := recipe_name.strip_edges()
	var recipe: Recipe = DataStore.get_recipe_by_name(name) if name != "" else null
	if recipe == null or recipe.categories.is_empty():
		_badge.visible = false
		return
	_badge.set_meta("color", Palette.category_color(recipe.categories[0]))
	_badge.visible = true
	_badge.queue_redraw()

## Réapplique le style après changement de `is_nobox` — le fond des cases réservées
## est décidé à la construction, il faut le redemander quand le réglage change.
func refresh_style() -> void:
	_apply_style(false)

## `lifted` : la case vient d'être saisie par un appui long et attend d'être déplacée.
## L'écart avec le simple survol doit se voir au premier coup d'œil — c'est le seul
## retour dont dispose le doigt pour savoir que la prise a eu lieu, là où la souris a
## le curseur et l'aperçu de glissement.
func _apply_style(hovered: bool, lifted := false) -> void:
	var sb := _ensure_panel_sb()
	var base: Color = Palette.CELL_NOBOX if is_nobox else Palette.CELL_BG
	var target_bg: Color = Palette.CELL_HOVER if hovered else base
	if grouped:
		# Demi-journée : pas d'ombre, pas de coins, pas d'agrandissement. Le fond suffit
		# à distinguer une case réservée de sa jumelle, et la prise se signale par la
		# bordure — le seul retour qui tienne dans un cadre dont on ne doit pas sortir.
		sb.set_corner_radius_all(0)
		# Trois et non six : la case n'a plus de cadre à elle, ses marges ne servent donc
		# qu'à écarter le contenu du trait de la journée. Six unités de chaque côté, sur
		# une demi-ligne de téléphone, se payaient en hauteur et en largeur utile.
		sb.set_content_margin_all(3)
		var border_w := 2 if lifted else 0
		_tween_panel_style(sb, target_bg, border_w, Palette.PRIMARY_INK, 0, Color.TRANSPARENT, Vector2.ZERO)
		MotionScript.hover_scale(self, Vector2.ONE)
		return
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(8)
	var shadow_size := 18 if lifted else (10 if hovered else 5)
	var shadow_color := Color(0.1, 0.2, 0.1, 0.22 if lifted else (0.14 if hovered else 0.07))
	var shadow_offset := Vector2(0, 6 if lifted else 2)
	var border_w := 0
	var border_col := Color.TRANSPARENT
	if lifted:
		border_w = 2
		border_col = Palette.PRIMARY_INK
	elif is_nobox:
		border_w = 1
		border_col = Palette.CELL_NOBOX_BORDER
	_tween_panel_style(sb, target_bg, border_w, border_col, shadow_size, shadow_color, shadow_offset)
	var target := Vector2(1.08, 1.08) if lifted else (Vector2(1.03, 1.03) if hovered else Vector2.ONE)
	MotionScript.hover_scale(self, target)

## Fait glisser le stylebox RÉUTILISÉ (`_ensure_panel_sb`) vers ses valeurs cibles plutôt
## que de les affecter d'un coup — le survol/la prise « sautaient » d'une couleur, d'une
## ombre et d'une bordure à l'autre entre deux images (2.0.0). Un seul `Tween` par appel,
## le précédent tué s'il tournait encore : le survol entre/sort vite, et deux transitions
## qui se chevauchent sur les mêmes propriétés se disputeraient la couleur d'arrivée.
func _tween_panel_style(sb: StyleBoxFlat, bg: Color, border_w: int, border_col: Color,
		shadow_size: int, shadow_color: Color, shadow_offset: Vector2) -> void:
	if not _style_initialized:
		_style_initialized = true
		sb.bg_color = bg
		sb.border_color = border_col
		sb.shadow_color = shadow_color
		sb.shadow_offset = shadow_offset
		sb.shadow_size = shadow_size
		sb.set_border_width_all(border_w)
		return
	if _style_tween != null and _style_tween.is_valid():
		_style_tween.kill()
	_style_tween = create_tween()
	_style_tween.set_parallel(true)
	var dur := MotionScript.HOVER_DURATION
	_style_tween.tween_property(sb, "bg_color", bg, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_style_tween.tween_property(sb, "border_color", border_col, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_style_tween.tween_property(sb, "shadow_color", shadow_color, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_style_tween.tween_property(sb, "shadow_offset", shadow_offset, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_style_tween.tween_property(sb, "shadow_size", shadow_size, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	for side in ["left", "top", "right", "bottom"]:
		_style_tween.tween_property(sb, "border_width_%s" % side, border_w, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

## Créé une seule fois et réutilisé : voir la remarque sur `_panel_sb`.
func _ensure_panel_sb() -> StyleBoxFlat:
	if _panel_sb == null:
		_panel_sb = StyleBoxFlat.new()
		add_theme_stylebox_override("panel", _panel_sb)
	return _panel_sb

func _on_mouse_entered() -> void:
	_apply_style(true)

func _on_mouse_exited() -> void:
	_apply_style(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		if not _lifted:
			_apply_style(true)
	elif what == NOTIFICATION_MOUSE_EXIT:
		if not _lifted:
			_apply_style(false)
	elif what == NOTIFICATION_DRAG_END:
		# Fin du déplacement, abouti ou non : la prise est rendue. Sans cela une case
		# déposée hors de toute cible resterait soulevée jusqu'au prochain appui.
		_press_active = false
		_lifted = false
		_apply_style(false)

# ===== Drag & Drop natif =====

## Vrai si la case accepte de partir en déplacement maintenant.
##
## À la souris, toujours — le geste est explicite et ne coûte rien. Au doigt, seulement
## après un appui long : sans cette condition, tout balayage parti d'une case démarrerait
## un déplacement au lieu de faire défiler la liste, et les deux gestes se disputeraient
## le même contact.
func can_be_dragged() -> bool:
	if recipe_name.strip_edges() == "":
		return false
	return _lifted or not Layout.is_phone()

func _get_drag_data(_at_position: Vector2) -> Variant:
	if not can_be_dragged():
		return null
	set_drag_preview(_make_drag_preview())
	_apply_style(true)
	return {"kind": "recipe", "name": recipe_name, "from_cell": self}

## Aperçu qui suit le pointeur pendant le déplacement.
##
## Au doigt il est décalé au-dessus du point de contact et posé sur un cadre opaque :
## sous la main, un libellé nu est à la fois caché et confondu avec les cases qu'il
## survole — on ne voit plus ni ce qu'on déplace ni où on le déplace.
func _make_drag_preview() -> Control:
	var label := Label.new()
	label.text = recipe_name
	label.add_theme_color_override("font_color", Palette.PRIMARY_INK)
	if not Layout.is_phone():
		return label

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Palette.card_style())
	card.add_child(label)
	var holder := Control.new()
	holder.add_child(card)
	var card_size := card.get_combined_minimum_size()
	card.position = -Vector2(card_size.x * 0.5, card_size.y + Layout.TOUCH_TARGET * 0.5)
	return holder

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "recipe"

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	var incoming: String = data.get("name", "")
	var previous := recipe_name
	set_recipe_name(incoming)
	# Si la source est une autre case, on échange les contenus.
	var from_cell = data.get("from_cell")
	if from_cell != null and from_cell != self and from_cell is MealCell:
		from_cell.set_recipe_name(previous)
		from_cell.cell_changed.emit()
	cell_changed.emit()

# ===== Gestes : menu, balayage, appui long =====

func _gui_input(event: InputEvent) -> void:
	if Layout.is_phone():
		_touch_input(event)
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
		context_requested.emit(self, get_global_mouse_position())

## Trois gestes se partagent la même case, sans clic droit pour les départager :
##
##  * **balayage** → défilement de la liste. La case ne consomme pas l'événement
##    (`MOUSE_FILTER_PASS`) et abandonne tout dès que le doigt a glissé.
##  * **appui bref** → menu de la case, d'où l'on choisit une recette. C'est l'action
##    la plus courante ici, elle garde donc le geste le plus simple.
##  * **appui long** → la case se soulève ; le glissement qui suit la déplace, et le
##    dépôt sur une autre case échange les deux repas.
##
## L'appui long ne peut pas être l'ouverture du menu ET la prise : c'est la prise, parce
## que le déplacement n'a pas d'autre geste disponible, là où le menu se contente de
## l'appui bref.
func _touch_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# Une fois la case soulevée, le glissement EST la prise : l'interrompre ici la
		# reposerait avant même que le déplacement n'ait pu démarrer.
		if _lifted:
			return
		if _press_active and event.position.distance_to(_press_origin) > TAP_SLOP:
			_cancel_press()   # devenu un balayage : ni menu ni prise
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		_press_origin = button.position
		_press_active = true
		_hold_timer.start()
		return

	var was_lifted := _lifted
	var tapped := _press_active and button.position.distance_to(_press_origin) <= TAP_SLOP
	_cancel_press()
	# Un relâchement qui conclut un dépôt ne doit pas ouvrir le menu par-dessus.
	if get_viewport().gui_is_dragging():
		return
	# Soulevée puis reposée sans avoir bougé : on en reste là. Ouvrir le menu ici
	# surprendrait — la case s'est visiblement saisie, c'est un déplacement abandonné.
	if was_lifted or not tapped:
		return
	context_requested.emit(self, get_global_mouse_position())

func _cancel_press() -> void:
	_press_active = false
	if _hold_timer != null:
		_hold_timer.stop()
	if _lifted:
		_lifted = false
		_apply_style(false)

func _on_hold_elapsed() -> void:
	# Une case vide n'a rien à déplacer : l'appui long y reste un appui, et le
	# relâchement ouvrira le menu comme d'habitude.
	if not _press_active or recipe_name.strip_edges() == "":
		return
	_lifted = true
	_apply_style(true, true)
