class_name TouchTap
extends RefCounted
## Fait d'un contrôle une cible qui n'agit qu'au toucher, jamais sur un défilement.
##
## Le même défaut est revenu trois fois — lignes de la liste de courses, cartes de la
## bibliothèque, cases à cocher du partage : un contrôle en `MOUSE_FILTER_STOP` consomme
## l'événement, le `ScrollContainer` qui le porte ne le voit jamais, et le défilement au
## doigt devient purement et simplement impossible. Or les listes occupent toute la
## largeur : le balayage part presque toujours d'un de leurs éléments.
##
## Deux précautions indissociables, et c'est bien leur réunion qui fait la solution :
##  * `MOUSE_FILTER_PASS`, pour que l'événement remonte au conteneur ;
##  * déclenchement au RELÂCHEMENT, et seulement si le doigt n'a pas glissé — sinon tout
##    balayage amorcé sur un élément l'activerait au passage, ce qui est pire que
##    l'absence de défilement : on cocherait au hasard en cherchant à lire.
##
## Usage : `TouchTap.connect_tap(row, func(): _toggle(item))`
##
## Le contrôle visé ne doit pas être un `Button` : celui-ci traite le clic pour son
## propre compte, et s'activerait donc AUSSI au terme d'un balayage. Un bouton se met en
## `MOUSE_FILTER_IGNORE` à l'intérieur de la cible, où il ne sert plus qu'à afficher.

const MotionScript := preload("res://ui/components/Motion.gd")

## Déplacement au-delà duquel un contact n'est plus un toucher mais un glissement.
## En unités logiques : ~8 dp, l'ordre de grandeur du « touch slop » d'Android.
const TAP_SLOP := 8.0

## Durée au-delà de laquelle un appui devient un appui long.
const HOLD_MS := 500

## Un seul contact suivi à la fois, pour toute l'application : il n'y a qu'un doigt, et
## un état par ligne n'apporterait rien qu'à tenir à jour.
static var _origin := Vector2.ZERO
static var _active := false
static var _started_ms := 0

## Rend un BOUTON compatible avec le défilement au doigt, et renvoie ce qu'il faut ajouter
## à l'arbre à sa place.
##
## Un `Button` traite le clic pour son propre compte et consomme l'événement : le
## `ScrollContainer` qui le porte ne voit jamais le glissement. Sur un écran couvert de
## pastilles — le réglage du planning en aligne vingt-sept —, presque tout balayage part
## de l'une d'elles, et la page refuse alors de défiler.
##
## Le bouton n'est donc plus qu'un AFFICHAGE : il passe en `MOUSE_FILTER_IGNORE`, et c'est
## l'enveloppe qui reçoit le geste, avec la règle habituelle — au relâchement, sur place.
## Son état visuel continue de se piloter comme avant (`set_pressed_no_signal`,
## `theme_type_variation`), l'appelant gardant sa référence au bouton.
##
## Sur ordinateur, rien n'est enveloppé : le bouton garde ses événements, donc son survol
## et son focus au clavier, et la molette fait défiler sans jamais passer par lui.
static func wrap_button(button: Button, on_tap: Callable) -> Control:
	if not Engine.get_main_loop().root.get_node("/root/Layout").is_phone():
		button.pressed.connect(on_tap)
		return button
	button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Une enveloppe qui DISPOSE son enfant et remonte sa taille minimale : un `Control` nu
	# n'en ferait ni l'un ni l'autre, et la pastille se retrouverait à taille zéro.
	var holder := MarginContainer.new()
	holder.add_child(button)
	connect_tap(holder, on_tap)
	return holder

## Même remède pour un CHAMP de saisie posé dans une liste défilante (2.0.10).
##
## Un `LineEdit` prend le focus dès l'APPUI et consomme l'événement : un balayage qui
## partait du champ « + Ajouter dans XXX » ne faisait pas défiler la liste, et ouvrait le
## clavier — par-dessus ce qu'on cherchait justement à lire. Sur une liste de courses, il y
## en a un au pied de chaque rayon : on finissait presque toujours par en toucher un.
##
## Le champ n'écoute donc plus rien tant qu'il n'a pas le focus (`MOUSE_FILTER_IGNORE`) ;
## c'est l'enveloppe qui reçoit le geste, et ne le lui donne qu'au toucher franc —
## relâché sur place. Une fois le focus pris, le champ reprend ses événements (placer le
## curseur, sélectionner), et les rend en le perdant.
##
## Sans pulsation, à la différence de `connect_tap` : un champ qui « rebondit » sous le
## doigt au moment où le clavier s'ouvre ferait un mouvement de trop.
##
## Sur ordinateur, rien n'est enveloppé : la molette fait défiler sans passer par le champ.
static func wrap_field(field: LineEdit) -> Control:
	if not Engine.get_main_loop().root.get_node("/root/Layout").is_phone():
		return field
	field.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var holder := MarginContainer.new()
	holder.size_flags_horizontal = field.size_flags_horizontal
	holder.size_flags_vertical = field.size_flags_vertical
	holder.mouse_filter = Control.MOUSE_FILTER_PASS
	holder.add_child(field)
	holder.gui_input.connect(func(event: InputEvent):
		handle(event, func():
			field.mouse_filter = Control.MOUSE_FILTER_STOP
			field.grab_focus()))
	field.focus_exited.connect(func(): field.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	return holder

## `on_hold` est optionnel : sans lui, la cible ne réagit qu'au toucher bref.
##
## `on_tap` est enveloppé d'une pulsation (`Motion.press_feedback`, 2.0.0) : c'est ICI, et
## nulle part ailleurs, que passe tout tap de l'app (lignes de la liste de courses,
## en-têtes de rayon, cases à cocher du partage…) — le seul point où l'ajouter couvre
## tout sans toucher un site d'appel. `handle()` reste volontairement pur (aucune
## référence à `control`), pour rester vérifiable en poussant des événements tout seul.
static func connect_tap(control: Control, on_tap: Callable, on_hold := Callable()) -> void:
	control.mouse_filter = Control.MOUSE_FILTER_PASS
	var tap_with_feedback := func():
		MotionScript.press_feedback(control)
		on_tap.call()
	control.gui_input.connect(func(event: InputEvent): handle(event, tap_with_feedback, on_hold))

## Exposée pour être vérifiable en poussant des événements, sans écran ni doigt.
static func handle(event: InputEvent, on_tap: Callable, on_hold := Callable()) -> void:
	if event is InputEventMouseMotion:
		if _active and event.position.distance_to(_origin) > TAP_SLOP:
			_active = false   # devenu un défilement : plus un toucher
		return
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		_origin = button.position
		_active = true
		_started_ms = Time.get_ticks_msec()
		return
	if _active and button.position.distance_to(_origin) <= TAP_SLOP:
		if on_hold.is_valid() and Time.get_ticks_msec() - _started_ms >= HOLD_MS:
			on_hold.call()
		else:
			on_tap.call()
	_active = false
