class_name KeyboardInset
extends Node
## Garde le champ en cours de saisie au-dessus du clavier virtuel.
##
## Le clavier d'Android se pose PAR-DESSUS l'application : ni la fenêtre ni le viewport
## ne rétrécissent, et rien n'avertit le ScrollContainer que sa moitié basse vient de
## disparaître. Le champ d'ajout de dernière minute clôt son rayon, il se trouve donc
## presque toujours en bas de la liste — on l'y remplissait à l'aveugle, sans voir ce
## qu'on tapait.
##
## Deux gestes, dans cet ordre. Le second seul ne suffirait pas :
##  1. une marge basse de la hauteur du clavier. Sans elle il n'y a rien à faire
##     défiler : la liste est déjà à son terme, et son dernier champ ne peut pas
##     remonter d'un pixel.
##  2. le défilement qui amène le champ au-dessus du clavier.
##
## Se pose comme `DragAutoScroll` : un enfant du ScrollContainer, sans autre réglage.

## Respiration entre le bas du champ et le haut du clavier. Un champ qui affleure le
## clavier se lit mal, et le doigt qui vise le champ touche la touche du dessous.
const MARGIN := 8.0
## Le clavier se déplie en s'animant, et la marge qu'on lui oppose met une image à se
## répercuter : on laisse le compte se stabiliser avant de replacer le champ.
const SETTLE_FRAMES := 2

var _scroll: ScrollContainer = null
## Conteneur du contenu défilant : seul endroit où une marge basse agrandit la zone
## défilable. `Layout.scroll_body` en pose un sur toutes les listes concernées ; à
## défaut, il reste le défilement, qui suffit à tout champ qui n'est pas le dernier.
##
## Cherché à l'USAGE et non à la construction. Les trois appelants posaient l'inset
## avant `Layout.scroll_body()` — l'ordre naturel, l'inset se réglant en une ligne et le
## contenu occupant les vingt suivantes. Or `add_child` déclenche `_ready()` sur-le-champ
## quand le parent est déjà dans l'arbre : le conteneur n'existait pas encore, `_body`
## restait nul, et la moitié du remède avec lui. Il ne restait que le défilement, qui
## traite tous les champs SAUF le dernier — c'est-à-dire précisément celui qu'on visait.
var _body: MarginContainer = null
## Champ suivi, ou null si le focus est ailleurs.
var _field: Control = null
var _inset := 0.0
## Images restant à attendre avant de replacer le champ : la marge doit d'abord être
## répercutée sur la hauteur du contenu, sinon le défilement demandé serait écrêté au
## terme de la liste — c'est-à-dire annulé, précisément dans le cas qui nous occupe.
var _settle := 0

func _ready() -> void:
	_scroll = get_parent() as ScrollContainer
	if _scroll == null:
		return
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	set_process(false)

## Le champ n'est suivi que s'il est DANS ce conteneur : une barre de recherche fixe
## posée au-dessus de la liste ne se rattraperait par aucun défilement de celle-ci.
func _on_focus_changed(control: Control) -> void:
	var field := control if _accepts(control) else null
	if field != _field:
		_field = field
		_settle = SETTLE_FRAMES
	# Le traitement continue après la perte du focus, le temps que le clavier se retire
	# et que la marge lui soit reprise.
	if _field != null or not is_zero_approx(_inset):
		set_process(true)

func _accepts(control: Control) -> bool:
	if control == null or _scroll == null:
		return false
	# Les seuls contrôles qui font monter le clavier. Un bouton qui prend le focus au
	# passage ne doit pas déplacer la liste sous le doigt.
	if not (control is LineEdit or control is TextEdit):
		return false
	return _scroll.is_ancestor_of(control)

func _process(_delta: float) -> void:
	var height := Layout.keyboard_height()
	if not is_equal_approx(height, _inset):
		_set_inset(height)
		_settle = SETTLE_FRAMES
	elif _settle > 0:
		_settle -= 1
		if _settle == 0:
			_reveal(height)
	elif _field != null and not is_zero_approx(_inset):
		# SURVEILLANCE, tant que le clavier est là. La remontée n'avait lieu qu'une fois,
		# deux images après que la hauteur du clavier s'était stabilisée : tout ce qui
		# déplaçait le champ APRÈS ce moment le renvoyait sous le clavier sans que rien ne
		# le rattrape — une ligne d'ingrédient ajoutée, une liste de suggestions qui
		# s'ouvre et se referme, une mise en page qui aboutit une image trop tard sur un
		# appareil chargé. Un `_reveal` ne coûte que deux rectangles tant qu'il n'y a rien
		# à faire, et ne bouge la liste que si le champ est réellement masqué.
		_reveal(height)
	# Rien à suivre et plus de marge à rendre : inutile d'interroger le système à
	# chaque image, l'appel traverse le pont Java.
	if _field == null and is_zero_approx(_inset) and _settle == 0:
		set_process(false)

## Le conteneur du contenu, cherché à la première marge à poser — donc une fois la liste
## bâtie. Renvoie null si le ScrollContainer n'en a pas : il reste alors le défilement.
func _find_body() -> MarginContainer:
	if _body != null and is_instance_valid(_body):
		return _body
	_body = null
	if _scroll == null:
		return null
	for child in _scroll.get_children():
		if child is MarginContainer:
			_body = child
			break
	return _body

func _set_inset(height: float) -> void:
	_inset = height
	if _find_body() == null:
		return
	if is_zero_approx(height):
		_body.remove_theme_constant_override("margin_bottom")
	else:
		_body.add_theme_constant_override("margin_bottom", int(ceil(height)))

## `height` : la hauteur du clavier, déjà connue de l'appelant. Elle est passée plutôt que
## redemandée à `Layout` — appelée maintenant à chaque image, cette fonction traverserait
## sinon le pont Java une seconde fois par image pour une valeur lue juste au-dessus.
func _reveal(height: float) -> void:
	if _scroll == null or _field == null or not is_instance_valid(_field):
		return
	var usable: float = get_tree().root.get_visible_rect().size.y - height
	var delta := scroll_delta(_scroll.get_global_rect(), _field.get_global_rect(), usable)
	# Seuil d'une unité : appelée à chaque image, une correction infinitésimale ferait
	# vibrer la liste sous le doigt sans jamais rien montrer de plus.
	if absf(delta) >= 1.0:
		_scroll.scroll_vertical += int(ceil(delta))

## Défilement à ajouter pour ramener `field` dans la partie de `view` que le clavier
## laisse voir. Positif = descendre dans la liste.
##
## Séparé du reste pour être vérifiable sans écran, sans clavier et sans appareil —
## c'est-à-dire là où ce calcul est écrit.
static func scroll_delta(view: Rect2, field: Rect2, usable_bottom: float) -> float:
	var bottom := minf(view.end.y, usable_bottom) - MARGIN
	var delta := 0.0
	if field.end.y > bottom:
		delta = field.end.y - bottom
	# Champ plus haut que la place restante — un pavé d'étapes de recette sur un demi
	# écran : mieux vaut voir son début, là où se tient le curseur, que sa fin. Cette
	# branche rattrape aussi un champ passé au-dessus de la zone visible.
	if field.position.y - delta < view.position.y:
		delta = field.position.y - view.position.y
	return delta
