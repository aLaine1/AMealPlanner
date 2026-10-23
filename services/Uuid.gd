extends RefCounted
## Génération d'UUID v4 (GDScript n'en fournit pas).
##
## Pourquoi des UUID et non des INTEGER AUTOINCREMENT : deux appareils du foyer
## éditant hors-ligne attribueraient tous deux le même prochain entier à une
## nouvelle recette, et la première sync les ferait entrer en collision. Un id
## tiré localement doit donc être unique sans coordination.
##
## Pas de `class_name` : le script est chargé par `preload`, ce qui évite de dépendre
## du cache de classes globales de Godot.

## UUID v4 canonique, en minuscules : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".
static func v4() -> String:
	var b := PackedByteArray()
	b.resize(16)
	for i in range(16):
		b[i] = randi() & 0xFF
	# Version 4 (aléatoire) et variant RFC 4122, comme l'exige le type uuid de Postgres.
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80

	var hex := ""
	for i in range(16):
		hex += "%02x" % b[i]
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12),
	]
