#!/bin/sh
# Builds the one-file Windows installer (needs makensis: apt install nsis).
# From the repository root, after installer/manifest.sh was run and committed:
#   sh installer/build.sh            -> PathOfBuildingIA-Setup.exe (small web
#                                       installer: the first start downloads
#                                       the program from GitHub)
#   FULL=1 sh installer/build.sh     -> PathOfBuildingIA-Setup-Full.exe (every
#                                       file inside, nothing downloaded)
# OUT=<folder> where the installer goes (default: the repository root).
set -e
ROOT=$(pwd)
OUT=${OUT:-$ROOT}
BRANCH=${BRANCH:-dev}
TMP=$(mktemp -d)
git archive HEAD | tar -x -C "$TMP"
VERSION=$(sed -n 's/.*<Version number="\([^"]*\)".*/\1/p' "$TMP/manifest.xml" | head -1)
STAGE="$TMP/stage"
mkdir -p "$STAGE"
# the runtime (the program's .exe, its libraries, fonts, Lua modules)
(cd "$TMP/runtime" && find . -type f) | while read -r f; do
	case "$f" in
		*lua-profiler.lua|*imgui.ini|*SimpleGraphic.cfg|*SimpleGraphic.log) continue ;;
	esac
	dest="$STAGE/$(echo "$f" | sed 's/{space}/ /g')"
	mkdir -p "$(dirname "$dest")"
	cp "$TMP/runtime/$f" "$dest"
done
if [ -n "$FULL" ]; then
	# every file the manifest lists
	python3 - "$TMP" "$STAGE" <<'EOF'
import sys, shutil, pathlib, xml.etree.ElementTree as Et
tmp, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
roots = {"default": tmp, "program": tmp / "src", "tree": tmp / "src"}
for f in Et.parse(tmp / "manifest.xml").getroot().iter("File"):
    part = f.get("part")
    if part not in roots:
        continue
    src = roots[part] / f.get("name")
    dst = stage / f.get("name").replace("{space}", " ")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
EOF
	NAME=PathOfBuildingIA-Setup-Full.exe
	EXTRA=""
else
	# what starts the program and its updater; the rest is downloaded
	for f in Launch.lua UpdateCheck.lua UpdateApply.lua; do cp "$TMP/src/$f" "$STAGE/$f"; done
	NAME=PathOfBuildingIA-Setup.exe
	EXTRA='$\r$\n$\r$\nThe first start downloads the program from GitHub (about 800 MB, a few minutes).'
fi
# an installed copy's manifest: the branch it updates from, its platform
sed "s|<Version number=\"$VERSION\" />|<Version number=\"$VERSION\" branch=\"$BRANCH\" platform=\"win32\" />|" "$TMP/manifest.xml" > "$STAGE/manifest.xml"
grep -q "branch=\"$BRANCH\"" "$STAGE/manifest.xml"
# (first start: the update check runs before the program loads)
: > "$STAGE/first.run"
cp "$ROOT/installer/pob.ico" "$TMP/pob.ico"
cp "$ROOT/installer/PathOfBuildingIA.nsi" "$TMP/PathOfBuildingIA.nsi"
(cd "$TMP" && makensis -V2 -DSTAGE=stage -DOUTFILE="$OUT/$NAME" -DVERSION="$VERSION" -DWELCOMEEXTRA="$EXTRA" PathOfBuildingIA.nsi)
rm -rf "$TMP"
ls -la "$OUT/$NAME"
