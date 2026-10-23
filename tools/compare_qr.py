#!/usr/bin/env python3.11
"""Compare les matrices de l'encodeur GDScript à celles de la bibliothèque `qrcode`.

Un QR mal formé ressemble trait pour trait à un QR valide : seule une comparaison
bit à bit avec une référence dit s'il est lisible. La sortie GDScript vient de
tools/dump_qr.gd.

    QR_OUT=/tmp/dump godot --headless --script res://tools/dump_qr.gd
    python3.11 tools/compare_qr.py /tmp/dump
"""
import sys
from urllib.parse import unquote
import qrcode
import qrcode.util
from qrcode.constants import ERROR_CORRECT_M


def reference(text, mask):
    q = qrcode.QRCode(error_correction=ERROR_CORRECT_M, box_size=1, border=0,
                      mask_pattern=mask)
    # Mode octet imposé des deux côtés : la référence choisit sinon le mode le plus
    # dense (alphanumérique pour « A »), alors que l'encodeur GDScript est
    # volontairement octet-seul — la charge utile partagée est du base64url, qui
    # contient des minuscules et ne rentre donc jamais en alphanumérique.
    q.add_data(qrcode.util.QRData(text.encode(), mode=qrcode.util.MODE_8BIT_BYTE))
    q.make(fit=True)
    return ["".join("1" if v else "0" for v in row) for row in q.get_matrix()]


def main(path):
    ok = fail = 0
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        kind, text = parts[0], unquote(parts[1])
        if kind == "CASE":
            mask, payload = int(parts[2]), parts[3]
            if payload == "TROP_LONG":
                print(f"  [IGNORÉ] {text[:24]!r} masque {mask} : refusé par l'encodeur")
                continue
            mine = payload.split(",")
            theirs = reference(text, mask)
        else:
            mine = parts[2].split(",")
            # Masque automatique : on vérifie seulement que la taille correspond et
            # que la matrice est l'une des 8 possibles.
            theirs = None
            for m in range(8):
                if reference(text, m) == mine:
                    theirs = mine
                    break
            if theirs is None:
                print(f"  [ÉCHEC] {text[:24]!r} masque auto : ne correspond à aucun masque de référence")
                fail += 1
                continue
            ok += 1
            continue

        if mine == theirs:
            ok += 1
        else:
            fail += 1
            diff = sum(1 for a, b in zip(mine, theirs) for x, y in zip(a, b) if x != y) \
                if len(mine) == len(theirs) else -1
            print(f"  [ÉCHEC] {text[:24]!r} masque {mask} : "
                  f"taille {len(mine)} vs {len(theirs)}, {diff} modules différents")
    print(f"\n{ok} matrices identiques à la référence, {fail} en écart.")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
