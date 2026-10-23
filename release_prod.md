# Procédure de publication

Comment produire une version de production d'**AMeal Planner** : APK Android signé,
exécutable Windows et version web, à partir d'une source de version unique.

Tout est automatisé par `tools/release.sh`. Ce document explique ce que le script fait,
ce qu'il faut préparer **une seule fois**, et ce qui reste manuel.

```bash
tools/release.sh patch      # 0.1.0 -> 0.1.1
tools/release.sh minor      # 0.1.0 -> 0.2.0
tools/release.sh major      # 0.1.0 -> 1.0.0
tools/release.sh 1.4.2      # version explicite
tools/release.sh patch --dry-run     # calcule et affiche, ne construit rien
```

---

## 1. Préparation, à faire une seule fois

### 1.1 Keystore de release

Android exige que **toutes** les mises à jour d'une application soient signées par la
même clé. Une application signée par une autre clé est, pour le système, une
application différente : elle ne peut pas s'installer par-dessus.

> ⚠️ **Ce keystore est irremplaçable.** Le perdre signifie ne plus jamais pouvoir mettre
> à jour l'application installée sur les appareils du foyer — il faudrait la désinstaller
> et tout réinstaller, en perdant au passage la base locale de chaque appareil.
> Sauvegarde-le hors de cette machine, et note le mot de passe ailleurs que dans le dépôt.

Création :

```bash
mkdir -p ~/.keystores
keytool -genkeypair -v \
    -keystore ~/.keystores/amealplanner-release.keystore \
    -alias amealplanner \
    -keyalg RSA -keysize 2048 \
    -validity 10000 \
    -dname "CN=A. Laine, O=AMeal Planner, C=FR"
```

`keytool` demande deux mots de passe (celui du magasin et celui de la clé) : **mets le
même**, Godot n'en transmet qu'un seul.

`-validity 10000` (≈ 27 ans) est la convention Android : une clé expirée ne permet plus
de publier de mise à jour.

Sauvegarde ensuite le fichier ailleurs — clé USB, gestionnaire de mots de passe,
autre machine. Il fait quelques kilo-octets.

### 1.2 Identifiants transmis par l'environnement

Le fichier `export_presets.cfg` est **versionné** : aucun mot de passe ne doit y
figurer. Godot lit donc les identifiants dans l'environnement, et les champs
`keystore/release*` du preset restent volontairement vides.

Crée `~/.amealplanner-release.env`, **hors du dépôt** :

```bash
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$HOME/.keystores/amealplanner-release.keystore"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="amealplanner"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="le-mot-de-passe-choisi"
```

```bash
chmod 600 ~/.amealplanner-release.env
```

À charger avant chaque publication :

```bash
source ~/.amealplanner-release.env
```

Le script s'arrête avec un message clair si l'une des trois variables manque, ou si le
keystore est introuvable.

### 1.3 Outillage

Déjà installé sur cette machine, à refaire seulement sur un poste neuf :

| Élément | Emplacement | Taille |
|---|---|---|
| Templates d'export Godot 4.7 (Android + Windows x86_64 + Web) | `~/.local/share/godot/export_templates/4.7.stable` | 424 Mo |
| SDK Android (`platform-tools`, `build-tools;35.0.0`) | `~/Android/Sdk` | 316 Mo |
| JDK 17 | `/usr/lib/jvm/java-17-openjdk-amd64` | — |
| NSIS (`makensis`) — installeur Windows | paquet `nsis` | 5 Mo |

Chemins renseignés dans `~/.config/godot/editor_settings-4.7.tres`. Détails
d'installation dans `docs/NOTES_DEVELOPPEMENT.md`, section « Construire l'APK de développement ».

Ni gradle ni NDK : l'export standard re-signe l'APK pré-construit et y empaquette les
bibliothèques du GDExtension. Ni `rcedit` ni Wine pour Windows : depuis Godot 4.4,
l'édition des ressources PE est intégrée (`application/modify_resources`).

---

## 2. Numérotation des versions

`application/config/version` dans `project.godot` est la **source unique de vérité**.
Le script la propage partout ; ne modifie jamais les presets à la main.

Convention `MAJEUR.MINEUR.CORRECTIF` :

| Incrément | Quand |
|---|---|
| `patch` | correction de bug, ajustement d'ergonomie, sans changement de comportement |
| `minor` | nouvelle fonctionnalité, changement visible d'interface |
| `major` | rupture — changement de schéma de données, de compte, ou d'usage |

### Le cas particulier d'Android

Android distingue deux notions :

- **`version/name`** — la chaîne affichée, identique à la version du projet ;
- **`version/code`** — un entier qui doit croître **strictement**. Le système refuse
  d'installer une version dont le code est inférieur ou égal à celui déjà présent.

Le script le dérive de la version plutôt que de tenir un compteur séparé, qui finirait
par diverger :

```
version/code = majeur × 10000 + mineur × 100 + correctif
```

`1.0.0` → `10000`, `1.2.3` → `10203`. **Contrainte : mineur et correctif doivent rester
sous 100** — le script s'arrête sinon, plutôt que de produire un code qui régresserait
silencieusement.

Windows attend quatre composantes : le script écrit `X.Y.Z.0` dans `file_version` et
`product_version`.

---

## 3. Publier

```bash
source ~/.amealplanner-release.env
tools/release.sh minor
```

Le script enchaîne :

1. **calcul de la version** à partir de `project.godot` ;
2. **suites de tests** sur une base jetable (`tools/run_tests.sh`) — publication
   interrompue si une suite échoue ; contournable par `--skip-tests`, à éviter ;
3. **vérification du keystore** — présence des trois variables et du fichier ;
4. **propagation de la version** dans `project.godot` et `export_presets.cfg` ;
5. **export Android release**, **export Windows release** puis **export Web release** ;
6. **contrôles de livraison** (section 4) ;
7. **archives zip** des dossiers Windows et web.

Résultat dans `build/release/<version>/` :

```
AMealPlanner-1.2.0.apk               ~28 Mo   à installer sur les téléphones
AMealPlanner-1.2.0.apk.idsig                  signature v4, produite par apksigner
AMealPlanner-1.2.0-windows.zip       ~38 Mo   à distribuer sur PC
AMealPlanner-1.2.0-web.zip           ~20 Mo   à déposer chez un hébergeur statique
windows/, web/                                contenu non compressé des archives
```

### Après le script

```bash
git commit -am "Version 1.2.0"
git tag v1.2.0
```

Le marquage git n'est pas automatisé volontairement : il fige un état du dépôt, et
c'est une décision qui t'appartient.

---

## 4. Contrôles automatiques

Le script refuse de livrer si l'un d'eux échoue. Chacun correspond à un incident réel
ou à une erreur facile à commettre.

| Contrôle | Ce qu'il empêche |
|---|---|
| `libgdsqlite` arm64 présente dans l'APK | L'application démarrerait puis échouerait à ouvrir sa base, sans message clair. |
| `recettes_export_personnel.json` absent | L'export des données privées de l'ancienne base partirait dans un APK distribué. |
| APK **non** signé par `CN=Android Debug` | Un APK signé avec la clé de debug ne peut pas être publié — et surtout ne pourra jamais être mis à jour par la vraie clé. |
| DLL présente à côté de l'exécutable Windows | Même conséquence que pour Android : démarrage puis échec silencieux sur la base. |
| `libgdsqlite` web **sans fils** présente | La page chargerait le moteur puis refuserait de lier le GDExtension, et resterait blanche. |
| Aucun fichier `res://build/` dans le paquet web | Sans `build/.gdignore`, Godot importe les images des exports précédents et les embarque. |

---

## 5. Distribuer

### Android

Pas de Play Store : l'application est destinée au foyer. Installation par transfert
direct.

```bash
~/Android/Sdk/platform-tools/adb install -r build/release/1.2.0/AMealPlanner-1.2.0.apk
```

Ou en copiant l'APK sur le téléphone et en l'ouvrant depuis le gestionnaire de
fichiers — Android demandera d'autoriser l'installation depuis cette source.

`-r` réinstalle par-dessus **en conservant les données** de l'application. C'est le
comportement voulu : la base locale, la session Supabase et les préférences d'affichage
survivent à la mise à jour. Cela n'est possible que parce que la clé de signature ne
change jamais.

### Windows

Deux livrables, produits ensemble :

| Fichier | Pour qui |
|---|---|
| `AMealPlanner-<version>-setup.exe` | **Le choix par défaut.** Installe, met à jour par-dessus, se désinstalle. |
| `AMealPlanner-<version>-windows.zip` | Version portable — clé USB, poste où l'on ne veut rien installer. |

L'installeur existe pour deux raisons. La première est la mise à jour : l'archive
oblige à supprimer l'ancien dossier puis à redécompresser à chaque version, là où
l'installeur remplace la version en place et laisse le raccourci du menu Démarrer
pointer au bon endroit. La seconde est la DLL : dans l'archive, rien n'empêche de
déplacer le seul exécutable en croyant emporter l'application, qui démarre alors puis
échoue à ouvrir sa base.

Il s'installe dans `%LOCALAPPDATA%\Programs\AMealPlanner`, **sans droits
administrateur**, et retrouve une installation existante par sa clé de registre au
lieu d'en poser une deuxième à côté. Si l'application est ouverte au moment de la mise
à jour, il le dit et propose de réessayer — sans ce contrôle, l'installation irait à
son terme en laissant l'ancienne version en place, sans rien signaler.

> **Les données ne sont jamais concernées.** La base et le jeton de compte vivent dans
> `%APPDATA%\Godot\app_userdata\AMeal Planner\`, hors du dossier d'installation. Ni la
> mise à jour ni la désinstallation n'y touchent — c'est pourquoi le désinstalleur ne
> propose pas de « tout supprimer », qui donnerait l'illusion d'un choix sans en être un.

Construit par `makensis` (paquet `nsis`) depuis `tools/installer.nsi`. Absent, le
script se contente d'un avertissement : l'APK et l'archive sont déjà produits et
valides, il n'y a pas de raison d'interrompre toute la publication.

L'exécutable n'est pas signé avec un certificat Authenticode : Windows SmartScreen
affichera un avertissement au premier lancement (« Informations complémentaires » →
« Exécuter quand même »). Un certificat de signature de code est payant et n'a d'intérêt
que pour une distribution large.

### GitHub (code et release)

Le dépôt public [aLaine1/AMealPlanner](https://github.com/aLaine1/AMealPlanner) reçoit un
**instantané par version**, jamais l'historique local : celui-ci contient une clé privée de
compte de service Google et la base personnelle de l'époque Python. Après le commit et le
tag de version :

```bash
tools/publish_github.sh        # code sur main + release vX.Y.Z avec APK, setup, zips
```

Le script publie le commit courant (pas l'arbre de travail), en retire l'export personnel
(`tools/recettes_export_personnel.json`) et refuse de publier s'il trouve une clé privée,
une base `.db`, `supabase_config.json` ou un keystore. Les notes de release reprennent le
message du commit « Version X.Y.Z ».

### Web

Version d'appoint, pour un **ordinateur** d'emprunt (pas d'adaptation mobile) :
connexion obligatoire à chaque ouverture, rien de stocké sur le poste — base en mémoire,
session non enregistrée, déconnexion = page rechargée.

En ligne sur **https://alaine1.github.io/AMealPlanner/** (GitHub Pages, branche
`gh-pages` du dépôt public AMealPlanner — branche qui ne porte que la version compilée,
jamais le code source). Après `tools/release.sh` :

```bash
tools/deploy_web.sh            # met en ligne build/release/<version>/web
```

Le script s'appuie sur `gh` (`~/.local/bin/gh`, connecté une fois par
`gh auth login --web`). Aucun en-tête particulier n'est requis côté hébergeur : l'export
est sans fils d'exécution. Pour l'essayer en local :

```bash
python3 -m http.server 8000 --directory build/release/<version>/web
```

Ouvrir directement `index.html` depuis le disque ne fonctionne pas : le navigateur
refuse de charger le moteur depuis `file://`.

---

## 6. Après une mise à jour, sur les appareils

La base locale migre toute seule au premier lancement (`LocalDatabase.SCHEMA_VERSION`),
et la synchronisation reprend d'elle-même. Rien à faire manuellement.

Deux points de vigilance quand une version touche au schéma de données :

- **Publier sur tous les appareils** avant qu'ils ne se synchronisent, si le format des
  lignes échangées change. Une version ancienne recevant des lignes d'un format récent
  peut les mal interpréter.
- **Vérifier la migration sur une copie** de la base avant de publier :

```bash
cp ~/.local/share/godot/app_userdata/AMeal\ Planner/mealplanner.db /tmp/verif.db
MEALPLANNER_DB=/tmp/verif.db tools/run_tests.sh
```

`MEALPLANNER_DB` détourne `LocalDatabase` vers une autre base — le même mécanisme que
celui qui isole les tests.
