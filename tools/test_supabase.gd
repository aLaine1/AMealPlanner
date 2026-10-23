extends SceneTree
## Test de connectivité Supabase (nécessite le réseau et supabase_config.json).
## godot --headless --path . --script res://tools/test_supabase.gd
##
## Ne teste PAS la connexion au compte : cela demanderait le mot de passe du foyer,
## qui n'a pas à vivre dans le dépôt. La connexion réelle se vérifie depuis l'écran
## de connexion de l'app.

var _fails := 0

func _initialize() -> void:
	var client = load("res://services/SupabaseClient.gd").new()
	root.add_child(client)
	await process_frame

	_check("configuration chargée", client.configured)
	if not client.configured:
		_done()
		return
	print("  URL : %s" % client.url)

	print("--- Joignabilité ---")
	var now_res = await client.server_now_ms("")
	if not now_res.ok and now_res.offline:
		print("  [IGNORÉ] serveur injoignable — test réseau sauté (%s)" % now_res.error)
		_done()
		return
	_check("rpc server_now_ms répond", now_res.ok)
	var server_ms := int(now_res.data)
	var local_ms := int(Time.get_unix_time_from_system() * 1000.0)
	_check("l'horloge serveur est plausible (ms)", server_ms > 1700000000000)
	print("  dérive locale vs serveur : %.2f s" % ((local_ms - server_ms) / 1000.0))

	print("--- Cloisonnement RLS (sans session) ---")
	# Sans jeton, on s'annonce avec la clé publique : les policies étant réservées au
	# rôle `authenticated`, aucune ligne ne doit remonter et aucune écriture ne doit
	# passer. C'est ce qui rend acceptable l'embarquement de la clé dans l'APK.
	var read = await client.select_changed_since("recipes", 0, "")
	_check("lecture anonyme : aucune ligne", read.ok and (read.data as Array).is_empty())

	var write = await client.upsert("recipes", [{
		"id": "00000000-0000-4000-8000-0000000000ff",
		"name": "ne doit jamais être écrit", "updated_at": 1,
	}], "")
	_check("écriture anonyme refusée", not write.ok and not write.offline)
	print("  refus renvoyé : HTTP %d — %s" % [write.code, write.error])

	print("--- Toutes les tables existent ---")
	for table in ["recipes", "ingredients", "categories", "breakfasts", "staples",
			"meal_plan_positions", "breakfast_slots", "shopping_items"]:
		var res = await client.select_changed_since(table, 0, "")
		_check("table %s interrogeable" % table, res.ok)

	print("--- Message d'erreur de connexion ---")
	var bad = await client.sign_in("inexistant@example.invalid", "mauvais-mot-de-passe")
	_check("identifiants invalides rejetés", not bad.ok and not bad.offline)

	_done()

func _done() -> void:
	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
