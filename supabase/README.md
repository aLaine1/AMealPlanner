# Phase 2 — mise en place de Supabase

Marche à suivre côté Supabase. Tout est à faire **une seule fois**, sur un seul projet,
puisque le modèle retenu est un **compte unique de foyer** partagé entre les appareils.

## 1. Créer le projet

1. Sur [supabase.com](https://supabase.com), créer un projet (plan gratuit suffisant :
   le jeu de données fait quelques centaines de lignes).
2. Choisir une **région proche** (`eu-west-3` / Paris) — la latence n'est pas critique,
   la sync est en arrière-plan, mais autant.
3. Noter la phrase secrète de la base de données quelque part de sûr.

## 2. Exécuter le schéma

Dans **SQL Editor** → nouvelle requête → coller le contenu de [`schema.sql`](schema.sql)
→ **Run**. Le script est idempotent : on peut le rejouer sans casse si le schéma évolue.

> ⚠️ **À rejouer avant d'installer la version 1.10.0**, qui ajoute les notifications en
> temps réel (Realtime). Le bloc de migration en fin de fichier ajoute les tables de sync à
> la publication `supabase_realtime` ; sans lui l'app fonctionne normalement mais retombe sur
> sa sonde périodique (une réactivité nettement moindre, pas une panne).

> ⚠️ **À rejouer avant d'installer la version 1.8**, qui ajoute au planning les jours 0..27,
> la colonne `meal_slot` et la colonne `servings` des recettes. Les trois blocs de migration
> sont en fin de fichier et sont idempotents.
>
> Puis, une seule fois, le bloc « Les deux comptes existants » du §6 de
> [`../0_plan_1.8.0.md`](../0_plan_1.8.0.md) : il écrit dans le même éditeur SQL les réglages
> de forme des foyers installés avant la 1.8, et donne 4 parts à leurs recettes. Rien à y
> remplacer, il désigne les comptes par leurs données.

> ⚠️ **À rejouer avant d'installer la version 1.7.5 ou suivante**, sur un projet créé
> avant elle. Le bloc de migration en fin de fichier fait passer la clé primaire des
> tables à `id` (`recipes`, `ingredients`, `categories`, `breakfasts`, `staples`,
> `aisles`) de `(id)` à `(owner_id, id)`, ce dont l'application a désormais besoin pour
> ses `upsert`. Dans l'autre ordre, toute synchronisation échoue sur
> `there is no unique or exclusion constraint matching the ON CONFLICT specification`
> (42P10) — sans perte de données, mais sans rien synchroniser non plus.

Vérifier ensuite dans **Table Editor** que les 8 tables sont là et que chacune affiche
le badge **RLS enabled**.

## 3. Créer le compte du foyer

**Authentication** → **Users** → **Add user** → *Create new user* :

- email : une adresse à laquelle vous avez accès ;
- mot de passe : au choix, il sera saisi une fois par appareil ;
- cocher **Auto Confirm User** (sinon la connexion échoue tant que l'email n'est pas
  confirmé, et il n'y a pas de flux de confirmation dans l'app).

Puis **Authentication** → **Providers** → **Email** : laisser *Email* activé et
**désactiver « Enable email signups »**. Personne d'autre ne doit pouvoir créer de
compte — l'app ne propose d'ailleurs que la connexion, jamais l'inscription.

## 4. Récupérer les identifiants pour l'app

**Project Settings** → **API** :

- **Project URL** — de la forme `https://xxxxxxxxxxxx.supabase.co`
- **anon / public key** — la clé publique, celle qui est embarquée dans l'app

> La clé `service_role` ne doit **jamais** entrer dans le projet Godot : elle contourne
> RLS. Seule la clé `anon` est utilisée, et elle n'ouvre rien sans authentification
> puisque toutes les policies exigent `authenticated`.

Ces deux valeurs vont dans `GODOT_REFACTOR/supabase_config.json` (non versionné, voir
le `.gitignore`) — le format attendu est documenté dans `services/SupabaseClient.gd`.

## 5. Plus tard : purge des tombstones

`schema.sql` installe une fonction `purge_tombstones(days)` mais **ne la planifie pas**.
Ne l'activer (via `pg_cron`) qu'une fois la sync en service depuis un moment : purger
un tombstone qu'un appareil n'a pas encore vu ferait réapparaître la ligne supprimée
sur cet appareil. 30 jours est la valeur retenue au plan (§3.4.1).

---

## Notes de conception

**Horodatages.** `updated_at` et `deleted_at` sont des `bigint` en **millisecondes epoch**,
et non des `timestamptz`. Raison : c'est la même représentation que dans le SQLite local,
donc la comparaison LWW est une comparaison d'entiers des deux côtés, sans parsing ni
fuseau. `server_now_ms()` permet de mesurer l'offset d'horloge de l'appareil au login.

**Invariant des suppressions.** Une suppression écrit `deleted_at` **et** `updated_at` à la
même valeur. Le pull incrémental filtre sur `updated_at > curseur` : sans cela, les
tombstones ne seraient jamais récupérés et les suppressions ne se propageraient pas.

**Recette = agrégat.** `recipes.ingredients` et `recipes.categories` sont des `jsonb` portés
par la ligne recette, pas des tables de liaison. Deux appareils qui éditent la même recette
hors-ligne : le plus récent gagne en entier. Écart assumé par rapport à la lettre du
§3.4.1 du plan, décidé pour éviter une machinerie de diff disproportionnée à l'échelle
d'un foyer. Les `ingredient_id` cités dans le jsonb **n'ont pas de contrainte FK** : lors
d'une sync, rien ne garantit qu'une recette n'arrive pas avant l'ingrédient qu'elle cite.

**Clés naturelles.** `meal_plan_positions` et `breakfast_slots` sont clés sur la position,
pas sur un uuid : deux appareils convergent ainsi sur la même ligne sans s'être concertés.
Même logique pour `shopping_items`, clé sur un `item_key` dérivé du nom et de l'unité
normalisés.
