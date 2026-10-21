#!/usr/bin/env python3
"""Construit le site des textes legaux publie sur GitHub Pages.

Google Play et l'App Store exigent une URL publique pour la politique de
confidentialite (ADR-0046). Les textes restent ecrits une seule fois, dans
app/assets/legal/, ou l'app les lit hors ligne : ce script n'en fait que la
version web, pour qu'une correction du texte ne soit jamais faite a deux
endroits.

Usage : python3 scripts/ci/build-legal-site.py <dossier de sortie>
"""

import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
LEGAL = ROOT / "app" / "assets" / "legal"

# Fichier source -> page publiee. Le nom de la page fait partie de l'URL
# declaree dans les consoles des magasins : le changer casse la fiche.
PAGES = {
    "confidentialite.txt": "confidentialite.html",
    "conditions.txt": "conditions.html",
}

# Une adresse, web ou e-mail, ne garde pas la ponctuation qui termine sa
# phrase : le texte de l'app finit chaque paragraphe par un point.
URL = re.compile(r"https?://[^\s)]+[^\s).,;]|[\w.+-]+@[\w-]+(?:\.[\w-]+)+")

STYLE = """
:root { color-scheme: dark; }
body {
  margin: 0; background: #121414; color: #e8e6e4;
  font: 17px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
main { max-width: 720px; margin: 0 auto; padding: 48px 16px 64px; }
h1 { font-size: 28px; line-height: 1.25; margin: 0 0 8px; }
h2 { font-size: 19px; margin: 32px 0 8px; }
p { margin: 0 0 12px; color: #c4c2c0; }
.date { color: #8f8d8b; font-size: 15px; }
a { color: #e8e6e4; }
"""


def inline(text: str) -> str:
    """Echappe une ligne et rend ses adresses web et e-mail cliquables."""
    out, last = [], 0
    for match in URL.finditer(text):
        out.append(html.escape(text[last:match.start()]))
        url = html.escape(match.group())
        href = url if url.startswith("http") else f"mailto:{url}"
        out.append(f'<a href="{href}">{url}</a>')
        last = match.end()
    out.append(html.escape(text[last:]))
    return "".join(out)


def render(source: str) -> tuple[str, str]:
    """Transforme un texte legal en (titre, corps HTML).

    Le format est celui que l'app affiche tel quel : la premiere ligne est le
    titre, et un intertitre est une ligne sans ponctuation finale suivie d'un
    paragraphe. Les paragraphes, eux, finissent tous par un point ou deux-points.
    """
    lines = [line.strip() for line in source.splitlines()]
    title = lines[0]
    if not title:
        raise ValueError("la premiere ligne doit etre le titre du document")
    body = []
    for i, line in enumerate(lines[1:], start=1):
        if not line:
            continue
        following = lines[i + 1] if i + 1 < len(lines) else ""
        if line.startswith("Dernière mise à jour"):
            body.append(f'<p class="date">{inline(line)}</p>')
        elif following and not line.endswith((".", ":", ";", "?", "!")):
            body.append(f"<h2>{inline(line)}</h2>")
        else:
            body.append(f"<p>{inline(line)}</p>")
    return title, "\n".join(body)


def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
<h1>{html.escape(title)}</h1>
{body}
</main>
</body>
</html>
"""


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage : build-legal-site.py <dossier de sortie>")
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    links = []
    for source, target in PAGES.items():
        title, body = render((LEGAL / source).read_text(encoding="utf-8"))
        (out / target).write_text(page(title, body), encoding="utf-8")
        links.append(f'<p><a href="{target}">{html.escape(title)}</a></p>')

    (out / "index.html").write_text(
        page("Onyx — informations légales", "\n".join(links)), encoding="utf-8"
    )
    # Sans ce fichier, GitHub Pages passe le site dans Jekyll, inutile ici.
    (out / ".nojekyll").write_text("", encoding="utf-8")


if __name__ == "__main__":
    main()
