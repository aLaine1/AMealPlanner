class_name TextFold
extends RefCounted
## Repli de casse et d'accents, pour des recherches tolérantes.
## Équivalent simplifié d'`unidecode`, dont dépendait la version Python.
##
## Existait en deux exemplaires (PlanningTab et AutocompleteEdit) ; le sélecteur au
## toucher en aurait fait un troisième. Une recherche qui se comporte différemment
## selon l'écran est un défaut difficile à remarquer et pénible à diagnostiquer.

const REPLACEMENTS := {
	"é": "e", "è": "e", "ê": "e", "ë": "e",
	"à": "a", "â": "a", "ä": "a",
	"î": "i", "ï": "i",
	"ô": "o", "ö": "o",
	"û": "u", "ù": "u", "ü": "u",
	"ç": "c",
	# Ligatures : « œufs » et « oeufs » doivent se ranger et se trouver ensemble.
	"œ": "oe", "æ": "ae",
}

static func fold(value: String) -> String:
	var folded := value.to_lower()
	for accented in REPLACEMENTS:
		folded = folded.replace(accented, REPLACEMENTS[accented])
	return folded

## Comparateur alphabétique à passer à `sort_custom`.
##
## `naturalnocasecmp_to` compare les caractères par leur code Unicode : « échalote »
## et « épinards » s'y rangent donc APRÈS « zeste », tous les accentués étant rejetés
## en fin de liste. Trier sur la forme repliée les remet à leur place alphabétique.
static func before(a: String, b: String) -> bool:
	return fold(a).naturalnocasecmp_to(fold(b)) < 0
