class_name ArrowNavigation
extends Node
## ↑ / ↓ passent d'un champ à l'autre dans un formulaire (2.0.13).
##
## Godot le fait déjà pour les boutons, cases et menus déroulants — mais un `LineEdit`
## consomme ↑ / ↓ (début et fin du texte), et un `TextEdit` s'en sert pour changer de
## ligne. Au clavier, on restait donc coincé dans le premier champ de saisie venu.
##
## La destination est le voisin GÉOMÉTRIQUE (celui du dessus, celui du dessous), comme pour
## les boutons : dans les lignes d'ingrédients, ↓ depuis une quantité mène à la quantité de
## la ligne suivante — la liste se parcourt comme une grille.
##
## Laissé à ce qu'il fait déjà :
##  * un champ dont les suggestions sont ouvertes — ↑ / ↓ y parcourent la liste ;
##  * un texte sur plusieurs lignes, sauf à sa première ligne (↑) ou à sa dernière (↓).
##
## Se pose comme `KeyboardInset` : un enfant du conteneur du formulaire, sans autre réglage.

var _scope: Control

func _ready() -> void:
	_scope = get_parent() as Control

func _input(event: InputEvent) -> void:
	if _scope == null or not (event is InputEventKey) or not event.pressed:
		return
	if event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	var side := -1
	match event.keycode:
		KEY_UP: side = SIDE_TOP
		KEY_DOWN: side = SIDE_BOTTOM
	if side < 0:
		return
	var focus := _scope.get_viewport().gui_get_focus_owner()
	if focus == null or not _scope.is_ancestor_of(focus) or not _should_leave(focus, side):
		return
	var target := focus.find_valid_focus_neighbor(side)
	if target != null:
		target.grab_focus()
		get_viewport().set_input_as_handled()

## Vrai si ↑ / ↓ doit quitter `focus` plutôt que d'agir à l'intérieur.
func _should_leave(focus: Control, side: int) -> bool:
	# Les suggestions ouvertes gardent les flèches.
	if focus.has_method("is_popup_open") and focus.is_popup_open():
		return false
	if focus is TextEdit:
		var text := focus as TextEdit
		var line := text.get_caret_line()
		if side == SIDE_TOP:
			return line == 0 and text.get_caret_wrap_index() == 0
		return line == text.get_line_count() - 1 \
			and text.get_caret_wrap_index() == text.get_line_wrap_count(line)
	# Seuls les champs de saisie sur une ligne ont besoin d'aide : les autres contrôles
	# laissent déjà passer les flèches à la navigation du moteur.
	return focus is LineEdit
