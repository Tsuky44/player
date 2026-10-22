"""Empreinte d'un bundle .app pour la signature des mises à jour macOS.

Le même manifeste que `bundleDigest` dans
app/lib/services/macos_update_signature_io.dart : une ligne par fichier
(« f chemin sha256 ») et par lien (« l chemin cible »), triées par chemin en
octets UTF-8, puis le SHA-256 du tout. Les liens ne sont jamais suivis.

    python3 scripts/macos_bundle_digest.py chemin/vers/Onyx.app
"""

import hashlib
import os
import sys


def bundle_digest(root):
    lines = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if "\n" in rel:
                raise ValueError("nom de fichier invalide dans le bundle : %r" % rel)
            if os.path.islink(full):
                lines.append((rel, "l %s %s\n" % (rel, os.readlink(full))))
            elif os.path.isfile(full):
                h = hashlib.sha256()
                with open(full, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                lines.append((rel, "f %s %s\n" % (rel, h.hexdigest())))
    lines.sort(key=lambda line: line[0].encode("utf-8"))
    return hashlib.sha256("".join(l for _, l in lines).encode("utf-8")).hexdigest()


if __name__ == "__main__":
    print(bundle_digest(sys.argv[1]))
