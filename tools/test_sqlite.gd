extends SceneTree
## Vérifie que la GDExtension godot-sqlite est chargée et fonctionnelle.

func _initialize() -> void:
	var db = SQLite.new()
	db.path = "res://.test_tmp.db"  # sera créé dans user:// équivalent? non -> utiliser user://
	db.path = "user://.test_tmp.db"
	db.open_db()
	db.query("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, name TEXT);")
	db.query("DELETE FROM t;")
	db.insert_row("t", {"name": "Bibimbap"})
	db.query("SELECT COUNT(*) AS n FROM t;")
	print("SQLite OK — rows=", db.query_result[0]["n"])
	db.close_db()
	quit()
