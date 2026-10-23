extends Node
## Harnais de capture hors écran, pour vérifier les mises en page sans appareil.
## Autoload TEMPORAIRE, activé à la demande — voir tools/shoot.sh.
##
## Le format d'écran étant déduit de la largeur du viewport (cf. Layout.gd), il suffit
## de lancer l'app à une résolution de téléphone sous Xvfb pour obtenir exactement la
## mise en page mobile. Aucun mode simulé, aucun appareil requis.
##
## Paramétrage par variables d'environnement :
##   SHOT_NAME  nom du fichier produit dans user:// (défaut : "shot")
##   SHOT_TAB   titre de l'onglet à sélectionner avant la capture (optionnel)
##   SHOT_WAIT  secondes d'attente avant capture (défaut : 1.2)
##   SHOT_BACK  simule N appuis sur le bouton Retour d'Android avant la capture

func _ready() -> void:
	var wait := float(OS.get_environment("SHOT_WAIT")) if OS.get_environment("SHOT_WAIT") != "" else 1.2
	await get_tree().create_timer(wait).timeout

	var tab := OS.get_environment("SHOT_TAB")
	if tab != "":
		_select_tab(get_tree().root, tab)
		await get_tree().create_timer(0.6).timeout

	# Le geste système n'existe que sur téléphone : sans ce relais, ce qu'il affiche —
	# le message de confirmation de sortie — ne serait vérifiable que sur un appareil.
	var backs := int(OS.get_environment("SHOT_BACK"))
	for _i in range(backs):
		get_tree().root.propagate_notification(NOTIFICATION_WM_GO_BACK_REQUEST)
		await get_tree().create_timer(0.3).timeout

	await RenderingServer.frame_post_draw
	var name := OS.get_environment("SHOT_NAME")
	if name == "":
		name = "shot"
	var image := get_viewport().get_texture().get_image()
	image.save_png("user://%s.png" % name)
	print("SHOT %s  (%dx%d, format=%s)" % [
		name, image.get_width(), image.get_height(), _form_name()])
	get_tree().quit()

func _form_name() -> String:
	match Layout.form:
		Layout.Form.PHONE:
			return "PHONE"
		Layout.Form.TABLET:
			return "TABLET"
		_:
			return "DESKTOP"

## Accepte le titre affiché comme le nom du nœud : les deux coïncident aujourd'hui, mais
## un libellé adapté au format ne doit pas casser `shoot.sh courses-tel … "Liste de
## course"`, la ligne inscrite au README.
func _select_tab(node: Node, title: String) -> void:
	if node is TabContainer:
		for i in node.get_tab_count():
			# Type explicite : `get_tab_control` renvoie un `Control` nullable, que le
			# moteur refuse d'inférer. Sans lui, le script ne compile pas, l'autoload
			# n'est pas instancié — et l'application tourne sans fin, sans capturer ni
			# sortir. Ce n'était donc pas `shoot.sh` qui se bloquait.
			var tab: Control = node.get_tab_control(i)
			if node.get_tab_title(i) == title or (tab != null and tab.name == title):
				node.current_tab = i
	for child in node.get_children():
		_select_tab(child, title)
