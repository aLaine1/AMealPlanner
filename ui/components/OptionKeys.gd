class_name OptionKeys
extends RefCounted
## Clavier d'un `OptionButton` : ← / → changent la valeur sur place, sans ouvrir la liste.
## Entrée ou Espace l'ouvrent toujours — c'est le comportement natif du bouton —, et Tab
## passe au champ suivant.
##
## ↑ / ↓ changeaient la valeur en 2.0.11 ; ils passent désormais d'un champ à l'autre,
## comme partout dans le formulaire (2.0.13, cf. `ArrowNavigation`). Un menu déroulant fermé
## n'a pas de curseur : ← / → y sont libres.
##
## Liste ouverte (2.0.12), Tab la parcourt comme ↓ et Maj+Tab comme ↑, en revenant en haut
## après la dernière ligne — comme les suggestions des champs de saisie. Entrée retient la
## ligne surlignée, Échap referme : c'est le menu natif qui s'en charge.
##
## Sans cela, atteint par Tab, un menu déroulant ne se changeait qu'à la souris, seul de
## tout le formulaire.
##
## Les écrans le chargent par preload : un `class_name` tout neuf n'est pas garanti dans
## le cache des classes globales au lancement (cf. `Haptics`).

static func attach(option: OptionButton) -> void:
	var popup := option.get_popup()
	# Le menu est une fenêtre à part : ses touches lui arrivent par `window_input`, et il
	# ignore Tab de lui-même — on lui fait jouer le rôle de ↓.
	popup.window_input.connect(func(event: InputEvent):
		if not (event is InputEventKey) or not event.pressed or event.keycode != KEY_TAB:
			return
		if popup.item_count == 0:
			return
		var step := -1 if event.shift_pressed else 1
		var current := popup.get_focused_item()
		var target := wrap_index(current, step, popup.item_count)
		popup.set_focused_item(target)
		popup.set_input_as_handled())
	option.gui_input.connect(func(event: InputEvent):
		if not (event is InputEventKey) or not event.pressed or option.disabled:
			return
		var step := 0
		match event.keycode:
			KEY_RIGHT: step = 1
			KEY_LEFT: step = -1
		if step == 0 or option.item_count == 0:
			return
		# Bornée, pas circulaire : arrivé au bout, → ne doit pas ramener en tête sans
		# prévenir — on croirait avoir changé de valeur au hasard.
		var index := clampi(option.selected + step, 0, option.item_count - 1)
		if index != option.selected:
			option.select(index)
			option.item_selected.emit(index)
		option.accept_event())

## Rang suivant (ou précédent) dans une liste de `count` lignes, en revenant à l'autre bout
## une fois le bord franchi. Sans ligne courante (-1), on entre par le haut — ou par le bas
## en remontant.
static func wrap_index(current: int, step: int, count: int) -> int:
	if count <= 0:
		return -1
	if current < 0:
		return 0 if step > 0 else count - 1
	return wrapi(current + step, 0, count)
