extends Node
## Palette de couleurs et styles — portage de config.THEME_COLORS (Python).
## Autoload "Palette". Utiliser Palette.PRIMARY, etc.

## Chargé par preload plutôt que par son class_name : le cache de classes globales de
## Godot n'est pas garanti à jour au lancement d'un autoload (même raison que dans
## Session.gd).
const TextFoldScript := preload("res://ui/components/TextFold.gd")

# ===== Charte et thèmes de couleur =====
#
# Chaque thème (2.0.7) est un jeu de RÔLES — nom pour nom ceux du schéma Material 3 de la
# charte, réduits à ceux que l'application lit vraiment. Rien d'autre dans l'application
# ne doit introduire une couleur qui n'en descende pas. Les noms historiques suivent,
# recalculés à partir du thème actif : le reste du code continue de lire
# `Palette.PRIMARY` ou `Palette.BORDER` sans rien savoir du thème choisi.
#
# Deux invariants que tous les thèmes respectent, sans lesquels un écran deviendrait
# illisible en changeant de thème — `test_palette.gd` les mesure sur chacun :
#  * PRIMARY et SECONDARY sont des REMPLISSAGES qui portent une encre blanche (en-têtes,
#    boutons pleins, onglet actif) : ils restent sombres, même dans le thème sombre ;
#  * PRIMARY_INK est le primaire en tant qu'ENCRE — texte, contour, soulignement posés
#    sur une surface. C'est PRIMARY sur fond clair ; sur fond sombre, une teinte claire
#    du même vert, sans quoi le texte vert foncé disparaîtrait dans le fond.
#
# `CELL`, facultatif, est le fond d'une case du calendrier, qui vaut SURFACE à défaut. Sur
# fond clair, une case blanche se détache de sa carte blanche par son OMBRE ; sur fond
# sombre, une ombre ne se voit plus, et la case doit être un ton plus claire que la carte.

## Thèmes proposés dans Paramètres > Apparence, dans l'ordre d'affichage.
const SCHEMES := {
	"vert": {
		"name": "Vert",
		"PRIMARY": "1E513B", "PRIMARY_INK": "1E513B", "SECONDARY": "4A8B6E",
		"SECONDARY_CONTAINER": "CEEAD6", "TERTIARY": "E67E22",
		"ERROR": "BA1A1A", "ERROR_CONTAINER": "FFDAD6",
		"BACKGROUND": "F9F8F3", "SURFACE": "FFFFFF", "SURFACE_VARIANT": "E1E4DF",
		"ON_SURFACE": "1C2833", "ON_SURFACE_VARIANT": "626567", "OUTLINE_VARIANT": "C2C8C0",
	},
	"orange": {
		"name": "Orange",
		"PRIMARY": "8F3F0E", "PRIMARY_INK": "8F3F0E", "SECONDARY": "B0571C",
		"SECONDARY_CONTAINER": "FBE0CC", "TERTIARY": "1F7A68",
		"ERROR": "BA1A1A", "ERROR_CONTAINER": "FFDAD6",
		"BACKGROUND": "FBF7F2", "SURFACE": "FFFFFF", "SURFACE_VARIANT": "EDE4DC",
		"ON_SURFACE": "2B2118", "ON_SURFACE_VARIANT": "6B5F56", "OUTLINE_VARIANT": "D6C7BB",
	},
	"bleu": {
		"name": "Bleu",
		"PRIMARY": "1D4A72", "PRIMARY_INK": "1D4A72", "SECONDARY": "35709F",
		"SECONDARY_CONTAINER": "D3E4F3", "TERTIARY": "E67E22",
		"ERROR": "BA1A1A", "ERROR_CONTAINER": "FFDAD6",
		"BACKGROUND": "F5F7FA", "SURFACE": "FFFFFF", "SURFACE_VARIANT": "DFE5EC",
		"ON_SURFACE": "1A2533", "ON_SURFACE_VARIANT": "5D6670", "OUTLINE_VARIANT": "C0CAD4",
	},
	"sombre": {
		"name": "Sombre",
		"PRIMARY": "2B6E4E", "PRIMARY_INK": "8FD3A8", "SECONDARY": "357A59",
		"SECONDARY_CONTAINER": "30503F", "TERTIARY": "F2A65A", "CELL": "272E2A",
		"ERROR": "FFB4AB", "ERROR_CONTAINER": "5C1B16",
		"BACKGROUND": "121614", "SURFACE": "1D2320", "SURFACE_VARIANT": "2E3632",
		"ON_SURFACE": "E3E8E4", "ON_SURFACE_VARIANT": "A8B2AC", "OUTLINE_VARIANT": "46504A",
	},
}
const DEFAULT_SCHEME := "vert"
## Clé de la préférence, propre à l'appareil et non synchronisée : on peut vouloir le
## thème sombre sur le téléphone et le clair sur l'ordinateur.
const SCHEME_PREFERENCE := "color_scheme"

## Thème actif, et ses rôles — remplis par `_apply_scheme`, jamais écrits ailleurs.
var scheme := DEFAULT_SCHEME
var M3_PRIMARY: Color
var M3_SECONDARY: Color
var M3_SECONDARY_CONTAINER: Color
var M3_TERTIARY: Color
var M3_ERROR: Color
var M3_ERROR_CONTAINER: Color
var M3_BACKGROUND: Color
var M3_SURFACE: Color
var M3_SURFACE_VARIANT: Color
var M3_ON_SURFACE: Color
var M3_ON_SURFACE_VARIANT: Color
var M3_OUTLINE_VARIANT: Color

# ===== Noms historiques =====
#
# Conservés pour ne pas réécrire deux cents appels, mais ils ne portent plus de valeur
# propre : chacun dit QUEL rôle du thème il désigne (cf. `_apply_scheme`).

var PRIMARY: Color
## Le primaire en tant qu'encre sur une surface — cf. les invariants plus haut.
var PRIMARY_INK: Color
var SECONDARY: Color
## Accent de la charte. Sert aux marques qui ne sont ni une action ni une erreur.
var ACCENT: Color
var BACKGROUND: Color
var SURFACE: Color
var TEXT_PRIMARY: Color
var TEXT_SECONDARY: Color
## Confirmation. La charte n'a pas de « succès » : c'est le primaire en encre, celui qui
## dit déjà l'action réussie partout ailleurs.
var SUCCESS: Color
## Avertissement — ni une erreur, ni une confirmation : l'accent.
var WARNING: Color
var ERROR: Color

var WINDOW_BG: Color
## Survol d'une case, ligne cochée, sélection douce : le conteneur secondaire.
var CELL_HOVER: Color
## Fond d'une case ordinaire du calendrier — cf. le rôle `CELL` plus haut.
var CELL_BG: Color
## Bordures douces — champs, pilules, séparations internes.
var BORDER: Color
## Fond d'une case réservée à un plat qui ne se transporte pas : une teinte très claire
## du thème, à MI-CHEMIN entre la case ordinaire et la case survolée (2.0.7).
##
## Elle a été d'abord un vert pâle indiscernable du survol (0,74 ΔE, la même couleur à
## l'œil), puis l'orange de l'accent, qui se distinguait bien mais tranchait sur tout le
## reste. À mi-chemin, elle reste à plus de 4 ΔE des deux autres fonds d'une même case,
## dans chaque thème — `test_palette.gd` le vérifie.
var CELL_NOBOX: Color
## Contour d'une case réservée : le même vert, un ton plus soutenu que le survol.
var CELL_NOBOX_BORDER: Color
## Contour d'une journée du calendrier portant deux repas. Le contour DISCRET de la charte,
## et non la bordure douce : celle-ci n'est qu'à 3,3 ΔE du survol, si bien que le cadre
## d'une journée survolée s'effaçait. Celui-ci reste au-dessus de 9 des trois fonds.
var DAY_FRAME: Color
## Fond d'un contrôle désactivé, et encre posée dessus.
var DISABLED_BG: Color
var DISABLED_INK: Color

## Affecte les rôles du thème `id` (repli sur le thème par défaut s'il est inconnu) et
## recalcule les noms historiques. Ne reconstruit PAS le thème Godot : cf. `set_scheme`.
func _apply_scheme(id: String) -> void:
	scheme = id if SCHEMES.has(id) else DEFAULT_SCHEME
	var roles: Dictionary = SCHEMES[scheme]
	M3_PRIMARY = Color(roles["PRIMARY"])
	M3_SECONDARY = Color(roles["SECONDARY"])
	M3_SECONDARY_CONTAINER = Color(roles["SECONDARY_CONTAINER"])
	M3_TERTIARY = Color(roles["TERTIARY"])
	M3_ERROR = Color(roles["ERROR"])
	M3_ERROR_CONTAINER = Color(roles["ERROR_CONTAINER"])
	M3_BACKGROUND = Color(roles["BACKGROUND"])
	M3_SURFACE = Color(roles["SURFACE"])
	M3_SURFACE_VARIANT = Color(roles["SURFACE_VARIANT"])
	M3_ON_SURFACE = Color(roles["ON_SURFACE"])
	M3_ON_SURFACE_VARIANT = Color(roles["ON_SURFACE_VARIANT"])
	M3_OUTLINE_VARIANT = Color(roles["OUTLINE_VARIANT"])

	PRIMARY = M3_PRIMARY
	PRIMARY_INK = Color(roles["PRIMARY_INK"])
	SECONDARY = M3_SECONDARY
	ACCENT = M3_TERTIARY
	BACKGROUND = M3_BACKGROUND
	SURFACE = M3_SURFACE
	TEXT_PRIMARY = M3_ON_SURFACE
	TEXT_SECONDARY = M3_ON_SURFACE_VARIANT
	SUCCESS = PRIMARY_INK
	WARNING = M3_TERTIARY
	ERROR = M3_ERROR
	WINDOW_BG = M3_BACKGROUND
	CELL_HOVER = M3_SECONDARY_CONTAINER
	BORDER = M3_SURFACE_VARIANT
	CELL_BG = Color(roles.get("CELL", roles["SURFACE"]))
	CELL_NOBOX = CELL_BG.lerp(M3_SECONDARY_CONTAINER, 0.5)
	CELL_NOBOX_BORDER = M3_SECONDARY_CONTAINER.lerp(M3_SECONDARY, 0.35)
	DAY_FRAME = M3_OUTLINE_VARIANT
	DISABLED_BG = M3_SURFACE_VARIANT
	DISABLED_INK = M3_ON_SURFACE_VARIANT

## Teintes de catégorie, réparties sur tout le cercle chromatique.
##
## Les huit précédentes tenaient dans un arc de 36° à 163° — jaunes, oranges et verts
## uniquement. Deux d'entre elles ne s'écartaient que de ΔE 4,4 en vision normale, et
## 2,5 en daltonisme simulé : indiscernables. Celles-ci gardent un écart minimal de
## **11,5 et 6,1** sur les mêmes mesures (distance euclidienne OKLab ×100, protanopie
## et deutéranopie simulées par Machado 2009), soit deux fois mieux.
##
## Les seuils de la visualisation de données (15 et 8) ne sont pas atteignables à dix
## teintes, et n'ont pas à l'être ici : la couleur est un appoint, jamais le seul
## porteur d'identité — le nom de la recette est toujours écrit à côté de sa pastille.
##
## Clarté et chroma sont bornées (L 0,52–0,72 · C 0,10–0,19 en OKLCH) pour rester dans
## le registre de l'application. Sans ces bornes, l'écart maximal se trouve dans des
## teintes fluo, qui jureraient sur le fond crème.
const CATEGORY_PALETTE: Array[Color] = [
	Color("ae6054"),  # 0 brique
	Color("f67e00"),  # 1 orange
	Color("786c00"),  # 2 olive profond
	Color("9ca85a"),  # 3 olive clair
	Color("00ba9c"),  # 4 vert d'eau
	Color("54a8d2"),  # 5 bleu ciel
	Color("0066cc"),  # 6 bleu franc
	Color("a290fc"),  # 7 lavande
	Color("8a66a8"),  # 8 violet
	Color("b42a78"),  # 9 framboise
]

## Teinte fixe des catégories du jeu d'exemple, par indice dans `CATEGORY_PALETTE`.
## Une table explicite plutôt qu'un tirage pour toutes : elle garantit huit couleurs
## distinctes là où un hachage en ferait forcément collisionner deux.
##
## « Légumes » et « Légumineuses » sont volontairement aux deux bouts du cercle : leurs
## noms se ressemblent déjà, leurs pastilles n'ont pas à s'y ajouter.
const CATEGORY_COLORS := {
	"Légumes": 3,       # olive clair
	"Légumineuses": 9,  # framboise
	"Oeufs": 1,         # orange
	"Pain": 0,          # brique
	"Pâtes": 7,         # lavande
	"Riz": 5,           # bleu ciel
	"Salade": 4,        # vert d'eau
	"Tubercules": 2,    # olive profond
}

const RADIUS := 10
const RADIUS_CARD := 16
## Hauteur de la barre de titre des sous-fenêtres, reprise par la marge d'expansion
## du fond : les deux doivent rester d'accord, sinon la bande est mal couverte.
const WINDOW_TITLE_HEIGHT := 34

var ui_theme: Theme

## Émis après un changement de thème : les couleurs sont lues à la construction de chaque
## écran, `MainWindow` reconstruit donc toute l'interface en le recevant.
signal scheme_changed

func _ready() -> void:
	# `DataStore` est déclaré AVANT Palette (cf. project.godot) précisément pour qu'on
	# puisse lire ici le thème choisi : construire le thème par défaut puis le refaire
	# ferait clignoter le vert au lancement de quiconque a choisi un autre thème.
	var store := get_node_or_null("/root/DataStore")
	var chosen: String = store.get_ui_preference(SCHEME_PREFERENCE, DEFAULT_SCHEME) \
		if store != null else DEFAULT_SCHEME
	_apply_scheme(chosen)
	ui_theme = make_theme()
	# La typographie suit le format : voir `apply_form_typography`. Branché ici et non
	# dans Layout — qui est déclaré AVANT Palette et dont le `_ready` s'exécute donc
	# quand `ui_theme` n'existe pas encore.
	var layout := get_node_or_null("/root/Layout")
	if layout != null:
		layout.form_changed.connect(func(_f): apply_form_typography())
		apply_form_typography()

## Change de thème, le mémorise sur l'appareil et reconstruit le thème Godot. Les écrans
## déjà construits gardent leurs anciennes couleurs jusqu'à leur reconstruction : c'est le
## rôle de `scheme_changed`.
func set_scheme(id: String) -> void:
	if not SCHEMES.has(id) or id == scheme:
		return
	_apply_scheme(id)
	var store := get_node_or_null("/root/DataStore")
	if store != null:
		store.set_ui_preference(SCHEME_PREFERENCE, scheme)
	ui_theme = make_theme()
	apply_form_typography()
	scheme_changed.emit()

# ===== Typographie selon le format =====

## Taille de base du texte, sur téléphone.
const FONT_SIZE_BODY := 15
## Boutons un cran en dessous : à 15, la barre d'actions de la bibliothèque se replie sur
## une rangée de plus et mange la hauteur de la liste.
const FONT_SIZE_BUTTON := 14
const FONT_SIZE_PILL := 13
const FONT_SIZE_TAB := 15
const FONT_SIZE_WINDOW_TITLE := 16

## Points ajoutés hors téléphone. Sur un grand écran, la même taille demande un effort de
## lecture qu'un écran tenu à trente centimètres n'impose pas. Sur téléphone, rien n'est
## ajouté : le contenu y est déjà mis à l'échelle selon la densité (cf. Layout), et deux
## points de plus y feraient déborder ce qui tient de justesse — la barre d'onglets
## d'abord, qui dispose de 22 unités de marge à 320.
const DESKTOP_FONT_BOOST := 2

## Les BOUTONS ne bougent pas, et ce n'est pas une omission : à 16, la barre d'actions de
## la bibliothèque se replie sur une rangée de PLUS et prend cette hauteur à la liste des
## recettes, qui perd une ligne et se retrouve coupée. Constaté à la capture, et déjà noté
## à l'époque où la taille de base est passée de 14 à 15. Le libellé d'un bouton se lit
## d'ailleurs par sa forme et sa position autant que par sa taille.
const DESKTOP_BUTTON_BOOST := 0

## Les pastilles de filtre gagnent un seul point : deux les feraient passer à la ligne sur
## une fenêtre étroite, où elles sont déjà nombreuses.
const DESKTOP_PILL_BOOST := 1

## Rehausse la typographie hors téléphone, en un seul endroit.
##
## Passe par le THÈME et non par des surcharges posées écran par écran : le thème est
## partagé, une taille modifiée ici se propage d'elle-même à tout ce qui ne s'en écarte
## pas explicitement. Les titres et les légendes, qui portent leur propre taille, ne
## bougent pas — ils sont déjà dimensionnés pour leur rôle.
func apply_form_typography() -> void:
	if ui_theme == null:
		return
	var layout := get_node_or_null("/root/Layout")
	var phone: bool = layout != null and layout.is_phone()
	var body := 0 if phone else DESKTOP_FONT_BOOST
	var button := 0 if phone else DESKTOP_BUTTON_BOOST
	var pill := 0 if phone else DESKTOP_PILL_BOOST
	ui_theme.default_font_size = FONT_SIZE_BODY + body
	ui_theme.set_font_size("font_size", "Button", FONT_SIZE_BUTTON + button)
	ui_theme.set_font_size("font_size", "PillButton", FONT_SIZE_PILL + pill)
	ui_theme.set_font_size("font_size", "TabContainer", FONT_SIZE_TAB + body)
	ui_theme.set_font_size("font_size", "TabBar", FONT_SIZE_TAB + body)
	ui_theme.set_font_size("title_font_size", "Window", FONT_SIZE_WINDOW_TITLE + body)

## Renvoie une couleur de rayon (aisle) déterministe pour les titres de la liste de courses.
func aisle_color(_aisle: String) -> Color:
	return PRIMARY

## Couleur d'accent associée à une catégorie de recette (badges, avatars). Repli neutre
## si la catégorie est vide.
func category_color(category_name: String) -> Color:
	var name := category_name.strip_edges()
	if name == "":
		return TEXT_SECONDARY
	if CATEGORY_COLORS.has(name):
		return CATEGORY_PALETTE[CATEGORY_COLORS[name]]
	return CATEGORY_PALETTE[_category_slot(name)]

## Teinte d'une catégorie hors table, tirée de son NOM et non de son rang.
##
## Les catégories sont libres : l'utilisateur en saisit ce qu'il veut. Les numéroter
## par ordre d'apparition ferait changer de couleur toutes celles qui suivent au
## premier ajout — des recettes auxquelles on n'a pas touché se repeindraient. Dérivée
## du nom, la couleur ne bouge jamais.
##
## FNV-1a plutôt que `String.hash()` : la stabilité de ce dernier d'une version de
## Godot à l'autre n'est pas garantie. Le nom est replié au passage, pour que
## « Pâtes » et « pates » partagent leur teinte.
func _category_slot(category_name: String) -> int:
	var digest := 2166136261
	for code in TextFoldScript.fold(category_name).to_utf8_buffer():
		digest = ((digest ^ code) * 16777619) & 0xFFFFFFFF
	return digest % CATEGORY_PALETTE.size()

## Encre lisible posée SUR une couleur : blanc ou encre foncée, celle des deux qui
## contraste le plus.
##
## Les initiales des pastilles étaient toujours blanches, ce qui les rendait illisibles
## sur les teintes claires — 1,5:1 sur l'ancien sable, là où 4,5:1 est le minimum pour
## un texte de cette taille. La palette couvrant désormais toute la bande de clarté, le
## choix ne peut plus être figé.
func ink_on(background: Color) -> Color:
	return Color.WHITE if _contrast(background, Color.WHITE) >= _contrast(background, TEXT_PRIMARY) \
		else TEXT_PRIMARY

func _contrast(a: Color, b: Color) -> float:
	var la := _relative_luminance(a)
	var lb := _relative_luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)

## Luminance relative WCAG.
func _relative_luminance(color: Color) -> float:
	var channels := [color.r, color.g, color.b]
	var linear := []
	for channel in channels:
		linear.append(channel / 12.92 if channel <= 0.04045 else pow((channel + 0.055) / 1.055, 2.4))
	return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

# ===== Thème global =====

func make_theme() -> Theme:
	var t := Theme.new()
	# Valeurs de base, celles du téléphone ; `apply_form_typography` les rehausse ailleurs.
	t.default_font_size = FONT_SIZE_BODY

	var body_font := _load_warm_font()
	if body_font != null:
		t.default_font = body_font

	# --- Cartes / panneaux ---
	t.set_stylebox("panel", "PanelContainer", card_style())
	var flat_panel := _sb(Color.TRANSPARENT, 0)
	t.set_stylebox("panel", "Panel", card_style())

	# --- Boutons (primaire par défaut) ---
	t.set_stylebox("normal", "Button", _btn(PRIMARY))
	t.set_stylebox("hover", "Button", _btn(SECONDARY))
	t.set_stylebox("pressed", "Button", _btn(PRIMARY.darkened(0.12)))
	t.set_stylebox("disabled", "Button", _btn(DISABLED_BG))
	t.set_stylebox("focus", "Button", _focus_ring(RADIUS))
	t.set_color("font_color", "Button", Color.WHITE)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_disabled_color", "Button", DISABLED_INK)
	t.set_font_size("font_size", "Button", FONT_SIZE_BUTTON)

	# Variante "Ghost" (secondaire discret, sans cadre) — même gabarit que le primaire
	t.set_stylebox("normal", "GhostButton", _btn_variant(Color.TRANSPARENT))
	t.set_stylebox("hover", "GhostButton", _btn_variant(CELL_HOVER))
	t.set_stylebox("pressed", "GhostButton", _btn_variant(BORDER))
	t.set_stylebox("disabled", "GhostButton", _btn_variant(Color.TRANSPARENT))
	t.set_stylebox("focus", "GhostButton", _focus_ring(RADIUS))
	t.set_type_variation("GhostButton", "Button")
	t.set_color("font_color", "GhostButton", PRIMARY_INK)
	t.set_color("font_hover_color", "GhostButton", PRIMARY_INK)
	t.set_color("font_pressed_color", "GhostButton", PRIMARY_INK)
	t.set_color("font_disabled_color", "GhostButton", TEXT_SECONDARY)

	# Variante "OutlineButton" (secondaire avec cadre) — même gabarit que le primaire
	t.set_stylebox("normal", "OutlineButton", _btn_variant(Color.TRANSPARENT, 1, SECONDARY))
	t.set_stylebox("hover", "OutlineButton", _btn_variant(CELL_HOVER, 1, PRIMARY_INK))
	t.set_stylebox("pressed", "OutlineButton", _btn_variant(BORDER, 1, PRIMARY_INK))
	t.set_stylebox("disabled", "OutlineButton", _btn_variant(Color.TRANSPARENT, 1, BORDER))
	t.set_stylebox("focus", "OutlineButton", _focus_ring(RADIUS))
	t.set_type_variation("OutlineButton", "Button")
	t.set_color("font_color", "OutlineButton", PRIMARY_INK)
	t.set_color("font_hover_color", "OutlineButton", PRIMARY_INK)
	t.set_color("font_pressed_color", "OutlineButton", PRIMARY_INK)
	t.set_color("font_disabled_color", "OutlineButton", TEXT_SECONDARY)

	# Variante "DangerButton" (suppression, cadre rouge léger) — même gabarit
	t.set_stylebox("normal", "DangerButton", _btn_variant(Color.TRANSPARENT, 1, M3_ERROR_CONTAINER))
	t.set_stylebox("hover", "DangerButton", _btn_variant(M3_ERROR_CONTAINER, 1, ERROR))
	t.set_stylebox("pressed", "DangerButton", _btn_variant(M3_ERROR_CONTAINER.darkened(0.06), 1, ERROR))
	t.set_stylebox("disabled", "DangerButton", _btn_variant(Color.TRANSPARENT, 1, BORDER))
	t.set_stylebox("focus", "DangerButton", _focus_ring(RADIUS))
	t.set_type_variation("DangerButton", "Button")
	t.set_color("font_color", "DangerButton", ERROR)
	t.set_color("font_hover_color", "DangerButton", ERROR)
	t.set_color("font_pressed_color", "DangerButton", ERROR)
	t.set_color("font_disabled_color", "DangerButton", TEXT_SECONDARY)

	# Variante "HeaderButton" (bouton posé sur l'en-tête vert : texte blanc, survol translucide)
	t.set_stylebox("normal", "HeaderButton", _btn_variant(Color.TRANSPARENT))
	t.set_stylebox("hover", "HeaderButton", _btn_variant(Color(1, 1, 1, 0.16)))
	t.set_stylebox("pressed", "HeaderButton", _btn_variant(Color(1, 1, 1, 0.26)))
	t.set_stylebox("disabled", "HeaderButton", _btn_variant(Color.TRANSPARENT))
	# Blanc et non le primaire des autres : c'est le seul bouton posé sur un fond déjà
	# PRIMARY, où un anneau de cette couleur disparaîtrait.
	t.set_stylebox("focus", "HeaderButton", _focus_ring(RADIUS, Color.WHITE))
	t.set_type_variation("HeaderButton", "Button")
	t.set_color("font_color", "HeaderButton", Color.WHITE)
	t.set_color("font_hover_color", "HeaderButton", Color.WHITE)
	t.set_color("font_pressed_color", "HeaderButton", Color.WHITE)

	# Variante "SegmentButton" (contrôle segmenté : sélection = plein vert)
	t.set_stylebox("normal", "SegmentButton", _seg(Color.TRANSPARENT))
	t.set_stylebox("hover", "SegmentButton", _seg(CELL_HOVER))
	t.set_stylebox("pressed", "SegmentButton", _seg(PRIMARY))
	t.set_stylebox("hover_pressed", "SegmentButton", _seg(SECONDARY))
	t.set_stylebox("disabled", "SegmentButton", _seg(Color.TRANSPARENT))
	t.set_stylebox("focus", "SegmentButton", _focus_ring(7, Color(0, 0, 0, 0), 14, 7))
	t.set_type_variation("SegmentButton", "Button")
	t.set_color("font_color", "SegmentButton", PRIMARY_INK)
	t.set_color("font_hover_color", "SegmentButton", PRIMARY_INK)
	t.set_color("font_pressed_color", "SegmentButton", Color.WHITE)
	t.set_color("font_hover_pressed_color", "SegmentButton", Color.WHITE)
	t.set_color("font_disabled_color", "SegmentButton", TEXT_SECONDARY)

	# Variante "PillButton" (filtres de catégorie : bascule ronde, sélection = plein vert).
	# Distincte de SegmentButton, qui vit collé à ses voisins dans un segment et se passe
	# donc de cadre : une pilule isolée doit rester visible non sélectionnée.
	t.set_stylebox("normal", "PillButton", _pill(Color.TRANSPARENT, 1, BORDER))
	t.set_stylebox("hover", "PillButton", _pill(CELL_HOVER, 1, SECONDARY))
	t.set_stylebox("pressed", "PillButton", _pill(PRIMARY))
	t.set_stylebox("hover_pressed", "PillButton", _pill(SECONDARY))
	t.set_stylebox("disabled", "PillButton", _pill(Color.TRANSPARENT, 1, BORDER))
	t.set_stylebox("focus", "PillButton", _focus_ring(999, Color(0, 0, 0, 0), 14, 6))
	t.set_type_variation("PillButton", "Button")
	t.set_font_size("font_size", "PillButton", FONT_SIZE_PILL)
	t.set_color("font_color", "PillButton", PRIMARY_INK)
	t.set_color("font_hover_color", "PillButton", PRIMARY_INK)
	t.set_color("font_pressed_color", "PillButton", Color.WHITE)
	t.set_color("font_hover_pressed_color", "PillButton", Color.WHITE)
	t.set_color("font_disabled_color", "PillButton", TEXT_SECONDARY)

	# Couleur du texte AU FOCUS, pour chaque variante : celle de son état normal (2.0.12).
	# Non définie, elle retombait sur celle du thème du moteur, presque blanche — atteint par
	# Tab, « Choisir une image… » devenait blanc sur fond clair, donc invisible. Godot ne la
	# lit que dans l'état normal : un bouton enfoncé ou survolé garde sa propre couleur.
	for variant in ["Button", "GhostButton", "OutlineButton", "DangerButton", "HeaderButton",
			"SegmentButton", "PillButton"]:
		t.set_color("font_focus_color", variant, t.get_color("font_color", variant))

	# --- Champs de saisie ---
	for type in ["LineEdit", "TextEdit", "CodeEdit"]:
		t.set_stylebox("normal", type, _field())
		t.set_stylebox("read_only", type, _field())
		var focus := _field()
		focus.border_color = PRIMARY_INK
		focus.set_border_width_all(2)
		t.set_stylebox("focus", type, focus)
		t.set_color("font_color", type, TEXT_PRIMARY)
		# Un champ verrouillé doit rester LISIBLE : c'est ainsi qu'on consulte une recette
		# depuis la 1.7.13, et la couleur par défaut d'un champ non modifiable la rendait
		# presque aussi pâle qu'un texte d'invite. Même encre que le texte modifiable, le
		# verrouillage se lisant à l'absence de curseur et aux actions de l'en-tête.
		t.set_color("font_uneditable_color", type, TEXT_PRIMARY)
		t.set_color("font_readonly_color", type, TEXT_PRIMARY)
		t.set_color("font_placeholder_color", type, TEXT_SECONDARY)
		t.set_color("caret_color", type, PRIMARY_INK)
		t.set_color("font_selected_color", type, Color.WHITE)
		t.set_color("selection_color", type, SECONDARY)

	# --- OptionButton (menu déroulant) : style champ ---
	t.set_stylebox("normal", "OptionButton", _field())
	t.set_stylebox("hover", "OptionButton", _field())
	t.set_stylebox("pressed", "OptionButton", _field())
	t.set_stylebox("focus", "OptionButton", _focus_ring(RADIUS, Color(0, 0, 0, 0), 10, 7))
	t.set_stylebox("disabled", "OptionButton", _field())
	t.set_color("font_color", "OptionButton", TEXT_PRIMARY)
	t.set_color("font_hover_color", "OptionButton", TEXT_PRIMARY)
	t.set_color("font_pressed_color", "OptionButton", TEXT_PRIMARY)
	# TOUS les états, comme pour la CheckBox : `font_focus_color` manquait, et retombait sur
	# la couleur du thème du moteur, presque blanche. Atteint par Tab, le champ semblait
	# alors se vider — son texte, blanc sur blanc, était simplement devenu invisible (2.0.11).
	t.set_color("font_focus_color", "OptionButton", TEXT_PRIMARY)
	t.set_color("font_hover_pressed_color", "OptionButton", TEXT_PRIMARY)
	t.set_color("font_disabled_color", "OptionButton", TEXT_SECONDARY)

	# --- ItemList ---
	t.set_stylebox("panel", "ItemList", _field())
	var sel := _sb(SECONDARY, 6)
	t.set_stylebox("selected", "ItemList", sel)
	t.set_stylebox("selected_focus", "ItemList", sel)
	t.set_stylebox("hovered", "ItemList", _sb(CELL_HOVER, 6))
	t.set_stylebox("cursor", "ItemList", _sb(Color.TRANSPARENT, 6))
	t.set_stylebox("cursor_unfocused", "ItemList", _sb(Color.TRANSPARENT, 6))
	t.set_color("font_color", "ItemList", TEXT_PRIMARY)
	t.set_color("font_selected_color", "ItemList", Color.WHITE)
	t.set_color("font_hovered_color", "ItemList", TEXT_PRIMARY)
	t.set_constant("v_separation", "ItemList", 4)
	t.set_constant("h_separation", "ItemList", 4)

	# --- PopupMenu ---
	t.set_stylebox("panel", "PopupMenu", card_style())
	t.set_stylebox("hover", "PopupMenu", _sb(CELL_HOVER, 6))
	t.set_color("font_color", "PopupMenu", TEXT_PRIMARY)
	t.set_color("font_hover_color", "PopupMenu", PRIMARY_INK)

	# --- TabContainer ---
	var tab_panel := _sb(SURFACE, RADIUS_CARD)
	t.set_stylebox("panel", "TabContainer", tab_panel)
	t.set_stylebox("tabbar_background", "TabContainer", _sb(Color.TRANSPARENT, 0))
	t.set_stylebox("tab_selected", "TabContainer", _tab(PRIMARY))
	t.set_stylebox("tab_unselected", "TabContainer", _tab(M3_SECONDARY_CONTAINER))
	t.set_stylebox("tab_hovered", "TabContainer", _tab(SECONDARY))
	t.set_color("font_selected_color", "TabContainer", Color.WHITE)
	t.set_color("font_unselected_color", "TabContainer", TEXT_PRIMARY)
	t.set_color("font_hovered_color", "TabContainer", Color.WHITE)
	t.set_font_size("font_size", "TabContainer", FONT_SIZE_TAB)

	# --- TabBar (onglets autonomes, ex. catégories de la liste de courses) — compacts ---
	t.set_stylebox("tab_selected", "TabBar", _tab_c(PRIMARY))
	t.set_stylebox("tab_unselected", "TabBar", _tab_c(M3_SECONDARY_CONTAINER))
	t.set_stylebox("tab_hovered", "TabBar", _tab_c(SECONDARY))
	t.set_stylebox("tab_focus", "TabBar", _sb(Color.TRANSPARENT, 0))
	t.set_color("font_selected_color", "TabBar", Color.WHITE)
	t.set_color("font_unselected_color", "TabBar", TEXT_PRIMARY)
	t.set_color("font_hovered_color", "TabBar", Color.WHITE)
	t.set_font_size("font_size", "TabBar", FONT_SIZE_TAB)
	t.set_constant("h_separation", "TabBar", 6)

	# --- Label (couleur par défaut lisible sur fond clair) ---
	t.set_color("font_color", "Label", TEXT_PRIMARY)

	# --- CheckBox (fond transparent : ne pas hériter du stylebox des boutons) ---
	var transp := _sb(Color.TRANSPARENT, 0)
	for st in ["normal", "hover", "pressed", "disabled", "hover_pressed", "focus"]:
		t.set_stylebox(st, "CheckBox", transp)
	# TOUS les états, y compris ceux qu'on n'a pas de raison de définir. Une couleur non
	# définie ne retombe pas sur celle du bouton voisin : elle retombe sur le thème par
	# DÉFAUT du moteur, taillé pour un fond sombre — donc presque blanche. Le libellé
	# devenait illisible sur fond blanc dès que la case prenait le focus, c'est-à-dire dès
	# qu'on la touchait.
	t.set_color("font_color", "CheckBox", TEXT_PRIMARY)
	t.set_color("font_hover_color", "CheckBox", PRIMARY_INK)
	t.set_color("font_pressed_color", "CheckBox", TEXT_PRIMARY)
	t.set_color("font_focus_color", "CheckBox", TEXT_PRIMARY)
	t.set_color("font_hover_pressed_color", "CheckBox", PRIMARY_INK)
	t.set_color("font_disabled_color", "CheckBox", TEXT_SECONDARY)

	# --- Tree (tableur liste de courses) ---
	t.set_stylebox("panel", "Tree", _sb(SURFACE, RADIUS_CARD))
	var tree_title := _sb(PRIMARY, 0)
	tree_title.content_margin_top = 7
	tree_title.content_margin_bottom = 7
	tree_title.content_margin_left = 6
	tree_title.content_margin_right = 6
	t.set_stylebox("title_button_normal", "Tree", tree_title)
	t.set_stylebox("title_button_hover", "Tree", tree_title)
	t.set_stylebox("title_button_pressed", "Tree", tree_title)
	t.set_color("title_button_color", "Tree", Color.WHITE)
	t.set_color("font_color", "Tree", TEXT_PRIMARY)
	t.set_color("font_selected_color", "Tree", TEXT_PRIMARY)
	t.set_stylebox("selected", "Tree", _sb(CELL_HOVER, 4))
	t.set_stylebox("selected_focus", "Tree", _sb(CELL_HOVER, 4))
	t.set_stylebox("cursor", "Tree", _sb(Color.TRANSPARENT, 4, 1, SECONDARY))
	t.set_stylebox("cursor_unfocused", "Tree", _sb(Color.TRANSPARENT, 4))
	t.set_constant("v_separation", "Tree", 6)

	# --- ScrollContainer / barres de défilement ---
	#
	# Elles n'étaient PAS habillées : seul le panneau du conteneur l'était, et Godot
	# retombait donc sur son thème par défaut — une glissière et un curseur gris ardoise,
	# les deux seules pièces de l'interface à ne descendre d'aucune charte. Elles sont
	# visibles sur presque tous les écrans.
	t.set_stylebox("panel", "ScrollContainer", _sb(Color.TRANSPARENT, 0))
	for bar in ["VScrollBar", "HScrollBar"]:
		var vertical: bool = bar == "VScrollBar"
		# Glissière : à peine teintée. Une barre de défilement indique une position, elle
		# n'a pas à peser autant que le contenu qu'elle accompagne.
		t.set_stylebox("scroll", bar, _bar(M3_SURFACE_VARIANT, vertical, 0.55))
		t.set_stylebox("scroll_focus", bar, _bar(M3_SURFACE_VARIANT, vertical, 0.55))
		t.set_stylebox("grabber", bar, _bar(M3_OUTLINE_VARIANT, vertical))
		t.set_stylebox("grabber_highlight", bar, _bar(SECONDARY, vertical))
		t.set_stylebox("grabber_pressed", bar, _bar(PRIMARY_INK, vertical))

	# --- SpinBox / HSlider ---
	#
	# Le curseur des parts de la fiche recette est arrivé en 1.9.0 avec, lui aussi, la
	# glissière grise du moteur.
	t.set_stylebox("slider", "HSlider", _bar(M3_SURFACE_VARIANT, false))
	t.set_stylebox("grabber_area", "HSlider", _bar(SECONDARY, false))
	t.set_stylebox("grabber_area_highlight", "HSlider", _bar(PRIMARY_INK, false))
	# Le BOUTON du curseur est une icône, et le thème ne remplace que des styleboxes : sans
	# celle-ci, il n'y avait rien à saisir à l'écran. On ne voyait qu'un rail rempli au
	# tiers, indiscernable d'une barre de progression — donc rien qui invite à le déplacer.
	var knob := _knob_texture(GRABBER_SIZE, PRIMARY_INK)
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", _knob_texture(GRABBER_SIZE, SECONDARY))
	t.set_icon("grabber_disabled", "HSlider", _knob_texture(GRABBER_SIZE, DISABLED_BG))

	# --- Fenêtres / popups (AcceptDialog, ConfirmationDialog héritent via la hiérarchie
	# de classes : pas besoin de les cibler séparément). Sans ceci, Godot retombe sur le
	# thème moteur par défaut (gris) pour le panneau et la bordure de fenêtre incrustée. ---
	# Angles droits : le panneau est serti dans le cadre de la fenêtre (cf. _window_border),
	# un arrondi y laisserait paraître le fond vert du cadre dans les coins.
	t.set_stylebox("panel", "AcceptDialog", _sb(SURFACE, 0))
	# --- Barre de titre des sous-fenêtres ---
	#
	# Godot dessine lui-même la barre de titre des fenêtres incrustées (les popups sont
	# des Window, et `embed_subwindows` vaut true). Elle était INVISIBLE : seul
	# `embedded_border` était défini, or une fenêtre qui n'a pas le focus utilise
	# `embedded_unfocused_border` — non défini, donc rien n'était peint et le titre
	# comme la croix se retrouvaient à même le contenu situé derrière.
	#
	# Fond vert de l'en-tête plutôt que SURFACE : sur un fond crème, un blanc cassé ne
	# se distinguait de toute façon presque pas.
	# La barre de titre est dessinée AU-DESSUS de la zone client, hors du rectangle de
	# la fenêtre. Sans marge d'expansion en haut, le stylebox ne peint que la zone
	# client et la bande de titre reste transparente : titre et croix se retrouvaient
	# tracés à même le contenu situé derrière, donc illisibles.
	var window_border := _window_border(PRIMARY)
	var window_border_unfocused := _window_border(SECONDARY)
	t.set_stylebox("embedded_border", "Window", window_border)
	t.set_stylebox("embedded_unfocused_border", "Window", window_border_unfocused)
	t.set_color("title_color", "Window", Color.WHITE)
	t.set_font_size("title_font_size", "Window", FONT_SIZE_WINDOW_TITLE)
	t.set_constant("title_height", "Window", WINDOW_TITLE_HEIGHT)

	return t

# ===== Police =====

## Charge Nunito depuis assets/fonts/ si les fichiers .ttf sont présents (à ajouter
## manuellement par l'utilisateur, licence OFL/Google Fonts). Repli silencieux sur la
## police système si absents — aucune autre action requise une fois les fichiers ajoutés.
##
## Les symboles de l'interface (✓ ✕ ⟳ ← → ▲ ▼ ▸ ▾ ◀ ▶) manquent à Nunito. Ailleurs, le système
## les fournit ; dans un navigateur Godot n'a accès à aucune police système, et ils sortaient en
## rectangles vides. D'où le repli explicite sur un extrait de DejaVu Sans réduit à ces plages.
func _load_warm_font() -> Font:
	const REGULAR := "res://assets/fonts/Nunito-Regular.ttf"
	const SYMBOLS := "res://assets/fonts/DejaVuSans-Symboles.ttf"
	if not ResourceLoader.exists(REGULAR):
		return null
	var font := load(REGULAR) as FontFile
	if font != null and ResourceLoader.exists(SYMBOLS) and font.fallbacks.is_empty():
		font.fallbacks = [load(SYMBOLS)]
	return font

# ===== Fabriques de styleboxes =====

## Diamètre du bouton d'un curseur, en pixels. Assez large pour être saisi au doigt sans
## viser, sans dépasser la hauteur d'une ligne de formulaire.
const GRABBER_SIZE := 22

## Pastille ronde du curseur : disque plein cerclé de blanc, dessinée à la volée. Une
## texture plutôt qu'un fichier — c'est une couleur de la charte, elle doit suivre la
## charte et non un PNG oublié dans les assets.
func _knob_texture(diameter: int, color: Color) -> ImageTexture:
	var image := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var center := (diameter - 1) * 0.5
	var radius := diameter * 0.5
	for y in range(diameter):
		for x in range(diameter):
			var distance := Vector2(x - center, y - center).length()
			if distance > radius - 0.5:
				continue
			# Anneau blanc au bord : sur le rail vert, un disque vert sans liseré ne se
			# détache pas de la portion déjà parcourue.
			image.set_pixel(x, y, Color.WHITE if distance > radius - 3.0 else color)
	return ImageTexture.create_from_image(image)

## Barre fine et arrondie : glissière ou curseur d'une barre de défilement, rail d'un
## curseur. `thickness` en unités ; l'épaisseur est portée par la marge de contenu, seule
## dimension qu'un StyleBox impose au contrôle.
func _bar(color: Color, vertical: bool, alpha := 1.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, alpha)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 0.0 if vertical else 4.0
	sb.content_margin_right = 0.0 if vertical else 4.0
	sb.content_margin_top = 4.0 if vertical else 0.0
	sb.content_margin_bottom = 4.0 if vertical else 0.0
	# Marge NÉGATIVE sur l'axe transversal : elle amincit la barre sans toucher à la
	# taille minimale du conteneur, que Godot déduit de la constante de thème.
	if vertical:
		sb.content_margin_left = 3.0
		sb.content_margin_right = 3.0
	else:
		sb.content_margin_top = 3.0
		sb.content_margin_bottom = 3.0
	return sb

func card_style() -> StyleBoxFlat:
	var sb := _sb(SURFACE, RADIUS_CARD)
	sb.set_content_margin_all(18)
	sb.shadow_size = 10
	sb.shadow_color = Color(0.1, 0.2, 0.1, 0.06)
	sb.shadow_offset = Vector2(0, 3)
	return sb

## Fond de fenêtre incrustée : la marge d'expansion supérieure couvre la barre de
## titre, les autres donnent une fine bordure autour du contenu.
## Épaisseur du liseré blanc qui détoure les popups. La barre de titre a la couleur exacte
## de l'en-tête de l'application : sans ce cadre, une popup ouverte en haut d'écran se
## fondait dans l'en-tête et ne se lisait plus comme une fenêtre posée par-dessus.
const WINDOW_FRAME_WIDTH := 2

func _window_border(bg: Color) -> StyleBoxFlat:
	# Le liseré occupe exactement la marge d'expansion latérale et basse : la zone client
	# ne bouge pas d'un pixel, le cadre se dessine autour d'elle.
	var sb := _sb(bg, RADIUS_CARD, WINDOW_FRAME_WIDTH, Color.WHITE)
	sb.expand_margin_top = WINDOW_TITLE_HEIGHT + WINDOW_FRAME_WIDTH
	sb.expand_margin_left = WINDOW_FRAME_WIDTH
	sb.expand_margin_right = WINDOW_FRAME_WIDTH
	sb.expand_margin_bottom = WINDOW_FRAME_WIDTH
	# Seule la barre de titre s'arrondit. En bas, le contenu des popups (un ColorRect plein
	# cadre) est à angles droits : un liseré arrondi le laissait dépasser dans les coins.
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	return sb

func _sb(bg: Color, radius: int, border_w: int = 0, border_col: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border_col
	return sb

## Anneau de focus clavier/manette — fond transparent, contour visible posé PAR-DESSUS
## le style normal/survolé/pressé (Godot dessine le stylebox "focus" en surcouche, il
## n'a pas à remplacer les autres). Sans lui, chaque variante de bouton posait un anneau
## `Color.TRANSPARENT` : rien ne distinguait le contrôle qui a le focus au clavier de
## celui qui ne l'a pas (2.0.0).
##
## Les marges de contenu doivent reprendre celles du gabarit de la variante — sinon la
## taille minimale du bouton change selon qu'il a le focus ou non, ce qui le fait
## visiblement « sauter » d'un pixel ou deux à la tabulation.
##
## Couleur : le primaire du thème en encre (2.0.12), et non plus l'accent. Celui-ci change
## de teinte d'un thème à l'autre sans rapport avec le primaire — vert d'eau dans le thème
## orange — et le cadre de focus jurait avec tout le reste de l'écran.
##
## Tracé 2 unités AU-DELÀ du contrôle (marge d'expansion) : de la couleur du primaire, un
## anneau posé SUR un bouton plein du même primaire y serait invisible. Décalé, il en reste
## séparé par un filet du fond, et se voit sur tout.
func _focus_ring(radius: int, color := Color(0, 0, 0, 0), margin_x: int = 16, margin_y: int = 9) -> StyleBoxFlat:
	var sb := _sb(Color.TRANSPARENT, radius + 2, 2, color if color.a > 0.0 else PRIMARY_INK)
	sb.set_expand_margin_all(2)
	sb.content_margin_left = margin_x
	sb.content_margin_right = margin_x
	sb.content_margin_top = margin_y
	sb.content_margin_bottom = margin_y
	return sb

func _btn(col: Color, radius: int = RADIUS) -> StyleBoxFlat:
	var sb := _sb(col, radius)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	return sb

## Stylebox de bouton (variantes) avec le MÊME gabarit que le primaire → hauteur identique.
func _btn_variant(bg: Color, border_w: int = 0, border_col: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := _sb(bg, RADIUS, border_w, border_col)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	return sb

func _field() -> StyleBoxFlat:
	var sb := _sb(SURFACE, RADIUS, 1, BORDER)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb

func _tab(col: Color) -> StyleBoxFlat:
	var sb := _sb(col, 0)
	sb.corner_radius_top_left = RADIUS
	sb.corner_radius_top_right = RADIUS
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

## Onglet compact (TabBar) — pilule/chip entièrement arrondie (catégories liste de courses).
func _tab_c(col: Color) -> StyleBoxFlat:
	var sb := _sb(col, 20)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb

## Stylebox d'un segment (contrôle segmenté).
## Pilule : rayon volontairement plus grand que la hauteur du bouton — Godot le ramène
## à la moitié de celle-ci, ce qui donne des bouts parfaitement ronds quelle que soit la
## taille de police.
func _pill(bg: Color, border_w: int = 0, border_col: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := _sb(bg, 999, border_w, border_col)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

func _seg(bg: Color) -> StyleBoxFlat:
	var sb := _sb(bg, 7)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb
