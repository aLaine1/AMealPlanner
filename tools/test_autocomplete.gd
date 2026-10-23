extends SceneTree
## Test headless de la logique de filtrage d'AutocompleteEdit (fonction pure).
## godot --headless --script res://tools/test_autocomplete.gd

## Chargé à l'exécution, et non nommé par son `class_name` : lancé en `--script`, le
## moteur ne compte les autoloads parmi les identifiants connus qu'une fois la scène
## principale en place. `AutocompleteEdit` interroge `Layout` pour savoir où le clavier
## virtuel laisse la place à sa popup : nommé ici, il ne compilerait pas.
static var _edit: GDScript = null

func _initialize() -> void:
	_edit = load("res://ui/components/AutocompleteEdit.gd")
	var check := func(label: String, ok: bool):
		print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])

	var sugg := ["épinard", "épices", "tomate", "pomme", "pomme de terre", "carotte", "pâtes"]

	# Tolérance aux accents + tri "commence par" d'abord
	var r1: Array = _edit.filter_suggestions("epi", sugg, 8)
	check.call("accents ignorés (epi → épinard/épices)", r1 == ["épinard", "épices"])

	var r2: Array = _edit.filter_suggestions("pomme", sugg, 8)
	check.call("commence par (pomme, pomme de terre)", r2 == ["pomme", "pomme de terre"])

	# "contient" quand pas de préfixe
	var r3: Array = _edit.filter_suggestions("te", sugg, 8)
	check.call("contient (tomate, pomme de terre, carotte)",
		r3.has("tomate") and r3.has("carotte") and r3.has("pomme de terre") and not r3.has("épinard"))

	# "commence par" prioritaire sur "contient"
	var r4: Array = _edit.filter_suggestions("pa", ["épatant", "pâtes", "papaye"], 8)
	check.call("préfixe avant contenu (pâtes, papaye, épatant)", r4 == ["pâtes", "papaye", "épatant"])

	# Limite
	var many: Array[String] = []
	for i in range(20):
		many.append("aXX%d" % i)
	check.call("limite à MAX_ITEMS (8)", _edit.filter_suggestions("a", many, 8).size() == 8)

	# Vide
	check.call("requête vide → aucune suggestion", _edit.filter_suggestions("", sugg, 8).is_empty())

	# ===== Rattachement de la popup à l'arbre =====
	#
	# La popup de suggestions est parentée à la fenêtre englobante, et non au champ : un
	# ScrollContainer parent la rognerait. Or ce rattachement a lieu pendant que ladite
	# fenêtre monte ses propres enfants — un nœud ne peut pas en recevoir un pendant ce
	# montage, et l'ajout échouait. La popup n'entrait jamais dans l'arbre : le champ
	# d'ajout de dernière minute de la liste de courses ne proposait donc rien, sans
	# autre trace qu'une erreur en console. Le filtrage, lui, restait parfait — c'est
	# pourquoi les vérifications ci-dessus n'y voyaient que du feu.
	var window := Window.new()
	root.add_child(window)
	var host := _Host.new()
	host.edit_script = _edit
	window.add_child(host)   # c'est PENDANT cet ajout que le champ voit le jour
	await process_frame

	check.call("le champ est construit", is_instance_valid(host.field))
	check.call("sa popup est bien entrée dans l'arbre",
		host.field._panel != null and host.field._panel.get_parent() != null)
	window.queue_free()

	quit()

## Reproduit la cascade réelle : la liste de courses construit ses champs d'ajout depuis
## le `_ready()` de son onglet, lui-même en train d'être monté dans la fenêtre que le
## champ vise pour y poser sa popup.
class _Host extends Control:
	## Passé par le dehors : une classe interne ne voit pas les membres du script qui
	## la contient, et c'est bien le script chargé à l'exécution qu'il faut instancier.
	var edit_script: GDScript = null
	var field: LineEdit

	func _ready() -> void:
		field = edit_script.new()
		field.suggestions = ["tomate", "beurre"]
		add_child(field)
