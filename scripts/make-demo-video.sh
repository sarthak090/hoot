#!/bin/bash
# Renders the demo scenes from the real app views (sample data only) and encodes
# docs/media/hoot-demo.mp4 plus its poster image. Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -x build/Hoot.app/Contents/MacOS/Hoot ] || ./scripts/build-app.sh
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT
build/Hoot.app/Contents/MacOS/Hoot --render-demo "$FRAMES"
mkdir -p docs/media
python3 - "$FRAMES" <<'PY'
import subprocess, sys
S = sys.argv[1]
scenes = [("01-title", 3.2), ("02-away", 4.2), ("03-notified", 4.2), ("04-card", 5.2), ("05-allowed", 4.4),
          ("06-question", 5.2), ("07-plan", 5.2), ("08-usage", 5.4), ("09-menubar", 3.0), ("09b-menubar-zoom", 3.6),
          ("10-end", 4.4)]
fade = 0.6
args = ["ffmpeg", "-loglevel", "error", "-y"]
for name, d in scenes:
    args += ["-loop", "1", "-framerate", "30", "-t", str(d), "-i", f"{S}/{name}.png"]
parts = [f"[{i}:v]scale=1920:1200:flags=lanczos,format=yuv420p,setsar=1[s{i}]" for i in range(len(scenes))]
offset, prev = 0.0, "s0"
for i in range(1, len(scenes)):
    offset += scenes[i - 1][1] - fade
    parts.append(f"[{prev}][s{i}]xfade=transition=fade:duration={fade}:offset={offset:.2f}[x{i}]")
    prev = f"x{i}"
args += ["-filter_complex", ";".join(parts), "-map", f"[{prev}]", "-c:v", "libx264", "-preset", "slow", "-crf", "20",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-r", "30", "docs/media/hoot-demo.mp4"]
subprocess.run(args, check=True)
PY
sips -Z 1920 -s format jpeg -s formatOptions 82 "$FRAMES/04-card.png" --out docs/media/hoot-demo-poster.jpg >/dev/null
# Social card (1200x630) from the title scene.
ffmpeg -loglevel error -y -i "$FRAMES/01-title.png" -vf "crop=2880:1512:0:144,scale=1200:630:flags=lanczos" docs/assets/social-card.png
echo "Wrote docs/media/hoot-demo.mp4, docs/media/hoot-demo-poster.jpg, docs/assets/social-card.png"
