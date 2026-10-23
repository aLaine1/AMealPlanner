class_name Haptics
extends RefCounted
## Retour tactile : une vibration à peine perceptible, qui confirme un geste sans le
## regarder — cocher un article en marchant, le téléphone dans une main.
##
## Réservé aux gestes qui changent un état (cocher / décocher), pas à chaque toucher :
## une vibration à tout propos ne signale plus rien.
##
## Exige la permission Android VIBRATE (`export_presets.cfg`) : sans elle, l'appel est
## refusé par le système et ne fait rien.

## Durée et intensité d'une « coche » : de l'ordre du tic du clavier d'Android. L'intensité
## n'est honorée qu'à partir d'Android 8 ; avant, ou sur un vibreur sans réglage d'amplitude,
## seule la durée — très courte — retient la vibration de se faire sentir davantage.
const TICK_MS := 12
const TICK_AMPLITUDE := 0.3

## Nombre de vibrations demandées depuis le lancement — pour les tests, qui ne peuvent pas
## sentir le téléphone vibrer.
static var ticks := 0

static func tick() -> void:
	ticks += 1
	# Sur ordinateur, `vibrate_handheld` ne fait rien ; l'éviter garde les journaux propres.
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(TICK_MS, TICK_AMPLITUDE)
