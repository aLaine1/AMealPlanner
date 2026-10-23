extends SceneTree
## Micro-interactions communes (`ui/components/Motion.gd`).
## godot --headless --path . --script res://tools/test_motion.gd
##
## Chaque primitive anime une propriété réelle sur un vrai `Tween` : ce test avance le
## temps en attendant réellement (`create_timer`), comme `test_shopping_collapse.gd` le
## fait déjà pour `TouchTap.HOLD_MS` — un `Tween` lit l'horloge murale au fil des images,
## une horloge de test simulée ne l'avancerait pas.

const MotionScript := preload("res://ui/components/Motion.gd")

var _fails := 0

func _initialize() -> void:
	root.size = Vector2i(200, 200)

	await _test_press_feedback()
	await _test_hover_scale()
	await _test_pop_in()
	await _test_pop_out()
	await _test_window_in()
	await _test_window_in_respects_min_size()
	await _test_window_in_fullscreen()
	await _test_fade_in()
	await _test_freed_control_is_a_no_op()

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _test_press_feedback() -> void:
	print("--- press_feedback : pulsation, retour à l'échelle d'origine ---")
	var c := _control()
	c.scale = Vector2.ONE
	# `is_running()` juste après l'appel, pas une valeur de `scale` à un instant choisi :
	# 80 ms est trop bref pour qu'un sondage par `scale` tombe de façon fiable pendant le
	# vol du `Tween` en `--headless`, où le débit d'images n'est pas fixé.
	var tween := MotionScript.press_feedback(c)
	_check("un Tween en cours juste après l'appel", tween != null and tween.is_running())
	await create_timer(MotionScript.PRESS_DURATION + 0.1).timeout
	_check("revenue exactement à l'origine une fois la pulsation finie",
		c.scale.is_equal_approx(Vector2.ONE))
	c.queue_free()

func _test_hover_scale() -> void:
	print("--- hover_scale : transition, pas un saut ---")
	var c := _control()
	c.scale = Vector2.ONE
	var target := Vector2(1.08, 1.08)
	MotionScript.hover_scale(c, target, 0.1)
	await process_frame
	_check("pas encore à la cible juste après l'appel (transition, pas un saut)",
		not c.scale.is_equal_approx(target))
	await create_timer(0.1 + 0.1).timeout
	_check("atteint la cible une fois la durée écoulée", c.scale.is_equal_approx(target))
	c.queue_free()

func _test_pop_in() -> void:
	print("--- pop_in : parti invisible et réduit, arrive plein et à taille normale ---")
	var c := _control()
	c.scale = Vector2.ONE
	c.modulate = Color.WHITE
	MotionScript.pop_in(c)
	# Posés AVANT le premier `tween_property`, donc déjà en place à l'image suivante —
	# c'est l'état de DÉPART de l'entrée, pas son résultat.
	_check("part invisible", is_zero_approx(c.modulate.a))
	_check("part réduit à 92 %", c.scale.is_equal_approx(Vector2(0.92, 0.92)))
	await create_timer(MotionScript.POP_DURATION + 0.15).timeout
	_check("arrive pleinement opaque", is_equal_approx(c.modulate.a, 1.0))
	_check("arrive à taille normale", c.scale.is_equal_approx(Vector2.ONE))
	c.queue_free()

func _test_pop_out() -> void:
	print("--- pop_out : `then` appelé APRÈS le fondu, pas à la place d'un retrait direct ---")
	var c := _control()
	c.modulate = Color.WHITE
	var called := [false]
	MotionScript.pop_out(c, func(): called[0] = true)
	await process_frame
	_check("`then` pas encore appelé juste après (le fondu n'est pas fini)", not called[0])
	_check("déjà en train de s'estomper", c.modulate.a < 1.0)
	await create_timer(MotionScript.POP_DURATION + 0.15).timeout
	_check("`then` appelé une fois le fondu terminé", called[0])
	c.queue_free()

func _test_window_in() -> void:
	print("--- window_in : agrandissement depuis le centre, contenu en fondu, fond intact ---")
	# En --headless, `root` reste à 64×64 quelle que soit la taille demandée : les fenêtres
	# d'essai sont donc taillées d'après l'écran RÉEL, sans quoi toutes passeraient pour du
	# plein écran — que `window_in` n'agrandit pas.
	var screen := _screen()
	var w := _window()
	w.min_size = Vector2i(4, 4)
	w.position = Vector2i(screen / 8)
	w.size = Vector2i(screen / 2)
	var bg := ColorRect.new()
	w.add_child(bg)
	var content := Label.new()
	w.add_child(content)
	var final_pos := w.position
	var final_size := w.size
	MotionScript.window_in(w)
	_check("rétréci juste après l'appel", w.size != final_size)
	_check("contenu effacé au départ", content.modulate.a < 0.01)
	_check("fond laissé tel quel", is_equal_approx(bg.modulate.a, 1.0))
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("revenu à la position finale", w.position == final_pos)
	_check("revenu à la taille finale", w.size == final_size)
	_check("contenu entièrement visible", is_equal_approx(content.modulate.a, 1.0))
	# Deux déclenchements dans la même image (ajout déjà visible, puis `popup_centered`) :
	# le second ne doit pas prendre la taille réduite par le premier pour la finale.
	await process_frame
	MotionScript.window_in(w)
	MotionScript.window_in(w)
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("double appel : revenue à la taille finale", w.size == final_size)
	w.queue_free()

func _test_window_in_respects_min_size() -> void:
	print("--- window_in : jamais en dessous de min_size, même comme point de départ ---")
	var half := Vector2i(_screen() / 2)
	var w := _window()
	w.min_size = half
	w.position = Vector2i(_screen() / 8)
	w.size = half   # déjà à sa taille minimale : rien à rétrécir
	MotionScript.window_in(w)
	_check("ne descend pas sous min_size même au départ", w.size.x >= half.x and w.size.y >= half.y)
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("toujours à la taille finale", w.size == half)
	w.queue_free()

## Les fenêtres d'un téléphone occupent tout l'écran : rien à agrandir, seul le contenu fond.
func _test_window_in_fullscreen() -> void:
	print("--- window_in : en plein écran, pas d'agrandissement ---")
	var full := Vector2i(_screen())
	var w := _window()
	w.position = Vector2i.ZERO
	w.size = full
	var content := Label.new()
	w.add_child(content)
	MotionScript.window_in(w)
	_check("taille inchangée", w.size == full)
	_check("contenu tout de même en fondu", content.modulate.a < 0.01)
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("contenu visible à la fin", is_equal_approx(content.modulate.a, 1.0))
	w.queue_free()

func _test_fade_in() -> void:
	print("--- fade_in : un onglet ou une section apparaît en fondu ---")
	var c := _control()
	MotionScript.fade_in(c)
	_check("effacé au départ", c.modulate.a < 0.01)
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("visible à la fin", is_equal_approx(c.modulate.a, 1.0))
	# Un fondu relancé avant la fin (deux changements d'onglet rapprochés) ne doit pas
	# laisser le contrôle à mi-chemin.
	MotionScript.fade_in(c)
	MotionScript.fade_in(c)
	await create_timer(MotionScript.FADE_DURATION + 0.15).timeout
	_check("visible après deux fondus rapprochés", is_equal_approx(c.modulate.a, 1.0))
	c.queue_free()

## Aucune des cinq fonctions ne doit tenter d'animer un contrôle/fenêtre déjà libéré — un
## tap qui aboutit juste après que sa ligne a été reconstruite (rebuild) y expose l'app
## sans qu'aucun geste inhabituel ne soit nécessaire pour le déclencher.
func _test_freed_control_is_a_no_op() -> void:
	print("--- Contrôle/fenêtre déjà libéré : aucune des cinq ne doit lever d'erreur ---")
	var c := _control()
	c.queue_free()
	await process_frame
	MotionScript.press_feedback(c)
	MotionScript.hover_scale(c, Vector2.ONE)
	MotionScript.pop_in(c)
	var called := [false]
	MotionScript.pop_out(c, func(): called[0] = true)
	_check("`pop_out` appelle quand même `then` sur un contrôle déjà libéré", called[0])
	var w := _window()
	w.queue_free()
	await process_frame
	MotionScript.window_in(w)
	MotionScript.fade_in(c)
	_check("arrivé jusqu'ici sans lever d'erreur", true)

func _screen() -> Vector2:
	return root.get_visible_rect().size

func _control() -> Control:
	var c := Control.new()
	root.add_child(c)
	return c

func _window() -> Window:
	var w := Window.new()
	root.add_child(w)
	return w

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
