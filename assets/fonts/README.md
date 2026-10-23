# Police Nunito

Le thème (`autoload/Palette.gd`, `_load_warm_font()`) applique automatiquement Nunito comme
police par défaut de l'app **si** le fichier suivant est présent ici :

- `Nunito-Regular.ttf`

Aucun changement de code n'est nécessaire ensuite : au prochain lancement, `Palette` détecte
le fichier et l'utilise. Tant qu'il est absent, l'app se replie silencieusement sur la police
système, sans erreur.

Téléchargement : [Google Fonts — Nunito](https://fonts.google.com/specimen/Nunito) (licence
OFL, libre de droits). Il suffit du fichier `Regular` pour activer le thème ; les graisses
`Medium`/`SemiBold`/`Bold` ne sont pas requises par le code actuel.

# Symboles de repli

`DejaVuSans-Symboles.ttf` est un extrait de DejaVu Sans (flèches, formes géométriques, ✓ ✕ ⟳),
branché en repli de Nunito par `_load_warm_font()`. Ces symboles manquent à Nunito ; hors
navigateur le système les fournissait, mais la version web n'a accès à aucune police système.

Licence : DejaVu (dérivée de Bitstream Vera), redistribution et modification libres. Regénérer
avec `pyftsubset` (paquet `fonttools`) :

```bash
pyftsubset /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
  --unicodes="U+2190-21FF,U+25A0-25FF,U+2713-2718,U+27F0-27FF" \
  --output-file=assets/fonts/DejaVuSans-Symboles.ttf --layout-features='' --no-hinting
```
