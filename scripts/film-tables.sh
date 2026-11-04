#!/bin/zsh
# Makes the film tables Pluck Studio ships: the per-pixel version of darktable's spektrafilm data,
# in build/FilmTables (film/, paper/, pair/, index.json, LICENSE, NOTICE.txt).
# It downloads the film pack (about 9 MB, every file checked against the published checksums),
# builds the helper for this Mac and asks it for every film, every paper and every film x paper
# pair: the Photo page lets any film be printed on any paper.
# Run it by hand, or let build-app.sh --edition studio run it when the tables are missing.
set -euo pipefail
SELF="${0:A}"
cd "${SELF:h}/.."

REPO="darktable-org/darktable-spektrafilm"
# The pack is pinned to one commit, and its list and licence to their checksums: the tables shipped are made from
# exactly this data. To move to newer data, change all three together.
COMMIT="b15cfe18fb35ec15084f78c986b0ebc730338e6e"
MANIFEST_SHA="45f54229d05964aa42634d4e897f81e3d6ed41684a0d598ab347cfcc95a0e254"
LICENSE_SHA="76d629501783ae52e8d63aee1e054c1e1a9713b9fe7d36fb306e25b1d14b24e9"
RAW="https://raw.githubusercontent.com/$REPO/$COMMIT"
PACK=build/film-pack
OUT=build/FilmTables
HOST=build/spektra-host
SPK=Helpers/PluckSpektra
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p build

# Python only reads and writes JSON here; -I keeps it from loading anything next to the files.
py() { python3 -I "$@"; }

# 1. The list of files, and whether the tables already match it (and the code that makes them).
# If the list can't be downloaded (offline), the tables we already have are kept.
if ! curl -fsSL --retry 3 "$RAW/manifest.json" -o "$WORK/manifest.json"; then
  if [[ -f $OUT/index.json && -f $OUT/.pack-sha ]]; then
    echo "Film tables: offline, keeping the existing ones"
    exit 0
  fi
  echo "Can't download the film list (manifest.json) and there are no film tables yet. Check the internet and run this again." >&2
  exit 1
fi
PACK_SHA="$(shasum -a 256 "$WORK/manifest.json" | cut -d' ' -f1)"
[[ "$PACK_SHA" == "$MANIFEST_SHA" ]] || { echo "The film list (manifest.json) at $COMMIT isn't the one pinned." >&2; exit 1; }
# The stamp also covers every file in the helper's folder and this script, so any edit to them remakes the tables.
SRC_SHA="$( { find "$SPK" -type f | sort | xargs shasum -a 256; shasum -a 256 "$SELF"; } | shasum -a 256 | cut -d' ' -f1)"
STAMP="$PACK_SHA $SRC_SHA"
if [[ -f $OUT/index.json && -f $OUT/.pack-sha && "$(cat $OUT/.pack-sha)" == "$STAMP" ]]; then
  echo "Film tables are up to date ($(du -sh $OUT | cut -f1))."
  exit 0
fi
rm -rf "$OUT"

# 2. The film pack, each file checked like FilmEngine.downloadPack does: formats 2 and 3, no
# absolute paths or "..", a size limit, and size and sha256 must match the manifest.
if [[ ! -f $PACK/.complete || "$(cat $PACK/.manifest-sha 2>/dev/null)" != "$PACK_SHA" ]]; then
  rm -rf "$PACK" "$WORK/pack"
  mkdir -p "$WORK/pack"
  py - "$WORK/manifest.json" > "$WORK/files.txt" <<'PY'
import json, sys
packs = [p for p in json.load(open(sys.argv[1]))["packs"] if p["pack_format"] in (2, 3)]
if not packs:
    sys.exit("There's no film data this version of Pluck can use.")
pack = packs[-1]
print(pack["base"])
for f in pack["files"]:
    path = f["path"]
    if path.startswith("/") or ".." in path or f["size"] >= 64 << 20:
        sys.exit("Unsafe path in the manifest: " + path)
    print(f["size"], f["sha256"], path, sep="\t")
PY
  BASE="$(head -1 "$WORK/files.txt")"
  echo "Downloading the film pack ($BASE)…"
  tail -n +2 "$WORK/files.txt" | while IFS=$'\t' read -r size sha rel; do
    mkdir -p "$WORK/pack/${rel:h}"
    curl -fsSL --retry 3 "$RAW/$BASE/$rel" -o "$WORK/pack/$rel"
    [[ "$(stat -f%z "$WORK/pack/$rel")" == "$size" && "$(shasum -a 256 "$WORK/pack/$rel" | cut -d' ' -f1)" == "$sha" ]] \
      || { echo "$rel didn't match its published checksum." >&2; exit 1; }
  done
  curl -fsSL --retry 3 "$RAW/LICENSE" -o "$WORK/pack/LICENSE"
  [[ "$(shasum -a 256 "$WORK/pack/LICENSE" | cut -d' ' -f1)" == "$LICENSE_SHA" ]] || { echo "The pack's licence isn't the one pinned." >&2; exit 1; }
  grep -q "Attribution-ShareAlike 4.0" "$WORK/pack/LICENSE" || { echo "The pack's licence isn't CC BY-SA 4.0 any more: check before shipping." >&2; exit 1; }
  echo "$PACK_SHA" > "$WORK/pack/.manifest-sha"
  touch "$WORK/pack/.complete"
  mv "$WORK/pack" "$PACK"
fi

# 3. The helper, built for this Mac (the same flags as build-app.sh).
mkdir -p "$HOST"
clang -O3 -std=gnu11 -ffp-contract=off -fblocks -mmacosx-version-min=14.0 \
  -I$SPK/shim -I$SPK/darktable -I$SPK/shim/common -w \
  $SPK/main.c $SPK/darktable/spektra_sim.c $SPK/darktable/spektra_core.c $SPK/shim/shim.c -lcompression \
  -o "$HOST/pluck-spektra"

# 4. What to make: films and papers from the helper's own list, then one job per part.
echo '{"do":"profiles","pack":"'"$PWD/$PACK"'"}' | "$HOST/pluck-spektra" > "$WORK/profiles.json"
# The settings' defaults the tables are made at (Pluck tells a changed setting from them).
echo '{"do":"schema"}' | "$HOST/pluck-spektra" > "$WORK/schema.json"
mkdir -p "$OUT/film" "$OUT/paper" "$OUT/pair"
py - "$WORK/profiles.json" "$PWD/$PACK" "$PWD/$OUT" "$PACK_SHA" "$WORK" "$WORK/schema.json" <<'PY'
import json, sys
profiles, pack, out, sha, work, schema = sys.argv[1:]
lists = json.load(open(profiles))
defaults = {k: v["default"] for k, v in json.load(open(schema)).items()
            if isinstance(v, dict) and isinstance(v.get("default"), (int, float)) and not isinstance(v.get("default"), bool)}
films, papers = lists["film"], lists["print"]
jobs = []
for f in films:
    # Slides and black-and-white reversal are looked at, not printed (what useFilm does): they keep
    # the film scan. A negative is built with its own target print, so its file has no unneeded scan
    # (a negative with no target print keeps the scan, as the helper decides).
    positive = f["type"] == "positive"
    scan = {"scan_film": 1} if positive else {}
    target = None if positive else f.get("print")
    jobs.append({"do": "tables", "part": "film", "pack": pack, "film": f["id"], "print": target,
                 "set": scan, "output": f"{out}/film/{f['id']}.pft"})
for p in papers:
    jobs.append({"do": "tables", "part": "paper", "pack": pack, "film": films[0]["id"], "print": p["id"],
                 "set": {}, "output": f"{out}/paper/{p['id']}.pft"})
pairs = []
for f in films:
    for p in papers:
        pairs.append(f["id"] + "__" + p["id"])
        jobs.append({"do": "tables", "part": "pair", "pack": pack, "film": f["id"], "print": p["id"],
                     "set": {}, "output": f"{out}/pair/{f['id']}__{p['id']}.pft"})
with open(f"{work}/jobs.jsonl", "w") as fh:
    for j in jobs:
        fh.write(json.dumps(j) + "\n")
with open(f"{out}/index.json", "w") as fh:
    json.dump({"format": 2, "pack_sha256": sha, "films": films, "papers": papers, "pairs": pairs, "defaults": defaults}, fh, indent=1)
print(len(films), "films,", len(papers), "papers,", len(pairs), "pairs")
PY

# 5. Run the jobs on every core; each helper takes its share of the list.
CORES="$(sysctl -n hw.performancecores 2>/dev/null || sysctl -n hw.ncpu)"
TOTAL=$(wc -l < "$WORK/jobs.jsonl" | tr -d " ")
split -l $(( (TOTAL + CORES - 1) / CORES )) "$WORK/jobs.jsonl" "$WORK/jobs."
echo "Making the tables on $CORES cores…"
for part in "$WORK"/jobs.??; do
  ( "$HOST/pluck-spektra" < "$part" > "$part.out" ) &
done
wait
BAD="$(cat "$WORK"/jobs.??.out | grep -vc '"ok":true' || true)"
GOT="$(cat "$WORK"/jobs.??.out | grep -c '"ok":true' || true)"
[[ "$BAD" == 0 && "$GOT" == "$(wc -l < "$WORK/jobs.jsonl" | tr -d ' ')" ]] \
  || { echo "Some tables failed:" >&2; cat "$WORK"/jobs.??.out | grep -v '"ok":true' | head >&2; rm -rf "$OUT"; exit 1; }

# 6. The licence and the credit travel with the tables.
cp "$PACK/LICENSE" "$OUT/LICENSE"
cat > "$OUT/NOTICE.txt" <<'TXT'
Film tables

These tables are derived from the film and paper data of darktable's spektrafilm port
(github.com/darktable-org/darktable-spektrafilm), which is the data of spektrafilm by Andrea
Volpato (github.com/andreavolpato/spektrafilm). They are the per-pixel form of that data,
computed with the spektrafilm simulation as darktable has it.

The data is licensed under Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA 4.0); the
tables made from it are licensed the same way. The licence text is in the file LICENSE.
TXT
# The folder must stay under 60 MB, or the app gets too big. If it's over, remove it and fail.
KB="$(du -sk "$OUT" | cut -f1)"
if (( KB > 60 * 1024 )); then
  rm -rf "$OUT"
  echo "Film tables are $((KB / 1024)) MB, over the 60 MB limit. Removed them." >&2
  exit 1
fi
echo "$STAMP" > "$OUT/.pack-sha"
echo "Film tables: $(du -sh "$OUT" | cut -f1) in $(find "$OUT" -name '*.pft' | wc -l | tr -d ' ') files."
