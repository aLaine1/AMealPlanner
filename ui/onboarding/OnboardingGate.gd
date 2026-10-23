class_name OnboardingGate
extends Control
## Première mise en route : connexion, puis questionnaire.
##
## L'application fonctionne hors ligne par conception, et exiger le réseau à chaque lancement
## lui retirerait cette qualité. L'écran de connexion ne s'affiche donc qu'à la PREMIÈRE mise en
## route — ensuite la session enregistrée suffit et le démarrage redevient silencieux. C'est la
## décision D1 du plan 1.8.
##
## L'ordre compte et n'est pas négociable : connexion, PUIS synchronisation, PUIS questionnaire.
## Sans la synchronisation au milieu, un foyer qui installe l'application sur un second appareil
## se verrait reposer des questions auxquelles il a déjà répondu — les réponses vivent dans les
## réglages, qui arrivent par le réseau.

signal finished

const MEALS_LABELS := ["Un repas par jour", "Deux repas"]

var _pages: VBoxContainer
var _login_page: Control
var _survey_page: Control
var _email: LineEdit
var _password: LineEdit
var _error: Label
var _sign_in_btn: Button
var _busy: Label

## Réponses en cours. Les défauts sont ceux du foyer courant : quelqu'un qui valide sans rien
## toucher obtient le comportement d'avant, pas une configuration vide.
var _weeks := 2
var _week_start := 5
var _meals := 1
var _servings := 4
var _weeks_buttons := {}
var _start_buttons := {}
var _meals_buttons := {}
var _servings_spin: SpinBox

func _ready() -> void:
	# Ancres ET marges : `set_anchors_preset` seul recalcule les marges pour garder le
	# rectangle courant — nul si la fenêtre n'a pas encore sa taille, comme au démarrage
	# dans un navigateur. L'écran restait alors réduit à un point, l'application à nu dessous.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Le thème est posé explicitement, comme sur les fenêtres secondaires : cet écran se place
	# par-dessus tout, et rien ne garantit qu'il héritera de celui de son parent.
	theme = Palette.ui_theme
	# Opaque et par-dessus tout : tant que la mise en route n'est pas finie, rien d'autre ne
	# doit être atteignable — ni au doigt, ni au clavier.
	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_weeks = DataStore.plan_weeks()
	_week_start = DataStore.plan_week_start()
	_meals = DataStore.plan_meals_per_day()
	_servings = DataStore.household_servings()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, Layout.margin() + 6)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_pages = VBoxContainer.new()
	_pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages.add_theme_constant_override("separation", 14)
	Layout.scroll_body(scroll).add_child(_pages)

	_login_page = _build_login()
	_pages.add_child(_login_page)
	_survey_page = _build_survey()
	_survey_page.visible = false
	_pages.add_child(_survey_page)

# =====================================================================
# Connexion
# =====================================================================

func _build_login() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "Bienvenue"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	box.add_child(title)

	_email = LineEdit.new()
	_email.placeholder_text = "Adresse e-mail"
	_email.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	box.add_child(_email)

	_password = LineEdit.new()
	_password.placeholder_text = "Mot de passe"
	_password.secret = true
	_password.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_password.text_submitted.connect(func(_t): _on_sign_in())
	box.add_child(_password)

	_error = Label.new()
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", Palette.ERROR)
	_error.visible = false
	box.add_child(_error)

	_busy = Label.new()
	_busy.add_theme_color_override("font_color", Palette.TEXT_SECONDARY)
	_busy.visible = false
	box.add_child(_busy)

	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	box.add_child(actions)

	_sign_in_btn = Button.new()
	_sign_in_btn.text = "Se connecter"
	_sign_in_btn.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	_sign_in_btn.pressed.connect(_on_sign_in)
	actions.add_child(_sign_in_btn)

	# Désactivé et non masqué : sa présence dit que la création de compte viendra, son état
	# grisé dit qu'elle n'est pas là. Masqué, il ne dirait rien du tout.
	var signup := Button.new()
	signup.text = "Inscription"
	signup.theme_type_variation = "OutlineButton"
	signup.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	signup.disabled = true
	signup.tooltip_text = "La création de compte depuis l'application viendra plus tard."
	actions.add_child(signup)
	return box

func _on_sign_in() -> void:
	var email := _email.text.strip_edges()
	if email == "" or _password.text == "":
		_show_error("Renseignez votre adresse et votre mot de passe.")
		return
	if not Session.is_configured():
		_show_error("La synchronisation n'est pas configurée sur cet appareil.")
		return

	_set_busy(true, "Connexion…")
	var failure: String = await Session.sign_in(email, _password.text)
	if failure != "":
		_set_busy(false, "")
		# Le message du serveur tel quel : « adresse ou mot de passe incorrect » et « serveur
		# injoignable » demandent deux gestes différents, les confondre ferait ressaisir un mot
		# de passe correct pendant une panne de réseau.
		_show_error(failure)
		return

	# La synchronisation AVANT le questionnaire : les réponses d'un foyer déjà installé sont
	# dans ses réglages, et les reposer sur un second appareil serait une faute.
	_set_busy(true, "Récupération de vos données…")
	# Un cycle de fond peut déjà tourner : son « déjà en cours » n'est pas un échec, on attend
	# qu'il finisse puis on lance le nôtre.
	while Sync.state == Sync.State.RUNNING:
		await Sync.state_changed
	var synced: Dictionary = await Sync.sync()
	_set_busy(false, "")

	# Version web : sans les données du compte, rien à montrer — la base en mémoire ne contient
	# que le jeu d'exemple. Et le questionnaire serait pire qu'inutile : ses réponses, plus
	# récentes que celles du foyer, les écraseraient au premier passage réussi. On reste donc
	# ici ; un nouvel essai refait connexion et synchronisation.
	if LocalDatabase.ephemeral() and not synced.ok:
		_show_error("Impossible de récupérer vos données : %s" % synced.get("error", ""))
		return

	if DataStore.onboarding_done():
		_finish()
		return
	_error.visible = false
	_login_page.visible = false
	_survey_page.visible = true
	_refresh_survey()

func _show_error(message: String) -> void:
	_error.text = message
	_error.visible = true

func _set_busy(busy: bool, message: String) -> void:
	_busy.text = message
	_busy.visible = busy
	_sign_in_btn.disabled = busy
	_email.editable = not busy
	_password.editable = not busy

# =====================================================================
# Questionnaire
# =====================================================================

## Quatre questions, sur un seul écran plutôt qu'en étapes successives : elles sont courtes, et
## les voir ensemble permet de comprendre ce qu'on règle. Chacune part de la valeur courante,
## si bien que valider sans rien toucher donne le comportement par défaut.
func _build_survey() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)

	var title := Label.new()
	title.text = "Quelques questions"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	box.add_child(title)

	box.add_child(_question("Quel jour faites-vous vos courses ?"))
	var days := _pill_row()
	for weekday in range(7):
		var button := _pill(DataStore.WEEKDAY_SHORT[weekday].replace(".", ""))
		button.pressed.connect(func():
			_week_start = weekday
			_refresh_survey())
		days.add_child(button)
		_start_buttons[weekday] = button
	box.add_child(days)

	box.add_child(_question("Vous planifiez pour combien de temps ?"))
	var weeks := _pill_row()
	for count in range(LocalDatabase.PLAN_WEEKS_MIN, LocalDatabase.PLAN_WEEKS_MAX + 1):
		var button := _pill("%d semaine%s" % [count, "s" if count > 1 else ""])
		button.pressed.connect(func():
			_weeks = count
			_refresh_survey())
		weeks.add_child(button)
		_weeks_buttons[count] = button
	box.add_child(weeks)

	box.add_child(_question("Vous cuisinez pour combien de personnes ?"))
	_servings_spin = SpinBox.new()
	_servings_spin.min_value = 1
	_servings_spin.max_value = 24
	_servings_spin.step = 1
	_servings_spin.value_changed.connect(func(value): _servings = int(value))
	box.add_child(_servings_spin)

	box.add_child(_question("Combien de repas cuisinez-vous par jour ?"))
	var meals := _pill_row()
	for count in [1, 2]:
		var button := _pill(MEALS_LABELS[count - 1])
		button.pressed.connect(func():
			_meals = count
			_refresh_survey())
		meals.add_child(button)
		_meals_buttons[count] = button
	box.add_child(meals)

	var done := Button.new()
	done.text = "C'est parti"
	done.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	done.pressed.connect(_on_survey_done)
	box.add_child(done)
	return box

func _question(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
	return label

func _pill_row() -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	return row

func _pill(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
	return button

func _refresh_survey() -> void:
	for weekday in _start_buttons:
		_paint(_start_buttons[weekday], weekday == _week_start)
	for count in _weeks_buttons:
		_paint(_weeks_buttons[count], count == _weeks)
	for count in _meals_buttons:
		_paint(_meals_buttons[count], count == _meals)
	_servings_spin.set_value_no_signal(_servings)

func _paint(button: Button, chosen: bool) -> void:
	button.set_pressed_no_signal(chosen)
	button.theme_type_variation = "PillButton" if chosen else "OutlineButton"

func _on_survey_done() -> void:
	DataStore.set_plan_shape(_weeks, _week_start, _meals)
	DataStore.set_household_servings(_servings)
	# Écrit en dernier : si quelque chose échouait avant, la question serait reposée plutôt que
	# perdue.
	DataStore.set_onboarding_done(true)
	_finish()

func _finish() -> void:
	finished.emit()
	queue_free()
