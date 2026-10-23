extends SceneTree
## Pastille de compte de l'en-tête (2.0.8) : ce qu'elle montre, et où mène son menu.
## godot --headless --path . --script res://tools/test_account_chip.gd
##
## L'état « connecté » est posé à la main, sans `Session._set_status` : le signal
## `status_changed` lancerait une vraie synchronisation (`Sync` l'écoute), donc des requêtes
## réseau avec un jeton inventé. La pastille est rafraîchie directement à la place.

const PHONE := Vector2i(412, 915)
const DESKTOP := Vector2i(1280, 800)

var _fails := 0
var _main: Control
var _session: Node

func _initialize() -> void:
	await process_frame
	_session = root.get_node("/root/Session")
	if _session.client != null and not _session.client.configured:
		_session.client.configured = true   # la pastille ne dit « connecté » que configurée

	root.size = DESKTOP
	_main = load("res://ui/MainWindow.tscn").instantiate()
	root.add_child(_main)
	await process_frame
	await process_frame

	await _test_signed_out()
	await _test_signed_in()
	await _test_phone()
	await _test_menu()
	_test_email_persisted()
	_test_settings_without_account()

	_set_state(0, "")
	print("")
	print("Pastille de compte conforme." if _fails == 0 else "%d problème(s)." % _fails)
	quit(1 if _fails > 0 else 0)

func _test_signed_out() -> void:
	print("--- Déconnecté, sur ordinateur ---")
	_set_state(0, "")
	await process_frame
	_check("« Déconnecté » écrit à côté de la pastille", _main._account_state.text == "Déconnecté"
		and _main._account_state.is_visible_in_tree())
	_check("pas d'adresse", not _main._account_email.visible)

func _test_signed_in() -> void:
	print("--- Connecté, sur ordinateur ---")
	_set_state(1, "camille@exemple.fr")
	await process_frame
	_check("« Connecté »", _main._account_state.text == "Connecté")
	_check("l'adresse en dessous", _main._account_email.visible
		and _main._account_email.text == "camille@exemple.fr")
	_check("plus petite que l'état", _main._account_email.get_theme_font_size("font_size")
		< _main._account_state.get_theme_font_size("font_size"))
	# Le bouton s'étend à son contenu : sans quoi le libellé déborderait du survol.
	_check("la pastille englobe son texte", _main._account_btn.get_combined_minimum_size().x
		>= _main._account_box.get_combined_minimum_size().x)
	# Hors ligne, le compte est toujours rattaché : seul le serveur manque.
	_set_state(2, "camille@exemple.fr")
	await process_frame
	_check("hors ligne : toujours « Connecté »", _main._account_state.text == "Connecté")

func _test_phone() -> void:
	print("--- Sur téléphone : la pastille seule ---")
	root.size = PHONE
	await process_frame
	await process_frame
	_check("(préparation) format téléphone", root.get_node("/root/Layout").is_phone())
	_check("ni état ni adresse écrits", not _main._account_state.is_visible_in_tree()
		and not _main._account_email.is_visible_in_tree())
	_check("la pastille reste", _main._account_btn.is_visible_in_tree())
	_check("…et dit l'état dans son infobulle",
		_main._account_btn.tooltip_text.contains("camille@exemple.fr"))
	root.size = DESKTOP
	await process_frame
	await process_frame

func _test_menu() -> void:
	print("--- Le menu ---")
	_set_state(0, "")
	_main._open_account_menu()
	await process_frame
	_check("ouvert", is_instance_valid(_main._account_menu))
	var labels := _menu_labels()
	_check("deux lignes", labels.size() == 2)
	_check("déconnecté : « Se connecter » puis « Paramètres »",
		labels == ["Se connecter", "Paramètres"])
	# Marges serrées (2.0.9) : le menu ne dépasse pas ses deux lignes de plus que quelques
	# unités — le style de carte qu'il portait en ajoutait dix-huit de chaque côté.
	var panel_style: StyleBox = _main._account_menu.get_theme_stylebox("panel")
	_check("marges intérieures serrées", panel_style.get_margin(SIDE_LEFT) <= 6
		and panel_style.get_margin(SIDE_TOP) <= 6)
	# Il se déroule DEPUIS la pastille : bord droit aligné, juste en dessous.
	var chip: Rect2 = _main._account_btn.get_global_rect()
	var menu_rect: Rect2 = _main._account_menu.get_global_rect()
	_check("sous la pastille, aligné à droite", absf(menu_rect.end.x - chip.end.x) < 1.0
		and menu_rect.position.y >= chip.end.y)

	# Un toucher ailleurs le referme.
	_main._account_menu_catcher.gui_input.emit(_press())
	await process_frame
	_check("refermé par un toucher ailleurs", not is_instance_valid(_main._account_menu))

	_set_state(1, "camille@exemple.fr")
	_main._open_account_menu()
	await process_frame
	_check("connecté : « Compte »", _menu_labels()[0] == "Compte")
	# Bouton Retour d'Android : le menu se replie d'abord, rien d'autre ne bouge.
	_main._go_back()
	await process_frame
	_check("refermé par Retour", not is_instance_valid(_main._account_menu))

	_main._open_account_menu()
	await process_frame
	_menu_button(0).pressed.emit()
	await process_frame
	_check("choisir une ligne referme le menu", not is_instance_valid(_main._account_menu))
	var account := _find_window("AccountWindow")
	_check("« Compte » ouvre la fenêtre du compte", account != null)
	if account != null:
		_check("…qui porte le formulaire de connexion", account.account != null
			and account.account.get_script().resource_path.ends_with("AccountTab.gd"))
		account.queue_free()
	# Une image : la fenêtre du compte est exclusive, et le reste tant qu'elle n'est pas
	# réellement libérée — en ouvrir une autre aussitôt serait refusé.
	await process_frame
	_main._open_account_menu()
	await process_frame
	_menu_button(1).pressed.emit()
	await process_frame
	var settings := _find_window("SettingsWindow")
	_check("« Paramètres » ouvre les Paramètres", settings != null)
	if settings != null:
		# Toute fenêtre ouverte reçoit son entrée en douceur, sans que l'écran l'ait demandé
		# (2.0.9) : c'est `MainWindow` qui la branche, une fois pour toutes.
		await process_frame
		_check("…en douceur (entrée animée par MainWindow)", settings.has_meta("_window_in_frame"))
		settings.queue_free()
	await process_frame

	print("--- Changement d'onglet en fondu ---")
	var tabs: TabContainer = _main._main_tabs
	tabs.current_tab = 1
	_check("le nouvel onglet part effacé", tabs.get_current_tab_control().modulate.a < 0.5)
	await create_timer(0.3).timeout
	_check("…et apparaît", is_equal_approx(tabs.get_current_tab_control().modulate.a, 1.0))
	tabs.current_tab = 0
	await create_timer(0.3).timeout

func _menu_button(index: int) -> Button:
	return _main._account_menu.get_child(0).get_child(index)

func _menu_labels() -> Array:
	var out := []
	for button in _main._account_menu.get_child(0).get_children():
		out.append(button.text)
	return out

func _press() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	return event

## L'adresse est enregistrée avec la session : elle doit s'afficher dès le lancement
## suivant, avant que le serveur ait répondu — et hors ligne, où il ne répondra pas.
func _test_email_persisted() -> void:
	print("--- L'adresse survit au redémarrage ---")
	_session._refresh_token = "jeton-de-test"
	_session.user_id = "00000000-0000-4000-8000-0000000000aa"
	_session._set_email("camille@exemple.fr")
	_session._store_session()
	_session._set_email("")
	_session._load_stored_session()
	_check("relue depuis la session enregistrée", _session.email == "camille@exemple.fr")
	_session._refresh_token = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_session.session_path()))

func _test_settings_without_account() -> void:
	print("--- Les Paramètres n'ont plus de section Compte ---")
	var names := []
	for section in load("res://ui/settings/SettingsWindow.gd").SECTIONS:
		names.append(section["name"])
	_check("pas de « Compte »", not names.has("Compte"))

## 0 = déconnecté, 1 = connecté, 2 = hors ligne (`Session.Status`).
func _set_state(status: int, email: String) -> void:
	_session.status = status
	_session.email = email
	_main._refresh_account_chip()

func _find_window(script_name: String) -> Window:
	for node in root.find_children("*", "Window", true, false):
		var script: Script = node.get_script()
		if script != null and script.resource_path.get_file() == script_name + ".gd" \
				and not node.is_queued_for_deletion():
			return node
	return null

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [ok] %s" % label)
	else:
		print("  [ÉCHEC] %s" % label)
		_fails += 1
