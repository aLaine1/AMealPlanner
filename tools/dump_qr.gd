extends SceneTree
## Écrit les matrices QR produites par l'encodeur GDScript, pour comparaison avec la
## bibliothèque de référence. Lu par tools/compare_qr.py.
const QrCode := preload("res://services/QrCode.gd")
func _initialize() -> void:
	var cases := [
		"A", "Bonjour", "AMEAL1:test",
		"x".repeat(40), "x".repeat(180), "x".repeat(400), "x".repeat(988),
		"Crêpes à la ricotta et aux épinards — 250 g farine, 3 œufs",
	]
	var out := FileAccess.open(OS.get_environment("QR_OUT"), FileAccess.WRITE)
	var qr = QrCode.new()
	for text in cases:
		for mask in range(8):
			var m = qr.encode(text, mask)
			if m.is_empty():
				out.store_line("CASE\t%s\t%d\tTROP_LONG" % [text.uri_encode(), mask])
				continue
			var rows := []
			for row in m:
				var s := ""
				for v in row:
					s += "1" if v else "0"
				rows.append(s)
			out.store_line("CASE\t%s\t%d\t%s" % [text.uri_encode(), mask, ",".join(rows)])
		# Masque choisi automatiquement
		var auto = qr.encode(text, -1)
		var arows := []
		for row in auto:
			var s := ""
			for v in row:
				s += "1" if v else "0"
			arows.append(s)
		out.store_line("AUTO\t%s\t%s" % [text.uri_encode(), ",".join(arows)])
	out.close()
	print("dump écrit")
	quit()
