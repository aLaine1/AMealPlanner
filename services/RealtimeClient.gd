extends Node
## Canal Supabase Realtime (Postgres Changes) — remplace la sonde par scrutation de
## `SyncEngine` par une notification poussée : un appareil apprend qu'un autre a modifié
## le compte en un aller-retour réseau, au lieu d'attendre jusqu'à `PROBE_INTERVAL_S`.
##
## Protocole (canaux Phoenix, vérifié à la main contre le vrai projet avant d'écrire ce
## fichier — Supabase ne fournit pas de client GDScript officiel) :
##   - connexion : GET wss://<projet>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0
##   - abonnement : un message `phx_join` sur un topic choisi (ici "realtime:db-changes"),
##     `payload.config.postgres_changes` listant une entrée par table à surveiller, chacune
##     avec son propre `filter` (ici `owner_id=eq.<uuid>`, en plus des policies RLS qui
##     filtrent déjà côté serveur), et `payload.access_token` pour l'autorisation.
##   - le serveur répond un `phx_reply` (`payload.status` "ok"/"error") pour le join, PUIS,
##     séparément, un événement `system` par table dont l'abonnement échoue (typiquement :
##     Realtime pas activé pour cette table côté projet — cf. `supabase/schema.sql`).
##   - un changement de ligne arrive en `event = "postgres_changes"` sur le même topic.
##   - il faut un `heartbeat` sur le topic spécial `"phoenix"` régulièrement, sans quoi le
##     serveur ferme la connexion pour inactivité.
##
## Best-effort et jamais bloquant, comme le reste de la synchronisation : une panne ici ne
## fait que priver l'app de la notification instantanée, `SyncEngine` continue de fonctionner
## sur sa sonde périodique de secours.

## Doit rester en dessous du délai d'inactivité du serveur Phoenix (~60 s).
const HEARTBEAT_INTERVAL_S := 25.0
## Paliers de nouvel essai après une coupure : rapide au début (résorbe les micro-coupures
## sans délai perceptible), long à la fin (n'insiste pas indéfiniment sur un réseau mort).
const RECONNECT_BACKOFF_S := [2.0, 5.0, 15.0, 30.0, 60.0]

const JOIN_TOPIC := "realtime:db-changes"

## Émis pour CHAQUE changement reçu — `SyncEngine` n'a pas besoin de savoir lequel, un
## cycle de sync complet est déjà bon marché (§ sonde existante) et gère tout uniformément.
signal changed
## Émis une fois par table dont Realtime a refusé l'abonnement (config serveur manquante),
## pour que l'appelant puisse le signaler une seule fois plutôt qu'à chaque reconnexion.
signal subscribe_failed(table: String, message: String)

var _socket: WebSocketPeer
var _url := ""
var _anon_key := ""
var _access_token := ""
var _user_id := ""
var _tables: Array[String] = []

var _join_ref := ""
var _join_sent := false
var _joined := false
var _heartbeat_elapsed := 0.0
var _ref_counter := 0
var _reconnect_attempt := 0
var _reconnect_wait := 0.0
var _wanted := false   ## true entre start() et stop() : pilote la reconnexion automatique
## Tables déjà signalées en échec, pour ne pas répéter l'avertissement à chaque reconnexion.
var _warned_tables := {}

func _process(delta: float) -> void:
	if _socket == null:
		if _wanted and _reconnect_wait > 0.0:
			_reconnect_wait -= delta
			if _reconnect_wait <= 0.0:
				_open_socket()
		return

	_socket.poll()
	var state := _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			if not _joined and not _join_sent:
				# Sans ce garde-fou, on renvoyait un `phx_join` à CHAQUE frame tant que la
				# réponse n'était pas arrivée (latence réseau normale, plusieurs frames) — avec
				# un nouveau `ref` à chaque fois, si bien que la réponse au premier ne correspondait
				# plus au `_join_ref` courant en `_handle_packet` et `_joined` ne passait jamais à
				# `true`. Phoenix, qui n'attend qu'un seul join par topic, coupait alors la
				# connexion — trouvé en reproduisant en direct contre le vrai projet.
				_join_sent = true
				_send_join()
			else:
				_heartbeat_elapsed += delta
				if _heartbeat_elapsed >= HEARTBEAT_INTERVAL_S:
					_heartbeat_elapsed = 0.0
					_send_heartbeat()
			# `_socket != null` réévalué à chaque tour : `_handle_packet` peut émettre `changed`,
			# dont un abonné (`SyncEngine._on_realtime_changed`) relance un cycle de sync qui,
			# à son premier `await`, peut déjà avoir laissé `_ensure_realtime` rouvrir CE MÊME
			# canal (jeton renouvelé entre-temps) — `start()` réaffecte alors `_socket` sous nos
			# pieds pendant que cette boucle tourne encore sur l'ancien.
			while _socket != null and _socket.get_available_packet_count() > 0:
				_handle_packet(_socket.get_packet())
		WebSocketPeer.STATE_CLOSED, WebSocketPeer.STATE_CLOSING:
			_on_disconnected()

## Ouvre le canal et s'abonne aux `tables` (schéma `public`) pour le compte `user_id`.
## Rappelable à tout moment (reconnexion après une coupure de jeton, par exemple) : referme
## proprement une connexion existante avant d'en ouvrir une nouvelle.
func start(base_url: String, anon_key: String, access_token: String, user_id: String,
		tables: Array[String]) -> void:
	stop()
	_url = base_url
	_anon_key = anon_key
	_access_token = access_token
	_user_id = user_id
	_tables = tables
	_wanted = true
	_reconnect_attempt = 0
	_open_socket()

## Nouveau jeton (renouvellement de session) : on rejoint le canal avec, sans attendre une
## coupure — un jeton expiré couperait sinon silencieusement les notifications jusqu'au
## prochain cycle de reconnexion.
func update_token(access_token: String) -> void:
	_access_token = access_token
	if _joined:
		_joined = false   # force un nouveau phx_join, qui repasse le jeton à jour
		_join_sent = false

func stop() -> void:
	_wanted = false
	_joined = false
	_join_sent = false
	_warned_tables.clear()
	if _socket != null:
		_socket.close()
		_socket = null

func _open_socket() -> void:
	_socket = WebSocketPeer.new()
	var ws_url := _url.replace("https://", "wss://").replace("http://", "ws://") \
		+ "/realtime/v1/websocket?apikey=%s&vsn=1.0.0" % _anon_key.uri_encode()
	var err := _socket.connect_to_url(ws_url)
	if err != OK:
		push_warning("RealtimeClient : connexion impossible (code %d)." % err)
		_socket = null
		_schedule_reconnect()

func _send_join() -> void:
	var changes := []
	for table in _tables:
		changes.append({
			"event": "*", "schema": "public", "table": table,
			"filter": "owner_id=eq.%s" % _user_id,
		})
	_join_ref = _next_ref()
	_send({
		"topic": JOIN_TOPIC, "event": "phx_join", "ref": _join_ref,
		"payload": {"config": {"postgres_changes": changes}, "access_token": _access_token},
	})

func _send_heartbeat() -> void:
	_send({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": _next_ref()})

func _handle_packet(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var event := str(parsed.get("event", ""))
	var payload: Dictionary = parsed.get("payload", {})

	match event:
		"phx_reply":
			if str(parsed.get("ref", "")) == _join_ref and payload.get("status") == "ok":
				_joined = true
				_heartbeat_elapsed = 0.0
				_reconnect_attempt = 0   # connexion pleinement établie : on repart de zéro
		"system":
			# Une table dont l'abonnement échoue (Realtime non activé pour elle côté
			# projet, cf. schéma) — le canal reste valide pour les autres.
			if payload.get("status") == "error":
				var table := _table_from_system_message(str(payload.get("message", "")))
				if table != "" and not _warned_tables.has(table):
					_warned_tables[table] = true
					subscribe_failed.emit(table, str(payload.get("message", "")))
		"phx_error", "phx_close":
			_on_disconnected()
		"postgres_changes":
			changed.emit()
		_:
			pass   # heartbeat ack, etc. — rien à faire

## Le message d'erreur serveur nomme la table entre guillemets dans son texte libre
## (« table: recipes » côté filtre) — on l'extrait pour ne prévenir qu'une fois PAR table
## plutôt qu'à chaque reconnexion, sans dépendre d'un format stable au-delà de ce repérage.
func _table_from_system_message(message: String) -> String:
	var marker := "table: "
	var idx := message.find(marker)
	if idx == -1:
		return ""
	var rest := message.substr(idx + marker.length())
	return rest.split(",")[0].strip_edges()

func _on_disconnected() -> void:
	_socket = null
	_joined = false
	_join_sent = false
	if _wanted:
		_schedule_reconnect()

func _schedule_reconnect() -> void:
	var idx := mini(_reconnect_attempt, RECONNECT_BACKOFF_S.size() - 1)
	_reconnect_wait = RECONNECT_BACKOFF_S[idx]
	_reconnect_attempt += 1

func _send(msg: Dictionary) -> void:
	if _socket != null:
		_socket.send_text(JSON.stringify(msg))

func _next_ref() -> String:
	_ref_counter += 1
	return str(_ref_counter)
