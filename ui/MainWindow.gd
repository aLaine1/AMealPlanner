extends Control
## Fenêtre principale : header + navigation par onglets imbriqués.
## Portage de main_window.MainWindow.

## Délai pendant lequel un second appui sur Retour quitte l'application.
const QUIT_CONFIRM_MS := 2500

var _main_tabs: TabContainer
var _tabs_margin: MarginContainer
## Marge horizontale appliquée de part et d'autre des onglets, retenue pour le calcul de
## la place disponible.
var _tab_margin := 16
var _sync_badge: Button
var _app_title: Label
## Pastille de compte (2.0.8) : dit en permanence si l'appareil est connecté, et ouvre le
## menu Compte / Paramètres. Remplace la roue crantée, dont elle reprend la place.
var _account_btn: Button
var _account_box: HBoxContainer
var _account_avatar: Control
var _account_state: Label
var _account_email: Label
## Menu déroulé sous la pastille, et l'attrape-clic qui le referme — null tant qu'il est
## replié.
var _account_menu: PanelContainer = null
var _account_menu_catcher: Control = null
## Instant du dernier appui sur Retour resté sans effet, faute d'écran à quitter.
var _quit_armed_ms := -QUIT_CONFIRM_MS

const OnboardingGateScript := preload("res://ui/onboarding/OnboardingGate.gd")
const AccountWindowScript := preload("res://ui/settings/AccountWindow.gd")
const MotionScript := preload("res://ui/components/Motion.gd")

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_present_onboarding_if_needed()
	Palette.scheme_changed.connect(_on_scheme_changed)
	get_tree().node_added.connect(_on_node_added)
	if AppState.reopen_settings_section != "":
		var section := AppState.reopen_settings_section
		AppState.reopen_settings_section = ""
		# Une image plus tard : la scène neuve finit d'abord de se disposer, la fenêtre
		# se centre alors sur sa taille réelle.
		(func(): _open_settings().open_section(section)).call_deferred()

## Toute fenêtre qui s'ouvre — popup, dialogue, Paramètres — entre en douceur (2.0.9).
##
## Branché ici, une fois, plutôt que dans chaque popup : la moitié d'entre eux apparaissait
## sans transition, faute d'y avoir pensé, et le prochain écran ajouté l'oublierait aussi.
##
## Les `Popup` (menus déroulants, infobulles) en sont exclus : leurs lignes sont dessinées
## par la fenêtre elle-même, sans enfant à faire fondre, et un menu d'`OptionButton` qui
## grandirait sous le curseur gênerait plus qu'il n'adoucirait.
##
## Différé : la fenêtre est souvent déjà visible à son ajout (c'est la valeur par défaut d'un
## `Window`), et `popup_centered()`, qui pose sa position et sa taille finales, ne passe
## qu'APRÈS — dans la même image, d'où l'appel en fin d'image.
func _on_node_added(node: Node) -> void:
	if not (node is Window) or node is Popup:
		return
	var window := node as Window
	var animate := Callable(MotionScript, "window_in")
	window.visibility_changed.connect(func():
		if window.visible:
			animate.call_deferred(window))
	if window.visible:
		animate.call_deferred(window)

## Nouveau thème de couleur : TOUTE l'interface est reconstruite, la scène rechargée.
##
## Chaque écran lit ses couleurs une fois, à sa construction — environ cent soixante
## lectures dans une trentaine de fichiers. Les faire toutes réagir à un signal aurait
## multiplié d'autant les occasions d'en oublier une ; recharger la scène les relit
## toutes, sans exception possible. Les données ne bougent pas : elles vivent dans les
## autoloads (`DataStore`, `AppState`), que le rechargement ne touche pas.
##
## Différé : le signal arrive au milieu du toucher sur la vignette, dont le nœud serait
## sinon libéré pendant qu'il traite encore son propre événement.
func _on_scheme_changed() -> void:
	AppState.reopen_settings_section = "Apparence"
	if get_tree().current_scene == self:
		get_tree().reload_current_scene.call_deferred()

## Première mise en route : connexion puis questionnaire, par-dessus l'application.
##
## La condition compte autant que l'écran. On ne le présente QUE si aucune session n'est
## enregistrée ET qu'aucun compte n'a jamais été vu sur cet appareil. Les deux, parce qu'ils
## disent deux choses différentes :
##
##  * une session enregistrée, c'est un appareil déjà connecté : le démarrage doit rester
##    silencieux et fonctionner hors ligne, comme depuis toujours ;
##  * un compte déjà vu sans session — une déconnexion volontaire — n'est pas une première
##    mise en route non plus : l'utilisateur sait où retrouver l'écran Compte, et lui barrer
##    la route serait le prendre pour un nouveau venu.
##
## Sans synchronisation configurée sur l'appareil, aucun écran non plus : il n'y aurait rien à
## quoi se connecter, et l'application est utilisable telle quelle.
##
## Version web (`LocalDatabase.ephemeral()`) : l'écran s'affiche à CHAQUE ouverture, sans
## condition. Rien n'est gardé sur le poste, le compte est donc le seul chemin vers les
## données — et un écran de connexion qu'on pourrait contourner ouvrirait sur le jeu
## d'exemple, pas sur le foyer. Une configuration absente n'en dispense pas non plus : elle
## rend l'application inutilisable, et l'écran le dira à la tentative de connexion. Seule
## exception, une session déjà ouverte : la scène se recharge à chaque changement de thème,
## et la session, portée par un autoload, y survit.
func _present_onboarding_if_needed() -> void:
	if LocalDatabase.ephemeral():
		if Session.status == Session.Status.SIGNED_OUT:
			add_child(OnboardingGateScript.new())
		return
	if not Session.is_configured():
		return
	if Session.has_stored_session():
		return
	if DataStore.local_database().get_sync_meta(LocalDatabase.ACCOUNT_KEY, "") != "":
		return
	var gate: Control = OnboardingGateScript.new()
	add_child(gate)

# ===== Bouton Retour d'Android =====

## `application/config/quit_on_go_back` est passé à `false` : sans cela, le moteur
## quitte l'application au premier appui, quoi qu'il y ait à l'écran. Perdre une recette
## à moitié saisie parce qu'on a voulu refermer son formulaire est une punition
## disproportionnée pour un bouton qu'on touche par réflexe.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# Traité en différé : le moteur distribue cette notification en parcourant
		# l'arbre, qui reste verrouillé pendant tout le parcours. Y ajouter un nœud —
		# ici le message de sortie — échoue, sans autre trace qu'une erreur en console.
		_go_back.call_deferred()

## Retour = défaire le dernier niveau d'entrée dans l'application, dans cet ordre :
## le menu de la pastille, la fenêtre ouverte par-dessus, puis une saisie restée ouverte, puis le détour par un
## autre onglet, puis l'application elle-même. Ce n'est qu'au dernier échelon que le geste
## devient irréversible, et il y demande confirmation.
func _go_back() -> void:
	if is_instance_valid(_account_menu):
		_close_account_menu()
		return
	var window := _topmost_window()
	if window != null:
		_dismiss_window(window)
		return
	# Un champ qui a encore le focus alors que le clavier est replié (le premier Retour,
	# Android le consomme pour replier le clavier, sans rien dire à l'app) : ce Retour-ci
	# termine la saisie, il ne quitte pas l'onglet sous les doigts. La perte de focus
	# suffit — chaque champ y fait déjà ce qui convient (la liste de courses valide).
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		focused.release_focus()
		return
	# Retour à l'onglet d'accueil, et non à l'onglet précédent : la barre n'en compte
	# que trois, sans profondeur — passer de la liste de courses au calendrier est un
	# déplacement latéral, pas un empilement dont il faudrait redescendre marche à marche.
	if _main_tabs != null and _main_tabs.current_tab != 0:
		_main_tabs.current_tab = 0
		return
	var now := Time.get_ticks_msec()
	if now - _quit_armed_ms <= QUIT_CONFIRM_MS:
		get_tree().quit()
		return
	_quit_armed_ms = now
	_flash_message("Appuyer à nouveau pour quitter")

## Fenêtre secondaire visible la plus haute : celle qui a le focus, à défaut la plus
## récemment créée — les identifiants d'instance croissent avec le temps, et une popup
## ouverte par-dessus une autre est forcément la plus jeune des deux.
func _topmost_window() -> Window:
	var best: Window = null
	for node in get_tree().root.find_children("*", "Window", true, false):
		var window := node as Window
		if window == null or not window.visible:
			continue
		if window.has_focus():
			return window
		if best == null or window.get_instance_id() > best.get_instance_id():
			best = window
	return best

## Ferme la fenêtre par le même chemin que la croix de sa barre de titre.
##
## Ni `hide()` ni `queue_free()` : chaque fenêtre sait ce qu'elle a à rendre en partant.
## La feuille latérale, notamment, doit remettre le panneau qu'elle a emprunté dans son
## conteneur d'origine — libérée sans cela, elle l'emporterait avec elle et l'écran se
## retrouverait sans bibliothèque de recettes.
##
## Les deux mécanismes coexistent dans le projet : les fenêtres maison branchent le
## signal `close_requested`, les dialogues du moteur écoutent la notification.
func _dismiss_window(window: Window) -> void:
	window.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	window.close_requested.emit()

## Message passager en bas de l'écran. Un `AcceptDialog` demanderait de confirmer une
## confirmation, et il n'y a rien à décider : le geste à faire est de refaire le geste.
## `seconds` : par défaut la fenêtre de confirmation de sortie, puisque c'est le message
## qui a fait naître ce toast. Un message qui ne porte pas de délai en dure davantage —
## il informe au lieu d'annoncer un geste à refaire.
func _flash_message(text: String, seconds := QUIT_CONFIRM_MS / 1000.0) -> void:
	var toast := PanelContainer.new()
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(Palette.TEXT_PRIMARY, 0.92)
	style.set_corner_radius_all(Palette.RADIUS)
	style.set_content_margin_all(12)
	toast.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color.WHITE)
	# Un message d'information tient en deux lignes plutôt qu'en une, qui déborderait
	# d'un écran de téléphone.
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(min(size.x - 3 * Layout.TOUCH_TARGET, 520.0), 0)
	toast.add_child(label)

	# Posé à la main : un conteneur ajouté à un Control nu n'est dimensionné par
	# personne, et resterait de taille nulle en haut à gauche.
	add_child(toast)
	var toast_size := toast.get_combined_minimum_size()
	toast.size = toast_size
	toast.position = Vector2((size.x - toast_size.x) * 0.5,
		size.y - toast_size.y - Layout.TOUCH_TARGET)

	# Disparaît de lui-même un peu après l'expiration du délai : un message qui
	# survivrait à la fenêtre pendant laquelle il dit vrai serait un mensonge.
	var tween := create_tween()
	tween.tween_interval(seconds)
	tween.tween_property(toast, "modulate:a", 0.0, 0.25)
	tween.tween_callback(toast.queue_free)

## Routeur global d'annulation : Ctrl+Z / Ctrl+Y (ou Ctrl+Maj+Z) vers l'onglet visible
## s'il expose undo()/redo(). Ne s'active que si aucun widget focalisé n'a déjà traité la touche.
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if not (event.ctrl_pressed or event.meta_pressed):
		return
	var node := _active_tab_node()
	if node == null:
		return
	var kc := (event as InputEventKey).keycode
	if kc == KEY_Z and not event.shift_pressed:
		if node.has_method("undo"):
			node.undo()
			get_viewport().set_input_as_handled()
	elif (kc == KEY_Z and event.shift_pressed) or kc == KEY_Y:
		if node.has_method("redo"):
			node.redo()
			get_viewport().set_input_as_handled()

func _active_tab_node() -> Node:
	if _main_tabs == null:
		return null
	return _main_tabs.get_current_tab_control()

func _build_ui() -> void:
	theme = Palette.ui_theme
	# Une taille plancher de 900x600 rendait l'app inaffichable sur téléphone. Le
	# plancher est désormais celui d'un petit téléphone : redimensionner la fenêtre
	# du poste de dev sous 600 unités bascule l'UI en mise en page mobile, ce qui
	# rend le responsive vérifiable sans appareil.
	get_window().min_size = Vector2i(320, 480)

	# Fond
	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# ===== Header =====
	var header := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.PRIMARY
	sb.set_content_margin_all(14)
	header.add_theme_stylebox_override("panel", sb)
	root.add_child(header)

	var header_box := HBoxContainer.new()
	header_box.add_theme_constant_override("separation", 14)
	header.add_child(header_box)

	var logo := Label.new()
	logo.text = "AMP"
	logo.add_theme_font_size_override("font_size", 26)
	logo.add_theme_color_override("font_color", Color.WHITE)
	header_box.add_child(logo)

	_app_title = Label.new()
	_app_title.text = "AMeal Planner"
	_app_title.add_theme_font_size_override("font_size", 20)
	_app_title.add_theme_color_override("font_color", Color.WHITE)
	_app_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_box.add_child(_app_title)

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_box.add_child(header_spacer)

	# Indicateur de synchronisation : cliquable pour lancer une sync à la demande.
	_sync_badge = Button.new()
	_sync_badge.theme_type_variation = "HeaderButton"
	_sync_badge.tooltip_text = "État de la synchronisation — cliquer pour synchroniser"
	_sync_badge.pressed.connect(_on_sync_badge_pressed)
	header_box.add_child(_sync_badge)
	Session.status_changed.connect(func(_s): _refresh_sync_badge())
	Sync.state_changed.connect(func(_s): _refresh_sync_badge())
	Sync.seed_decision_required.connect(_ask_seed_decision)
	# Sans ce mot, l'appareil paraîtrait avoir perdu son contenu : changer de compte vide
	# la base, et rien à l'écran ne dirait pourquoi.
	Sync.account_switched.connect(func(): _flash_message(
		"Nouveau compte : les données de l'ancien ont été retirées de cet appareil.", 8.0))
	_refresh_sync_badge()

	header_box.add_child(_build_account_chip())

	Layout.form_changed.connect(func(_f): _apply_form())
	# La garantie ci-dessous porte sur la LARGEUR, qui varie sans changer de format :
	# deux téléphones de même catégorie n'ont pas le même nombre d'unités logiques.
	Layout.viewport_resized.connect(func(_w): _fit_tab_bar())

	# ===== Onglets principaux =====
	_tabs_margin = MarginContainer.new()
	_tabs_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_tabs_margin.add_theme_constant_override(m, 16)
	root.add_child(_tabs_margin)
	var tabs_margin := _tabs_margin

	# Un seul groupe d'onglets : Calendrier · Petit Déj · Liste de course · Ingrédients.
	var main_tabs := TabContainer.new()
	main_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs_margin.add_child(main_tabs)
	_main_tabs = main_tabs

	# La barre elle-même dit quand elle a changé de largeur : c'est le seul instant où le
	# plafond peut être décidé sur des mesures valides.
	# Le CONTENEUR, et non la barre : lui est étiré à la largeur disponible, elle non.
	main_tabs.resized.connect(_fit_tab_bar)
	# Le nouvel onglet apparaît en fondu, au lieu de remplacer l'ancien d'un coup (2.0.9).
	main_tabs.tab_changed.connect(func(_index):
		MotionScript.fade_in(main_tabs.get_current_tab_control()))

	var planning_tab := PlanningTab.new()
	planning_tab.name = "Calendrier"
	main_tabs.add_child(planning_tab)

	var breakfast := BreakfastTab.new()
	breakfast.name = "Petit Déj"
	main_tabs.add_child(breakfast)

	var shopping_tab := ShoppingTab.new()
	shopping_tab.name = "Liste de course"
	main_tabs.add_child(shopping_tab)

	# En dernier, une fois les onglets en place : la mise en forme les touche, et
	# l'appeler avant laisserait la barre de navigation dans son état de départ
	# jusqu'au premier changement de format — qui n'arrive jamais si l'application
	# démarre déjà sur un téléphone.
	_apply_form()

## L'en-tête portait une largeur minimale de 485 unités (logo + titre + badge + bouton
## libellé). Un VBoxContainer imposant son minimum à toute la colonne, cette largeur se
## propageait au TabContainer et faisait déborder TOUS les onglets sur un écran de
## 412 px — le défaut se manifestait donc loin de sa cause. Sur téléphone, l'en-tête se
## réduit au logo et à deux icônes.
func _apply_form() -> void:
	var phone := Layout.is_phone()
	_app_title.visible = not phone
	_refresh_account_chip()
	_refresh_sync_badge()
	_apply_tab_form(phone)

## Les trois onglets doivent tenir côte à côte sur N'IMPORTE QUEL téléphone.
##
## Ils débordaient dès 412 unités — la largeur de l'appareil de test — et la barre
## affichait alors une flèche pour atteindre le troisième. Le défaut se voyait sur un
## téléphone et pas sur un autre, ce qui n'est pas une question de chance mais de
## largeur logique : elle dépend de la densité de l'écran, pas de sa taille.
##
## Relevé à 320 unités : 216 de barre disponible pour 330 d'onglets, dont **108 de
## remplissage pur** — les styles d'onglet portaient 18 unités de marge de chaque côté.
## Un seul levier suffit : les ramener à 8, ce qui libère 60 unités. Ni libellé raccourci
## ni police réduite — les deux avaient été ajoutés sur la foi d'une mesure prise AVANT
## cette réduction, et remesurer les a montrés inutiles. « Liste de course » à la police
## normale exige 270 unités pour 292 disponibles sur un écran de 320.
func _apply_tab_form(phone: bool) -> void:
	if _main_tabs == null:
		return
	# Les marges d'onglet : 18+18 par onglet, soit la moitié de la place à 320.
	for item in ["tab_selected", "tab_unselected", "tab_hovered", "tab_disabled"]:
		var box: StyleBox = Palette.ui_theme.get_stylebox(item, "TabContainer")
		if box == null:
			continue
		var tight := box.duplicate()
		tight.content_margin_left = 8 if phone else 18
		tight.content_margin_right = 8 if phone else 18
		_main_tabs.add_theme_stylebox_override(item, tight)

	# La police du thème est conservée : la barre de navigation se lit d'un coup d'œil au
	# pouce, et 22 unités de marge à 320 suffisent — le plafond de `_apply_max_tab_width`
	# est là pour le cas extrême, et il coupe un libellé plutôt que d'en cacher un.
	_main_tabs.remove_theme_font_size_override("font_size")

	# L'espace vertical est la ressource rare sur téléphone, mais c'est ici la marge
	# HORIZONTALE qui compte : 6 unités de moins de chaque côté, autant pour la barre.
	_tab_margin = Layout.margin() if phone else 16
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		_tabs_margin.add_theme_constant_override(m, _tab_margin)

	_fit_tab_bar()

## Plafonne la largeur d'un onglet au tiers de la barre. C'est la GARANTIE : quelles que
## soient la densité de l'écran et la longueur des libellés, les trois tiennent, le texte
## se coupant plutôt que de renvoyer un onglet hors champ. Les trois leviers ci-dessus
## servent à ce que cette coupe n'arrive jamais en pratique — mesuré, elle n'arrive pas
## au-dessus de 300 unités.
##
## Différé : appelé depuis un signal de redimensionnement, la barre n'a pas encore sa
## nouvelle taille.
func _fit_tab_bar() -> void:
	if _main_tabs == null:
		return
	_apply_max_tab_width.call_deferred()

## Le plafond n'est posé QUE s'il est nécessaire, et il est recalculé chaque fois que la
## barre change de largeur.
##
## Un plafond permanent tronquait les libellés alors que la place ne manquait pas —
## « Cal », « Peti », « Cou » à la capture. La valeur avait été calculée sur une barre pas
## encore disposée, puis conservée telle quelle.
##
## La largeur naturelle est donc calculée depuis la POLICE et les marges de style, sans
## passer par `get_tab_rect` : celui-ci reflète le plafond en vigueur, et s'en servir pour
## décider du plafond revenait à se mordre la queue.
func _apply_max_tab_width() -> void:
	if _main_tabs == null or not is_instance_valid(_main_tabs):
		return
	var bar := _main_tabs.get_tab_bar()
	var count := bar.get_tab_count()
	# `get_viewport_rect()` et non le `size` de ce Control : celui-ci dépend de sa propre
	# mise en page, et vaut encore zéro quand ce calcul tourne. La largeur du viewport est
	# la même mesure dont `Layout` déduit le format — la seule qui soit vraie dès le départ.
	var screen := get_viewport_rect().size.x
	if count == 0 or screen <= 0.0:
		return

	# La place disponible est déduite de la LARGEUR DE L'ÉCRAN, et non mesurée sur un
	# conteneur. Deux mesures ont été essayées et sont fausses :
	#  * la TabBar se dimensionne sur ses onglets et ne s'étire pas — une fois un plafond
	#    posé elle rétrécit, ce qui justifie le plafond, qui la fait rétrécir : la boucle
	#    s'entretenait seule et tronquait les trois onglets à 40 unités sur tout écran ;
	#  * le TabContainer n'a pas encore sa largeur définitive quand ce calcul tourne.
	# La largeur de la fenêtre, elle, est connue dès le départ et ne dépend de rien.
	var panel: StyleBox = _main_tabs.get_theme_stylebox("panel", "TabContainer")
	var chrome := 0.0 if panel == null \
		else panel.content_margin_left + panel.content_margin_right
	var available := screen - 2.0 * _tab_margin - chrome

	# Lues sur le TabContainer et sous le type « TabContainer » : c'est lui qui porte les
	# surcharges posées plus haut, et une surcharge de thème ne se transmet PAS aux
	# enfants. Interrogée sur elle-même, la TabBar renvoyait la police et les marges du
	# thème de base — la largeur naturelle était surestimée d'un tiers, et le plafond
	# tombait alors qu'il y avait la place. C'est ce qui donnait « Cal », « Peti », « Cou ».
	var font := _main_tabs.get_theme_font("font", "TabContainer")
	var font_size := _main_tabs.get_theme_font_size("font_size", "TabContainer")
	var box: StyleBox = _main_tabs.get_theme_stylebox("tab_unselected", "TabContainer")
	var padding := 0.0 if box == null else box.content_margin_left + box.content_margin_right
	var separation := bar.get_theme_constant("h_separation", "TabBar")

	var natural := float(separation * (count - 1))
	for index in range(count):
		natural += padding + font.get_string_size(
			bar.get_tab_title(index), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	# Aucun libellé n'est coupé tant que les trois tiennent — ce qui, les trois leviers
	# appliqués, est le cas dès 320 unités.
	bar.max_tab_width = 0 if natural <= available \
		else int(maxf((available - separation * (count - 1)) / count, 1.0))

## L'état de sync est volontairement discret : hors-ligne n'est pas une erreur mais
## un mode de fonctionnement normal, l'app étant utilisable sans réseau par
## conception. Seul un échec véritable est signalé en couleur d'alerte.
func _refresh_sync_badge() -> void:
	if _sync_badge == null:
		return
	if not Session.is_configured() or Session.status == Session.Status.SIGNED_OUT:
		_sync_badge.visible = false
		return
	_sync_badge.visible = true
	# Sur téléphone le badge se réduit à son pictogramme quand tout va bien ; un état
	# anormal, lui, s'écrit en toutes lettres — c'est celui qu'il faut lire. Pas
	# d'émoticône (2.0.9) : ⚠ et ☁ sortaient en couleur sur Android, seuls de l'en-tête.
	var compact := Layout.is_phone()
	match Sync.state:
		Sync.State.RUNNING:
			_sync_badge.text = "⟳" if compact else "⟳  Synchronisation…"
		Sync.State.ERROR:
			_sync_badge.text = "Erreur" if compact else "Erreur de sync"
		Sync.State.OFFLINE:
			_sync_badge.text = "Hors ligne"
		_:
			_sync_badge.text = "✓" if compact else "✓  Synchronisé"

func _on_sync_badge_pressed() -> void:
	await Sync.sync()

## Compte vierge alors que l'appareil porte encore le jeu d'exemple : on demande.
##
## Un AcceptDialog avec deux boutons explicites, et non un ConfirmationDialog : dans
## ce dernier, fermer par la croix déclenche `canceled` — soit ici la suppression des
## recettes. Aucune fermeture accidentelle ne doit détruire quoi que ce soit ; ignorer
## la question la fait simplement reposer à la synchronisation suivante.
func _ask_seed_decision() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Ce compte est vide"
	dialog.dialog_text = "L'application est fournie avec quelques recettes d'exemple.\n\n" \
		+ "Tu peux les garder comme point de départ — elles deviendront alors tes " \
		+ "recettes, sur tous tes appareils — ou repartir d'une base vierge et " \
		+ "constituer ta propre collection."
	# Le dialogue se dimensionne sur son texte, et sans repli il le pose sur UNE ligne :
	# mesuré à 1092 unités de large pour un écran de 412. Le repli seul ne suffit pas, il
	# lui faut une largeur cible — sans quoi il n'a rien contre quoi se replier.
	dialog.dialog_autowrap = true

	# Libellés courts au doigt : les deux boutons côte à côte réclamaient plus de 400
	# unités à eux seuls, et le texte au-dessus dit déjà ce que chacun engage.
	var phone := Layout.is_phone()
	dialog.get_ok_button().text = "Garder les exemples" if phone \
		else "Garder les recettes d'exemple"
	dialog.add_button("Base vierge" if phone else "Partir d'une base vierge", true, "clear")
	dialog.confirmed.connect(func(): _resolve_seed(dialog, true))
	dialog.custom_action.connect(func(action):
		if action == "clear":
			_resolve_seed(dialog, false))
	add_child(dialog)
	# `min_size`, et non la taille passée à `popup_centered` : celle-ci est ignorée dès
	# que `dialog_autowrap` est actif, le dialogue retombant alors à sa taille minimale.
	# Ce dialogue-ci y échappait par accident — ses deux boutons côte à côte lui
	# imposaient déjà plus de 400 unités —, mais la largeur ne venait pas d'où on le
	# croyait, et un libellé raccourci l'aurait fait fondre sans prévenir.
	var margin := float(Layout.margin())
	var width := minf(size.x - 2.0 * margin, 520.0)
	dialog.min_size = Vector2i(int(width), 0)
	dialog.popup_centered()

func _resolve_seed(dialog: AcceptDialog, keep: bool) -> void:
	dialog.hide()
	dialog.queue_free()
	await Sync.resolve_seed_decision(keep)

# ===== Pastille de compte =====

## Diamètre de la pastille : celui d'un pictogramme d'en-tête, dans une cible tactile.
const AVATAR_SIZE := 34
## Identifiants des deux lignes du menu.
const MENU_ACCOUNT := 0
const MENU_SETTINGS := 1

## La pastille : un rond portant l'initiale du compte quand l'appareil est connecté, une
## silhouette vide sinon — la convention des applications de Google, qu'on reconnaît sans
## l'avoir apprise. Sur ordinateur, l'état est aussi écrit à côté, avec l'adresse.
##
## Un `Button` (survol, focus, clic) dont le contenu est un HBox posé PAR-DESSUS : un
## bouton ne se dimensionne pas sur ses enfants, sa taille minimale suit donc celle du
## HBox (cf. `_fit_account_chip`).
func _build_account_chip() -> Control:
	_account_btn = Button.new()
	_account_btn.theme_type_variation = "HeaderButton"
	_account_btn.pressed.connect(_open_account_menu)

	_account_box = HBoxContainer.new()
	_account_box.add_theme_constant_override("separation", 10)
	_account_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_account_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_account_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_account_box.minimum_size_changed.connect(_fit_account_chip)
	_account_btn.add_child(_account_box)

	_account_avatar = Control.new()
	_account_avatar.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	_account_avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_account_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_account_avatar.draw.connect(_draw_avatar)
	_account_box.add_child(_account_avatar)

	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_account_box.add_child(text)

	_account_state = Label.new()
	_account_state.add_theme_color_override("font_color", Color.WHITE)
	_account_state.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(_account_state)

	_account_email = Label.new()
	_account_email.add_theme_font_size_override("font_size", 12)
	_account_email.add_theme_color_override("font_color", Color(1, 1, 1, 0.78))
	_account_email.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(_account_email)

	Session.status_changed.connect(func(_s): _refresh_account_chip())
	Session.email_changed.connect(func(_e): _refresh_account_chip())
	_refresh_account_chip()
	return _account_btn

## Vrai si un compte est rattaché à l'appareil — y compris hors ligne : le compte est
## toujours là, seul le serveur manque, et le badge de synchronisation le dit déjà.
func _is_signed_in() -> bool:
	return Session.is_configured() and Session.status != Session.Status.SIGNED_OUT

func _refresh_account_chip() -> void:
	if _account_btn == null:
		return
	var signed_in := _is_signed_in()
	var phone := Layout.is_phone()
	_account_state.text = "Connecté" if signed_in else "Déconnecté"
	_account_email.text = Session.email
	_account_state.get_parent().visible = not phone
	_account_email.visible = signed_in and Session.email != ""
	# Sur téléphone, la pastille seule : l'état se lit à sa forme, l'infobulle le redit.
	_account_btn.tooltip_text = ("Connecté — %s" % Session.email if Session.email != ""
		else "Connecté") if signed_in else "Déconnecté"
	_account_avatar.queue_redraw()
	_fit_account_chip()

func _fit_account_chip() -> void:
	if _account_btn == null:
		return
	# Marges du gabarit des boutons d'en-tête, pour que le survol déborde un peu le contenu.
	_account_btn.custom_minimum_size = _account_box.get_combined_minimum_size() + Vector2(16, 8)

func _draw_avatar() -> void:
	var c := _account_avatar
	var radius := AVATAR_SIZE / 2.0
	var center := Vector2(radius, radius)
	if not _is_signed_in():
		# Silhouette vide : un cercle, une tête, des épaules.
		c.draw_arc(center, radius - 1.5, 0, TAU, 48, Color(1, 1, 1, 0.85), 2.0, true)
		c.draw_circle(center + Vector2(0, -radius * 0.22), radius * 0.26, Color(1, 1, 1, 0.85))
		c.draw_arc(center + Vector2(0, radius * 0.62), radius * 0.5, PI, TAU, 24,
			Color(1, 1, 1, 0.85), 2.0, true)
		return
	c.draw_circle(center, radius, Color.WHITE)
	var initial := Session.email.substr(0, 1).to_upper() if Session.email != "" else "✓"
	var font := c.get_theme_default_font()
	var font_size := 17
	var text_size := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline := center + Vector2(-text_size.x / 2.0,
		(font.get_ascent(font_size) - font.get_descent(font_size)) / 2.0)
	c.draw_string(font, baseline, initial, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		Palette.PRIMARY)

## Deux lignes : le compte (« Se connecter » tant qu'il n'y en a pas), puis les Paramètres.
##
## Un panneau posé sur l'écran, et non un `PopupMenu` (2.0.9) : celui-ci prenait le style
## des cartes, et ses marges — taillées pour une carte de contenu — noyaient deux mots
## dans le vide. Et un `PopupMenu` est une fenêtre, qu'on ne peut pas faire apparaître en
## fondu : celui-ci se déroule depuis la pastille au lieu de surgir.
func _open_account_menu() -> void:
	if is_instance_valid(_account_menu):
		_close_account_menu()
		return

	_account_menu_catcher = Control.new()
	_account_menu_catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	_account_menu_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_account_menu_catcher.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			_close_account_menu())
	add_child(_account_menu_catcher)

	_account_menu = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.SURFACE
	style.set_corner_radius_all(Palette.RADIUS)
	style.set_border_width_all(1)
	style.border_color = Palette.BORDER
	style.shadow_color = Color(0, 0, 0, 0.18)
	style.shadow_size = 8
	style.shadow_offset = Vector2(0, 3)
	style.set_content_margin_all(4)
	_account_menu.add_theme_stylebox_override("panel", style)

	var items := VBoxContainer.new()
	items.add_theme_constant_override("separation", 0)
	_account_menu.add_child(items)
	var phone := Layout.is_phone()
	for entry in [[MENU_ACCOUNT, "Compte" if _is_signed_in() else "Se connecter"],
			[MENU_SETTINGS, "Paramètres"]]:
		var item := Button.new()
		item.text = entry[1]
		item.theme_type_variation = "GhostButton"
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# Une cible tactile par ligne au doigt ; plus serré à la souris.
		item.custom_minimum_size = Vector2(160, Layout.TOUCH_TARGET if phone else 36)
		item.pressed.connect(_on_account_menu.bind(entry[0]))
		items.add_child(item)
	add_child(_account_menu)

	# Aligné sur le bord droit de la pastille, juste en dessous : le menu se déroule DEPUIS
	# elle, et l'écran s'arrête à sa droite.
	_account_menu.reset_size()
	var anchor := _account_btn.get_global_rect()
	var menu_size := _account_menu.get_combined_minimum_size()
	_account_menu.position = Vector2(anchor.end.x - menu_size.x, anchor.end.y + 4) \
		- get_global_position()
	MotionScript.pop_in(_account_menu, Vector2(menu_size.x, 0))

func _close_account_menu() -> void:
	if is_instance_valid(_account_menu_catcher):
		_account_menu_catcher.queue_free()
	if is_instance_valid(_account_menu):
		var menu := _account_menu
		MotionScript.pop_out(menu, func(): menu.queue_free(), Vector2(menu.size.x, 0))
	_account_menu = null
	_account_menu_catcher = null

func _on_account_menu(id: int) -> void:
	_close_account_menu()
	match id:
		MENU_ACCOUNT: _open_account()
		MENU_SETTINGS: _open_settings()

func _open_account() -> Window:
	var win: Window = AccountWindowScript.new()
	add_child(win)
	win.popup_centered()
	return win

func _open_settings() -> SettingsWindow:
	# Ingrédients + articles de base derrière la roue crantée.
	var win := SettingsWindow.new()
	add_child(win)
	win.popup_centered()
	return win
