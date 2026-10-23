extends SceneTree
## Version web : rien ne reste sur le poste, et l'écran de connexion ne se contourne pas.
## MEALPLANNER_EPHEMERAL=1 godot --headless --path . --script res://tools/test_web.gd
##
## La version web sert sur un ordinateur d'emprunt. Une base ou une session laissée sur le
## disque livrerait le foyer au suivant ; un écran de connexion qui se laisserait passer
## ouvrirait l'application sur le jeu d'exemple, sans rien de ce qui fait son intérêt.
## `run_tests.sh` pose la variable pour cette seule suite.

var _fails := 0
var _store

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(1280, 800)
	await process_frame
	_store = root.get_node_or_null("/root/DataStore")
	if _store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return
	if not LocalDatabase.ephemeral():
		print("  [ÉCHEC] MEALPLANNER_EPHEMERAL=1 attendu — lancer via tools/run_tests.sh")
		quit(1)
		return

	_test_nothing_on_disk()
	await _test_gate_always_shown()

	print("")
	print("Version web conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## La base vit en mémoire, et la session n'est jamais écrite.
func _test_nothing_on_disk() -> void:
	print("--- Rien sur le disque ---")
	_check("base en mémoire", LocalDatabase.db_path() == ":memory:")
	# La base doit pourtant fonctionner : le jeu d'exemple est semé, on y écrit, on relit.
	var db = _store.local_database()
	db.set_sync_meta("test_web", "ok")
	_check("la base en mémoire répond", db.get_sync_meta("test_web", "") == "ok")
	_check("jeu d'exemple chargé", not _store.get_all_recipe_objects().is_empty())
	var file_db := OS.get_environment("MEALPLANNER_DB")
	_check("aucun fichier de base créé", file_db == "" or not FileAccess.file_exists(file_db))

	var session = root.get_node("/root/Session")
	_check("aucune session reprise au lancement", not session.has_stored_session())
	# Écriture forcée : un jeton en main, la session ne doit toujours rien poser sur le disque.
	session._refresh_token = "jeton-de-test"
	session._store_session()
	session._refresh_token = ""
	_check("la session n'est jamais écrite", not FileAccess.file_exists(session.session_path()))

## L'écran s'affiche à chaque ouverture — même sur une base qui a déjà vu un compte, cas
## où la version installée, elle, ne le montre plus.
func _test_gate_always_shown() -> void:
	print("--- Connexion obligatoire ---")
	var db = _store.local_database()
	db.set_sync_meta(LocalDatabase.ACCOUNT_KEY, "00000000-0000-4000-8000-00000000aaaa")
	_check("compte déjà vu : l'écran s'affiche quand même", await _gate_appears())
	db.set_sync_meta(LocalDatabase.ACCOUNT_KEY, "")
	_check("aucun compte vu : l'écran s'affiche", await _gate_appears())

func _gate_appears() -> bool:
	var main: Control = load("res://ui/MainWindow.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var found := false
	for child in main.get_children():
		if child.get_script() != null and child.has_method("_on_survey_done"):
			# Présent ne suffit pas : réduit à un point, l'écran laissait l'application à nu.
			found = child.is_visible_in_tree() and child.size.x > 0 and child.size == main.size
	main.queue_free()
	await process_frame
	return found

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
