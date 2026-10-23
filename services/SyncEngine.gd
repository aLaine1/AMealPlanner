extends Node
## Synchronisation local ↔ Supabase, en Last-Write-Wins par ligne (plan §3.4.1).
##
## ===== Principe =====
##
## La base SQLite locale est la **source de vérité** : l'app fonctionne intégralement
## sans réseau, et Supabase n'est qu'un point de rendez-vous entre les appareils du
## foyer. Une sync est donc toujours facultative et jamais bloquante.
##
## Un cycle = **pull puis push** :
##  1. on tire les lignes dont `updated_at` dépasse le curseur de la table ;
##  2. chaque ligne distante est confrontée à sa contrepartie locale, la plus
##     récemment ÉDITÉE l'emporte (horodatage posé au moment de l'édition sur
##     l'appareil, pas au moment de la sync) ;
##  3. on pousse ensuite tout ce qui est encore marqué `dirty` — c'est-à-dire les
##     éditions locales qui ont survécu à l'étape 2.
##
## Pull avant push : on part de la vue la plus fraîche, et une édition locale battue
## par une version distante plus récente n'est jamais renvoyée inutilement.
##
## ===== Déclenchement (depuis la 1.10.0) =====
##
## Trois chemins mènent à un cycle, du plus rapide au plus lent :
##  1. `RealtimeClient` — notification poussée par Supabase (Postgres Changes) dès qu'un
##     AUTRE appareil modifie une ligne du compte. C'est lui qui donne la réactivité perçue.
##  2. `_on_local_change` → `PUSH_DEBOUNCE_S` — une écriture LOCALE programme un envoi
##     rapproché, pour que ce QU'ON vient de modifier parte sans attendre.
##  3. `_on_probe` (`PROBE_INTERVAL_S`) et `AUTO_SYNC_INTERVAL_S` — repli de secours si
##     Realtime est indisponible (réseau qui bloque les websockets, ou table pas encore
##     ajoutée à la publication côté projet). Sans lui, une panne de Realtime rendrait la
##     sync aussi lente qu'avant la 1.10.0 sans que rien ne le signale.
##
## ===== Ordre des tables =====
##
## `categories` et `ingredients` sont traitées AVANT `recipes` et `breakfasts`.
## Côté serveur l'ordre est indifférent (aucune contrainte de clé étrangère,
## délibérément), mais en local une recette dont les ingrédients ne sont pas encore
## arrivés perdrait silencieusement ces ingrédients : la lecture d'une recette passe
## par une jointure, qui écarte sans bruit les liens orphelins.
##
## ===== Égalité d'horodatage =====
##
## À `updated_at` strictement égal, **le serveur l'emporte**. C'est une règle
## déterministe : tous les appareils adoptent la même valeur et convergent, là où
## « le local gagne » les ferait diverger durablement chacun sur sa version.

const SYNC_TABLES := [
	{"table": "categories", "key": "id", "on_conflict": "owner_id,id"},
	# Avant les ingrédients : ceux-ci référencent un rayon par son nom, et une liste de
	# courses reçue avant ses rayons afficherait brièvement des articles regroupés
	# sous « Autres ».
	{"table": "aisles", "key": "id", "on_conflict": "owner_id,id"},
	{"table": "ingredients", "key": "id", "on_conflict": "owner_id,id"},
	{"table": "recipes", "key": "id", "on_conflict": "owner_id,id",
		"bools": ["nobox"], "aggregate": "recipe"},
	{"table": "breakfasts", "key": "id", "on_conflict": "owner_id,id",
		"aggregate": "breakfast"},
	# Après les recettes : une photo qui arriverait avant la sienne serait rattachée à
	# une recette encore inconnue, donc invisible jusqu'au cycle suivant.
	{"table": "recipe_photos", "key": "recipe_id", "on_conflict": "owner_id,recipe_id"},
	{"table": "staples", "key": "id", "on_conflict": "owner_id,id"},
	# Avant le planning : les cases réservées conditionnent son affichage.
	{"table": "settings", "key": "key", "on_conflict": "owner_id,key"},
	# Clé locale à DEUX colonnes depuis la 1.8 : un jour peut porter deux repas. Le jour garde
	# son numéro, le repas s'ajoute à côté — c'est ce qui permet d'activer le second repas sans
	# renuméroter le planning déjà enregistré.
	{"table": "meal_plan_positions", "key": "position_index,meal_slot",
		"on_conflict": "owner_id,position_index,meal_slot"},
	{"table": "breakfast_slots", "key": "slot", "on_conflict": "owner_id,slot"},
	{"table": "shopping_items", "key": "item_key", "on_conflict": "owner_id,item_key",
		"bools": ["checked"]},
]

## Le script de Session est préchargé pour son enum Status : les identifiants
## d'autoload ne sont pas résolus à la compilation en mode --script, ce qui rendrait
## le moteur intestable en headless.
const SessionScript := preload("res://autoload/Session.gd")
const RealtimeClientScript := preload("res://services/RealtimeClient.gd")

## Tolérance au-delà de laquelle un `updated_at` distant est traité comme corrompu plutôt
## que comme une simple différence d'horloge entre appareils.
##
## Trouvé en reproduisant le symptôme « impossible de modifier le planning sur Windows »
## contre un vrai compte : une ligne dont l'horodatage a été poussé dans le futur (horloge
## d'un appareil déréglée au moment de l'écriture, `clock_offset_ms` mesuré une seule fois
## par session dans `Session._measure_clock_offset()`) gagne le LWW indéfiniment — aucun
## appareil à l'horloge correcte ne peut plus jamais la dépasser. PIRE : le CURSEUR de
## synchronisation de la table (`max_seen` dans `_pull_table`) avance sur ce même horodatage
## corrompu, ce qui rend alors invisibles TOUTES les éditions légitimes suivantes de la
## table sur tous les appareils, pas seulement la ligne touchée.
##
## On traite donc tout horodatage distant dépassant l'horloge locale corrigée de plus d'une
## heure comme corrompu : il est ramené à l'heure locale, à la fois pour la comparaison LWW
## et pour l'avancement du curseur, et la ligne corrigée repart `dirty = 1` pour propager le
## correctif aux autres appareils — ce qui guérit une ligne déjà corrompue au premier appareil
## sain qui la pousse.
const MAX_FUTURE_DRIFT_MS := 3600000

enum State { IDLE, RUNNING, OFFLINE, ERROR }

signal state_changed(state: State)
## Émis quand l'appareil se connecte à un compte VIERGE alors qu'il porte encore le
## jeu d'exemple embarqué. Adopter ces recettes ou repartir de zéro engage le compte
## sur tous ses futurs appareils : c'est une décision utilisateur, pas technique.
signal seed_decision_required
## Émis quand la base appartenait à un AUTRE compte et vient d'être remise à neuf.
## L'écran Compte le dit : l'appareil paraîtrait sinon avoir perdu son contenu.
signal account_switched
## Émis après une sync ayant modifié des données locales : l'UI doit se rafraîchir.
signal data_pulled

var state: State = State.IDLE
var last_error: String = ""
var last_sync_ms: int = 0

## Cadence de la sync de fond. Assez lâche pour rester invisible et économe (le
## tier gratuit de Supabase a des quotas), assez serrée pour qu'un article coché en
## magasin apparaisse rapidement sur l'autre appareil.
const AUTO_SYNC_INTERVAL_S := 120.0
## Délai après la dernière écriture locale avant de pousser. Assez court pour que
## l'autre appareil voie la modification presque tout de suite, assez long pour qu'une
## rafale — décocher toute une liste, faire glisser trois recettes — parte en un seul
## envoi plutôt qu'en dix.
const PUSH_DEBOUNCE_S := 2.0
## Cadence de la sonde de fraîcheur — repli de secours depuis la 1.10.0. La réactivité
## perçue vient normalement de `RealtimeClient` (Postgres Changes, notification poussée en
## un aller-retour au lieu d'une attente moyenne d'une demi-période de sonde) ; cette sonde
## ne sert plus qu'à couvrir les cas où Realtime est indisponible — websocket bloqué par un
## réseau restrictif, ou table pas encore ajoutée à la publication côté projet
## (`supabase/schema.sql`). D'où l'espacement, bien plus lâche qu'avant : sa réactivité
## n'est plus ce qui se voit au quotidien.
const PROBE_INTERVAL_S := 60.0
## Délai avant la sync de lancement : laisse Session restaurer sa session et l'UI
## s'afficher — le démarrage ne doit jamais attendre le réseau.
const STARTUP_SYNC_DELAY_S := 3.0

var _db: LocalDatabase
var _session  ## Session
var _running := false
var _timer: Timer
## Armé au début d'un cycle si le jeu d'exemple est encore en place. Le seed n'est
## écarté qu'au moment où la PREMIÈRE ligne distante est appliquée : un compte vide
## ne déclenche rien, et son premier appareil pousse donc bien le seed — c'est le
## comportement voulu pour amorcer un nouveau foyer.
var _seed_discard_armed := false
## Vrai entre la question posée et la réponse : le push du jeu d'exemple est suspendu
## d'ici là, pour ne rien envoyer d'irréversible sur le compte.
var _seed_decision_pending := false
var _push_timer: Timer
var _probe_timer: Timer
## Dernier `updated_at` connu du serveur. La sonde ne déclenche un pull complet que
## si le serveur a bougé au-delà de cette valeur.
var _known_watermark := 0
## La sonde est asynchrone : sur réseau lent, le tic suivant la relancerait avant que
## la précédente n'ait répondu, et les requêtes s'empileraient.
var _probing := false
## Tables absentes du serveur, déjà signalées une fois. Évite de répéter le message
## à chaque cycle.
var _missing_tables := {}
## Lignes reçues que SQLite a refusé d'écrire pendant le pull en cours. Tant qu'il y en a,
## le curseur de la table ne bouge pas : sans quoi elles ne reviendraient plus jamais.
var _write_failures := 0

var _realtime  ## RealtimeClient, créé paresseusement au premier jeton valide
## user_id pour lequel `_realtime` est actuellement abonné — vide tant que non démarré, ou
## après un changement de compte (cf. `claim_account`) qui doit rouvrir le canal.
var _realtime_user := ""
## Dernier jeton transmis à `_realtime` : évite de rejoindre le canal à chaque cycle de
## sync alors que le jeton n'a pas changé (`get_access_token()` renvoie le même la
## plupart du temps, seulement renouvelé toutes les heures environ).
var _realtime_token := ""

func _ready() -> void:
	# DataStore et Session sont déclarés avant Sync dans project.godot.
	var store := get_node_or_null("/root/DataStore")
	var session := get_node_or_null("/root/Session")
	if store == null or session == null:
		return   # instancié hors arbre (tests) : setup() sera appelé explicitement
	setup(store.local_database(), session)
	data_pulled.connect(store.refresh_after_sync)
	# Une écriture locale programme un envoi. On écoute `local_change` et non
	# `data_changed` : ce dernier est aussi émis à la réception de données, ce qui
	# ferait boucler la synchronisation sur elle-même.
	store.local_change.connect(_on_local_change)
	# Une déconnexion doit fermer le canal Realtime : sinon il resterait ouvert avec un
	# jeton qui ne sera plus jamais renouvelé.
	session.status_changed.connect(_on_session_status_changed)
	_start_auto_sync()

func _on_session_status_changed(status) -> void:
	if status == SessionScript.Status.SIGNED_OUT and _realtime != null:
		_realtime.stop()
		_realtime_user = ""
		_realtime_token = ""

## Sync de fond. Un cycle échoué (hors-ligne) ne coûte qu'une requête avortée et
## sera retenté au tic suivant : inutile d'ajouter une temporisation exponentielle
## à cette échelle.
func _start_auto_sync() -> void:
	_timer = Timer.new()
	_timer.wait_time = AUTO_SYNC_INTERVAL_S
	_timer.timeout.connect(_on_auto_sync)
	add_child(_timer)
	_timer.start()

	_push_timer = Timer.new()
	_push_timer.one_shot = true
	_push_timer.timeout.connect(_on_auto_sync)
	add_child(_push_timer)

	_probe_timer = Timer.new()
	_probe_timer.wait_time = PROBE_INTERVAL_S
	_probe_timer.timeout.connect(_on_probe)
	add_child(_probe_timer)
	_probe_timer.start()

	var startup := get_tree().create_timer(STARTUP_SYNC_DELAY_S)
	startup.timeout.connect(_on_auto_sync)

## Programme un envoi peu après la dernière écriture. Jusqu'ici, une modification
## attendait le tic suivant — jusqu'à deux minutes avant même de quitter l'appareil.
func _on_local_change() -> void:
	if _push_timer == null:
		return
	_push_timer.start(PUSH_DEBOUNCE_S)   # relancé à chaque écriture : seule la dernière compte

func _on_auto_sync() -> void:
	if _running or _session == null or not _session.is_configured():
		return
	await sync()

## Interroge le serveur sur sa fraîcheur, et ne déclenche une synchronisation complète
## que si quelque chose a réellement changé.
##
## Repli de secours (cf. `PROBE_INTERVAL_S`) : la réactivité au quotidien vient de
## `RealtimeClient`, qui appelle `sync()` directement dès qu'une notification arrive —
## cette sonde ne fait plus qu'assurer qu'on ne reste jamais bloqué plus d'une minute si
## Realtime est indisponible. Les échecs restent silencieux : être hors-ligne est un mode
## de fonctionnement normal, pas un incident à signaler à chaque tic.
func _on_probe() -> void:
	if _running or _seed_decision_pending or _session == null or not _session.is_configured():
		return
	if _session.status == SessionScript.Status.SIGNED_OUT:
		return
	if _probing:
		return
	_probing = true
	var token: String = await _session.get_access_token()
	var remote := -1
	if token != "":
		var res: Dictionary = await _session.client.sync_watermark(token)
		if res.ok:
			remote = int(res.data)
	_probing = false
	if remote > _known_watermark:
		await sync()

## `RealtimeClient` a reçu une notification de changement — c'est le chemin rapide,
## équivalent à ce que fait `_on_probe` mais sans même le détour par `sync_watermark`.
func _on_realtime_changed() -> void:
	if _running or _seed_decision_pending or _session == null or not _session.is_configured():
		return
	await sync()

## Une table n'a pas pu être suivie en temps réel — typiquement parce qu'elle n'a pas
## encore été ajoutée à la publication Realtime côté projet (cf. `supabase/schema.sql`).
## Sans conséquence sur la correction : `_on_probe` continue de couvrir cette table, juste
## moins vite. Signalé une seule fois (cf. `RealtimeClient._warned_tables`), pas à chaque
## reconnexion.
func _on_realtime_subscribe_failed(table: String, message: String) -> void:
	push_warning(("Sync : notifications en temps réel indisponibles pour « %s » (%s). " +
		"Exécuter supabase/schema.sql (ALTER PUBLICATION supabase_realtime) pour l'activer. " +
		"Repli sur la sonde périodique.") % [table, message])

## Démarre ou met à jour l'abonnement Realtime pour le compte courant. Appelé à chaque
## cycle de sync réussi (juste après l'obtention du jeton) plutôt que câblé sur un
## événement de connexion séparé : c'est le point où l'on sait déjà que la session est
## valide et le compte connu, sans dupliquer cette logique.
func _ensure_realtime(token: String) -> void:
	if token == _realtime_token and _realtime_user == _session.user_id:
		return   # rien de neuf : ni premier démarrage, ni jeton renouvelé, ni changement de compte
	if _realtime == null:
		_realtime = RealtimeClientScript.new()
		add_child(_realtime)
		_realtime.changed.connect(_on_realtime_changed)
		_realtime.subscribe_failed.connect(_on_realtime_subscribe_failed)
	_realtime_token = token
	if _realtime_user == _session.user_id:
		_realtime.update_token(token)   # même compte, jeton renouvelé : pas besoin de tout rouvrir
		return
	_realtime_user = _session.user_id
	var tables: Array[String] = []
	for descriptor in SYNC_TABLES:
		tables.append(str(descriptor.table))
	_realtime.start(_session.client.url, _session.client.anon_key, token, _session.user_id, tables)

## Dépendances injectées plutôt que lues comme autoloads, pour que le moteur soit
## testable en headless avec une base et une session de substitution.
func setup(db: LocalDatabase, session = null) -> void:
	_db = db
	_session = session
	if _db != null:
		_known_watermark = int(_db.get_sync_meta("sync_watermark", "0"))

## Guérit l'état de sync DÉJÀ enregistré sur l'appareil. La 1.10.0 n'assainissait que ce qui
## arrive : un curseur de pull, la marque de fraîcheur ou des lignes locales posés dans le futur
## par une horloge déréglée (typiquement un PC Windows non resynchronisé) restaient en base.
## Curseur dans le futur → le pull ne ramène plus rien de ce que les autres appareils écrivent ;
## ligne locale dans le futur → elle gagne le LWW contre toute édition distante ;
## marque dans le futur → la sonde ne déclenche plus jamais de pull. Ramener le curseur à
## l'heure actuelle est sans risque : un pull plus large est idempotent.
func _heal_future_state() -> void:
	var now: int = _db._now()
	var limit := now + MAX_FUTURE_DRIFT_MS
	var healed := 0
	for descriptor in SYNC_TABLES:
		var key := "sync_cursor_%s" % descriptor.table
		var cursor := int(_db.get_sync_meta(key, "0"))
		if cursor > limit:
			_db.set_sync_meta(key, "0")   # repart de zéro : on ne sait plus ce qui a été vu
			healed += 1
	if _known_watermark > limit:
		_known_watermark = 0
		_db.set_sync_meta("sync_watermark", "0")
		healed += 1
	var rows := _db.heal_future_rows(now, MAX_FUTURE_DRIFT_MS)
	if healed > 0 or rows > 0:
		push_warning("Sync : état local daté dans le futur corrigé (%d curseur(s), %d ligne(s))."
			% [healed, rows])

## Lance un cycle complet. Renvoie
## { ok, pulled, pushed, merged, offline, error, skipped }.
## Ne lève jamais : un échec réseau est un résultat normal.
func sync() -> Dictionary:
	if _running:
		return _result(false, "Synchronisation déjà en cours", true)
	if _db == null or _session == null or not _session.is_configured():
		return _result(false, "Synchronisation non configurée", true)

	_running = true
	_set_state(State.RUNNING)

	var token: String = await _session.get_access_token()
	if token == "":
		# Pas de session exploitable : soit jamais connecté, soit serveur injoignable.
		# Dans les deux cas on repart sans bruit, l'app reste utilisable.
		_running = false
		_set_state(State.OFFLINE if _session.status == SessionScript.Status.OFFLINE else State.IDLE)
		return _result(false, "Aucune session active", true)

	# Une base = un compte, et cette vérification passe AVANT le pull : les curseurs de
	# l'ancien compte feraient croire que tout est à jour, et rien du nouveau n'arriverait.
	if _db.claim_account(_session.user_id):
		account_switched.emit()

	# Repart cette sync avec la réactivité en temps réel armée pour ce compte — best effort,
	# jamais bloquant : une notification manquée n'est rattrapée que par `_on_probe`.
	_ensure_realtime(token)

	# Aligne les horodatages d'édition sur l'horloge serveur : le LWW compare des
	# dates produites par des appareils différents.
	_db.clock_offset_ms = _session.clock_offset_ms
	_heal_future_state()
	_seed_discard_armed = _db.has_pending_seed()

	var pulled := 0
	var pushed := 0
	for descriptor in SYNC_TABLES:
		var pull_res := await _pull_table(descriptor, token)
		if not pull_res.ok:
			if _is_missing_table(pull_res, descriptor.table):
				continue
			return _abort(pull_res)
		pulled += int(pull_res.count)

	# Le jeu d'exemple est toujours en place APRÈS un pull complet : c'est que rien
	# n'est arrivé, donc que le compte est vierge (sur une installation neuve le
	# curseur vaut 0, le pull ramène donc tout ce que le compte contient). On
	# suspend le push et on laisse l'utilisateur trancher.
	if _db.has_pending_seed():
		if not _seed_decision_pending:
			_seed_decision_pending = true
			seed_decision_required.emit()
		_running = false
		_set_state(State.IDLE)
		var pending := _result(true, "", false)
		pending.pulled = pulled
		pending.needs_seed_decision = true
		return pending

	# Les rayons du jeu d'exemple ne pouvaient pas être écartés pendant le pull : on ne
	# savait pas encore si le compte en apporterait. Maintenant, si — et AVANT la fusion,
	# sans quoi elle les prendrait pour des homonymes à tombstoner et les pousserait.
	_db.discard_seed_aisles()

	# Les homonymes créés en parallèle sur deux appareils sont résorbés APRÈS le pull
	# et AVANT le push : la fusion produit des tombstones qu'il faut propager.
	var merged := _db.merge_duplicate_ingredients() + _db.merge_duplicate_categories() \
		+ _db.merge_duplicate_aisles()

	for descriptor in SYNC_TABLES:
		var push_res := await _push_table(descriptor, token)
		if not push_res.ok:
			if _is_missing_table(push_res, descriptor.table):
				continue
			return _abort(push_res)
		pushed += int(push_res.count)

	# Relevé APRÈS le push : nos propres envois font avancer la fraîcheur du serveur,
	# et sans cela la sonde déclencherait un pull inutile juste après chaque écriture.
	var mark: Dictionary = await _session.client.sync_watermark(token)
	if mark.ok:
		_known_watermark = int(mark.data)
		_db.set_sync_meta("sync_watermark", str(_known_watermark))

	_running = false
	last_error = ""
	last_sync_ms = int(Time.get_unix_time_from_system() * 1000.0)
	_set_state(State.IDLE)
	if pulled > 0 or merged > 0:
		data_pulled.emit()

	var out := _result(true, "", false)
	out.pulled = pulled
	out.pushed = pushed
	out.merged = merged
	return out

# =====================================================================
# Pull
# =====================================================================

func _pull_table(descriptor: Dictionary, token: String) -> Dictionary:
	var table: String = descriptor.table
	var cursor := int(_db.get_sync_meta("sync_cursor_%s" % table, "0"))
	var applied := 0
	var offset := 0
	var max_seen := cursor
	_write_failures = 0

	while true:
		var res: Dictionary = await _session.client.select_changed_since(table, cursor, token, offset)
		if not res.ok:
			return {"ok": false, "count": applied, "res": res}
		var rows: Array = res.data if typeof(res.data) == TYPE_ARRAY else []
		for row in rows:
			if _apply_remote_row(descriptor, row):
				applied += 1
			# Sur l'horodatage ASSAINI, jamais le brut : sans quoi une seule ligne corrompue
			# pousse le curseur dans le futur et rend invisibles toutes les éditions saines
			# qui suivent, sur TOUTE la table (cf. MAX_FUTURE_DRIFT_MS).
			max_seen = max(max_seen, _sane_updated_at(int(row.get("updated_at", 0))))
		if rows.size() < _session.client.PAGE_SIZE:
			break
		offset += rows.size()

	# Le curseur n'avance qu'après application complète : une interruption fait
	# simplement retirer les mêmes lignes au cycle suivant, sans perte. Une écriture
	# refusée (schéma local en retard, par exemple) compte comme une interruption.
	if _write_failures > 0:
		push_warning("Sync : %d ligne(s) de %s non écrite(s) localement, curseur conservé."
			% [_write_failures, table])
	else:
		_db.set_sync_meta("sync_cursor_%s" % table, str(max_seen))
	return {"ok": true, "count": applied}

## Applique une ligne distante si elle gagne le LWW. Renvoie true si elle a été écrite.
func _apply_remote_row(descriptor: Dictionary, remote: Dictionary) -> bool:
	var table: String = descriptor.table
	var key_column: String = descriptor.key
	# Une ligne distante amputée d'une partie de sa clé n'est pas exploitable : `meal_slot`
	# manque par exemple sur une ligne écrite par un client antérieur à la 1.8.
	var keys := _key_values(descriptor, remote)
	if keys.has(null):
		# Sauf `meal_slot`, dont l'absence se lit comme « le repas unique de la journée » : c'est
		# exactement ce qu'écrivait la 1.7, et la ligne doit rester lisible.
		if key_column.contains("meal_slot") and remote.get("position_index") != null:
			remote = remote.duplicate()
			remote["meal_slot"] = 0
			keys = _key_values(descriptor, remote)
		else:
			return false

	var local := _db.fetch_row(table, key_column, keys)
	var raw_remote_updated := int(remote.get("updated_at", 0))
	var remote_updated := _sane_updated_at(raw_remote_updated)
	# Horodatage corrompu (appareil déréglé au moment de l'écriture) : on l'assainit et on
	# la repousse dirty pour que le correctif se propage aux autres appareils.
	var corrupted := remote_updated != raw_remote_updated
	if corrupted:
		remote = remote.duplicate()
		remote["updated_at"] = remote_updated
		push_warning("Sync : horodatage futur corrompu sur %s %s (%d), ramené à %d."
			% [table, str(keys), raw_remote_updated, remote_updated])
	if not local.is_empty():
		var local_updated := int(local.get("updated_at", 0))
		if local_updated > remote_updated:
			return false   # l'édition locale est plus récente : elle sera poussée
		if local_updated == remote_updated and int(local.get("dirty", 0)) == 0:
			return false   # déjà à jour, rien à écrire

	# Première donnée reçue d'un compte non vide : le jeu d'exemple embarqué cède la
	# place. Fait ici, et pas en amont, pour ne rien jeter si le compte est vierge.
	if _seed_discard_armed:
		_seed_discard_armed = false
		_db.discard_seed_rows()
		local = _db.fetch_row(table, key_column, keys)

	var row := _local_row_from_remote(descriptor, remote)
	if corrupted:
		row["dirty"] = 1
	if not _db.sync_write_row(table, key_column, row):
		_write_failures += 1
		return false

	# Les tables filles de l'agrégat ne sont réécrites que si la ligne est vivante :
	# inutile de reconstruire les liens d'une recette supprimée.
	if remote.get("deleted_at") == null:
		match descriptor.get("aggregate", ""):
			"recipe":
				# Ces agrégats ont une clé d'une seule colonne : le premier élément suffit.
				_db.sync_write_recipe_children(str(keys[0]),
					_as_array(remote.get("ingredients")), _as_array(remote.get("categories")))
			"breakfast":
				_db.sync_write_breakfast_children(str(keys[0]), _as_array(remote.get("ingredients")))
	return true

## Ligne distante → ligne locale : on retire ce qui est propre au serveur, on
## convertit les booléens en 0/1 (SQLite n'a pas de type booléen) et on marque
## `dirty = 0` — sinon tout ce qui est reçu repartirait aussitôt.
func _local_row_from_remote(descriptor: Dictionary, remote: Dictionary) -> Dictionary:
	var row := {}
	var bools: Array = descriptor.get("bools", [])
	for column in remote.keys():
		if column == "owner_id" or column == "ingredients" or column == "categories":
			continue
		var value = remote[column]
		if bools.has(column):
			value = 1 if value else 0
		row[column] = value
	row["dirty"] = 0
	return row

# =====================================================================
# Push
# =====================================================================

func _push_table(descriptor: Dictionary, token: String) -> Dictionary:
	var table: String = descriptor.table
	var key_column: String = descriptor.key
	var dirty := _db.fetch_dirty(table)
	if dirty.is_empty():
		return {"ok": true, "count": 0}

	var payload := []
	for local in dirty:
		payload.append(_remote_row_from_local(descriptor, local))

	var res: Dictionary = await _session.client.upsert(table, payload, token, descriptor.on_conflict)
	if not res.ok:
		return {"ok": false, "count": 0, "res": res}

	for local in dirty:
		_db.mark_clean(table, key_column, _key_values(descriptor, local),
			int(local.get("updated_at", 0)))
	return {"ok": true, "count": dirty.size()}

## Valeurs de la clé locale d'une ligne, dans l'ordre déclaré par le descripteur. Une seule
## colonne pour presque toutes les tables ; deux pour les cases du planning.
func _key_values(descriptor: Dictionary, row: Dictionary) -> Array:
	var values := []
	for column in str(descriptor.key).split(","):
		values.append(row.get(column.strip_edges()))
	return values

## Ligne locale → charge utile distante. `owner_id` est renseigné explicitement
## plutôt que laissé au DEFAULT de Postgres : PostgREST doit disposer de toutes les
## colonnes de la clé de conflit pour les tables à clé naturelle composite.
func _remote_row_from_local(descriptor: Dictionary, local: Dictionary) -> Dictionary:
	var row := {}
	var bools: Array = descriptor.get("bools", [])
	for column in local.keys():
		if column == "dirty":
			continue
		var value = local[column]
		if bools.has(column):
			value = int(value) != 0
		row[column] = value
	row["owner_id"] = _session.user_id

	match descriptor.get("aggregate", ""):
		"recipe":
			var recipe_id := str(local["id"])
			row["ingredients"] = _db.fetch_recipe_ingredient_links(recipe_id)
			# Les catégories voyagent par NOM et non par id : deux appareils ayant créé
			# « Pâtes » indépendamment ont des UUID différents, mais le même nom.
			row["categories"] = _db.fetch_recipe_category_names(recipe_id)
		"breakfast":
			row["ingredients"] = _db.fetch_breakfast_ingredient_links(str(local["id"]))
	return row

# =====================================================================
# Utilitaires
# =====================================================================

## Une table peut manquer côté serveur quand l'application est plus récente que le
## schéma Supabase — typiquement entre l'installation d'une mise à jour et l'exécution
## de la SQL correspondante.
##
## On saute la table concernée au lieu d'interrompre tout le cycle : sans cela, une
## seule table manquante casserait la synchronisation de TOUTES les autres, et
## l'ordre des deux opérations deviendrait critique.
func _is_missing_table(failure: Dictionary, table: String) -> bool:
	var res: Dictionary = failure.get("res", {})
	if int(res.get("code", 0)) != 404:
		return false
	if not _missing_tables.has(table):
		_missing_tables[table] = true
		push_warning("Sync : table « %s » absente du serveur, ignorée. " % table
			+ "Exécuter supabase/schema.sql pour l'activer.")
	return true

func _abort(failure: Dictionary) -> Dictionary:
	var res: Dictionary = failure.get("res", {})
	_running = false
	last_error = str(res.get("error", "Erreur inconnue"))
	var offline := bool(res.get("offline", false))
	_set_state(State.OFFLINE if offline else State.ERROR)
	return _result(false, last_error, offline)

func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)

func _result(ok: bool, error: String, offline: bool) -> Dictionary:
	return {"ok": ok, "error": error, "offline": offline,
		"pulled": 0, "pushed": 0, "merged": 0, "needs_seed_decision": false}

## Réponse de l'utilisateur à `seed_decision_required`.
## `keep` : les recettes d'exemple deviennent sa collection et partent sur son compte.
## Sinon elles sont supprimées et il repart d'une base vierge.
func resolve_seed_decision(keep: bool) -> Dictionary:
	_seed_decision_pending = false
	if keep:
		_db.adopt_seed()
	else:
		_db.discard_seed_rows()
		data_pulled.emit()
	return await sync()

func _as_array(value) -> Array:
	return value if typeof(value) == TYPE_ARRAY else []

## Ramène un horodatage distant à l'heure locale corrigée s'il la dépasse de plus de
## `MAX_FUTURE_DRIFT_MS` (tolérance large : une simple différence d'horloge entre appareils
## ne doit pas être prise pour de la corruption). Une fois le seuil dépassé, on ramène à
## l'heure ACTUELLE (pas à la limite de tolérance) : sinon la ligne assainie resterait quand
## même en avance, et une édition faite l'instant d'après perdrait encore le LWW pendant
## jusqu'à une heure de plus — la guérison doit être immédiate, pas simplement bornée.
func _sane_updated_at(raw: int) -> int:
	var now := _db._now()
	return raw if raw <= now + MAX_FUTURE_DRIFT_MS else now
