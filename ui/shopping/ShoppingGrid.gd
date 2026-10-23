class_name ShoppingGrid
extends Control
## Grille de type tableur pour la liste de courses.
## Colonnes texte éditables : Article | Qté | Unité (+ case à cocher et ✕ par ligne).
##
## Comportement tableur :
## - Clic : sélectionne une cellule ; Maj+clic : étend la sélection (plage).
## - Frappe d'un caractère / Entrée / F2 : édite la cellule active.
## - Flèches : déplacement de cellule ; Maj+Flèches : extension de la sélection.
## - Tab / Maj+Tab : cellule suivante/précédente (fonctionne aussi en cours de saisie).
## - Ctrl+C / Ctrl+X / Ctrl+V : copier / couper / coller une PLAGE (format TSV).
## - Suppr : vide les cellules sélectionnées.
## - Ligne vide en bas : la remplir crée l'article et une nouvelle ligne vide.

signal changed  ## émis après toute mutation (le parent sauvegarde + met à jour les compteurs)

const FIELDS := ["nom", "quantite", "unite"]
const NCOLS := 3

var items: Array = []      ## tableau partagé de tous les articles
var aisle: String = ""     ## catégorie affichée

var _grid: GridContainer
var _editor: LineEdit
var _rows: Array = []       ## [{item, cells:[Panel x3], labels:[Label x3]}]
var _uid_ref: Callable      ## fournie par le parent pour créer des items

var _ar := 0   ## ligne active
var _ac := 0   ## colonne active
var _anr := 0  ## ancre de sélection (ligne)
var _anc := 0  ## ancre de sélection (colonne)
var _editing := false
var _dragging := false
var _keep_scroll_v := -1   ## restaurer le défilement après rebuild (>=0)
var _pending_r := -1       ## cellule à réactiver après rebuild
var _pending_c := -1
var _undo_stack: Array = []
var _redo_stack: Array = []
var _check_on: Texture2D
var _check_off: Texture2D
var _x_icon: Texture2D

func setup(items_ref: Array, make_item: Callable) -> void:
	items = items_ref
	_uid_ref = make_item

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	_check_on = _make_check_icon(true)
	_check_off = _make_check_icon(false)
	_x_icon = _make_x_icon()

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = 5
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 0)
	_grid.add_theme_constant_override("v_separation", 0)
	Layout.scroll_body(scroll).add_child(_grid)

	_editor = LineEdit.new()
	_editor.visible = false
	_editor.gui_input.connect(_on_editor_input)
	_editor.focus_exited.connect(func(): if _editing: _commit(0, 0))
	add_child(_editor)

func rebuild() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_rows.clear()

	var rows := items.filter(func(i): return i["aisle"] == aisle)
	for item in ShoppingListService.display_order(rows):
		_make_row(item)
	_make_row(null)  # ligne vide

	_ar = clampi(_ar, 0, _rows.size() - 1)
	_ac = clampi(_ac, 0, NCOLS - 1)
	_anr = _ar
	_anc = _ac
	# Après calcul du layout : styles + restauration défilement/focus éventuels.
	call_deferred("_post_rebuild")

func _post_rebuild() -> void:
	_refresh_styles()
	var scroll := _grid.get_parent() as ScrollContainer
	if _keep_scroll_v >= 0 and scroll:
		scroll.scroll_vertical = _keep_scroll_v
	_keep_scroll_v = -1
	if _pending_r >= 0:
		_set_active(_pending_r, _pending_c, false)
		_ensure_visible()
		_pending_r = -1
		_pending_c = -1

func _make_row(item) -> void:
	var rec := {"item": item, "cells": [], "labels": []}

	# Col 0 : case à cocher (vide pour la ligne vide)
	if item != null:
		var cb := TextureButton.new()
		cb.custom_minimum_size = Vector2(40, 34)
		cb.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
		cb.texture_normal = _check_on if item["checked"] else _check_off
		cb.pressed.connect(func():
			push_undo()
			item["checked"] = not item["checked"]
			changed.emit()
			# Comme dans la vue magasin : l'article coché passe en bas de son rayon.
			# Le tableur suit le même ordre que la liste, deux ordres différents pour
			# les mêmes articles se contrediraient d'un écran à l'autre.
			rebuild())
		_grid.add_child(cb)
	else:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(40, 34)
		_grid.add_child(spacer)

	# Col 1..3 : cellules texte
	for c in range(NCOLS):
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		if c == 0:
			panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			panel.custom_minimum_size = Vector2(78 if c == 1 else 86, 34)
		var lbl := Label.new()
		lbl.add_theme_color_override("font_color", Palette.TEXT_PRIMARY)
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.clip_text = true
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_constant_override("line_spacing", 0)
		var mc := MarginContainer.new()
		mc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mc.add_theme_constant_override("margin_left", 6)
		mc.add_theme_constant_override("margin_right", 6)
		mc.add_child(lbl)
		panel.add_child(mc)
		panel.set_meta("row", _rows.size())
		panel.set_meta("col", c)
		panel.gui_input.connect(_on_cell_input.bind(panel))
		_grid.add_child(panel)
		rec["cells"].append(panel)
		rec["labels"].append(lbl)
		lbl.text = _cell_text(item, c)

	# Col 4 : bouton supprimer
	if item != null:
		var del := TextureButton.new()
		del.custom_minimum_size = Vector2(44, 34)
		del.stretch_mode = TextureButton.STRETCH_KEEP_CENTERED
		del.texture_normal = _x_icon
		del.pressed.connect(func(): _delete(item))
		_grid.add_child(del)
	else:
		var spacer2 := Control.new()
		spacer2.custom_minimum_size = Vector2(44, 34)
		_grid.add_child(spacer2)

	_rows.append(rec)
	_apply_row_dim(rec)

# ===== Données =====

func _cell_text(item, c: int) -> String:
	if item == null:
		return ""
	if c == 1:
		return _fmt_qty(item["quantite"])
	return str(item[FIELDS[c]])

func _set_cell(r: int, c: int, text: String) -> bool:
	## Écrit une valeur ; promeut la ligne vide si nécessaire. Retourne true si rebuild requis.
	var rec = _rows[r]
	if rec["item"] == null:
		if text.strip_edges() == "":
			return false
		var it: Dictionary = _uid_ref.call(aisle)
		items.append(it)
		rec["item"] = it
		_write_field(it, c, text)
		return true
	_write_field(rec["item"], c, text)
	rec["labels"][c].text = _cell_text(rec["item"], c)
	return false

func _write_field(item: Dictionary, c: int, text: String) -> void:
	if c == 1:
		item["quantite"] = ShoppingListService.parse_quantity(text)
	else:
		item[FIELDS[c]] = text

func _delete(item: Dictionary) -> void:
	push_undo()
	for i in range(items.size()):
		if items[i].get("_uid") == item.get("_uid"):
			items.remove_at(i)
			break
	changed.emit()
	rebuild()

# ===== Sélection / navigation =====

func _on_cell_input(event: InputEvent, panel: PanelContainer) -> void:
	var r: int = panel.get_meta("row")
	var c: int = panel.get_meta("col")
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()
			if event.double_click:
				_set_active(r, c, false)
				_begin_edit()
			else:
				_set_active(r, c, event.shift_pressed)
				_dragging = true
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_dragging = false
		else:
			# La souris est « capturée » par la cellule de départ → on retrouve la cellule
			# réellement survolée via sa position globale.
			var t := _cell_at_global(get_global_mouse_position())
			if t.y >= 0:
				_set_active(t.y, t.x, true)  # étend la sélection

func _cell_at_global(pos: Vector2) -> Vector2i:
	for ri in range(_rows.size()):
		for ci in range(NCOLS):
			var p: Control = _rows[ri]["cells"][ci]
			if Rect2(p.global_position, p.size).has_point(pos):
				return Vector2i(ci, ri)  # x = colonne, y = ligne
	return Vector2i(-1, -1)

func _set_active(r: int, c: int, extend: bool) -> void:
	_ar = clampi(r, 0, _rows.size() - 1)
	_ac = clampi(c, 0, NCOLS - 1)
	if not extend:
		_anr = _ar
		_anc = _ac
	_refresh_styles()

func _move(dr: int, dc: int, extend: bool) -> void:
	_set_active(_ar + dr, _ac + dc, extend)
	_ensure_visible()

func _sel_bounds() -> Array:
	return [mini(_anr, _ar), maxi(_anr, _ar), mini(_anc, _ac), maxi(_anc, _ac)]

func _refresh_styles() -> void:
	var b := _sel_bounds()
	for ri in range(_rows.size()):
		for ci in range(NCOLS):
			var selected: bool = ri >= b[0] and ri <= b[1] and ci >= b[2] and ci <= b[3]
			var active: bool = ri == _ar and ci == _ac
			_style_cell(_rows[ri]["cells"][ci], selected, active, _rows[ri]["item"] == null)

func _style_cell(panel: PanelContainer, selected: bool, active: bool, empty: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.BACKGROUND if empty else (Palette.CELL_HOVER if selected else Palette.SURFACE)
	sb.border_color = Color(Palette.SECONDARY, 0.30)
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	if active:
		sb.border_color = Palette.PRIMARY_INK
		sb.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", sb)

func _apply_row_dim(rec: Dictionary) -> void:
	var item = rec["item"]
	var col := Palette.TEXT_SECONDARY if (item != null and item["checked"]) else Palette.TEXT_PRIMARY
	for lbl in rec["labels"]:
		lbl.add_theme_color_override("font_color", col)

func _ensure_visible() -> void:
	if _ar < _rows.size():
		var cell: Control = _rows[_ar]["cells"][_ac]
		var scroll := _grid.get_parent() as ScrollContainer
		if scroll:
			scroll.ensure_control_visible(cell)

# ===== Édition =====

func _begin_edit(initial := "") -> void:
	if _ar >= _rows.size():
		return
	var cell: Control = _rows[_ar]["cells"][_ac]
	_editor.position = cell.global_position - global_position
	_editor.size = cell.size
	_editor.text = initial if initial != "" else _cell_text(_rows[_ar]["item"], _ac)
	_editor.visible = true
	_editing = true
	_editor.grab_focus()
	if initial == "":
		_editor.select_all()
	else:
		_editor.caret_column = _editor.text.length()

func _commit(move_dr: int, move_dc: int) -> void:
	if not _editing:
		return
	_editing = false
	_editor.visible = false
	var cur = _rows[_ar]["item"]
	var old := _cell_text(cur, _ac)
	var did_change := _editor.text != old
	if did_change:
		push_undo()
	var need_rebuild := _set_cell(_ar, _ac, _editor.text)
	if did_change:
		changed.emit()
	grab_focus()
	if need_rebuild:
		# Promotion d'une ligne vide : garder la vue et placer le focus sur la Quantité.
		var scroll := _grid.get_parent() as ScrollContainer
		_keep_scroll_v = scroll.scroll_vertical if scroll else -1
		_pending_r = _ar
		_pending_c = 1
		rebuild()
		return
	if move_dr != 0 or move_dc != 0:
		_move(move_dr, move_dc, false)

func _cancel_edit() -> void:
	_editing = false
	_editor.visible = false
	grab_focus()

func _on_editor_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	match event.keycode:
		KEY_ESCAPE:
			_cancel_edit()
			_editor.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_commit(1, 0)
			_editor.accept_event()
		KEY_TAB:
			_commit(0, -1 if event.shift_pressed else 1)
			_editor.accept_event()
		KEY_UP:
			_commit(-1, 0)
			_editor.accept_event()
		KEY_DOWN:
			_commit(1, 0)
			_editor.accept_event()

# ===== Clavier (grille non en édition) =====

func _gui_input(event: InputEvent) -> void:
	if _editing or not (event is InputEventKey) or not event.pressed:
		return
	var kc := (event as InputEventKey).keycode
	if event.ctrl_pressed or event.meta_pressed:
		match kc:
			KEY_C: _copy(); accept_event()
			KEY_X: _cut(); accept_event()
			KEY_V: _paste(); accept_event()
			KEY_Z:
				if event.shift_pressed: redo()
				else: undo()
				accept_event()
			KEY_Y: redo(); accept_event()
		return
	match kc:
		KEY_LEFT: _move(0, -1, event.shift_pressed); accept_event()
		KEY_RIGHT: _move(0, 1, event.shift_pressed); accept_event()
		KEY_UP: _move(-1, 0, event.shift_pressed); accept_event()
		KEY_DOWN: _move(1, 0, event.shift_pressed); accept_event()
		KEY_TAB: _move(0, -1 if event.shift_pressed else 1, false); accept_event()
		KEY_ENTER, KEY_KP_ENTER, KEY_F2: _begin_edit(); accept_event()
		KEY_DELETE, KEY_BACKSPACE: _clear_selection(); accept_event()
		_:
			if event.unicode >= 32 and not event.ctrl_pressed:
				_begin_edit(String.chr(event.unicode))
				accept_event()

func _clear_selection() -> void:
	push_undo()
	var b := _sel_bounds()
	var need_rebuild := false
	for ri in range(b[0], b[1] + 1):
		for ci in range(b[2], b[3] + 1):
			if _set_cell(ri, ci, ""):
				need_rebuild = true
	changed.emit()
	if need_rebuild:
		rebuild()
	else:
		for ri in range(b[0], b[1] + 1):
			for ci in range(b[2], b[3] + 1):
				if _rows[ri]["item"] != null:
					_rows[ri]["labels"][ci].text = _cell_text(_rows[ri]["item"], ci)

# ===== Annuler / Rétablir =====

func push_undo() -> void:
	_undo_stack.append(_snapshot())
	if _undo_stack.size() > 100:
		_undo_stack.pop_front()
	_redo_stack.clear()

func _snapshot() -> Array:
	var snap := []
	for d in items:
		snap.append((d as Dictionary).duplicate(true))
	return snap

func _restore(snap: Array) -> void:
	items.clear()
	for d in snap:
		items.append((d as Dictionary).duplicate(true))
	changed.emit()
	rebuild()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(_snapshot())
	_restore(_undo_stack.pop_back())

func redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(_snapshot())
	_restore(_redo_stack.pop_back())

# ===== Presse-papier (plage, format TSV) =====

func _copy() -> void:
	var b := _sel_bounds()
	var lines := []
	for ri in range(b[0], b[1] + 1):
		var cols := []
		for ci in range(b[2], b[3] + 1):
			cols.append(_cell_text(_rows[ri]["item"], ci))
		lines.append("\t".join(cols))
	DisplayServer.clipboard_set("\n".join(lines))

func _cut() -> void:
	_copy()
	_clear_selection()

func _paste() -> void:
	var text := DisplayServer.clipboard_get()
	if text == "":
		return
	push_undo()
	var raw_lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var lines := []
	for l in raw_lines:
		lines.append(l)
	while lines.size() > 1 and lines[lines.size() - 1] == "":
		lines.remove_at(lines.size() - 1)

	# S'assurer qu'il y a assez de lignes réelles (créer des articles si besoin).
	var needed := _ar + lines.size()
	while _real_count() < needed:
		items.append(_uid_ref.call(aisle))

	# Écrire les valeurs directement dans les items filtrés.
	var filtered := _filtered_items()
	for i in range(lines.size()):
		var cells := str(lines[i]).split("\t")
		for j in range(cells.size()):
			var c := _ac + j
			if c >= NCOLS:
				break
			var idx := _ar + i
			if idx < filtered.size():
				_write_field(filtered[idx], c, cells[j])
	changed.emit()
	rebuild()

func _real_count() -> int:
	var n := 0
	for item in items:
		if item["aisle"] == aisle:
			n += 1
	return n

func _filtered_items() -> Array:
	var out := []
	for item in items:
		if item["aisle"] == aisle:
			out.append(item)
	return out

# ===== Utilitaires =====

func _fmt_qty(q: float) -> String:
	return str(int(round(q))) if absf(q - round(q)) < 0.001 else str(q)

func _make_x_icon() -> Texture2D:
	var d := 22
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(6, d - 6):
		for o in [-1, 0, 1]:
			var a := clampi(i + o, 0, d - 1)
			img.set_pixel(a, i, Palette.ERROR)
			img.set_pixel(a, d - 1 - i, Palette.ERROR)
	return ImageTexture.create_from_image(img)

func _make_check_icon(checked: bool) -> Texture2D:
	var s := 22
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(1, s - 1):
		for j in range(1, s - 1):
			var edge: bool = i < 3 or i >= s - 3 or j < 3 or j >= s - 3
			if checked:
				img.set_pixel(i, j, Palette.PRIMARY)
			elif edge:
				img.set_pixel(i, j, Palette.BORDER)
	if checked:
		_draw_seg(img, Vector2(6, 11), Vector2(10, 15))
		_draw_seg(img, Vector2(10, 15), Vector2(16, 6))
	return ImageTexture.create_from_image(img)

func _draw_seg(img: Image, a: Vector2, b: Vector2) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var steps := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) * 2
	for k in range(steps + 1):
		var t := float(k) / maxf(1.0, float(steps))
		var p := a.lerp(b, t)
		for o in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)]:
			img.set_pixel(clampi(int(p.x + o.x), 0, w - 1), clampi(int(p.y + o.y), 0, h - 1), Color.WHITE)
