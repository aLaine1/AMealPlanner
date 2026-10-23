extends SceneTree
## Première mise en route : quand l'écran s'affiche, et ce que le questionnaire écrit.
## godot --headless --path . --script res://tools/test_onboarding.gd
##
## Deux risques, et ce sont des risques d'EXCÈS. Un écran de connexion qui s'affiche quand il ne
## faut pas retire à l'application sa qualité fondatrice — fonctionner hors ligne — et un
## questionnaire reposé sur un second appareil efface des réponses déjà données. Les conditions
## d'affichage comptent donc autant que l'écran lui-même.
##
## Voir 0_plan_1.8.0.md, étape 6 et décision D1.

var _fails := 0
var _store
var _db

func _initialize() -> void:
	await process_frame
	root.size = Vector2i(412, 915)
	await process_frame
	_store = root.get_node_or_null("/root/DataStore")
	if _store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return
	_db = _store.local_database()

	await _test_gate_conditions()
	await _test_survey_writes_settings()
	_test_defaults_are_current_values()

	print("")
	print("Mise en route conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## L'écran ne doit apparaître qu'à la toute première mise en route.
func _test_gate_conditions() -> void:
	print("--- Quand l'écran s'affiche ---")
	var saved_account: String = _db.get_sync_meta(LocalDatabase.ACCOUNT_KEY, "")

	# Un compte déjà vu sur cet appareil : ce n'est pas une première mise en route, même sans
	# session valide — une déconnexion volontaire ne doit pas barrer la route.
	_db.set_sync_meta(LocalDatabase.ACCOUNT_KEY, "00000000-0000-4000-8000-00000000aaaa")
	_check("compte déjà vu : aucun écran", not await _gate_appears())

	# Aucun compte jamais vu : l'écran s'affiche, à condition que la synchronisation soit
	# configurée — sans elle il n'y aurait rien à quoi se connecter.
	_db.set_sync_meta(LocalDatabase.ACCOUNT_KEY, "")
	var configured: bool = root.get_node("/root/Session").is_configured()
	if configured:
		_check("aucun compte vu : l'écran s'affiche", await _gate_appears())
	else:
		_check("sans synchronisation configurée : aucun écran", not await _gate_appears())

	_db.set_sync_meta(LocalDatabase.ACCOUNT_KEY, saved_account)

func _gate_appears() -> bool:
	var main: Control = load("res://ui/MainWindow.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var found := false
	for child in main.get_children():
		if child.get_script() != null and child.has_method("_on_survey_done"):
			found = true
	main.queue_free()
	await process_frame
	return found

## Le questionnaire écrit les quatre réglages, et marque la mise en route comme faite.
func _test_survey_writes_settings() -> void:
	print("--- Ce que le questionnaire écrit ---")
	_store.set_plan_shape(2, 5, 1)
	_store.set_household_servings(4)
	_store.set_onboarding_done(false)

	var gate: Control = load("res://ui/onboarding/OnboardingGate.gd").new()
	root.add_child(gate)
	await process_frame
	await process_frame

	# Réponses : courses le lundi, trois semaines, six personnes, deux repas.
	gate._week_start = 0
	gate._weeks = 3
	gate._servings = 6
	gate._meals = 2
	gate._on_survey_done()
	await process_frame

	_check("jour des courses écrit", _store.plan_week_start() == 0)
	_check("durée écrite", _store.plan_weeks() == 3)
	_check("convives écrits", _store.household_servings() == 6)
	_check("repas par jour écrits", _store.plan_meals_per_day() == 2)
	_check("le planning compte 42 cases", _store.plan_slot_count() == 42)
	# Marqué en DERNIER : si quelque chose échouait avant, la question serait reposée plutôt que
	# perdue.
	_check("la mise en route est marquée faite", _store.onboarding_done())

	_store.set_plan_shape(2, 5, 1)
	_store.set_household_servings(4)
	_store.set_onboarding_done(false)

## Les réponses partent des valeurs courantes : valider sans rien toucher ne doit pas
## reconfigurer le foyer au hasard.
func _test_defaults_are_current_values() -> void:
	print("--- Le questionnaire part de l'existant ---")
	_store.set_plan_shape(3, 2, 2)
	_store.set_household_servings(5)
	var gate: Control = load("res://ui/onboarding/OnboardingGate.gd").new()
	root.add_child(gate)
	_check("durée reprise", gate._weeks == 3)
	_check("jour repris", gate._week_start == 2)
	_check("repas repris", gate._meals == 2)
	_check("convives repris", gate._servings == 5)
	gate.queue_free()
	_store.set_plan_shape(2, 5, 1)
	_store.set_household_servings(4)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
