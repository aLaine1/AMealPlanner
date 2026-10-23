class_name AccountWindow
extends Window
## Fenêtre « Compte » (2.0.8), ouverte depuis la pastille de l'en-tête.
##
## Elle portait la première section des Paramètres. Or se connecter n'est pas un réglage :
## c'est ce qu'on cherche en arrivant sur un nouvel appareil, et le ranger derrière la roue
## crantée, entre les rayons et les articles de base, le rendait introuvable. La pastille
## dit maintenant l'état du compte en permanence, et y mène directement.
##
## Le contenu est l'`AccountTab` d'avant, inchangé : connexion, état de la synchronisation,
## déconnexion.

const AccountTabScript := preload("res://ui/settings/AccountTab.gd")
const KeyboardInsetScript := preload("res://ui/components/KeyboardInset.gd")

var account: Control

func _ready() -> void:
	title = "Compte"
	Layout.fit_window(self, Vector2i(560, 520), Vector2i(420, 400))
	exclusive = true
	theme = Palette.ui_theme
	close_requested.connect(queue_free)

	var bg := ColorRect.new()
	bg.color = Palette.WINDOW_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# Sur téléphone la fenêtre est en plein écran, sans barre de titre : ce retour est le
	# seul moyen d'en sortir (cf. SettingsWindow).
	if Layout.is_phone():
		var back := Button.new()
		back.text = "←  Compte"
		back.theme_type_variation = "GhostButton"
		back.alignment = HORIZONTAL_ALIGNMENT_LEFT
		back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		back.custom_minimum_size = Vector2(0, Layout.TOUCH_TARGET)
		back.pressed.connect(queue_free)
		root.add_child(back)

	var card := PanelContainer.new()
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(card)

	# Défilant : le formulaire se saisit au clavier, qui le recouvrirait sinon.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.scroll_deadzone = 8
	card.add_child(scroll)
	account = AccountTabScript.new()
	account.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Layout.scroll_body(scroll).add_child(account)
	scroll.add_child(KeyboardInsetScript.new())

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		queue_free()
