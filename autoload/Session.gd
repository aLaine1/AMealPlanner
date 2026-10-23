extends Node
## Compte du foyer : état d'authentification et cycle de vie des jetons.
## Autoload "Session". Détient l'unique `SupabaseClient` de l'app.
##
## Modèle retenu (cf. plan, annexe 1) : **un seul compte partagé** entre les quelques
## appareils du foyer, donc pas de notion d'utilisateur courant à afficher ni de
## partage à gérer. L'app ne propose que la connexion — jamais l'inscription, qui est
## par ailleurs désactivée côté Supabase.
##
## Principe directeur : **l'authentification n'est jamais bloquante**. La base locale
## est la source de vérité et l'app doit rester pleinement utilisable déconnectée
## (usage en magasin, projet Supabase en pause, avion…). Être signé out n'est pas un
## état d'erreur, c'est un mode de fonctionnement normal.

## Chargé par preload plutôt que par son class_name : le cache de classes globales
## de Godot n'est pas garanti à jour au lancement (notamment en mode --script).
const SupabaseClientScript := preload("res://services/SupabaseClient.gd")

const DEFAULT_SESSION_PATH := "user://session.json"

## Chemin du jeton persisté, surchargeable par la variable d'environnement
## MEALPLANNER_SESSION — même principe que MEALPLANNER_DB (`LocalDatabase.db_path()`).
##
## Sans cette bascule, les suites headless (`test_onboarding.gd` notamment) partagent le
## VRAI fichier de session de la machine : une connexion faite à la main pour essayer
## l'appli — la vôtre, à l'instant — laisse un jeton que la suite suivante prend pour un
## compte déjà vu, et son verdict devient un pile ou face sur ce que quelqu'un a fait sur
## la machine entre deux lancements de tests plutôt que sur le code.
static func session_path() -> String:
	var override := OS.get_environment("MEALPLANNER_SESSION")
	return override if override != "" else DEFAULT_SESSION_PATH

## Durée de vie d'un partage déposé. Doit rester d'accord avec
## `RecipeShare.SHARE_DAYS`, qui l'annonce à l'utilisateur.
const SHARE_DAYS := 30

## Marge avant expiration en dessous de laquelle on renouvelle par anticipation :
## évite qu'une requête parte avec un jeton qui expire pendant son trajet.
const REFRESH_MARGIN_S := 120

## Le décalage d'horloge n'était mesuré qu'une fois par session (connexion ou reprise
## silencieuse au lancement) : sur une session de bureau qui tourne des heures ou des jours,
## une horloge qui dérive, se resynchronise (NTP), ou était simplement fausse au moment de la
## mesure (avant que Windows n'ait eu le temps de se resynchroniser au démarrage) laissait
## `clock_offset_ms` faux pour TOUTE la session — chaque écriture locale en héritait, avec un
## `updated_at` qui pouvait être poussé loin dans le futur côté serveur. Un tel horodatage gagne
## alors le LWW indéfiniment (cf. `SyncEngine.MAX_FUTURE_DRIFT_MS`), et pire, fait avancer le
## curseur de synchronisation de la table dans le futur, rendant invisibles toutes les
## éditions saines suivantes sur tous les appareils. Recalibrer périodiquement borne l'exposition
## à une mesure ponctuelle mauvaise, au lieu de la figer pour toute la durée de vie de l'appli.
const CLOCK_RECHECK_INTERVAL_S := 900.0

var _clock_timer: Timer

enum Status {
	SIGNED_OUT,    ## aucun compte connecté sur cet appareil
	SIGNED_IN,     ## jeton valide en mémoire
	OFFLINE,       ## compte connu, mais serveur injoignable pour l'instant
}

signal status_changed(status: Status)
## L'adresse du compte a changé — connexion, déconnexion, ou première lecture après une
## session enregistrée avant la 2.0.8, qui ne la portait pas encore.
signal email_changed(email: String)

var status: Status = Status.SIGNED_OUT
var client  ## SupabaseClient
var user_id: String = ""
## Adresse du compte connecté, affichée dans l'en-tête. Vide si inconnue ou déconnecté.
var email: String = ""

## Décalage horloge serveur − horloge locale, en millisecondes. Appliqué aux
## horodatages sortants : la comparaison LWW n'a de sens que si les appareils
## datent leurs éditions sur une base commune (§3.4.1).
var clock_offset_ms: int = 0

var _access_token: String = ""
var _refresh_token: String = ""
var _expires_at_s: int = 0
var _last_error: String = ""

## Vrai dès qu'une connexion a abouti. En version web, perdre ensuite le compte efface tout
## (cf. `_forget_everything`) ; un simple échec de connexion, lui, ne doit rien recharger.
var _had_session := false

func _ready() -> void:
	client = SupabaseClientScript.new()
	client.name = "SupabaseClient"
	add_child(client)
	if not LocalDatabase.ephemeral():
		_load_stored_session()
	if _refresh_token != "":
		# Reconnexion silencieuse au lancement — sans bloquer le démarrage de l'UI.
		_restore_session.call_deferred()

	_clock_timer = Timer.new()
	_clock_timer.wait_time = CLOCK_RECHECK_INTERVAL_S
	_clock_timer.timeout.connect(func():
		if status != Status.SIGNED_OUT:
			_measure_clock_offset())
	add_child(_clock_timer)
	_clock_timer.start()

## Une session est déjà enregistrée sur cet appareil : le démarrage n'a donc pas à passer par
## l'écran de connexion, et il ne doit pas — l'application fonctionne hors ligne, et exiger le
## réseau à chaque lancement reviendrait à retirer cette qualité fondatrice. Voir la décision
## D1 du plan 1.8 : bloquant à la PREMIÈRE mise en route seulement.
func has_stored_session() -> bool:
	return _refresh_token != ""

func is_configured() -> bool:
	return client != null and client.configured

func last_error() -> String:
	return _last_error

# =====================================================================
# Connexion / déconnexion
# =====================================================================

## Connexion explicite depuis l'écran de connexion. Renvoie "" si succès, sinon
## un message d'erreur affichable.
func sign_in(email: String, password: String) -> String:
	if not is_configured():
		return "Synchronisation non configurée sur cet appareil."
	var res: Dictionary = await client.sign_in(email.strip_edges(), password)
	if not res.ok:
		_last_error = res.error
		_set_status(Status.OFFLINE if res.offline else Status.SIGNED_OUT)
		return _friendly_error(res)
	_adopt_session(res.data)
	await _measure_clock_offset()
	return ""

# =====================================================================
# Partage de recettes par référence
# =====================================================================

## Dépose un partage et renvoie son jeton, ou "" en cas d'échec — `last_error()`
## porte alors le message à montrer.
##
## Publier demande d'être connecté : le partage est écrit sur le compte de
## l'émetteur, et c'est lui qui en répond.
func publish_share(payload: String) -> String:
	if not is_configured():
		_last_error = "Synchronisation non configurée sur cet appareil."
		return ""
	var token := await get_access_token()
	if token == "":
		_last_error = "Connecte-toi pour créer un partage."
		return ""
	var res: Dictionary = await client.publish_shared_bundle(payload, SHARE_DAYS, token)
	if not res.ok:
		_last_error = _friendly_error(res)
		return ""
	return str(res.data).strip_edges().trim_prefix("\"").trim_suffix("\"")

## Récupère le contenu d'un partage. Ne demande **aucun compte** : le destinataire
## n'en a pas, c'est tout l'objet de la manœuvre.
func fetch_share(share_token: String) -> Dictionary:
	if not is_configured():
		return {"ok": false, "payload": "",
			"error": "Synchronisation non configurée sur cet appareil."}
	var res: Dictionary = await client.fetch_shared_bundle(share_token)
	if not res.ok:
		return {"ok": false, "payload": "", "error": _friendly_error(res)}
	var payload := str(res.data).strip_edges()
	# La fonction serveur rend NULL pour un jeton inconnu comme pour un jeton périmé,
	# sans les distinguer : confirmer l'existence d'un partage renseignerait qui
	# essaierait des jetons au hasard.
	if payload == "" or payload == "null" or payload == "<null>":
		return {"ok": false, "payload": "",
			"error": "Ce partage n'existe plus. Les codes expirent au bout de %d jours." % SHARE_DAYS}
	return {"ok": true, "payload": payload.trim_prefix("\"").trim_suffix("\""), "error": ""}

func sign_out() -> void:
	if _access_token != "":
		await client.sign_out(_access_token)
	_access_token = ""
	_refresh_token = ""
	_expires_at_s = 0
	user_id = ""
	_set_email("")
	clock_offset_ms = 0
	DirAccess.remove_absolute(ProjectSettings.globalize_path(session_path()))
	_set_status(Status.SIGNED_OUT)

## Jeton d'accès valide, ou "" si indisponible. Renouvelle au besoin.
## Les appelants (SyncEngine) traitent "" comme « on retentera plus tard » et
## non comme une erreur.
func get_access_token() -> String:
	if _refresh_token == "":
		return ""
	var now := int(Time.get_unix_time_from_system())
	if _access_token != "" and now < _expires_at_s - REFRESH_MARGIN_S:
		return _access_token
	return await _refresh()

# =====================================================================
# Interne
# =====================================================================

func _restore_session() -> void:
	var token := await get_access_token()
	if token != "":
		await _measure_clock_offset()

func _refresh() -> String:
	var res: Dictionary = await client.refresh_session(_refresh_token)
	if not res.ok:
		_last_error = res.error
		if res.offline:
			# Serveur injoignable : on GARDE le refresh token, la session reprendra
			# au retour du réseau. Effacer ici forcerait une resaisie du mot de passe
			# à chaque coupure, ce qui est précisément ce qu'on veut éviter.
			_set_status(Status.OFFLINE)
		else:
			# Refus explicite (jeton révoqué/expiré) : là, il faut se reconnecter.
			_refresh_token = ""
			_access_token = ""
			DirAccess.remove_absolute(ProjectSettings.globalize_path(session_path()))
			_set_status(Status.SIGNED_OUT)
		return ""
	_adopt_session(res.data)
	return _access_token

func _adopt_session(data) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	_access_token = str(data.get("access_token", ""))
	# Supabase fait tourner le refresh token à chaque renouvellement : ne pas
	# persister le nouveau invaliderait la session au renouvellement suivant.
	var new_refresh := str(data.get("refresh_token", ""))
	if new_refresh != "":
		_refresh_token = new_refresh
	_expires_at_s = int(Time.get_unix_time_from_system()) + int(data.get("expires_in", 3600))
	var user = data.get("user", {})
	if typeof(user) == TYPE_DICTIONARY:
		user_id = str(user.get("id", user_id))
		_set_email(str(user.get("email", email)))
	_last_error = ""
	_had_session = true
	_store_session()
	_set_status(Status.SIGNED_IN)

func _measure_clock_offset() -> void:
	var res: Dictionary = await client.server_now_ms(_access_token)
	if not res.ok:
		return
	var server_ms := int(res.data)
	var local_ms := int(Time.get_unix_time_from_system() * 1000.0)
	clock_offset_ms = server_ms - local_ms

func _set_status(new_status: Status) -> void:
	if status == new_status:
		return
	status = new_status
	status_changed.emit(status)
	if new_status == Status.SIGNED_OUT and _had_session and LocalDatabase.ephemeral():
		_forget_everything.call_deferred()

## Version web : le compte parti — déconnexion, ou jeton refusé par le serveur — la page
## repart de zéro. Recharger vide la mémoire d'un coup, base comprise, et ramène l'écran de
## connexion : plus sûr que de vider chaque table en espérant n'en oublier aucune.
## Hors navigateur (MEALPLANNER_EPHEMERAL), l'équivalent est de quitter : la mémoire part
## avec le processus. Différé : les écouteurs de `status_changed` finissent d'abord leur travail.
func _forget_everything() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.location.reload();")
	else:
		get_tree().quit()

func _set_email(value: String) -> void:
	if value == email:
		return
	email = value
	email_changed.emit(email)

func _store_session() -> void:
	if LocalDatabase.ephemeral():
		return
	var f := FileAccess.open(session_path(), FileAccess.WRITE)
	if f:
		# L'adresse est gardée pour s'afficher dès le lancement, avant même que le serveur
		# ait répondu — et hors ligne, où il ne répondrait pas.
		f.store_string(JSON.stringify({"refresh_token": _refresh_token, "user_id": user_id,
			"email": email}))

func _load_stored_session() -> void:
	if not FileAccess.file_exists(session_path()):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(session_path()))
	if typeof(data) != TYPE_DICTIONARY:
		return
	_refresh_token = str(data.get("refresh_token", ""))
	user_id = str(data.get("user_id", ""))
	_set_email(str(data.get("email", "")))

func _friendly_error(res: Dictionary) -> String:
	if res.offline:
		return "Serveur injoignable. L'application continue de fonctionner hors-ligne."
	if res.code == 400 or res.code == 401:
		return "Email ou mot de passe incorrect."
	return res.error
