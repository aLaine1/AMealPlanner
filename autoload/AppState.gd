extends Node
## État applicatif partagé entre onglets (le planning courant, la saison).
## Remplace le passage de référence `meal_planner_app` du code Python.

var current_meal_plan: MealPlan = MealPlan.new()
## "hiver" | "mix" | "ete". « Mix » par défaut : c'est le réglage qui n'exclut rien, donc
## celui qui puise dans toute la collection — un premier planning ne doit pas écarter la
## moitié des recettes sans que personne l'ait demandé.
var current_season: String = "mix"

const BREAKFAST_SLOTS := 4
var breakfast_slots: Array[String] = ["", "", "", ""]  ## noms de petits déjeuners sélectionnés

## Section des Paramètres à rouvrir après la reconstruction de l'interface — un changement
## de thème la provoque depuis Paramètres > Apparence, et l'on doit y revenir. Vide sinon.
var reopen_settings_section := ""

signal plan_changed
signal breakfast_changed

func set_plan(plan: MealPlan) -> void:
	current_meal_plan = plan
	plan_changed.emit()

func set_breakfast_slots(slots: Array[String]) -> void:
	breakfast_slots = slots
	breakfast_changed.emit()

## Ingrédients (non agrégés) des petits déjeuners actuellement sélectionnés.
func get_breakfast_ingredients() -> Array[Ingredient]:
	var out: Array[Ingredient] = []
	for name in breakfast_slots:
		if name.strip_edges() == "":
			continue
		var b := DataStore.get_breakfast_by_name(name)
		if b != null:
			for ing in b.ingredients:
				out.append(ing)
	return out

## Saison à exclure lors de la génération, selon la saison courante.
## "hiver" -> exclut "ete" ; "ete" -> exclut "hiver" ; "mix" -> rien.
func excluded_season() -> String:
	match current_season:
		"hiver":
			return "ete"
		"ete":
			return "hiver"
		_:
			return ""
