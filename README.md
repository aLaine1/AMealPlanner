# AMeal Planner

Planificateur de repas pour le foyer : un planning sur une à quatre semaines, rempli à la main
ou tiré au sort parmi vos recettes, et la liste de courses qui en découle, rangée par rayon.
Sur Android, Windows et dans le navigateur, synchronisé entre les appareils de la maison.

**[Ouvrir la version web](https://alaine1.github.io/AMealPlanner/)** ·
**[Télécharger la dernière version](https://github.com/aLaine1/AMealPlanner/releases/latest)**

## Fonctionnalités

- **Planning des repas** — un ou deux repas par jour, sur une à quatre semaines, à partir du
  jour de courses. Glisser-déposer depuis la bibliothèque, échange entre cases, plats libres
  (« Restaurant »…), annuler / rétablir.
- **Planification aléatoire** — remplit le planning selon la saison (Hiver / Mix / Été), sans
  doublon ni même catégorie deux jours de suite ; une case seule peut être retirée au sort.
- **Repas réservés** — les repas qui ne sont pas suivis d'une gamelle sont réservés aux plats
  qui ne se transportent pas ; les autres restent pour les jours où l'on emporte les restes.
- **Petits déjeuners** — un choix à part, qui alimente lui aussi la liste de courses.
- **Liste de courses** — quantités cumulées par ingrédient, regroupées par rayon dans l'ordre du
  magasin, articles de base ajoutés d'office, cases à cocher ; vue « magasin » sur téléphone.
- **Recettes** — saison, catégories, ingrédients et quantités, étapes, nombre de parts
  (quantités remises à l'échelle), photo cadrée ; recherche tolérante aux accents.
- **Partage** — une recette s'envoie par un code ou un QR code, lisible sans compte.
- **Synchronisation** — un compte pour le foyer, et chaque appareil garde sa copie complète :
  l'application reste pleinement utilisable hors ligne.
- **Apparence** — quatre thèmes de couleur (vert, orange, bleu, sombre), mise en page adaptée
  au téléphone comme au grand écran.

## Installer

| Plateforme | Fichier | Remarques |
|---|---|---|
| **Android** | `AMealPlanner-<version>.apk` | Autoriser l'installation d'applications de source inconnue. Les mises à jour s'installent par-dessus, données conservées. |
| **Windows** | `AMealPlanner-<version>-setup.exe` | Installe sans droits administrateur et se met à jour par-dessus. Non signé : SmartScreen avertit au premier lancement (« Informations complémentaires » → « Exécuter quand même »). |
| **Windows (portable)** | `AMealPlanner-<version>-windows.zip` | À décompresser ; garder la DLL à côté de l'exécutable. |
| **Web** | [alaine1.github.io/AMealPlanner](https://alaine1.github.io/AMealPlanner/) | Pour une utilisation nomade : rien n'est conservé sur le poste. |

Les fichiers sont joints à chaque [version publiée](https://github.com/aLaine1/AMealPlanner/releases).

### La version web

Faite pour dépanner quand on n'a pas ses appareils sous la main. Elle vise l'**ordinateur**
(pas d'adaptation au téléphone) et **ne garde rien sur le poste** : connexion obligatoire à
chaque ouverture, données tenues en mémoire le temps de la visite, et tout est oublié à la
déconnexion ou à la fermeture de l'onglet. Les modifications partent sur le compte au fil de
l'eau, comme depuis les autres appareils.

## Compte et synchronisation

La synchronisation passe par [Supabase](https://supabase.com). Un seul compte est partagé par
les appareils du foyer ; l'application ne propose que la connexion, les comptes se créent côté
Supabase. La connexion est demandée au premier lancement, puis plus jamais sur cet appareil
(sauf en version web, à chaque ouverture).

Chaque appareil garde sa propre base (SQLite) et échange ses modifications ligne par ligne : la
plus récente l'emporte. Une coupure réseau n'interrompt rien, l'envoi reprend au retour de la
connexion.

Héberger sa propre instance : voir [`supabase/README.md`](supabase/README.md).

## Développement

Projet [Godot 4.7](https://godotengine.org) en GDScript ; code et commentaires en français.

```bash
godot --editor --path .          # ouvrir dans l'éditeur
godot --path .                   # lancer l'application
tools/run_tests.sh               # suites de tests headless, sur une base jetable
```

Pour la synchronisation, copier `supabase_config.example.json` en `supabase_config.json` et le
compléter (ce fichier n'est pas versionné).

| Document | Contenu |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Architecture et règles à connaître avant de modifier le code. |
| [`release_prod.md`](release_prod.md) | Publier une version : APK signé, Windows, web. |
| [`supabase/README.md`](supabase/README.md) | Schéma Postgres, règles d'accès, mise en place du serveur. |
| [`docs/NOTES_DEVELOPPEMENT.md`](docs/NOTES_DEVELOPPEMENT.md) | Journal de développement : décisions et pièges, version après version. |

L'addon [godot-sqlite](https://github.com/2shady4u/godot-sqlite) est inclus (binaires
compris), en v4.4 — sauf pour le web, en v4.9 ; les raisons sont dans `CLAUDE.md`.

---

AMeal Planner est né en Python (CustomTkinter, versions 1.0.x) ; il a depuis été entièrement
réécrit avec Godot.
