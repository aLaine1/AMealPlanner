class_name DragAutoScroll
extends Node
## Rend au conteneur qui le porte un défilement utilisable pendant un glisser-déposer :
## il devient le SEUL à défiler, et il défile aux bords.
##
## Sans lui, un déplacement ne peut atteindre que ce qui est déjà à l'écran : la liste du
## calendrier compte quatorze cases pour sept ou huit visibles sur un téléphone, et la
## moitié des échanges de position seraient irréalisables — le doigt tient la case, et
## rien d'autre ne peut plus faire défiler la liste tant qu'il ne l'a pas lâchée.
##
## À la souris, la molette reste disponible pendant un glissement ; ce n'est donc utile
## qu'au doigt, mais le comportement ne gêne pas et n'a pas à être conditionné.

## Bande, au bord du conteneur, où le défilement s'enclenche.
const EDGE := 64.0
## Vitesse atteinte au ras du bord, en unités par seconde. Elle décroît linéairement
## jusqu'à zéro à l'entrée de la bande : approcher du bord accélère, ce qui permet de
## doser un défilement lent sans viser au pixel près.
const SPEED := 900.0

var _scroll: ScrollContainer = null
## Filtre d'entrée du conteneur hors glisser-déposer, à lui rendre à la fin de celui-ci.
## Relevé et non supposé : un ScrollContainer naît en PASS, quand un Control naît en STOP.
var _idle_filter := Control.MOUSE_FILTER_PASS
var _frozen := false

## Le conteneur suivi est le parent : il suffit d'ajouter ce nœud au ScrollContainer.
## Pas de fabrique statique — s'y nommer soi-même exige que le cache des classes
## globales soit à jour, ce qu'un lancement headless ne garantit pas.
func _ready() -> void:
	_scroll = get_parent() as ScrollContainer

# ===== Gel du défilement au doigt pendant le déplacement =====

## Un même doigt portait la case ET la liste. La case est en `MOUSE_FILTER_PASS` — sans
## quoi aucun balayage parti d'une case ne ferait défiler quoi que ce soit —, si bien que
## l'événement remonte jusqu'au ScrollContainer, qui panoramique de son côté pendant que
## la case se déplace du sien. Les deux mouvements s'annulaient : la case restait sous le
## doigt sans jamais changer de voisins, et viser une position précise devenait un
## exercice d'équilibre. Mesuré ici : 100 unités de défilement parasite pour un geste
## de 100 unités.
##
## Le conteneur est donc gelé le temps du déplacement, et ne défile plus que par
## `_process` ci-dessous — aux bords, à vitesse maîtrisée, ce qui est précisément le
## défilement dont un déplacement a besoin.
func _notification(what: int) -> void:
	# Le moteur distribue ces deux notifications à TOUT l'arbre, ce nœud compris bien
	# qu'il ne soit pas un Control. DRAG_BEGIN arrive au moment même où le glissement
	# démarre : le gel précède le premier déplacement, là où une surveillance de
	# `gui_is_dragging()` dans `_process` laisserait passer une image de panoramique.
	if what == NOTIFICATION_DRAG_BEGIN:
		_set_frozen(true)
	elif what == NOTIFICATION_DRAG_END:
		_set_frozen(false)

## `MOUSE_FILTER_IGNORE` plutôt qu'un `SCROLL_MODE_DISABLED` : ce dernier ramènerait la
## position à zéro et interdirait le défilement automatique, qui est justement le seul
## encore souhaitable. IGNORE ne rend le conteneur transparent qu'à lui-même — ses
## enfants, les cases, continuent de recevoir les événements et donc d'accueillir le
## dépôt.
func _set_frozen(frozen: bool) -> void:
	if _scroll == null or frozen == _frozen:
		return
	_frozen = frozen
	if frozen:
		_idle_filter = _scroll.mouse_filter
		_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		_scroll.mouse_filter = _idle_filter

func _process(delta: float) -> void:
	if _scroll == null or not _scroll.is_visible_in_tree():
		return
	var viewport := get_viewport()
	if viewport == null or not viewport.gui_is_dragging():
		# Filet de sécurité : un conteneur resté gelé ne défilerait plus jamais, et la
		# case qui a demandé le gel peut disparaître avant la fin du glissement — les
		# cases sont reconstruites au dépôt.
		_set_frozen(false)
		return
	var step := scroll_step(_scroll.get_global_rect(), _scroll.get_global_mouse_position(), delta)
	if not is_zero_approx(step):
		_scroll.scroll_vertical += int(step)

## Décalage vertical à appliquer, en unités : négatif vers le haut, nul si le pointeur
## est hors du conteneur ou loin de ses bords.
##
## Séparé du reste pour être vérifiable sans écran ni glissement en cours.
static func scroll_step(rect: Rect2, pointer: Vector2, delta: float) -> float:
	if not rect.has_point(pointer):
		return 0.0
	# La bande ne dépasse jamais le quart de la hauteur : sur un conteneur court, deux
	# bandes de 64 se recouvriraient et le sens du défilement deviendrait arbitraire.
	var edge := minf(EDGE, rect.size.y * 0.25)
	if edge <= 0.0:
		return 0.0
	if pointer.y < rect.position.y + edge:
		return -(rect.position.y + edge - pointer.y) / edge * SPEED * delta
	if pointer.y > rect.end.y - edge:
		return (pointer.y - (rect.end.y - edge)) / edge * SPEED * delta
	return 0.0
