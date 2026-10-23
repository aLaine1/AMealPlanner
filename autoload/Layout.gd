extends Node
## Format d'écran courant et métriques tactiles. Autoload "Layout".
##
## L'app vise le bureau (Windows/Linux) **et** Android depuis une base unique. Plutôt
## que deux arborescences d'UI, chaque onglet interroge `Layout.form` et se réarrange.
##
## ===== Unités =====
##
## Le viewport est en `canvas_items` + `expand` : les tailles manipulées dans le code
## sont donc des unités logiques, pas des pixels physiques. Sur mobile on règle
## `content_scale_factor` d'après la densité de l'écran, de sorte qu'une unité logique
## vaille à peu près un **dp Android** — un bouton de 48 unités fait alors ~48 dp,
## soit la taille de cible tactile recommandée, quelle que soit la densité réelle.
##
## Sur bureau l'échelle reste à 1 : on ne veut pas modifier le rendu existant, qui est
## déjà satisfaisant.
##
## ===== Détection =====
##
## Le format se déduit de la **largeur logique du viewport**, et non d'un test
## « est-ce Android ». Deux raisons : une tablette Android en paysage mérite la mise
## en page bureau, et surtout cela rend le mode téléphone testable en redimensionnant
## simplement la fenêtre sur le poste de dev — sans appareil ni mode simulé.

enum Form {
	PHONE,    ## < 600 unités de large : une seule colonne, navigation au pouce
	TABLET,   ## 600–899 : mise en page bureau resserrée
	DESKTOP,  ## >= 900 : mise en page complète
}

const PHONE_MAX_WIDTH := 600
const TABLET_MAX_WIDTH := 900

## Cible tactile minimale recommandée (Android : 48 dp). Utilisée pour les cases à
## cocher de la liste de courses, les boutons de barre d'action, etc.
const TOUCH_TARGET := 48
## Hauteur de ligne confortable au doigt dans les listes défilantes.
const TOUCH_ROW := 56
## Marge de respiration réduite sur petit écran : l'espace vertical y est la ressource rare.
const PHONE_MARGIN := 10
const DESKTOP_MARGIN := 16

## Largeur d'un panneau latéral en dessous de laquelle il ne descend jamais, et
## au-dessus de laquelle il ne monte pas. Le seuil de croissance est choisi juste
## au-dessus des fenêtres courantes (1280 de large) : en fenêtré, rien ne bouge.
## 320 et non 300 depuis la 1.7.11 : le texte du bureau ayant gagné deux points, un nom
## comme « Croque-monsieur végétarien » ne tenait plus dans la carte et se coupait en
## plein mot. Vingt unités prises au calendrier, qui en compte plusieurs centaines.
const SIDE_PANEL_MIN := 320
const SIDE_PANEL_MAX := 520
const SIDE_PANEL_RATIO := 0.24
const SIDE_PANEL_GROW_FROM := 1300

signal form_changed(form: Form)
## Émis à chaque redimensionnement du viewport, quel que soit le format.
signal viewport_resized(width: float)

var form: Form = Form.DESKTOP

func _ready() -> void:
	_apply_content_scale()
	get_tree().root.size_changed.connect(_update_form)
	_update_form()
	_log_metrics()

## Trace unique au démarrage. Les métriques d'écran ne sont pas observables autrement
## sur un appareil : sans elles, un mauvais format se diagnostique à l'aveugle.
func _log_metrics() -> void:
	print("Layout: fenêtre=%s viewport=%s dpi=%d échelle=%.2f → %s" % [
		DisplayServer.window_get_size(),
		get_tree().root.get_visible_rect().size,
		DisplayServer.screen_get_dpi(),
		get_window().content_scale_factor,
		["PHONE", "TABLET", "DESKTOP"][form],
	])

## true si l'entrée principale est le doigt. Sert à choisir entre survol et appui,
## et à activer le repli tap-to-place du drag & drop.
func is_touch() -> bool:
	return DisplayServer.is_touchscreen_available()

func is_phone() -> bool:
	return form == Form.PHONE

func is_compact() -> bool:
	return form != Form.DESKTOP

func margin() -> int:
	return PHONE_MARGIN if is_phone() else DESKTOP_MARGIN

## Densité de l'écran → facteur d'échelle du contenu, sur mobile uniquement.
## 160 dpi est la densité de référence Android (mdpi), où 1 dp = 1 px.
func _apply_content_scale() -> void:
	if not OS.has_feature("mobile"):
		return
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0:
		return
	get_window().content_scale_factor = clampf(float(dpi) / 160.0, 1.0, 4.0)

# ===== Clavier virtuel =====

## Hauteur du clavier virtuel, **en unités logiques**, 0 s'il est replié.
##
## `DisplayServer` la donne en pixels physiques. Comparée telle quelle à des positions
## de contrôles, elle désignerait un tout autre endroit de l'écran : sur le Redmi de
## test (~440 dpi, échelle 2,75) un clavier de 900 px vaudrait 900 unités sur un écran
## qui n'en compte que 915, et l'application entière se croirait recouverte.
func keyboard_height() -> float:
	if forced_keyboard_height >= 0.0:
		return forced_keyboard_height
	# `KeyboardInset` interroge cette fonction à CHAQUE image tant qu'un champ a le focus.
	# Sur PC (Windows, Linux), le serveur d'affichage n'a pas de clavier virtuel et
	# `virtual_keyboard_get_height()` le dit par un WARNING — pas juste un zéro silencieux
	# comme le documentait ce commentaire. Sans ce garde-fou, taper dans n'importe quel
	# champ noie les journaux de la version bureau à 60 avertissements par seconde.
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return 0.0
	return keyboard_units(float(DisplayServer.virtual_keyboard_get_height()),
		get_window().content_scale_factor)

## Hauteur de clavier imposée, en unités logiques. Négatif = on interroge le système.
##
## Une prise pour les essais, et la seule possible : le clavier virtuel n'existe que sur
## l'appareil, `virtual_keyboard_get_height()` rendant zéro partout ailleurs. Sans elle, le
## remède au clavier n'est vérifiable que de tête — ce qui l'a laissé à moitié branché
## pendant toute la 1.7, sous une suite verte. On ne simule pas le clavier ici : on impose
## sa hauteur, et tout le reste du chemin est celui de l'appareil.
var forced_keyboard_height := -1.0

## Séparée pour être vérifiable sans appareil : c'est la conversion, et non l'appel au
## système, qui peut être fausse.
static func keyboard_units(pixels: float, scale: float) -> float:
	if pixels <= 0.0:
		return 0.0
	return pixels / maxf(scale, 0.001)

## Ordonnée sous laquelle plus rien n'est visible : le bas du viewport, ou le haut du
## clavier s'il est déplié. Le clavier d'Android se pose PAR-DESSUS l'application, sans
## que la fenêtre ni le viewport ne rétrécissent : personne d'autre ne sait que la
## moitié basse de l'écran vient de disparaître.
func usable_bottom() -> float:
	return get_tree().root.get_visible_rect().size.y - keyboard_height()

## Écart entre le contenu défilant et la barre de défilement. Godot colle la barre
## verticale au bord droit de la zone : sans gouttière, elle touche les cartes.
const SCROLL_GUTTER := 10

## Insère une gouttière à droite du contenu d'un ScrollContainer et renvoie le
## conteneur auquel rattacher ce contenu.
##
## Pas de drapeau d'expansion verticale : dans un ScrollContainer, il forcerait le
## contenu à la hauteur visible et empêcherait tout défilement.
func scroll_body(scroll: ScrollContainer) -> MarginContainer:
	var gutter := MarginContainer.new()
	gutter.add_theme_constant_override("margin_right", SCROLL_GUTTER)
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(gutter)
	return gutter

## Dimensionne une fenêtre secondaire (popup, réglages) selon le format.
##
## Sur téléphone elle occupe tout l'écran : les tailles pensées pour le bureau
## (jusqu'à 920x660 pour les Réglages) débordent d'un écran de 412 unités, et une
## fenêtre partiellement hors champ n'est pas refermable au doigt.
func fit_window(window: Window, desktop_size: Vector2i, desktop_min: Vector2i) -> void:
	if is_phone():
		var screen := get_tree().root.get_visible_rect().size
		window.min_size = Vector2i(280, 320)
		window.size = Vector2i(screen)
		window.position = Vector2i.ZERO
	else:
		window.min_size = desktop_min
		window.size = desktop_size

func _update_form() -> void:
	var width := get_tree().root.get_visible_rect().size.x
	var new_form := Form.DESKTOP
	if width < PHONE_MAX_WIDTH:
		new_form = Form.PHONE
	elif width < TABLET_MAX_WIDTH:
		new_form = Form.TABLET
	# Émis à CHAQUE redimensionnement, là où `form_changed` ne parle qu'aux trois
	# seuils : les panneaux latéraux suivent la largeur en continu, ils ne peuvent pas
	# se contenter d'un signal qui ne se déclenche qu'en changeant de format.
	viewport_resized.emit(width)
	if new_form == form:
		return
	form = new_form
	form_changed.emit(form)

## Largeur d'un panneau latéral — bibliothèque de recettes, choix de petits déjeuners.
##
## Fixe tant que la fenêtre reste modeste : le calendrier a besoin de toute la place
## qu'on peut lui laisser, et le panneau doit surtout rester visible. Au-delà de
## `SIDE_PANEL_GROW_FROM`, l'espace ne manque plus et c'est l'inverse qui gêne — sur un
## grand écran, un panneau resté à 300 points paraît étriqué à côté d'un calendrier
## démesuré. Il devient donc proportionnel, jusqu'à un plafond : au-delà, on ne ferait
## qu'éloigner les cases du calendrier les unes des autres.
func side_panel_width() -> float:
	var width := get_tree().root.get_visible_rect().size.x
	if width <= SIDE_PANEL_GROW_FROM:
		return float(SIDE_PANEL_MIN)
	return clampf(width * SIDE_PANEL_RATIO, SIDE_PANEL_MIN, SIDE_PANEL_MAX)
