#!/usr/bin/env python3
"""
One-shot migration : recettes.db (SQLite, colonnes accentuées) -> seed JSON normalisé (ASCII).

Sortie : GODOT_REFACTOR/data/mealplanner_seed.json

Le PoC Godot charge ce JSON via DataStore.gd. Quand on passera à godot-sqlite,
ce même schéma normalisé servira de base au fichier .db local et au Postgres Supabase.

Usage :
    python3 GODOT_REFACTOR/tools/migrate_db_to_json.py [chemin_recettes.db]
"""

import json
import sqlite3
import sys
import pathlib

# Mapping des saisons vers des clés ASCII stables
SEASON_MAP = {
    "Été": "ete",
    "Ete": "ete",
    "Hiver": "hiver",
    "Toute": "toute",
}

ROOT = pathlib.Path(__file__).resolve().parents[2]  # .../MealPlanner_Refactored
DEFAULT_DB = ROOT / "recettes.db"
OUT_PATH = ROOT / "GODOT_REFACTOR" / "data" / "mealplanner_seed.json"


def normalize_season(raw: str) -> str:
    if raw is None:
        return "toute"
    return SEASON_MAP.get(raw.strip(), raw.strip().lower())


def main(db_path: pathlib.Path) -> None:
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # --- Ingrédients (aisle = category = rayon magasin) ---
    ingredients = []
    cur.execute("SELECT id, nom, category FROM Ingrédients ORDER BY nom")
    for row in cur.fetchall():
        ingredients.append({
            "id": row["id"],
            "name": row["nom"],
            "aisle": row["category"] if row["category"] else "Divers",
        })

    # --- Catégories (type de plat) ---
    cur.execute("SELECT nom FROM Catégories ORDER BY nom")
    categories = [row["nom"] for row in cur.fetchall()]

    # --- Recettes + ingrédients liés + catégories liées ---
    recipes = []
    cur.execute("SELECT id, nom, saison, nobox, etapes FROM Recettes ORDER BY nom")
    recipe_rows = cur.fetchall()

    for r in recipe_rows:
        rid = r["id"]

        # Ingrédients de la recette
        cur.execute(
            """
            SELECT i.id AS ingredient_id, i.nom AS name, i.category AS aisle,
                   ri.quantité AS quantity, ri.unité AS unit
            FROM Recettes_Ingrédients ri
            JOIN Ingrédients i ON ri.ingrédient_id = i.id
            WHERE ri.recette_id = ?
            """,
            (rid,),
        )
        recipe_ingredients = [
            {
                "ingredient_id": ing["ingredient_id"],
                "name": ing["name"],
                "aisle": ing["aisle"] if ing["aisle"] else "Divers",
                "quantity": ing["quantity"] if ing["quantity"] is not None else 0,
                "unit": ing["unit"] if ing["unit"] else "",
            }
            for ing in cur.fetchall()
        ]

        # Catégories de la recette
        cur.execute(
            """
            SELECT c.nom AS name
            FROM Recettes_Catégories rc
            JOIN Catégories c ON rc.catégorie_id = c.id
            WHERE rc.recette_id = ?
            """,
            (rid,),
        )
        recipe_categories = [c["name"] for c in cur.fetchall()]

        recipes.append({
            "id": rid,
            "name": r["nom"],
            "season": normalize_season(r["saison"]),
            "nobox": bool(r["nobox"]),
            "steps": r["etapes"] if r["etapes"] else "",
            "categories": recipe_categories,
            "ingredients": recipe_ingredients,
        })

    conn.close()

    payload = {
        "schema_version": 1,
        "source": str(db_path.name),
        "recipes": recipes,
        "ingredients": ingredients,
        "categories": categories,
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    print(f"OK -> {OUT_PATH}")
    print(f"  recipes:     {len(recipes)}")
    print(f"  ingredients: {len(ingredients)}")
    print(f"  categories:  {len(categories)}")


if __name__ == "__main__":
    db = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db.exists():
        sys.exit(f"DB introuvable : {db}")
    main(db)
