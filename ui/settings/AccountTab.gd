class_name AccountTab
extends MarginContainer
## Contenu de la fenêtre « Compte » (`AccountWindow`, ouverte depuis la pastille de
## l'en-tête) : connexion au compte du foyer, état et déclenchement manuel de la
## synchronisation. Première section des Paramètres jusqu'à la 2.0.8.
##
## Il n'y a **pas d'inscription** : le compte du foyer est unique et créé une fois
## pour toutes depuis le tableau de bord Supabase (les inscriptions y sont d'ailleurs
## désactivées). Cet écran ne sert qu'à rattacher un appareil de plus.
##
## Se déconnecter ne supprime aucune donnée locale : la base SQLite reste la source
## de vérité et l'app continue de fonctionner normalement, simplement sans partage.

const ArrowNavigationScript := preload("res://ui/components/ArrowNavigation.gd")

var _status_label: Label
var _detail_label: Label
var _message: Label
var _email: LineEdit
var _password: LineEdit
var _sign_in_btn: Button
var _sync_btn: Button
var _sign_out_btn: Button
var _form: VBoxContainer

func _ready() -> void:
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		add_theme_constant_override(m, 20)
	_build()
	Session.status_changed.connect(func(_s): _refresh())
	Sync.state_changed.connect(func(_s): _refresh())
	_refresh()

func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 16)
	add_child(root)

	# ===== État courant =====
	var card := PanelContainer.new()
	root.add_child(card)
	var card_box := VBoxContainer.new()
	card_box.add_theme_constant_override("separation", 6)
	card.add_child(card_box)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 18)
	card_box.add_child(_status_label)

	_detail_label = Label.new()
	_detail_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	card_box.add_child(_detail_label)

	# ===== Formulaire de connexion =====
	_form = VBoxContainer.new()
	_form.add_theme_constant_override("separation", 10)
	root.add_child(_form)
	# ↑ / ↓ entre l'adresse, le mot de passe et le bouton (2.0.13).
	_form.add_child(ArrowNavigationScript.new())


	_email = LineEdit.new()
	_email.placeholder_text = "Adresse email"
	_form.add_child(_email)

	_password = LineEdit.new()
	_password.placeholder_text = "Mot de passe"
	_password.secret = true
	_password.text_submitted.connect(func(_t): _on_sign_in())
	_form.add_child(_password)

	_sign_in_btn = Button.new()
	_sign_in_btn.text = "Se connecter"
	_sign_in_btn.pressed.connect(_on_sign_in)
	_form.add_child(_sign_in_btn)

	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.visible = false
	root.add_child(_message)

	# ===== Actions une fois connecté =====
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 10)
	root.add_child(actions)

	_sync_btn = Button.new()
	_sync_btn.text = "Synchroniser maintenant"
	_sync_btn.pressed.connect(_on_sync_now)
	actions.add_child(_sync_btn)

	_sign_out_btn = Button.new()
	_sign_out_btn.text = "Se déconnecter"
	_sign_out_btn.theme_type_variation = "GhostButton"
	_sign_out_btn.pressed.connect(_on_sign_out)
	actions.add_child(_sign_out_btn)


# =====================================================================

func _refresh() -> void:
	if not Session.is_configured():
		_status_label.text = "Synchronisation non configurée"
		_status_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
		_detail_label.text = "Le fichier supabase_config.json est absent ou incomplet. " \
			+ "L'application fonctionne normalement, en local uniquement."
		_form.visible = false
		_sync_btn.disabled = true
		_sign_out_btn.visible = false
		return

	var signed_in := Session.status == Session.Status.SIGNED_IN \
		or Session.status == Session.Status.OFFLINE
	_form.visible = not signed_in
	_sync_btn.disabled = not signed_in or Sync.state == Sync.State.RUNNING
	_sign_out_btn.visible = signed_in

	match Session.status:
		Session.Status.SIGNED_IN:
			_status_label.text = "Appareil connecté"
			_status_label.add_theme_color_override("font_color", Palette.SUCCESS)
			_detail_label.text = _sync_detail()
		Session.Status.OFFLINE:
			_status_label.text = "Connecté — serveur injoignable"
			_status_label.add_theme_color_override("font_color", Palette.WARNING)
			_detail_label.text = "Les modifications sont enregistrées localement et " \
				+ "seront synchronisées au retour du réseau."
		_:
			_status_label.text = "Appareil non connecté"
			_status_label.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
			_detail_label.text = "Les données de cet appareil ne sont pas partagées."

func _sync_detail() -> String:
	if Sync.state == Sync.State.RUNNING:
		return "Synchronisation en cours…"
	if Sync.state == Sync.State.ERROR and Sync.last_error != "":
		return "Dernière synchronisation en échec : %s" % Sync.last_error
	if Sync.last_sync_ms == 0:
		return "Aucune synchronisation effectuée depuis le lancement."
	# Heure locale : `get_datetime_dict_from_unix_time` rend l'heure UTC, d'où un décalage
	# d'une ou deux heures selon la saison.
	var local_s: int = Sync.last_sync_ms / 1000 + Time.get_time_zone_from_system().bias * 60
	var stamp := Time.get_datetime_dict_from_unix_time(local_s)
	return "Dernière synchronisation à %02d:%02d." % [stamp.hour, stamp.minute]

func _show_message(text: String, is_error: bool) -> void:
	_message.text = text
	_message.add_theme_color_override("font_color",
		Palette.ERROR if is_error else Palette.SUCCESS)
	_message.visible = text != ""

func _on_sign_in() -> void:
	if _email.text.strip_edges() == "" or _password.text == "":
		_show_message("Renseigne l'adresse email et le mot de passe.", true)
		return
	_sign_in_btn.disabled = true
	_show_message("Connexion…", false)

	var error: String = await Session.sign_in(_email.text, _password.text)
	_sign_in_btn.disabled = false
	# Le mot de passe ne reste pas en mémoire une fois la tentative faite.
	_password.text = ""

	if error != "":
		_show_message(error, true)
		_refresh()
		return
	_show_message("", false)
	_refresh()
	await _run_sync()

func _on_sign_out() -> void:
	await Session.sign_out()
	_show_message("Appareil déconnecté. Les données locales sont conservées.", false)
	_refresh()

func _on_sync_now() -> void:
	await _run_sync()

func _run_sync() -> void:
	_refresh()
	var res: Dictionary = await Sync.sync()
	if res.get("needs_seed_decision", false):
		_show_message("Ce compte est vide : indique si tu veux garder les recettes d'exemple.", false)
		_refresh()
		return
	if res.ok:
		_show_message("Synchronisé : %d élément(s) reçu(s), %d envoyé(s)."
			% [res.pulled, res.pushed], false)
	elif res.offline:
		_show_message("Serveur injoignable. Les modifications partiront au prochain essai.", false)
	else:
		_show_message("Échec : %s" % res.error, true)
	_refresh()
