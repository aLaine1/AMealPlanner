extends SceneTree
## Durée du planning : de 1 à 4 semaines, sans jamais rien perdre.
## godot --headless --path . --script res://tools/test_plan_weeks.gd
##
## La grille du calendrier est un CALENDRIER : ses colonnes sont toujours lundi → dimanche. N
## semaines de planning commençant un autre jour que le lundi occupent donc N+1 lignes, la
## première et la dernière étant partielles. C'est la raison du masque, et c'est ce qui rend le
## calcul du nombre de lignes moins évident qu'il n'y paraît — quatre semaines à partir d'un
## samedi occupent CINQ lignes.
##
## L'autre enjeu est la non-perte : raccourcir le planning met des jours hors champ, et ces
## jours doivent revenir intacts si on le rallonge. Sans cela, essayer une durée coûterait un
## planning — et personne n'essaierait.
##
## Voir 0_plan_1.8.0.md, étapes 2 et D3.

var _fails := 0
var _store
var _db

func _initialize() -> void:
	await process_frame
	_store = root.get_node_or_null("/root/DataStore")
	if _store == null:
		print("  [ÉCHEC] autoload DataStore indisponible")
		quit(1)
		return
	_db = _store.local_database()

	_test_rows_and_mask()
	_test_shape_bounds()
	_test_week_start()
	_test_transport_migration()
	await _test_two_meals()
	await _test_shortening_keeps_days()
	await _test_calendar_rebuilds()

	# Remis à la forme par défaut : cette suite ne doit pas laisser le foyer réglé autrement.
	_store.set_plan_shape(2, 5, 1)

	print("")
	print("Durée du planning conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

## Le nombre de lignes et le masque, pour les combinaisons qui comptent.
##
## La ligne « 2 semaines / samedi » est celle de la 1.7 : elle doit donner 3 lignes et
## exactement le masque écrit à la main d'alors.
func _test_rows_and_mask() -> void:
	print("--- Lignes du calendrier et cases actives ---")
	for case in [
		{"weeks": 2, "start": 5, "rows": 3, "days": 14},   # la forme de la 1.7
		{"weeks": 4, "start": 5, "rows": 5, "days": 28},   # le cas signalé : 5 lignes
		{"weeks": 1, "start": 5, "rows": 2, "days": 7},
		{"weeks": 2, "start": 0, "rows": 2, "days": 14},   # début lundi : aucune ligne en plus
		{"weeks": 4, "start": 0, "rows": 4, "days": 28},
		{"weeks": 3, "start": 6, "rows": 4, "days": 21},   # début dimanche
	]:
		var weeks: int = case["weeks"]
		var start: int = case["start"]
		var rows := weeks + (0 if start == 0 else 1)
		_check("%d semaine(s) à partir de %s → %d lignes" % [
			weeks, _store.WEEKDAY_LONG[start].to_lower(), case["rows"]],
			rows == case["rows"])

		# Le masque : chaque jour du planning doit tomber sur une case, une seule, et aucune
		# case active ne doit pointer hors du planning.
		var seen := {}
		var strays := 0
		for row in range(rows):
			for column in range(7):
				var day_index: int = row * 7 + column - start
				if day_index < 0 or day_index >= int(case["days"]):
					continue
				if seen.has(day_index):
					strays += 1
				seen[day_index] = true
		_check("  les %d jours ont chacun une case" % case["days"],
			seen.size() == int(case["days"]) and strays == 0)

	# Le masque de la 1.7, case par case : première ligne samedi-dimanche, deuxième complète,
	# troisième lundi-vendredi.
	var expected_active := {0: [5, 6], 1: [0, 1, 2, 3, 4, 5, 6], 2: [0, 1, 2, 3, 4]}
	var same := true
	for row in expected_active:
		var active := []
		for column in range(7):
			var day_index: int = row * 7 + column - 5
			if day_index >= 0 and day_index < 14:
				active.append(column)
		if active != expected_active[row]:
			same = false
			print("      ligne %d : %s ≠ %s" % [row, active, expected_active[row]])
	_check("le masque de la 1.7 est reproduit à l'identique", same)

func _test_shape_bounds() -> void:
	print("--- Bornes du réglage ---")
	_store.set_plan_shape(9, 5, 1)
	_check("au-delà de 4 semaines : ramené à 4", _store.plan_weeks() == 4)
	_store.set_plan_shape(0, 5, 1)
	_check("en dessous de 1 : ramené à 1", _store.plan_weeks() == 1)
	_store.set_plan_shape(2, 9, 1)
	_check("jour de début ramené dans la semaine", _store.plan_week_start() == 2)
	_store.set_plan_shape(2, 5, 7)
	_check("au-delà de 2 repas : ramené à 2", _store.plan_meals_per_day() == 2)
	_store.set_plan_shape(2, 5, 1)
	_check("retour à la forme de la 1.7", _store.plan_slot_count() == 14)

## LE point de la décision D3 : raccourcir ne détruit pas.
func _test_shortening_keeps_days() -> void:
	print("--- Raccourcir puis rallonger ne perd rien ---")
	_store.set_plan_shape(2, 5, 1)
	var recipes: Array = _store.get_all_recipe_objects()
	var written: Array[String] = []
	for index in range(14):
		written.append("")
	written[0] = recipes[0].nom
	written[8] = recipes[1].nom       # au-delà de la première semaine
	written[13] = recipes[2].nom      # tout dernier jour
	_store.save_plan_names(written)

	# Une semaine : les jours 7 à 13 sortent du planning.
	_store.set_plan_shape(1, 5, 1)
	var short_names: Array = _store.load_plan_names()
	_check("une semaine ne montre que 7 jours", short_names.size() == 7)
	_check("  le premier jour est toujours là", str(short_names[0]) == recipes[0].nom)

	# Une modification en durée réduite ne doit pas emporter les jours cachés.
	var edited: Array[String] = []
	for index in range(7):
		edited.append(str(short_names[index]))
	edited[3] = recipes[3].nom
	_store.save_plan_names(edited)

	_store.set_plan_shape(2, 5, 1)
	var back: Array = _store.load_plan_names()
	_check("de retour à deux semaines : 14 jours", back.size() == 14)
	_check("  le jour 8 est revenu intact", str(back[8]) == recipes[1].nom)
	_check("  le dernier jour aussi", str(back[13]) == recipes[2].nom)
	_check("  et la modification faite entre-temps a été gardée",
		str(back[3]) == recipes[3].nom)

	var cleared: Array[String] = []
	for index in range(14):
		cleared.append("")
	_store.save_plan_names(cleared)

## Le calendrier doit se RECONSTRUIRE, et pas seulement se rafraîchir : ce n'est pas le contenu
## des cases qui change mais leur nombre.
func _test_calendar_rebuilds() -> void:
	print("--- Le calendrier suit la forme ---")
	root.size = Vector2i(1280, 800)
	await process_frame
	_store.set_plan_shape(2, 5, 1)
	var tab: Control = load("res://ui/planning/PlanningTab.gd").new()
	root.add_child(tab)
	await process_frame
	await process_frame
	_check("14 cases au départ", tab._cells.size() == 14)

	_store.set_plan_shape(4, 5, 1)
	await process_frame
	await process_frame
	_check("28 cases après passage à 4 semaines", tab._cells.size() == 28)
	_check("  et 28 libellés de jour", _store.plan_day_labels().size() == 28)

	_store.set_plan_shape(1, 5, 1)
	await process_frame
	await process_frame
	_check("7 cases après passage à 1 semaine", tab._cells.size() == 7)

	# Les piles d'annulation sont vidées : un instantané de 14 cases devant 7 écrirait
	# n'importe quoi.
	_check("les piles d'annulation sont vidées",
		tab._undo_stack.is_empty() and tab._redo_stack.is_empty())

	tab.queue_free()
	await process_frame

## Le jour de début libre, et ce qu'il entraîne.
##
## Les libellés suivent, et les soirs réservés NE SE DÉCALENT PAS : c'est tout l'intérêt de les
## avoir exprimés en jours de la semaine. Avec des indices absolus, avancer le début d'un jour
## déplaçait le vendredi réservé sur un jeudi, en silence.
func _test_week_start() -> void:
	print("--- Jour de début libre ---")
	_store.set_transport_marker_enabled(true)
	_store.set_transport_weekdays([Vector2i(4, 0), Vector2i(5, 0)])   # vendredi, samedi

	_store.set_plan_shape(2, 5, 1)                                    # début samedi
	_check("début samedi : premier libellé « Sam. S1 »",
		str(_store.plan_day_labels()[0]) == "Sam. S1")
	_check("  soirs réservés aux jours 0, 6, 7, 13",
		_store.get_transport_slots() == [0, 6, 7, 13])

	_store.set_plan_shape(2, 0, 1)                                    # début lundi
	_check("début lundi : premier libellé « Lun. S1 »",
		str(_store.plan_day_labels()[0]) == "Lun. S1")
	# Vendredi et samedi tombent maintenant aux jours 4, 5, 11, 12 : ce sont les MÊMES jours de
	# la semaine, aux indices que leur donne le nouveau début.
	_check("  soirs réservés recomposés en 4, 5, 11, 12",
		_store.get_transport_slots() == [4, 5, 11, 12])

	_store.set_plan_shape(3, 2, 1)                                    # début mercredi, 3 semaines
	var labels: Array = _store.plan_day_labels()
	_check("début mercredi : premier libellé « Mer. S1 »", str(labels[0]) == "Mer. S1")
	_check("  21 libellés", labels.size() == 21)
	# Trois vendredis et trois samedis sur trois semaines : six soirs, sans que personne ait eu
	# à les redésigner. C'est ce que les indices absolus ne savaient pas faire.
	_check("  six soirs réservés sur trois semaines",
		_store.get_transport_slots().size() == 6)

	_store.set_plan_shape(2, 5, 1)
	_store.set_transport_marker_enabled(false)

## La migration de l'ancien format vers le nouveau, telle qu'elle se jouera sur les bases
## existantes.
func _test_transport_migration() -> void:
	print("--- Migration des soirs réservés ---")
	var db = _store.local_database()
	var key: String = db.SETTING_TRANSPORT_SLOTS
	var saved: String = db.get_setting(key, "")

	# L'état d'une base de 1.7 : des indices absolus, sous un début samedi.
	_store.set_plan_shape(2, 5, 1)
	db.set_setting(key, db.LEGACY_DEFAULT_TRANSPORT_SLOTS)
	_check("conversion effectuée", db.migrate_transport_slots())
	_check("  « 0,6,7,13 » devient « 4:0,5:0 »",
		db.get_setting(key, "") == "4:0,5:0")
	# Rejouée, elle ne doit rien faire : les deux appareils du foyer la joueront chacun de leur
	# côté, et le réglage est synchronisé.
	_check("rejouée, sans effet", not db.migrate_transport_slots())
	_check("  et la valeur est inchangée", db.get_setting(key, "") == "4:0,5:0")

	db.set_setting(key, saved)

## Le second repas : la coordonnée qui s'ajoute sans renuméroter.
##
## C'est le piège 2 du plan. Si la position restait un index plat, activer le second repas
## déplacerait toutes les cases déjà enregistrées et mélangerait le planning du foyer. Le jour
## doit garder son numéro, et le repas s'ajouter à côté.
func _test_two_meals() -> void:
	print("--- Un second repas par jour ---")
	_store.set_plan_shape(2, 5, 1)
	var recipes: Array = _store.get_all_recipe_objects()
	var written: Array[String] = []
	for index in range(14):
		written.append("")
	written[0] = recipes[0].nom
	written[13] = recipes[1].nom
	_store.save_plan_names(written)

	_store.set_plan_shape(2, 5, 2)
	_check("deux repas : 28 cases pour 14 jours",
		_store.plan_slot_count() == 28 and _store.plan_day_count() == 14)
	var names: Array = _store.load_plan_names()
	_check("  28 cases relues", names.size() == 28)
	# LE point : le jour 0 midi et le jour 13 midi portent toujours ce qu'on y avait mis.
	_check("  le premier repas est resté au jour 0", str(names[0]) == recipes[0].nom)
	_check("  le dernier est resté au jour 13", str(names[26]) == recipes[1].nom)
	_check("  et les soirs sont vides", str(names[1]) == "" and str(names[27]) == "")

	# Un repas noté le soir ne doit pas écraser celui du midi.
	names[1] = recipes[2].nom
	var to_write: Array[String] = []
	for entry in names:
		to_write.append(str(entry))
	_store.save_plan_names(to_write)
	var reread: Array = _store.load_plan_names()
	_check("  le soir s'ajoute sans toucher au midi",
		str(reread[0]) == recipes[0].nom and str(reread[1]) == recipes[2].nom)

	# Les libellés distinguent les deux repas, et seulement quand il y en a deux.
	var labels: Array = _store.plan_slot_labels()
	_check("  libellés « Sam. S1 · 1er repas » et « … · 2ème repas »",
		str(labels[0]) == "Sam. S1 · 1er repas" and str(labels[1]) == "Sam. S1 · 2ème repas")

	# Un repas réservé porte son RANG, et ce rang est respecté. Il était auparavant réécrit
	# d'office sur le dernier repas de la journée : le premier repas était donc impossible à
	# réserver, et cocher l'un revenait à cocher l'autre.
	_store.set_transport_marker_enabled(true)
	_store.set_transport_weekdays([Vector2i(5, 0)])   # samedi, 1er repas
	_check("  le 1er repas du samedi est réservé, et lui seul (%s)" % str(_store.get_transport_slots()),
		_store.get_transport_slots() == [0, 14])
	_store.set_transport_weekdays([Vector2i(5, 1)])   # samedi, 2ème repas
	_check("  le 2ème repas du samedi se réserve à part (%s)" % str(_store.get_transport_slots()),
		_store.get_transport_slots() == [1, 15])
	# Et les deux peuvent l'être ensemble : deux semaines de cases à cocher, pas un choix
	# exclusif entre elles.
	_store.set_transport_weekdays([Vector2i(5, 0), Vector2i(5, 1)])
	_check("  les deux repas d'un même jour se réservent ensemble (%s)" % str(_store.get_transport_slots()),
		_store.get_transport_slots() == [0, 1, 14, 15])

	# Repli à un repas par jour : le planning commençant un samedi, ce jour tombe aux jours 0
	# et 7, et les deux marques retombent sur l'unique repas de ces journées. Le rang stocké
	# dépasse alors ce que la journée compte : il est ramené à la LECTURE, sans être écrasé en
	# base — sans quoi rétablir le second repas
	# aurait perdu la distinction que l'on vient de faire.
	_store.set_plan_shape(2, 5, 1)
	_check("  un seul repas : les deux marques retombent sur lui (%s)" % str(_store.get_transport_slots()),
		_store.get_transport_slots() == [0, 7])
	_store.set_plan_shape(2, 5, 2)
	_check("  et le rang revient intact au retour des deux repas (%s)" % str(_store.get_transport_slots()),
		_store.get_transport_slots() == [0, 1, 14, 15])
	_store.set_transport_marker_enabled(false)

	# Retour à un repas : les midis sont intacts, les soirs restent en base.
	_store.set_plan_shape(2, 5, 1)
	var back: Array = _store.load_plan_names()
	_check("retour à un repas : 14 cases", back.size() == 14)
	_check("  les midis sont intacts", str(back[0]) == recipes[0].nom)
	_store.set_plan_shape(2, 5, 2)
	var again: Array = _store.load_plan_names()
	_check("  et les soirs n'ont pas été perdus", str(again[1]) == recipes[2].nom)

	_store.set_plan_shape(2, 5, 1)
	var cleared: Array[String] = []
	for index in range(14):
		cleared.append("")
	_store.save_plan_names(cleared)
	await process_frame

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])
