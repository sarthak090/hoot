#!/bin/bash
# Renders the demo scenes from the real app views (sample data only), narrates them with
# macOS text-to-speech, and writes:
#   docs/media/hoot-demo.mp4         the video, with narration
#   docs/media/hoot-demo.en.vtt      captions of the narration
#   docs/media/hoot-demo-poster.jpg  poster frame
#   docs/assets/social-card.png      1200x630 link preview image
#
#   VOICE="Ava (Premium)" ./scripts/make-demo-video.sh
#   VOICE=none ./scripts/make-demo-video.sh        # silent video
#
# Needs ffmpeg (brew install ffmpeg). Premium voices: System Settings › Accessibility ›
# Spoken Content › System Voice › Manage Voices….
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VOICE="${VOICE:-Samantha}"
[ -x build/Hoot.app/Contents/MacOS/Hoot ] || ./scripts/build-app.sh
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
build/Hoot.app/Contents/MacOS/Hoot --render-demo "$WORK"
mkdir -p docs/media docs/assets

python3 - "$WORK" "$VOICE" <<'PY'
import json, subprocess, sys
work, voice = sys.argv[1], sys.argv[2]

# (scene, minimum seconds, narration). Scenes stretch to fit their line.
scenes = [
    ("01-title", 3.2, "Meet Hoot, a menu-bar owl for Claude Code."),
    ("02-away", 4.2, "Claude Code is busy in your terminal, and you've moved on to something else."),
    ("03-notified", 4.2, "When Claude needs permission, Hoot lets you know right away."),
    ("04-card", 5.2, "Open the menu to see exactly what will run. Allow it once, always allow it, or deny it with a reason for Claude."),
    ("05-allowed", 4.4, "Answer from the menu bar, and the terminal picks up where it left off."),
    ("06-question", 5.2, "If Claude has a question, pick an answer, or type your own."),
    ("07-plan", 5.2, "Plans work the same way. Approve them, or send them back with feedback."),
    ("08-usage", 5.4, "The Usage tab shows how much of your session and weekly limits you've used, plus your tokens and an estimated cost."),
    ("09-menubar", 2.6, "And your session usage sits right next to the owl, so you can check it at a glance."),
    ("09b-menubar-zoom", 3.4, None),  # the line above continues over the zoom
    ("10-end", 4.6, "Hoot is free and open source. Find it on GitHub."),
]
FADE, LEAD, TAIL = 0.6, 0.35, 0.7   # crossfade, pause before a line, pause after it

def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                         check=True, capture_output=True, text=True).stdout
    return float(json.loads(out)["format"]["duration"])

narrate = voice.lower() != "none"
clips = {}
if narrate:
    for i, (name, _, line) in enumerate(scenes):
        if line:
            path = f"{work}/vo-{i:02d}.aiff"
            subprocess.run(["say", "-v", voice, "-r", "172", "-o", path, line], check=True)
            clips[i] = (path, duration(path))

# Scene lengths: long enough for the line (a line on scene 9 may run into 9b).
lengths = [m for _, m, _ in scenes]
for i, (path, d) in clips.items():
    need = LEAD + d + TAIL
    if scenes[i][0] == "09-menubar":
        lengths[i + 1] = max(lengths[i + 1], need - (lengths[i] - FADE))
    else:
        lengths[i] = max(lengths[i], need)

starts, t = [], 0.0
for i, d in enumerate(lengths):
    starts.append(t)
    t += d - FADE
total = sum(lengths) - FADE * (len(lengths) - 1)

# Video: stills with crossfades.
args = ["ffmpeg", "-loglevel", "error", "-y"]
for (name, _, _), d in zip(scenes, lengths):
    args += ["-loop", "1", "-framerate", "30", "-t", f"{d:.3f}", "-i", f"{work}/{name}.png"]
n = len(scenes)
parts = [f"[{i}:v]scale=1920:1200:flags=lanczos,format=yuv420p,setsar=1[s{i}]" for i in range(n)]
prev = "s0"
for i in range(1, n):
    parts.append(f"[{prev}][s{i}]xfade=transition=fade:duration={FADE}:offset={starts[i]:.3f}[x{i}]")
    prev = f"x{i}"
maps = ["-map", f"[{prev}]"]

# Audio: each line placed at its scene start (+ a short lead), mixed, normalised.
vtt = ["WEBVTT", ""]
if clips:
    a_inputs = []
    for k, (i, (path, d)) in enumerate(sorted(clips.items())):
        args += ["-i", path]
        at = starts[i] + LEAD
        a_inputs.append(f"[{n + k}:a]aresample=48000,adelay={int(at * 1000)}:all=1[a{k}]")
        def ts(x):
            return f"{int(x // 3600):02d}:{int(x % 3600 // 60):02d}:{x % 60:06.3f}"
        vtt += [f"{ts(at)} --> {ts(at + d)}", scenes[i][2], ""]
    mix = "".join(f"[a{k}]" for k in range(len(clips)))
    parts += a_inputs
    parts.append(f"{mix}amix=inputs={len(clips)}:normalize=0,apad,atrim=0:{total:.3f},loudnorm=I=-16:TP=-1.5:LRA=11[aout]")
    maps += ["-map", "[aout]", "-c:a", "aac", "-b:a", "160k"]

args += ["-filter_complex", ";".join(parts)] + maps + [
    "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "30",
    "-t", f"{total:.3f}", "-movflags", "+faststart", "docs/media/hoot-demo.mp4"]
subprocess.run(args, check=True)
if clips:
    open("docs/media/hoot-demo.en.vtt", "w").write("\n".join(vtt))
print(f"video {total:.1f}s, {'narrated by ' + voice if clips else 'silent'}")
PY

sips -Z 1920 -s format jpeg -s formatOptions 82 "$WORK/04-card.png" --out docs/media/hoot-demo-poster.jpg >/dev/null
ffmpeg -loglevel error -y -i "$WORK/01-title.png" -vf "crop=2880:1512:0:144,scale=1200:630:flags=lanczos" docs/assets/social-card.png
echo "Wrote docs/media/hoot-demo.mp4 (+ captions), docs/media/hoot-demo-poster.jpg, docs/assets/social-card.png"
