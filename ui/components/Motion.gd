class_name Motion
extends RefCounted
## Micro-interactions communes (2.0.0) — quelques primitives bâties sur `Tween`, pour les
## endroits où un état bascule sans la moindre transition visible. Trois fonctions ont
## suffi à couvrir tap, survol/prise d'une case et ouverture/fermeture d'un panneau
## flottant : ce n'est pas une bibliothèque d'easing à part entière, juste ce qu'il a
## fallu.
##
## Aucun état partagé (RefCounted, comme `TouchTap`) : chaque appel crée son propre Tween
## via `control.create_tween()`, à la charge du CONTRÔLE animé — Godot l'arrête de
## lui-même si celui-ci sort de l'arbre, aucun nettoyage à écrire ici.

const PRESS_DURATION := 0.08
const HOVER_DURATION := 0.12
const POP_DURATION := 0.16
## Entrée d'une fenêtre, changement d'onglet ou de section (2.0.9) : à peine perceptible —
## de quoi adoucir l'apparition, pas de quoi faire attendre. Au-delà de 150 ms environ, une
## transition sur chaque clic commence à se faire sentir comme un délai.
const FADE_DURATION := 0.12

## Pulsation brève à l'aboutissement d'un tap/clic — la seule confirmation visuelle d'un
## geste tactile était jusqu'ici l'état final (case cochée, éditeur ouvert…), rien entre
## le relâchement du doigt et ce résultat.
##
## Renvoie le `Tween`, ignoré par la quasi-totalité des appelants — utile pour vérifier
## `is_running()` juste après l'appel plutôt que d'interroger `scale` à un instant
## quelconque, peu fiable sur une animation aussi brève (80 ms) en `--headless`.
##
## `control` n'a VOLONTAIREMENT aucune annotation de type sur ces quatre fonctions.
## Un tap qui aboutit juste après que sa ligne a été reconstruite (`rebuild`) passe ici un
## contrôle déjà libéré — précisément le cas que `is_instance_valid` doit écarter. Avec un
## paramètre typé `: Control`, Godot vérifie le type AVANT d'entrer dans le corps de la
## fonction et lève une erreur sur une référence déjà libérée : le garde-fou qui suit
## n'aurait jamais eu l'occasion de s'exécuter. Trouvé en écrivant le test de ce cas.
static func press_feedback(control) -> Tween:
	if not is_instance_valid(control):
		return null
	var origin: Vector2 = control.scale
	var tween: Tween = control.create_tween()
	tween.tween_property(control, "scale", origin * 0.96, PRESS_DURATION * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", origin, PRESS_DURATION * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	return tween

## Anime `control.scale` vers `target` — remplace une affectation directe (`MealCell` la
## faisait « sauter » d'un cadre à l'autre) sans toucher à ce qui décide de la cible.
static func hover_scale(control, target: Vector2, duration := HOVER_DURATION) -> void:
	if not is_instance_valid(control):
		return
	var tween: Tween = control.create_tween()
	tween.tween_property(control, "scale", target, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

## Entrée d'un panneau flottant (popup, cadre d'édition) : fondu + léger agrandissement
## depuis 92 %, plutôt qu'une apparition instantanée. Pose `pivot_offset` au centre du
## contrôle au passage — sans lui, l'agrandissement part du coin haut-gauche et le
## panneau semble glisser au lieu de grandir sur place.
##
## `pivot` remplace ce centre quand le panneau naît d'un point précis — le menu de la
## pastille se déroule depuis son coin haut-droit, juste sous elle (2.0.9).
static func pop_in(control, pivot := Vector2(-1, -1)) -> void:
	if not is_instance_valid(control):
		return
	control.pivot_offset = pivot if pivot.x >= 0.0 else control.size / 2.0
	control.modulate = Color(1, 1, 1, 0)
	control.scale = Vector2(0.92, 0.92)
	var tween: Tween = control.create_tween()
	tween.set_parallel(true)
	tween.tween_property(control, "modulate:a", 1.0, POP_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", Vector2.ONE, POP_DURATION) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Sortie d'un panneau flottant : fondu et léger retrait, PUIS `then` (typiquement
## `queue_free`) — jamais un retrait direct, qui ferait disparaître le cadre d'un coup
## alors qu'il vient précisément d'apparaître en douceur.
static func pop_out(control, then: Callable, pivot := Vector2(-1, -1)) -> void:
	if not is_instance_valid(control):
		then.call()
		return
	control.pivot_offset = pivot if pivot.x >= 0.0 else control.size / 2.0
	var tween: Tween = control.create_tween()
	tween.set_parallel(true)
	tween.tween_property(control, "modulate:a", 0.0, POP_DURATION * 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_property(control, "scale", Vector2(0.94, 0.94), POP_DURATION * 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(then)

## Fondu d'entrée d'un contrôle déjà en place : nouvel onglet, nouvelle section des
## Paramètres (2.0.9). Rien ne bouge, seul l'apparition s'adoucit — un déplacement à
## chaque changement d'onglet finirait par lasser.
static func fade_in(control, duration := FADE_DURATION) -> void:
	if not is_instance_valid(control):
		return
	# Toujours vers l'opacité pleine : un fondu relancé à mi-course (deux changements
	# d'onglet rapprochés) partirait sinon de la valeur intermédiaire, et s'y arrêterait.
	control.modulate.a = 0.0
	var tween: Tween = control.create_tween()
	tween.tween_property(control, "modulate:a", 1.0, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

## Entrée de N'IMPORTE QUELLE fenêtre (popup, dialogue, Paramètres…), branchée une seule
## fois pour toutes par `MainWindow` (2.0.9) plutôt qu'écran par écran — la moitié des
## popups apparaissait sans transition, faute d'y avoir pensé.
##
## Un `Window` n'est PAS un `CanvasItem` : ni `modulate` ni `scale` n'y existent. Deux gestes
## donc, sur ce qui s'y prête :
##  * le CONTENU fond à l'entrée — ses enfants `Control`, sauf le fond (`ColorRect`) : celui-
##    ci reste, sans quoi le cadre de la fenêtre, peint par le moteur, montrerait sa couleur
##    pendant le fondu ;
##  * la fenêtre grandit à peine, depuis 96 % et son centre — sauf en plein écran (les
##    fenêtres d'un téléphone), où il n'y a nulle part où grandir, et où relayouter tout un
##    écran à chaque image pour un effet invisible ne servirait à rien.
##
## `window` doit déjà porter sa position et sa taille FINALES : l'appelant le diffère
## (`call_deferred`) après le `popup_centered()` qui les pose.
static func window_in(window) -> void:
	if not is_instance_valid(window) or not window.visible:
		return
	# Une seule fois par apparition. Ajoutée déjà visible PUIS réaffichée par
	# `popup_centered()`, une fenêtre déclenche deux appels dans la même image ; le second
	# lirait la taille DÉJÀ réduite par le premier comme taille finale, et la fenêtre
	# resterait à 96 %.
	var frame := Engine.get_process_frames()
	if window.get_meta("_window_in_frame", -1) == frame:
		return
	window.set_meta("_window_in_frame", frame)
	for child in window.get_children(true):
		if child is Control and not (child is ColorRect) and child.visible:
			fade_in(child)

	var final_pos: Vector2i = window.position
	var final_size: Vector2i = window.size
	var screen := Vector2(window.get_tree().root.get_visible_rect().size)
	if final_size.x >= screen.x * 0.95 and final_size.y >= screen.y * 0.95:
		return
	var center := Vector2(final_pos) + Vector2(final_size) / 2.0
	# Jamais en dessous de `min_size` : Godot y borne `size` de toute façon, une cible de
	# départ plus petite s'y ferait simplement écrêter — et `start_pos`, calculé pour cette
	# taille jamais atteinte, décalerait la fenêtre au lieu de la centrer.
	var start_size := (Vector2(final_size) * 0.96).max(Vector2(window.min_size))
	var start_pos := center - start_size / 2.0
	window.position = Vector2i(start_pos)
	window.size = Vector2i(start_size)
	var tween: Tween = window.create_tween()
	tween.set_parallel(true)
	tween.tween_property(window, "position", final_pos, FADE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(window, "size", final_size, FADE_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
