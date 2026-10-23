-- AMeal Planner — schéma Supabase (Phase 2)
-- À exécuter tel quel dans l'éditeur SQL du projet Supabase (une seule fois).
-- Idempotent : réexécutable sans casse.
--
-- Modèle : compte unique de foyer. Chaque ligne porte owner_id = auth.uid() ;
-- les policies RLS ne laissent voir/écrire que ses propres lignes. Un seul compte
-- étant utilisé, cela revient à un jeu de données partagé, mais sans fuite si un
-- second compte est créé un jour.
--
-- Stratégie de sync : LWW par ligne + tombstones (cf. GODOT_REFACTOR_PLAN.md §3.4.1).
--   * updated_at : bigint, epoch en MILLISECONDES, daté au moment de l'édition sur
--     l'appareil (pas au moment de la sync).
--   * deleted_at : bigint nullable. INVARIANT : toute suppression écrit
--     deleted_at ET updated_at à la même valeur, sinon le tombstone ne serait
--     jamais récupéré par un pull incrémental filtré sur updated_at.
--
-- Granularité : la recette est un AGRÉGAT — ses ingrédients et ses catégories
-- vivent en jsonb sur la ligne recette et suivent son updated_at. Décision prise
-- avec l'utilisateur (le §3.4.1 évoquait du LWW par ligne de liaison ; jugé
-- disproportionné pour un usage foyer). Idem pour les petits déjeuners.

-- =====================================================================
-- Entités principales
-- =====================================================================

create table if not exists public.recipes (
    id          uuid    not null,
    owner_id    uuid    not null default auth.uid() references auth.users (id) on delete cascade,
    name        text    not null,
    season      text    not null default 'toute',   -- 'ete' | 'hiver' | 'toute'
    nobox       boolean not null default false,
    steps       text    not null default '',
    -- Parts pour lesquelles la recette est écrite. 0 = non renseigné, lu « autant que le
    -- foyer » : le facteur d'échelle vaut alors 1 (1.8, décision D4).
    servings    int     not null default 0,
    -- [{ "ingredient_id": uuid, "quantity": number, "unit": text }, ...]
    ingredients jsonb   not null default '[]'::jsonb,
    -- ["Pâtes", "Légumes", ...]  (noms de catégories, cf. table categories)
    categories  jsonb   not null default '[]'::jsonb,
    updated_at  bigint  not null,
    deleted_at  bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

create table if not exists public.ingredients (
    id         uuid   not null,
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    name       text   not null,
    aisle      text   not null default 'Divers',   -- rayon magasin
    updated_at bigint not null,
    deleted_at bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

create table if not exists public.categories (
    id         uuid   not null,
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    name       text   not null,
    updated_at bigint not null,
    deleted_at bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

create table if not exists public.breakfasts (
    id          uuid   not null,
    owner_id    uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    name        text   not null,
    ingredients jsonb  not null default '[]'::jsonb,
    updated_at  bigint not null,
    deleted_at  bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

-- Articles de base / courses récurrentes (F3 + F4 fusionnés).
create table if not exists public.staples (
    id         uuid   not null,
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    name       text   not null,
    aisle      text   not null default 'Autres',
    quantity   real   not null default 1,
    unit       text   not null default '',
    updated_at bigint not null,
    deleted_at bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

-- =====================================================================
-- État applicatif synchronisé
-- =====================================================================

-- Planning : 14 lignes indépendantes, une par position. La clé naturelle
-- (owner_id, position) garantit que deux appareils convergent sur LA MÊME ligne
-- sans coordination d'id — réarranger des cases différentes en parallèle fusionne
-- proprement, seule une même case éditée des deux côtés applique LWW.
create table if not exists public.meal_plan_positions (
    owner_id     uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    -- nommé position_index et non "position" : POSITION est un mot-clé de fonction SQL.
    -- Le JOUR du planning, 0 à 27 : de 1 à 4 semaines depuis la 1.8.
    position_index int  not null check (position_index between 0 and 27),
    -- Le repas dans la journée : 0 = midi ou repas unique, 1 = soir. Seconde coordonnée, et
    -- non un pas plus fin sur la première : activer le second repas ne doit RIEN renuméroter.
    meal_slot    int    not null default 0 check (meal_slot between 0 and 1),
    recipe_id    uuid,                          -- null = case vide
    custom_label text   not null default '',    -- plat saisi à la main (clic droit > Ajouter)
    updated_at   bigint not null,
    deleted_at   bigint,
    primary key (owner_id, position_index, meal_slot)
);

-- Petits déjeuners sélectionnés : 4 slots, même logique de clé naturelle.
create table if not exists public.breakfast_slots (
    owner_id     uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    slot         int    not null check (slot between 0 and 3),
    breakfast_id uuid,
    updated_at   bigint not null,
    deleted_at   bigint,
    primary key (owner_id, slot)
);

-- Liste de courses : une ligne par article. item_key est une clé stable dérivée du
-- nom + unité normalisés, pour que deux appareils qui génèrent la même liste
-- produisent les mêmes clés. C'est le cas de conflit le plus fréquent (cocher en
-- magasin) : items différents → fusion triviale, même item → dernier geste gagne.
create table if not exists public.shopping_items (
    owner_id   uuid    not null default auth.uid() references auth.users (id) on delete cascade,
    item_key   text    not null,
    name       text    not null,
    aisle      text    not null default 'Autres',
    quantity   real    not null default 0,
    unit       text    not null default '',
    checked    boolean not null default false,
    updated_at bigint  not null,
    deleted_at bigint,
    primary key (owner_id, item_key)
);

-- =====================================================================
-- Index : le pull incrémental filtre sur (owner_id, updated_at > curseur)
-- =====================================================================

create index if not exists recipes_sync_idx             on public.recipes             (owner_id, updated_at);
create index if not exists ingredients_sync_idx         on public.ingredients         (owner_id, updated_at);
create index if not exists categories_sync_idx          on public.categories          (owner_id, updated_at);
create index if not exists breakfasts_sync_idx          on public.breakfasts          (owner_id, updated_at);
create index if not exists staples_sync_idx             on public.staples             (owner_id, updated_at);
create index if not exists meal_plan_positions_sync_idx on public.meal_plan_positions (owner_id, updated_at);
create index if not exists breakfast_slots_sync_idx     on public.breakfast_slots     (owner_id, updated_at);
create index if not exists shopping_items_sync_idx      on public.shopping_items      (owner_id, updated_at);

-- =====================================================================
-- RLS — chaque compte ne voit que ses lignes
-- =====================================================================

do $$
declare t text;
begin
    foreach t in array array[
        'recipes', 'ingredients', 'categories', 'breakfasts', 'staples',
        'meal_plan_positions', 'breakfast_slots', 'shopping_items'
    ] loop
        execute format('alter table public.%I enable row level security;', t);
        execute format('drop policy if exists own_rows on public.%I;', t);
        -- using : lignes visibles en lecture/update/delete
        -- with check : lignes autorisées en insert/update — empêche d'écrire pour autrui
        execute format(
            'create policy own_rows on public.%I for all to authenticated
                 using (owner_id = auth.uid()) with check (owner_id = auth.uid());', t);
    end loop;
end $$;

-- =====================================================================
-- Horloge serveur — sert à corriger la dérive d'horloge des appareils (§3.4.1).
-- Appelée au login : POST /rest/v1/rpc/server_now_ms
-- =====================================================================

create or replace function public.server_now_ms()
returns bigint
language sql
stable
as $$ select (extract(epoch from now()) * 1000)::bigint $$;

grant execute on function public.server_now_ms() to authenticated;

-- =====================================================================
-- Purge des tombstones (§3.4.1 : conservés ~30 jours puis supprimés).
-- À planifier via pg_cron une fois que la sync tourne, PAS avant : purger des
-- tombstones qu'un appareil n'a pas encore vus ferait « ressusciter » ses lignes.
-- =====================================================================

create or replace function public.purge_tombstones(older_than_days int default 30)
returns void
language plpgsql
security invoker
as $$
declare
    t      text;
    cutoff bigint := (extract(epoch from now()) * 1000)::bigint
                     - (older_than_days::bigint * 86400000);
begin
    -- `aisles` et `recipe_photos` manquaient : toutes deux sont nées après cette
    -- fonction, et le même oubli avait déjà laissé les rayons hors de la
    -- réconciliation des homonymes. Leurs tombstones s'accumulaient donc sans fin.
    foreach t in array array[
        'recipes', 'ingredients', 'categories', 'breakfasts', 'staples', 'aisles',
        'meal_plan_positions', 'breakfast_slots', 'shopping_items', 'recipe_photos'
    ] loop
        execute format(
            'delete from public.%I where deleted_at is not null and deleted_at < $1;', t)
            using cutoff;
    end loop;
end $$;

-- =====================================================================
-- Sonde de fraîcheur (ajoutée en 1.1) — renvoie le plus grand `updated_at`
-- toutes tables confondues, pour le compte appelant.
--
-- Permet d'interroger le serveur toutes les quelques secondes avec UNE requête
-- minuscule au lieu des huit requêtes de pull. Sans elle, une détection rapide des
-- changements coûterait ~70 000 requêtes par appareil et par jour ; avec elle,
-- environ 8 000, et un pull complet n'a lieu que lorsque quelque chose a bougé.
-- =====================================================================

create or replace function public.sync_watermark()
returns bigint
language sql
stable
as $$
    select coalesce(max(m), 0) from (
        select max(updated_at) as m from public.recipes             where owner_id = auth.uid()
        union all select max(updated_at) from public.ingredients         where owner_id = auth.uid()
        union all select max(updated_at) from public.categories          where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfasts          where owner_id = auth.uid()
        union all select max(updated_at) from public.staples             where owner_id = auth.uid()
        union all select max(updated_at) from public.meal_plan_positions where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfast_slots     where owner_id = auth.uid()
        union all select max(updated_at) from public.shopping_items      where owner_id = auth.uid()
    ) t
$$;

grant execute on function public.sync_watermark() to authenticated;

-- =====================================================================
-- Rayons (ajoutés en 1.1) — l'ordre de parcours en magasin est propre à chaque
-- foyer, et « Picard » n'a de sens que pour certains. Trois listes codées en dur
-- dans l'application les remplaçaient jusqu'ici, et avaient déjà divergé.
--
-- Les ingrédients référencent le rayon par son NOM, pas par cet identifiant :
-- même parti pris que les catégories de recettes. Renommer un rayon reporte donc
-- le nouveau nom sur tout ce qui le référence, côté application.
-- =====================================================================

create table if not exists public.aisles (
    id         uuid   not null,
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    name       text   not null,
    sort_order int    not null default 0,
    updated_at bigint not null,
    deleted_at bigint,
    -- (owner_id, id) et non (id) seul : cf. la migration en fin de fichier.
    primary key (owner_id, id)
);

create index if not exists aisles_sync_idx on public.aisles (owner_id, updated_at);

alter table public.aisles enable row level security;
drop policy if exists own_rows on public.aisles;
create policy own_rows on public.aisles for all to authenticated
    using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- La sonde de fraîcheur doit voir cette table, sinon un rayon renommé sur un
-- appareil ne déclencherait aucune synchronisation sur l'autre.
create or replace function public.sync_watermark()
returns bigint
language sql
stable
as $$
    select coalesce(max(m), 0) from (
        select max(updated_at) as m from public.recipes             where owner_id = auth.uid()
        union all select max(updated_at) from public.ingredients         where owner_id = auth.uid()
        union all select max(updated_at) from public.categories          where owner_id = auth.uid()
        union all select max(updated_at) from public.aisles              where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfasts          where owner_id = auth.uid()
        union all select max(updated_at) from public.staples             where owner_id = auth.uid()
        union all select max(updated_at) from public.meal_plan_positions where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfast_slots     where owner_id = auth.uid()
        union all select max(updated_at) from public.shopping_items      where owner_id = auth.uid()
    ) t
$$;

grant execute on function public.sync_watermark() to authenticated;

-- =====================================================================
-- Réglages du foyer (ajoutés en 1.2) — décrivent COMMENT le planning est
-- construit, donc partagés entre les appareils. À distinguer de la table `meta`
-- locale, qui garde les curseurs de synchronisation et les préférences
-- d'affichage propres à chaque appareil.
-- =====================================================================

create table if not exists public.settings (
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    key        text   not null,
    value      text   not null default '',
    updated_at bigint not null,
    deleted_at bigint,
    primary key (owner_id, key)
);

create index if not exists settings_sync_idx on public.settings (owner_id, updated_at);

alter table public.settings enable row level security;
drop policy if exists own_rows on public.settings;
create policy own_rows on public.settings for all to authenticated
    using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function public.sync_watermark()
returns bigint
language sql
stable
as $$
    select coalesce(max(m), 0) from (
        select max(updated_at) as m from public.recipes             where owner_id = auth.uid()
        union all select max(updated_at) from public.ingredients         where owner_id = auth.uid()
        union all select max(updated_at) from public.categories          where owner_id = auth.uid()
        union all select max(updated_at) from public.aisles              where owner_id = auth.uid()
        union all select max(updated_at) from public.settings            where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfasts          where owner_id = auth.uid()
        union all select max(updated_at) from public.staples             where owner_id = auth.uid()
        union all select max(updated_at) from public.meal_plan_positions where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfast_slots     where owner_id = auth.uid()
        union all select max(updated_at) from public.shopping_items      where owner_id = auth.uid()
    ) t
$$;

grant execute on function public.sync_watermark() to authenticated;

-- =====================================================================
-- Photos de recettes (ajoutées en 1.5) — une par recette, dans sa propre
-- table : côté client, la lire avec la recette traînerait plusieurs mégaoctets
-- à chaque rafraîchissement du cache.
--
-- Les images sont du base64 en `text`, et non du `bytea`. PostgREST rend le
-- bytea en hexadécimal échappé, plus lourd que le base64 et à reconvertir des
-- deux côtés ; en texte, la ligne traverse le moteur de synchronisation sans
-- qu'il ait le moindre cas particulier à connaître.
-- =====================================================================

create table if not exists public.recipe_photos (
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    recipe_id  text   not null,
    image      text   not null,
    thumb      text   not null,
    updated_at bigint not null,
    deleted_at bigint,
    primary key (owner_id, recipe_id)
);

create index if not exists recipe_photos_sync_idx on public.recipe_photos (owner_id, updated_at);

alter table public.recipe_photos enable row level security;
drop policy if exists own_rows on public.recipe_photos;
create policy own_rows on public.recipe_photos for all to authenticated
    using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function public.sync_watermark()
returns bigint
language sql
stable
as $$
    select coalesce(max(m), 0) from (
        select max(updated_at) as m from public.recipes             where owner_id = auth.uid()
        union all select max(updated_at) from public.ingredients         where owner_id = auth.uid()
        union all select max(updated_at) from public.categories          where owner_id = auth.uid()
        union all select max(updated_at) from public.aisles              where owner_id = auth.uid()
        union all select max(updated_at) from public.settings            where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfasts          where owner_id = auth.uid()
        union all select max(updated_at) from public.staples             where owner_id = auth.uid()
        union all select max(updated_at) from public.recipe_photos       where owner_id = auth.uid()
        union all select max(updated_at) from public.meal_plan_positions where owner_id = auth.uid()
        union all select max(updated_at) from public.breakfast_slots     where owner_id = auth.uid()
        union all select max(updated_at) from public.shopping_items      where owner_id = auth.uid()
    ) t
$$;

grant execute on function public.sync_watermark() to authenticated;

-- =====================================================================
-- Partages de recettes (ajoutés en 1.6) — le QR ne transporte plus les
-- recettes mais un JETON ; le contenu vit ici. C'est ce qui permet d'y
-- joindre les photos : un QR lisible plafonne à ~1200 octets, une photo
-- normalisée en pèse 131 000.
-- =====================================================================

create table if not exists public.shared_bundles (
    token      text   primary key,
    owner_id   uuid   not null default auth.uid() references auth.users (id) on delete cascade,
    payload    text   not null,
    created_at bigint not null,
    expires_at bigint not null
);

create index if not exists shared_bundles_expiry_idx on public.shared_bundles (expires_at);

-- RLS : le propriétaire voit SES partages (pour les relire ou les révoquer), et
-- personne d'autre n'a d'accès direct à la table — surtout pas `anon`.
--
-- C'est le point critique de ce mécanisme. La clé anonyme est embarquée dans
-- l'application, donc publique : la moindre policy de lecture ouverte à `anon`
-- permettrait à quiconque possède l'APK de faire un SELECT sans filtre et de
-- récupérer les recettes et les photos de TOUS les foyers. Le contenu ne
-- s'obtient donc que par la fonction ci-dessous, qui exige le jeton.
alter table public.shared_bundles enable row level security;
drop policy if exists own_bundles on public.shared_bundles;
create policy own_bundles on public.shared_bundles for all to authenticated
    using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Lecture par jeton, ouverte à tous : le destinataire n'a pas de compte — c'est
-- toute la raison d'un partage. `security definer` fait tourner la fonction avec
-- les droits du propriétaire, contournant la RLS pour cette seule requête, qui
-- ne peut rendre qu'une ligne et seulement si l'on connaît son jeton.
create or replace function public.fetch_shared_bundle(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_payload text;
begin
    select payload into v_payload
      from public.shared_bundles
     where token = p_token
       and expires_at > (extract(epoch from now()) * 1000)::bigint;
    -- NULL si le jeton est inconnu OU périmé : le client ne distingue pas les
    -- deux cas, ce qui évite de confirmer l'existence d'un partage à qui essaie
    -- des jetons au hasard.
    return v_payload;
end $$;

grant execute on function public.fetch_shared_bundle(text) to anon, authenticated;

-- Publication. Passe par une fonction plutôt que par un INSERT direct pour trois
-- raisons : le jeton est tiré côté serveur (128 bits, hors de portée d'une
-- énumération), la taille est bornée, et les partages périmés sont balayés au
-- passage — un ménage opportuniste qui évite d'avoir à installer un cron.
create or replace function public.publish_shared_bundle(p_payload text, p_days int default 30)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_token text;
    v_now bigint := (extract(epoch from now()) * 1000)::bigint;
begin
    if auth.uid() is null then
        raise exception 'authentification requise pour publier un partage';
    end if;
    if p_payload is null or length(p_payload) = 0 then
        raise exception 'partage vide';
    end if;
    if length(p_payload) > 8000000 then
        raise exception 'partage trop volumineux';
    end if;

    delete from public.shared_bundles where expires_at < v_now;

    v_token := replace(gen_random_uuid()::text, '-', '');
    insert into public.shared_bundles (token, owner_id, payload, created_at, expires_at)
    values (v_token, auth.uid(), p_payload, v_now, v_now + (p_days::bigint * 86400000));
    return v_token;
end $$;

grant execute on function public.publish_shared_bundle(text, int) to authenticated;

-- =====================================================================
-- Migration : clé primaire (owner_id, id) sur les tables à id
-- =====================================================================
--
-- `id` seul était la clé primaire : une même ligne ne pouvait exister que pour UN
-- compte, sur l'ensemble du projet. Un appareil qui change de compte pousse ses lignes
-- locales avec le nouvel owner_id ; l'upsert tombait alors sur la ligne de l'ancien
-- compte, et `ON CONFLICT DO UPDATE` la modifie — ce que la RLS refuse, à raison :
--
--     new row violates row-level security policy (USING expression) for table "categories"
--
-- Ce message est réservé à ce cas précis : c'est la RLS qui a arrêté une écriture
-- inter-comptes. La cause première est côté application — une base locale = un compte,
-- cf. LocalDatabase.claim_account. Cette clé composite en est le garde-fou structurel :
-- deux comptes peuvent désormais détenir le même id sans se rencontrer, et aucun push
-- ne peut plus atteindre la ligne d'autrui, quelle que soit l'erreur en amont.
--
-- Idempotent : ne fait rien si la clé compte déjà deux colonnes. Sans danger sur les
-- données en place — `id` y étant unique globalement, aucun doublon n'est possible.
-- Aucune table applicative ne référence ces clés (les liens voyagent en jsonb, les
-- rayons par leur nom) : il n'y a donc aucune contrainte à rétablir derrière.
do $$
declare
    t text;
    pk_name text;
    pk_cols int;
begin
    foreach t in array array[
        'recipes', 'ingredients', 'categories', 'breakfasts', 'staples', 'aisles'
    ] loop
        select con.conname, cardinality(con.conkey) into pk_name, pk_cols
        from pg_constraint con
        where con.conrelid = format('public.%I', t)::regclass and con.contype = 'p';

        if pk_name is not null and pk_cols = 1 then
            execute format('alter table public.%I drop constraint %I;', t, pk_name);
            execute format('alter table public.%I alter column id set not null;', t);
            execute format('alter table public.%I add primary key (owner_id, id);', t);
            raise notice 'clé primaire de % : (owner_id, id)', t;
        end if;
    end loop;
end $$;

-- =====================================================================
-- Migration : le planning s'étend et se divise (1.8)
-- =====================================================================
--
-- Trois changements sur `meal_plan_positions`, à jouer AVANT d'installer une 1.8 :
--
--   * `position_index` monte de 13 à 27 : le planning couvre de 1 à 4 semaines ;
--   * `meal_slot` apparaît : 0 = midi ou repas unique, 1 = soir ;
--   * la clé primaire devient (owner_id, position_index, meal_slot).
--
-- `meal_slot = 0` par défaut laisse les lignes existantes exactement où elles sont : le jour
-- ne change pas de numéro, et c'est tout l'intérêt d'une seconde coordonnée plutôt que d'un
-- pas plus fin. Un client 1.7 continue d'ailleurs de lire et d'écrire ces lignes-là.
--
-- Idempotent : chaque étape vérifie son état avant d'agir.
do $$
begin
    if not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'meal_plan_positions'
          and column_name = 'meal_slot'
    ) then
        alter table public.meal_plan_positions
            add column meal_slot int not null default 0;
        alter table public.meal_plan_positions
            add constraint meal_plan_positions_meal_slot_check
            check (meal_slot between 0 and 1);
        alter table public.meal_plan_positions
            drop constraint meal_plan_positions_pkey;
        alter table public.meal_plan_positions
            add primary key (owner_id, position_index, meal_slot);
        raise notice 'meal_plan_positions : meal_slot ajouté, clé (owner_id, position_index, meal_slot)';
    end if;

    -- La borne des jours, séparément : elle peut avoir été élargie sans que meal_slot le soit.
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.meal_plan_positions'::regclass
          and conname = 'meal_plan_positions_position_index_check'
          and pg_get_constraintdef(oid) like '%13%'
    ) then
        alter table public.meal_plan_positions
            drop constraint meal_plan_positions_position_index_check;
        alter table public.meal_plan_positions
            add constraint meal_plan_positions_position_index_check
            check (position_index between 0 and 27);
        raise notice 'meal_plan_positions : jours 0..27';
    end if;
end $$;

-- =====================================================================
-- Migration : parts par recette (1.8)
-- =====================================================================
--
-- 0 se lit « autant que le foyer » : ajouter la colonne ne change donc aucune quantité. Les
-- foyers déjà installés reçoivent leur valeur par le SQL de mise en route (cf. plan, §6).
alter table public.recipes add column if not exists servings int not null default 0;

-- =====================================================================
-- Migration : Realtime pour toutes les tables de sync (1.10.0)
-- =====================================================================
--
-- Sans ceci, un appareil ne découvre les modifications d'un autre qu'à la sonde périodique
-- (`SyncEngine.PROBE_INTERVAL_S`, une minute) au lieu d'une notification quasi instantanée.
-- RLS s'applique aux notifications Realtime exactement comme aux requêtes REST : un appareil
-- ne reçoit que les changements qu'il aurait pu lire lui-même — publier la table à toute la
-- publication ne relâche rien côté sécurité.
--
-- `alter publication ... add table` échoue si la table y est déjà (contrairement à un DDL
-- normal, pas de variante IF NOT EXISTS avant Postgres 15) : on vérifie donc son appartenance
-- avant d'agir, pour que le bloc reste rejouable comme le reste de ce fichier.
do $$
declare
    t text;
begin
    foreach t in array array[
        'categories', 'aisles', 'ingredients', 'recipes', 'breakfasts', 'recipe_photos',
        'staples', 'settings', 'meal_plan_positions', 'breakfast_slots', 'shopping_items'
    ] loop
        if not exists (
            select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
        ) then
            execute format('alter publication supabase_realtime add table public.%I;', t);
            raise notice 'Realtime activé pour %', t;
        end if;
    end loop;
end $$;
