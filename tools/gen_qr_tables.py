#!/usr/bin/env python3.11
"""Régénère services/QrTables.gd depuis la bibliothèque de référence `qrcode`.

Les tables du QR code (blocs de correction, motifs d'alignement) représentent une
centaine de valeurs par niveau de correction. Recopiées à la main, une seule coquille
produirait des codes illisibles sans que rien ne le signale — d'où cette génération.

    python3.11 -m pip install --user qrcode
    python3.11 tools/gen_qr_tables.py
"""
import os
import qrcode.util as u
import qrcode.base as b
from qrcode.constants import ERROR_CORRECT_M

MAXV = 40
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

rs_lines, align_lines, cap = [], [], []
for v in range(1, MAXV + 1):
    blocks = [(r.total_count, r.data_count) for r in b.rs_blocks(v, ERROR_CORRECT_M)]
    rs_lines.append("\t[" + ", ".join("[%d, %d]" % t for t in blocks) + "],")
    align_lines.append("\t[" + ", ".join(str(x) for x in u.PATTERN_POSITION_TABLE[v - 1]) + "],")
    cap.append(sum(d for _, d in blocks))

print("Régénère services/QrTables.gd — relancer test_qr.gd ensuite.")
