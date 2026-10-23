extends SceneTree
## Test de la fusion LWW, sans réseau : on injecte des lignes « distantes »
## synthétiques dans le moteur et on vérifie qui gagne.
##
## C'est la logique la plus risquée de la Phase 2, et la moins observable : une
## erreur d'arbitrage ne se voit pas sur un seul appareil, elle se manifeste par une
## perte silencieuse de données entre deux appareils, longtemps après.
##
## godot --headless --path . --script res://tools/test_sync_merge.gd

const Uuid := preload("res://services/Uuid.gd")

## Session de substitution : le moteur n'a besoin que de `user_id` pour composer
## l'owner_id des lignes poussées. Le reste du cycle (jetons, réseau) n'est pas
## sollicité ici, on teste l'arbitrage seul.
class StubSession:
	var user_id := "00000000-0000-4000-8000-0000000000aa"
	## Le cycle de sync complet n'est pas jouable hors réseau : les tests qui
	## l'atteignent doivent en sortir proprement plutôt que d'échouer.
	func is_configured() -> bool: return false

var _fails := 0
var _db: LocalDatabase
var _engine

func _initialize() -> void:
	_db = LocalDatabase.new()
	_db.open()
	# Instancié hors arbre : _ready ne s'exécute pas, on injecte la base à la main.
	_engine = load("res://services/SyncEngine.gd").new()
	_engine.setup(_db, StubSession.new())

	var raw = _db._db
	var backup := _backup(raw)

	_test_simple_row()
	_test_tombstone()
	_test_recipe_aggregate()
	_test_booleans()
	_test_duplicate_names()
	_test_seed_discard()
	_test_seed_aisles()
	_test_seed_categories()
	_test_duplicate_aisles()
	await _test_seed_decision()
	_test_account_switch()
	_test_future_state()

	_restore(raw, backup)

	print("")
	print("Tous les tests passent." if _fails == 0 else "%d test(s) en échec." % _fails)
	quit(1 if _fails > 0 else 0)

# =====================================================================

func _test_simple_row() -> void:
	print("--- Arbitrage LWW sur une ligne simple ---")
	var desc := {"table": "ingredients", "key": "id", "on_conflict": "id"}
	var id := Uuid.v4()

	var applied: bool = _engine._apply_remote_row(desc, {
		"id": id, "name": "Tofu distant", "aisle": "Frais",
		"updated_at": 2000, "deleted_at": null, "owner_id": "peu importe",
	})
	_check("ligne inconnue : insérée", applied)
	var row := _db.fetch_row("ingredients", "id", id)
	_check("nom écrit", row.get("name", "") == "Tofu distant")
	# Sans cela, tout ce qui est reçu repartirait au push suivant, en boucle.
	_check("ligne reçue marquée propre (dirty = 0)", int(row.get("dirty", 1)) == 0)
	_check("owner_id non recopié en local", not row.has("owner_id"))

	# Édition locale postérieure : elle doit résister à une version distante plus ancienne.
	raw_exec("UPDATE ingredients SET name='Tofu local', aisle='Picard', updated_at=3000, dirty=1 WHERE id=?;", [id])
	applied = _engine._apply_remote_row(desc, {
		"id": id, "name": "Tofu distant", "aisle": "Frais",
		"updated_at": 2500, "deleted_at": null,
	})
	_check("distant plus ancien : rejeté", not applied)
	_check("édition locale préservée",
		_db.fetch_row("ingredients", "id", id).get("name", "") == "Tofu local")

	applied = _engine._apply_remote_row(desc, {
		"id": id, "name": "Tofu plus récent", "aisle": "Frais",
		"updated_at": 4000, "deleted_at": null,
	})
	_check("distant plus récent : appliqué", applied)
	var after := _db.fetch_row("ingredients", "id", id)
	_check("valeur distante adoptée", after.get("name", "") == "Tofu plus récent")
	_check("la ligne n'est plus à pousser", int(after.get("dirty", 1)) == 0)

	# Égalité stricte : le serveur tranche, pour que tous les appareils convergent
	# sur la même valeur plutôt que de rester chacun sur la sienne.
	raw_exec("UPDATE ingredients SET name='Concurrent local', updated_at=5000, dirty=1 WHERE id=?;", [id])
	applied = _engine._apply_remote_row(desc, {
		"id": id, "name": "Concurrent distant", "aisle": "Frais",
		"updated_at": 5000, "deleted_at": null,
	})
	_check("égalité d'horodatage : le serveur l'emporte", applied)
	_check("valeur serveur adoptée",
		_db.fetch_row("ingredients", "id", id).get("name", "") == "Concurrent distant")

	raw_exec("DELETE FROM ingredients WHERE id=?;", [id])

func _test_tombstone() -> void:
	print("--- Propagation des suppressions ---")
	var desc := {"table": "staples", "key": "id", "on_conflict": "id"}
	var id := Uuid.v4()
	_engine._apply_remote_row(desc, {
		"id": id, "name": "Éponge", "aisle": "Ménage", "quantity": 1.0, "unit": "",
		"updated_at": 1000, "deleted_at": null,
	})
	_check("article présent", _db.fetch_all_staples().any(func(s): return s.id == id))

	var applied: bool = _engine._apply_remote_row(desc, {
		"id": id, "name": "Éponge", "aisle": "Ménage", "quantity": 1.0, "unit": "",
		"updated_at": 2000, "deleted_at": 2000,
	})
	_check("tombstone distant appliqué", applied)
	_check("article disparu des lectures",
		not _db.fetch_all_staples().any(func(s): return s.id == id))
	_check("la ligne subsiste en base (tombstone, pas effacement)",
		not _db.fetch_row("staples", "id", id).is_empty())

	# Une réédition postérieure à la suppression doit ressusciter la ligne (§3.4.1).
	applied = _engine._apply_remote_row(desc, {
		"id": id, "name": "Éponge verte", "aisle": "Ménage", "quantity": 2.0, "unit": "",
		"updated_at": 3000, "deleted_at": null,
	})
	_check("édition postérieure : la ligne ressuscite",
		applied and _db.fetch_all_staples().any(func(s): return s.id == id))
	raw_exec("DELETE FROM staples WHERE id=?;", [id])

func _test_recipe_aggregate() -> void:
	print("--- Recette : agrégat et catégories par nom ---")
	var desc := {"table": "recipes", "key": "id", "on_conflict": "id",
		"bools": ["nobox"], "aggregate": "recipe"}

	var ing_id := Uuid.v4()
	_engine._apply_remote_row({"table": "ingredients", "key": "id"}, {
		"id": ing_id, "name": "Pois chiches distants", "aisle": "Divers",
		"updated_at": 1000, "deleted_at": null,
	})

	var recipe_id := Uuid.v4()
	_engine._apply_remote_row(desc, {
		"id": recipe_id, "name": "Houmous distant", "season": "toute", "nobox": true,
		"steps": "Mixer.", "updated_at": 2000, "deleted_at": null,
		"ingredients": [{"ingredient_id": ing_id, "quantity": 400.0, "unit": "g"}],
		"categories": ["Légumineuses"],
	})

	var recipe := _db.fetch_recipe_by_name("Houmous distant")
	_check("recette créée", recipe != null)
	_check("ingrédient de l'agrégat relié",
		recipe != null and recipe.ingredients.size() == 1
		and recipe.ingredients[0].nom == "Pois chiches distants"
		and recipe.ingredients[0].quantite == 400.0)
	# Les catégories voyagent par nom : « Légumineuses » existe déjà localement avec
	# un autre UUID, la recette doit s'y rattacher plutôt que d'en créer une seconde.
	_check("catégorie résolue par nom",
		recipe != null and recipe.categories.has("Légumineuses"))
	raw_exec("SELECT COUNT(*) AS n FROM categories WHERE name='Légumineuses' AND deleted_at IS NULL;", [])
	_check("aucune catégorie dupliquée", int(_db._db.query_result[0]["n"]) == 1)

	# Remplacement de l'agrégat : les anciens liens doivent disparaître.
	_engine._apply_remote_row(desc, {
		"id": recipe_id, "name": "Houmous distant", "season": "toute", "nobox": false,
		"steps": "Mixer longuement.", "updated_at": 3000, "deleted_at": null,
		"ingredients": [], "categories": [],
	})
	recipe = _db.fetch_recipe_by_name("Houmous distant")
	_check("agrégat remplacé, liens purgés",
		recipe != null and recipe.ingredients.is_empty() and recipe.categories.is_empty())

	raw_exec("DELETE FROM recipe_ingredients WHERE recipe_id=?;", [recipe_id])
	raw_exec("DELETE FROM recipe_categories WHERE recipe_id=?;", [recipe_id])
	raw_exec("DELETE FROM recipes WHERE id=?;", [recipe_id])
	raw_exec("DELETE FROM ingredients WHERE id=?;", [ing_id])

func _test_booleans() -> void:
	print("--- Conversion des booléens (Postgres ↔ SQLite) ---")
	var desc := {"table": "shopping_items", "key": "item_key",
		"on_conflict": "owner_id,item_key", "bools": ["checked"]}
	_engine._apply_remote_row(desc, {
		"item_key": "zzz-test||kg", "name": "Article test", "aisle": "Divers",
		"quantity": 1.0, "unit": "kg", "checked": true,
		"updated_at": 1000, "deleted_at": null,
	})
	var row := _db.fetch_row("shopping_items", "item_key", "zzz-test||kg")
	# SQLite n'a pas de type booléen : true doit devenir 1, sinon la lecture renvoie 0.
	_check("booléen distant true → 1 en local", int(row.get("checked", -1)) == 1)

	var payload: Dictionary = _engine._remote_row_from_local(desc, row)
	_check("booléen local 1 → true au push", payload.get("checked") == true)
	_check("colonne dirty non envoyée au serveur", not payload.has("dirty"))
	raw_exec("DELETE FROM shopping_items WHERE item_key='zzz-test||kg';", [])

func _test_duplicate_names() -> void:
	print("--- Homonymes créés en parallèle sur deux appareils ---")
	# Scénario : deux appareils hors-ligne créent chacun « Yuzu » avec un UUID
	# différent. Les deux lignes arrivent en base ; sans réconciliation, l'ingrédient
	# apparaîtrait deux fois dans toutes les listes.
	var id_a := "00000000-0000-4000-8000-00000000aaaa"
	var id_b := "ffffffff-0000-4000-8000-00000000bbbb"
	raw_exec("INSERT INTO ingredients (id, name, aisle, updated_at, dirty) VALUES (?, 'Yuzu', 'Frais', 1000, 0);", [id_a])
	raw_exec("INSERT INTO ingredients (id, name, aisle, updated_at, dirty) VALUES (?, 'Yuzu', 'Asiatique', 2000, 0);", [id_b])

	var recipe_id := Uuid.v4()
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Recette Yuzu', 1000, 0);", [recipe_id])
	raw_exec("INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit) VALUES (?, ?, 1, '');", [recipe_id, id_b])

	var merged: int = _db.merge_duplicate_ingredients()
	_check("un doublon résorbé", merged == 1)
	# Le plus petit UUID gagne : règle arbitraire mais identique sur tous les
	# appareils, donc tous convergent sans se concerter.
	_check("le plus petit UUID est conservé",
		_db.fetch_row("ingredients", "id", id_a).get("deleted_at") == null)
	_check("l'autre est tombstoné",
		_db.fetch_row("ingredients", "id", id_b).get("deleted_at") != null)
	# Sans repointage, la recette perdrait cet ingrédient (la lecture passe par une jointure).
	var recipe := _db.fetch_recipe_by_name("ZZZ Recette Yuzu")
	_check("les références sont repointées vers le gagnant",
		recipe != null and recipe.ingredients.size() == 1 and recipe.ingredients[0].id == id_a)

	raw_exec("DELETE FROM recipe_ingredients WHERE recipe_id=?;", [recipe_id])
	raw_exec("DELETE FROM recipes WHERE id=?;", [recipe_id])
	raw_exec("DELETE FROM ingredients WHERE id IN (?, ?);", [id_a, id_b])

func _test_seed_discard() -> void:
	print("--- Abandon du jeu d'exemple à l'arrivée des données du compte ---")
	# Scénario : installation neuve. L'app sème son jeu d'exemple, puis l'utilisateur
	# se connecte à un compte qui contient déjà des recettes. Sans abandon du seed,
	# tout apparaîtrait en double — et les exemplaires semés seraient poussés,
	# contaminant les autres appareils.
	var saved_stamp := _db.get_sync_meta("seed_stamp", "0")
	var stamp := 1700000000000
	_db.set_sync_meta("seed_stamp", str(stamp))

	var seeded := Uuid.v4()
	var edited := Uuid.v4()
	var own := Uuid.v4()
	var ing := Uuid.v4()
	raw_exec("INSERT INTO ingredients (id, name, aisle, updated_at, dirty) VALUES (?, 'ZZZ ing exemple', 'Divers', ?, 1);", [ing, stamp])
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Exemple intact', ?, 1);", [seeded, stamp])
	raw_exec("INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity, unit) VALUES (?, ?, 1, '');", [seeded, ing])
	# Recette d'exemple retouchée par l'utilisateur : horodatage postérieur.
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Exemple modifié', ?, 1);", [edited, stamp + 5000])
	# Recette créée par l'utilisateur avant de se connecter.
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Recette perso', ?, 1);", [own, stamp + 90000])

	_check("le seed est signalé comme en attente", _db.has_pending_seed())

	# Une ligne distante arrive : c'est le déclencheur.
	_engine._seed_discard_armed = true
	_engine._apply_remote_row({"table": "recipes", "key": "id", "bools": ["nobox"], "aggregate": "recipe"}, {
		"id": Uuid.v4(), "name": "ZZZ Recette du compte", "season": "toute", "nobox": false,
		"steps": "", "updated_at": stamp + 200000, "deleted_at": null,
		"ingredients": [], "categories": [],
	})

	_check("l'exemple intact est supprimé",
		_db.fetch_row("recipes", "id", seeded).is_empty())
	_check("ses liens d'ingrédients aussi",
		_db.fetch_recipe_ingredient_links(seeded).is_empty())
	_check("l'ingrédient d'exemple est supprimé",
		_db.fetch_row("ingredients", "id", ing).is_empty())
	# Ce que l'utilisateur a touché lui appartient : cela doit survivre et être poussé.
	_check("l'exemple MODIFIÉ par l'utilisateur survit",
		not _db.fetch_row("recipes", "id", edited).is_empty())
	_check("la recette créée par l'utilisateur survit",
		not _db.fetch_row("recipes", "id", own).is_empty())
	_check("la recette du compte est bien arrivée",
		_db.fetch_recipe_by_name("ZZZ Recette du compte") != null)
	_check("le seed n'est plus en attente", not _db.has_pending_seed())

	# Suppression sèche et non tombstone : ces lignes n'ont jamais existé côté serveur.
	raw_exec("SELECT COUNT(*) AS n FROM recipes WHERE name='ZZZ Exemple intact';", [])
	_check("aucun tombstone laissé derrière", int(_db._db.query_result[0]["n"]) == 0)

	_test_seed_derivatives(stamp)

	raw_exec("DELETE FROM recipes WHERE name LIKE 'ZZZ %';", [])
	raw_exec("DELETE FROM ingredients WHERE name LIKE 'ZZZ %';", [])
	_db.set_sync_meta("seed_stamp", saved_stamp)

## Les rayons semés doivent partir comme le reste du jeu d'exemple.
##
## Ils ne le faisaient pas : `aisles` est né en 1.1, après l'écriture de l'abandon du
## seed, et n'avait jamais été ajouté à sa liste de tables. Un appareil qui se
## connectait gardait donc les dix rayons par défaut EN PLUS de ceux du compte, puis
## les poussait — les répandant sur tous les autres appareils. Constaté en vrai.
## Les rayons du jeu d'exemple partent EN DEUX TEMPS, et c'est tout l'objet de ce test.
##
## Leur garde-fou — ne les retirer que si le compte en apporte d'autres — protège d'un
## serveur au schéma antérieur à la 1.1, qui ne renvoie aucun rayon : les effacer
## laisserait l'appareil sans aucun rayon et toute la liste de courses sous « Autres ».
##
## Mais `discard_seed_rows()` est déclenché par la PREMIÈRE ligne reçue du cycle, donc
## pendant le pull de `categories`, alors qu'`aisles` n'a pas encore été demandé. La
## condition était donc toujours fausse sur une installation neuve : les dix rayons
## d'exemple survivaient à chaque connexion, et la fusion des homonymes les mettait en
## tombstone juste après pour les pousser au compte. Dix lignes inutiles par appareil,
## à chaque fois.
func _test_seed_aisles() -> void:
	print("--- Les rayons du jeu d'exemple partent avec lui, mais plus tard ---")
	var saved_stamp := _db.get_sync_meta("seed_stamp", "0")
	var stamp := 1700000000000
	_db.set_sync_meta("seed_stamp", str(stamp))

	var seeded := Uuid.v4()
	raw_exec("INSERT INTO aisles (id, name, sort_order, updated_at, dirty) VALUES (?, 'ZZZ Rayon exemple', 90, ?, 1);", [seeded, stamp])
	# Ingrédient saisi par l'utilisateur AVANT la connexion, rangé dans un rayon
	# d'exemple : il survit, mais son rayon disparaît sous lui.
	raw_exec("INSERT INTO ingredients (id, name, aisle, updated_at, dirty) VALUES (?, 'ZZZ Ing perso', 'ZZZ Rayon exemple', ?, 1);", [Uuid.v4(), stamp + 90000])

	# Premier temps : le compte n'a encore livré aucun rayon — c'est l'état réel au
	# moment où l'écartement se déclenche.
	_db.discard_seed_rows()
	_check("le rayon d'exemple survit au premier temps",
		not _db.fetch_row("aisles", "id", seeded).is_empty())

	# Second temps, après le pull : les rayons du compte sont là.
	var from_account := Uuid.v4()
	raw_exec("INSERT INTO aisles (id, name, sort_order, updated_at, dirty) VALUES (?, 'ZZZ Rayon du compte', 91, ?, 0);", [from_account, stamp + 200000])
	_db.discard_seed_aisles()

	_check("le rayon d'exemple est supprimé",
		_db.fetch_row("aisles", "id", seeded).is_empty())
	_check("le rayon du compte survit",
		not _db.fetch_row("aisles", "id", from_account).is_empty())
	# Sans rattachement, il sortirait de la liste de courses, qui groupe par rayon.
	_check("l'ingrédient orphelin retombe sur le repli",
		_scalar("SELECT aisle FROM ingredients WHERE name='ZZZ Ing perso';") == _db.FALLBACK_AISLE)
	_check("le rayon de repli existe toujours",
		int(_scalar("SELECT COUNT(*) AS n FROM aisles WHERE name='%s' AND deleted_at IS NULL;" % _db.FALLBACK_AISLE)) >= 1)
	# Une seule tentative : le compte n'apportera pas plus de rayons au cycle suivant.
	_check("l'attente est consommée",
		_db.get_sync_meta(_db.SEED_AISLES_KEY, "0") == "0")

	# Garde-fou : compte sans aucun rayon, rien ne doit être effacé.
	_db.set_sync_meta("seed_stamp", str(stamp))
	raw_exec("UPDATE aisles SET updated_at = ?, dirty = 1 WHERE deleted_at IS NULL;", [stamp])
	var before := int(_scalar("SELECT COUNT(*) AS n FROM aisles WHERE deleted_at IS NULL;"))
	_db.discard_seed_rows()
	_db.discard_seed_aisles()
	_check("aucun rayon effacé si le compte n'en apporte aucun",
		int(_scalar("SELECT COUNT(*) AS n FROM aisles WHERE deleted_at IS NULL;")) == before)

	raw_exec("DELETE FROM aisles WHERE name LIKE 'ZZZ %';", [])
	raw_exec("DELETE FROM ingredients WHERE name LIKE 'ZZZ %';", [])
	_db.set_sync_meta("seed_stamp", saved_stamp)

## Les catégories d'exemple doivent porter l'horodatage du semis, sans quoi rien ne les
## distingue de celles que l'utilisateur a créées lui-même.
##
## `_category_id()` appelait `_now()` pour son propre compte, quelques dizaines de
## millisecondes après le `seed_stamp` mémorisé en meta. `discard_seed_rows()` reconnaît
## une ligne d'exemple à l'égalité STRICTE de son `updated_at` avec ce stamp : il n'en
## voyait donc aucune. Les huit catégories d'exemple survivaient à chaque connexion, se
## retrouvaient en doublon avec celles du compte, et la fusion tranchait par le plus petit
## id — une fois sur deux c'est la ligne DU COMPTE qui perdait, mise en tombstone et
## remplacée par celle de l'appareil neuf. Relevé sur le compte de test : 3 catégories
## légitimes supprimées sur 8.
func _test_seed_categories() -> void:
	print("--- Les catégories d'exemple portent la marque du semis ---")
	var saved_stamp := _db.get_sync_meta("seed_stamp", "0")
	var stamp := 1700000000000
	_db.set_sync_meta("seed_stamp", str(stamp))

	var seeded: String = _db._category_id("ZZZ Cat exemple", stamp)
	_check("une catégorie semée porte l'horodatage du semis",
		int(_scalar("SELECT updated_at FROM categories WHERE id='%s';" % seeded)) == stamp)

	# Sans stamp, c'est une création de l'utilisateur : elle ne doit PAS être reconnue.
	var mine: String = _db._category_id("ZZZ Cat perso")
	_check("une catégorie créée à la main ne l'est pas",
		int(_scalar("SELECT updated_at FROM categories WHERE id='%s';" % mine)) != stamp)

	_db.discard_seed_rows()
	_check("la catégorie d'exemple est écartée",
		_db.fetch_row("categories", "id", seeded).is_empty())
	_check("celle de l'utilisateur survit",
		not _db.fetch_row("categories", "id", mine).is_empty())

	raw_exec("DELETE FROM categories WHERE name LIKE 'ZZZ %';", [])
	_db.set_sync_meta("seed_stamp", saved_stamp)

## Deux rayons de même nom — l'un semé, l'autre venu du compte — doivent fusionner.
## La réconciliation des homonymes ne couvrait qu'`ingredients` et `categories` : le
## « Frais » en double restait à l'écran indéfiniment.
func _test_duplicate_aisles() -> void:
	print("--- Rayons homonymes ---")
	var from_account := Uuid.v4()
	var seeded := Uuid.v4()
	raw_exec("INSERT INTO aisles (id, name, sort_order, updated_at, dirty) VALUES (?, 'ZZZ Frais', 2, 5000, 0);", [from_account])
	raw_exec("INSERT INTO aisles (id, name, sort_order, updated_at, dirty) VALUES (?, 'ZZZ Frais', 40, 4000, 1);", [seeded])

	var merged: int = _db.merge_duplicate_aisles()

	_check("un doublon résorbé", merged == 1)
	_check("il ne reste qu'un « ZZZ Frais »",
		int(_scalar("SELECT COUNT(*) AS n FROM aisles WHERE name='ZZZ Frais' AND deleted_at IS NULL;")) == 1)
	# Le survivant doit être celui du compte : c'est SON rang de parcours que
	# l'utilisateur a choisi en réordonnant ses rayons.
	_check("le rayon du compte est le survivant",
		_db.fetch_row("aisles", "id", from_account).get("deleted_at") == null)
	_check("le doublon local est tombstoné, donc propageable",
		int(_db.fetch_row("aisles", "id", seeded).get("dirty", 0)) == 1)

	raw_exec("DELETE FROM aisles WHERE name LIKE 'ZZZ %';", [])

func _test_seed_decision() -> void:
	print("--- Compte vierge : décision de l'utilisateur sur le jeu d'exemple ---")
	# Un compte vierge ne doit RIEN décider tout seul : adopter les recettes
	# d'exemple engage le compte sur tous ses futurs appareils.
	var saved_stamp := _db.get_sync_meta("seed_stamp", "0")
	var stamp := 1700000000000

	# --- Branche « garder » ---
	_db.set_sync_meta("seed_stamp", str(stamp))
	var kept := Uuid.v4()
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Exemple gardé', ?, 1);", [kept, stamp])
	await _engine.resolve_seed_decision(true)
	_check("« garder » : la recette d'exemple est conservée",
		not _db.fetch_row("recipes", "id", kept).is_empty())
	_check("« garder » : elle reste à pousser sur le compte",
		int(_db.fetch_row("recipes", "id", kept).get("dirty", 0)) == 1)
	# Le seed est devenu la collection de l'utilisateur : plus jamais candidat à
	# une suppression automatique, même bien plus tard.
	_check("« garder » : l'abandon est désarmé", not _db.has_pending_seed())

	# --- Branche « base vierge » ---
	_db.set_sync_meta("seed_stamp", str(stamp))
	var dropped := Uuid.v4()
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Exemple jeté', ?, 1);", [dropped, stamp])
	await _engine.resolve_seed_decision(false)
	_check("« base vierge » : la recette d'exemple est supprimée",
		_db.fetch_row("recipes", "id", dropped).is_empty())
	_check("« base vierge » : l'abandon est désarmé", not _db.has_pending_seed())

	raw_exec("DELETE FROM recipes WHERE name LIKE 'ZZZ %';", [])
	_db.set_sync_meta("seed_stamp", saved_stamp)

## Ce qui DÉCOULE du jeu d'exemple doit partir avec lui.
##
## Une liste de courses générée avant connexion contient les ingrédients du jeu
## d'exemple ; sans ce nettoyage elle survivait à l'abandon et partait polluer le
## compte, où elle se répliquait sur tous les appareils. C'est exactement ce qui
## s'est produit en conditions réelles.
func _test_seed_derivatives(stamp: int) -> void:
	print("--- Ce qui découle du jeu d'exemple part avec lui ---")
	_db.set_sync_meta("seed_stamp", str(stamp))

	var seeded_ing := Uuid.v4()
	var seeded_recipe := Uuid.v4()
	raw_exec("INSERT INTO ingredients (id, name, aisle, updated_at, dirty) VALUES (?, 'ZZZ Curry exemple', 'Divers', ?, 1);", [seeded_ing, stamp])
	raw_exec("INSERT INTO recipes (id, name, updated_at, dirty) VALUES (?, 'ZZZ Plat exemple', ?, 1);", [seeded_recipe, stamp])

	# Dérivés : produits plus tard, ils ne portent donc PAS l'horodatage de semis.
	raw_exec("INSERT INTO shopping_items (item_key, name, aisle, quantity, unit, checked, updated_at, dirty) VALUES ('zzz-curry||', 'ZZZ Curry exemple', 'Divers', 1, '', 0, ?, 1);", [stamp + 90000])
	raw_exec("INSERT INTO shopping_items (item_key, name, aisle, quantity, unit, checked, updated_at, dirty) VALUES ('zzz-perso||', 'ZZZ Article perso', 'Divers', 1, '', 0, ?, 1);", [stamp + 90000])
	raw_exec("INSERT INTO meal_plan_positions (position_index, recipe_id, custom_label, updated_at, dirty) VALUES (11, ?, '', ?, 1);", [seeded_recipe, stamp + 90000])

	_db.discard_seed_rows()

	raw_exec("SELECT COUNT(*) AS n FROM shopping_items WHERE item_key='zzz-curry||';", [])
	_check("l'article issu d'un ingrédient d'exemple est retiré", int(_db._db.query_result[0]["n"]) == 0)
	# Ce que l'utilisateur a saisi lui-même avant de se connecter doit survivre.
	raw_exec("SELECT COUNT(*) AS n FROM shopping_items WHERE item_key='zzz-perso||';", [])
	_check("l'article ajouté par l'utilisateur survit", int(_db._db.query_result[0]["n"]) == 1)
	raw_exec("SELECT COUNT(*) AS n FROM meal_plan_positions WHERE position_index=11;", [])
	_check("la case pointant une recette d'exemple est retirée", int(_db._db.query_result[0]["n"]) == 0)

	raw_exec("DELETE FROM shopping_items WHERE item_key LIKE 'zzz-%';", [])
	raw_exec("DELETE FROM recipes WHERE name LIKE 'ZZZ %';", [])
	raw_exec("DELETE FROM ingredients WHERE name LIKE 'ZZZ %';", [])

# =====================================================================

## Première colonne de la première ligne, en texte — pour les COUNT et les lectures
## d'une seule valeur.
func _scalar(sql: String) -> String:
	_db._db.query(sql)
	if _db._db.query_result.is_empty():
		return "<aucune ligne>"
	return str(_db._db.query_result[0].values()[0])

func raw_exec(sql: String, bindings: Array) -> void:
	if bindings.is_empty():
		_db._db.query(sql)
	else:
		_db._db.query_with_bindings(sql, bindings)

## Une base locale n'appartient qu'à UN compte.
##
## Rien ne le vérifiait : `sign_out()` efface la session sans toucher à la base, et
## `sign_in()` ne compare rien. Une base ayant servi à deux comptes accumulait leurs
## lignes — 48 catégories pour 8 noms sur le poste de développement. Comme aucune table
## locale ne porte de propriétaire, `merge_duplicate_*` résorbait ensuite les homonymes à
## travers les comptes et poussait des tombstones visant les lignes d'autrui : refusées
## par la RLS dans le meilleur des cas, appliquées dans le pire — une suppression
## silencieuse chez un compte tiers.
##
## C'est le pire défaut possible pour ce projet : invisible sur un appareil, il détruit
## des données sur un autre, longtemps après. D'où cette vérification.
func _test_account_switch() -> void:
	print("--- Une base = un compte ---")
	var raw = _db._db
	var a := "00000000-0000-4000-8000-00000000aaaa"
	var b := "00000000-0000-4000-8000-00000000bbbb"

	# Base réputée appartenir au compte A, avec une recette et un curseur avancé.
	_db.set_sync_meta("account_id", a)
	_db.set_sync_meta("sync_cursor_recipes", "123456789")
	var doomed := Uuid.v4()
	raw.query_with_bindings(
		"INSERT INTO recipes (id, name, season, nobox, steps, updated_at, dirty) VALUES (?, ?, 'toute', 0, '', ?, 0);",
		[doomed, "ZZZ Recette du compte A", 123456789])

	_check("le même compte ne déclenche rien", not _db.claim_account(a))
	_check("  et la recette est toujours là", not _db.fetch_row("recipes", "id", doomed).is_empty())

	# Changement de compte : remise à neuf.
	_check("un autre compte remet la base à neuf", _db.claim_account(b))
	_check("  la recette de l'ancien compte est partie",
		_db.fetch_row("recipes", "id", doomed).is_empty())
	_check("  la base est rattachée au nouveau compte",
		_db.get_sync_meta("account_id", "") == b)
	# Le curseur DOIT repartir de zéro : conservé, le premier pull ne demanderait que les
	# lignes plus récentes que le dernier passage de l'ancien compte, et tout ce que le
	# nouveau contient déjà resterait invisible — une base vide, sans erreur.
	_check("  les curseurs de sync sont remis à zéro",
		_db.get_sync_meta("sync_cursor_recipes", "0") == "0")
	# Sans rayons, toute la liste de courses tomberait sous « Autres ».
	_check("  le jeu d'exemple est réarmé", _db.has_pending_seed())
	raw.query("SELECT COUNT(*) AS n FROM aisles;")
	_check("  les rayons par défaut sont revenus", int(raw.query_result[0]["n"]) > 0)
	raw.query("SELECT COUNT(*) AS n FROM recipes;")
	_check("  et les recettes d'exemple aussi", int(raw.query_result[0]["n"]) > 0)

	# Base sans marqueur — celles d'avant cette version : on ne peut pas savoir à qui
	# elles appartiennent, elles sont donc adoptées sans rien jeter.
	_db.set_sync_meta("account_id", "")
	raw.query("SELECT COUNT(*) AS n FROM recipes;")
	var before := int(raw.query_result[0]["n"])
	_check("une base sans marqueur est adoptée telle quelle", not _db.claim_account(a))
	raw.query("SELECT COUNT(*) AS n FROM recipes;")
	_check("  rien n'a été jeté", int(raw.query_result[0]["n"]) == before)

func _backup(raw) -> Dictionary:
	var out := {}
	for t in ["meal_plan_positions", "shopping_items", "breakfast_slots"]:
		raw.query("SELECT * FROM %s;" % t)
		out[t] = raw.query_result.duplicate(true)
	return out

func _restore(raw, backup: Dictionary) -> void:
	for t in backup.keys():
		raw.query("DELETE FROM %s;" % t)
		for row in backup[t]:
			var columns: Array = row.keys()
			var placeholders := ",".join(columns.map(func(_c): return "?"))
			raw.query_with_bindings(
				"INSERT INTO %s (%s) VALUES (%s);" % [t, ",".join(columns), placeholders],
				row.values())

func _check(label: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print("  [%s] %s" % ["OK" if ok else "ÉCHEC", label])

func _test_future_state() -> void:
	print("--- État local daté dans le futur ---")
	var id := Uuid.v4()
	var future: int = _db._now() + 10 * 3600000
	_db._db.query_with_bindings(
		"INSERT INTO staples (id, name, aisle, quantity, unit, updated_at, dirty) VALUES (?, 'Futur', 'Autres', 1, '', ?, 0);",
		[id, future])
	_db.set_sync_meta("sync_cursor_recipes", str(future))
	_engine._heal_future_state()
	var row := _db.fetch_row("staples", "id", id)
	_check("ligne future ramenée à l'heure actuelle", int(row.get("updated_at", future)) < future)
	_check("ligne guérie repart dirty", int(row.get("dirty", 0)) == 1)
	_check("curseur futur remis à zéro", _db.get_sync_meta("sync_cursor_recipes", "x") == "0")
