class_name SupabaseClient
extends Node
## Client HTTP Supabase : authentification GoTrue + accès PostgREST.
##
## Volontairement bas niveau et sans état : il ne connaît ni la session ni la
## stratégie de sync. C'est `Session` qui détient les jetons et `SyncEngine` qui
## décide quoi lire et écrire.
##
## Toutes les méthodes publiques sont asynchrones (`await`) et renvoient un
## dictionnaire de résultat uniforme :
##     { ok: bool, code: int, data: Variant, error: String, offline: bool }
##
## `offline` distingue « la requête n'est jamais partie / n'a pas abouti » d'une
## réponse d'erreur du serveur. La distinction est structurante ici : l'app doit
## rester pleinement utilisable sans réseau (usage en magasin), donc un échec
## réseau est un cas NORMAL à retenter plus tard, alors qu'un 4xx est un vrai
## défaut à signaler. Le tier gratuit de Supabase met d'ailleurs le projet en
## pause après ~7 jours d'inactivité, ce qui se présente exactement comme une
## panne réseau.

const CONFIG_PATH := "res://supabase_config.json"
const REQUEST_TIMEOUT := 20.0

## Nombre maximal de lignes ramenées par page lors d'un pull.
const PAGE_SIZE := 500

var url: String = ""
var anon_key: String = ""

## false si supabase_config.json est absent ou incomplet : l'app fonctionne alors
## en local pur, sans jamais tenter de requête.
var configured: bool = false

func _ready() -> void:
	_load_config()

func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_warning("SupabaseClient : %s absent — synchronisation désactivée." % CONFIG_PATH)
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("SupabaseClient : %s illisible — synchronisation désactivée." % CONFIG_PATH)
		return
	url = str(data.get("url", "")).rstrip("/")
	anon_key = str(data.get("anon_key", ""))
	configured = url != "" and anon_key != "" and not anon_key.begins_with("COLLER")
	if not configured:
		push_warning("SupabaseClient : configuration incomplète — synchronisation désactivée.")

# =====================================================================
# Authentification (GoTrue)
# =====================================================================

## Connexion par email + mot de passe. En cas de succès, `data` contient
## access_token, refresh_token, expires_in et user.
func sign_in(email: String, password: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password",
		{"email": email, "password": password}, "")

## Renouvelle la session à partir du refresh token. C'est ce qui évite de
## redemander le mot de passe à chaque lancement.
func refresh_session(refresh_token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=refresh_token",
		{"refresh_token": refresh_token}, "")

func sign_out(access_token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/auth/v1/logout", {}, access_token)

# =====================================================================
# Données (PostgREST)
# =====================================================================

## Horloge serveur en millisecondes — sert à mesurer la dérive de l'horloge locale.
func server_now_ms(access_token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/rest/v1/rpc/server_now_ms", {}, access_token)

## Plus grand `updated_at` du compte, toutes tables confondues.
## Sonde bon marché : une requête minuscule qui dit s'il vaut la peine d'aller
## chercher quoi que ce soit.
func sync_watermark(access_token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/rest/v1/rpc/sync_watermark", {}, access_token)

## Dépose un partage et renvoie son jeton. Demande d'être connecté : c'est une
## écriture sur le compte de l'émetteur.
func publish_shared_bundle(payload: String, days: int, access_token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/rest/v1/rpc/publish_shared_bundle",
		{"p_payload": payload, "p_days": days}, access_token)

## Récupère un partage par son jeton. Appelée **sans jeton de session** : le
## destinataire n'a pas de compte, c'est tout l'objet d'un partage. La fonction est
## ouverte à `anon` côté serveur, et ne peut rendre qu'une ligne — celle dont on
## connaît le jeton.
func fetch_shared_bundle(token: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/rest/v1/rpc/fetch_shared_bundle",
		{"p_token": token}, "")

## Lignes d'une table dont `updated_at` dépasse le curseur, par ordre croissant.
##
## Le tri et la pagination sont indispensables : en cas d'interruption, on peut
## reprendre au dernier `updated_at` traité sans risquer de sauter des lignes.
## Les tombstones (deleted_at non nul) sont volontairement inclus — c'est ainsi
## que les suppressions se propagent.
func select_changed_since(table: String, cursor_ms: int, access_token: String,
		offset: int = 0) -> Dictionary:
	# `gte` et non `gt` : deux lignes peuvent partager la même milliseconde, et l'une
	# d'elles peut être écrite juste après notre lecture. Refaire passer la frontière
	# à chaque pull est sans conséquence (l'application d'une ligne est idempotente),
	# alors qu'un `gt` la perdrait définitivement.
	var path := "/rest/v1/%s?select=*&updated_at=gte.%d&order=updated_at.asc&limit=%d&offset=%d" % [
		table, cursor_ms, PAGE_SIZE, offset]
	return await _request(HTTPClient.METHOD_GET, path, null, access_token)

## Insertion ou mise à jour en masse.
## `on_conflict` nomme les colonnes de la clé sur laquelle fusionner ; il est
## obligatoire pour les tables à clé naturelle composite (owner_id + position…),
## que PostgREST ne devine pas correctement quand la clé n'est pas un simple `id`.
func upsert(table: String, rows: Array, access_token: String,
		on_conflict: String = "") -> Dictionary:
	if rows.is_empty():
		return {"ok": true, "code": 200, "data": [], "error": "", "offline": false}
	var path := "/rest/v1/%s" % table
	if on_conflict != "":
		path += "?on_conflict=%s" % on_conflict
	return await _request(HTTPClient.METHOD_POST, path, rows, access_token,
		["Prefer: resolution=merge-duplicates,return=minimal"])

# =====================================================================
# Transport
# =====================================================================

func _request(method: int, path: String, body, access_token: String,
		extra_headers: Array = []) -> Dictionary:
	if not configured:
		return _fail("Supabase non configuré", true)

	var headers := [
		"apikey: %s" % anon_key,
		"Content-Type: application/json",
		"Accept: application/json",
		# Sans jeton de session, on s'annonce avec la clé publique : les policies RLS
		# ne laisseront alors rien passer, ce qui est le comportement voulu.
		"Authorization: Bearer %s" % (access_token if access_token != "" else anon_key),
	]
	headers.append_array(extra_headers)

	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	# Version web : le navigateur décompresse lui-même les réponses gzip, mais laisse voir
	# l'en-tête `Content-Encoding: gzip`. Godot tente alors une seconde décompression, qui
	# échoue (RESULT_BODY_DECOMPRESS_FAILED) — et l'échec passe pour une coupure réseau.
	# Seules les petites réponses, non compressées, passaient : la connexion aboutissait,
	# puis toute synchronisation tombait « hors ligne ».
	http.accept_gzip = not OS.has_feature("web")
	add_child(http)

	var body_str := "" if body == null else JSON.stringify(body)
	var err := http.request(url + path, headers, method, body_str)
	if err != OK:
		http.queue_free()
		return _fail("Requête non émise (code %d)" % err, true)

	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var code: int = response[1]
	var raw: PackedByteArray = response[3]

	if result != HTTPRequest.RESULT_SUCCESS:
		# Pas de réponse du serveur : hors-ligne, DNS, timeout, projet en pause…
		return _fail("Réseau indisponible (résultat %d)" % result, true)

	var text := raw.get_string_from_utf8()
	var parsed = JSON.parse_string(text) if text.strip_edges() != "" else null

	if code < 200 or code >= 300:
		return {
			"ok": false, "code": code, "data": parsed, "offline": false,
			"error": _error_message(parsed, code),
		}
	return {"ok": true, "code": code, "data": parsed, "error": "", "offline": false}

func _error_message(parsed, code: int) -> String:
	if typeof(parsed) == TYPE_DICTIONARY:
		for key in ["msg", "message", "error_description", "error"]:
			if parsed.has(key) and str(parsed[key]) != "":
				return str(parsed[key])
	return "HTTP %d" % code

func _fail(message: String, offline: bool) -> Dictionary:
	return {"ok": false, "code": 0, "data": null, "error": message, "offline": offline}
