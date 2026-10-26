#!/bin/sh
# Rebuilds manifest.xml (every file's SHA1) from the committed files, so the
# installed copies (installer/PathOfBuildingIA.nsi) can update from this
# repository's dev branch. Run from the repository root after committing:
#   sh installer/manifest.sh            (then commit manifest.xml and push)
# POB_REPO (default trubat-d/PathOfBuilding): the repository they update from.
set -e
REPO=${POB_REPO:-trubat-d/PathOfBuilding}
VERSION=${VERSION:-2.67.2-ia.$(date -u +%Y%m%d%H%M)}
TMP=$(mktemp -d)
git archive HEAD | tar -x -C "$TMP"
cp manifest.xml update_manifest.py manifest.cfg "$TMP/"
(cd "$TMP" && POB_REPO="$REPO" python3 update_manifest.py --in-place --set-version "$VERSION")
cp "$TMP/manifest.xml" manifest.xml
rm -rf "$TMP"
echo "manifest.xml: version $VERSION, $(grep -c '<File ' manifest.xml) files, updates from $REPO"
