#!/usr/bin/env bash
# BarDisplay — make sure the active bar can honor per-display visibility.
#
# Idempotent and non-destructive:
#   * verifies the marker before touching anything,
#   * backs the file up before any edit,
#   * refuses to edit when the expected structure changed after an update,
#   * restores the backup if a verification step fails.
#
# Exit status / first stdout line:
#   ok              already supported (a previous BarDisplay patch is present)
#   patched         support was added; the bar needs a reload to pick it up
#   needs-admin     the bar file is root-owned (stock omarchy bar); second line
#                   carries the pkexec command to run it with privileges
#   unsupported-bar the bar isn't a known bar plugin; left untouched
#   error           anchors were missing; nothing was changed, backup restored
set -uo pipefail

BAR_FILE="${1:-}"
MARKER_SHOW="function showBarOnScreen"
MARKER_PROP="barMonitors"

say() { printf '%s\n' "$*"; }

if [[ -z "$BAR_FILE" ]]; then
  say "usage: $0 <Bar.qml>"
  exit 0
fi
if [[ ! -f "$BAR_FILE" ]]; then
  say "unsupported-bar"
  exit 0
fi

# Already supported? Nothing to do (also covers the legacy reapply script's
# patch, which exposes the same interface).
if grep -qF "$MARKER_SHOW" "$BAR_FILE" && grep -qF "$MARKER_PROP" "$BAR_FILE"; then
  say "ok"
  exit 0
fi

# Identify the bar flavour so the anchors stay precise. Unknown bars are left
# alone rather than guessed at.
if grep -qF "outputWindowsEnabled" "$BAR_FILE" && grep -qF "Core.BarPanel" "$BAR_FILE"; then
  BAR_FLAVOUR="shibumi"
elif grep -qF "barConfigSerial" "$BAR_FILE"; then
  BAR_FLAVOUR="stock"
else
  say "unsupported-bar"
  exit 0
fi

if [[ ! -w "$BAR_FILE" ]]; then
  say "needs-admin"
  say "pkexec \"$0\" \"$BAR_FILE\""
  exit 2
fi

# --- Symlink hardening (runs elevated via pkexec) ---
# A crafted symlink at BAR_FILE or BACKUP can make the privileged cp -f or
# Python write overwrite an arbitrary root-owned file.  Refuse to operate on
# symlinks and validate that the resolved path is the expected stock bar.

if [[ -L "$BAR_FILE" ]]; then
  say "error"
  say "Bar file is a symlink; refusing to patch (security)"
  exit 1
fi

BAR_REAL="$(readlink -f "$BAR_FILE" 2>/dev/null || true)"
if [[ -n "$BAR_REAL" && "$BAR_REAL" != "$BAR_FILE" ]]; then
  say "error"
  say "Bar file resolved to a different path; refusing (security)"
  exit 1
fi

EXPECTED="/usr/share/omarchy/shell/plugins/bar/Bar.qml"
if [[ "$BAR_FILE" != "$EXPECTED" ]]; then
  say "error"
  say "Refusing to patch unexpected path (security)"
  exit 1
fi

BACKUP="${BAR_FILE}.bardisplay.bak"
if [[ -L "$BACKUP" ]]; then
  say "error"
  say "Backup path is a symlink; refusing (security)"
  exit 1
fi
if [[ -e "$BACKUP" && "$(dirname "$(readlink -f "$BACKUP" 2>/dev/null || echo "$BACKUP")")" != "$(dirname "$BAR_FILE")" ]]; then
  say "error"
  say "Backup path resolves outside bar directory; refusing (security)"
  exit 1
fi

cp -f "$BAR_FILE" "$BACKUP"

# Re-check: ensure the bar file is still a regular file (not swapped to a
# symlink between our earlier check and the write below).
if [[ -L "$BAR_FILE" ]]; then
  cp -f "$BACKUP" "$BAR_FILE"
  say "error"
  say "Bar file became a symlink before write; restored from backup"
  exit 1
fi

if ! python3 - "$BAR_FILE" "$BAR_FLAVOUR" <<'PY'
import sys

path, flavour = sys.argv[1], sys.argv[2]

with open(path) as f:
    s = f.read()

if flavour == "shibumi":
    replacements = [
        (
            "  property bool outputWindowsEnabled: true\n",
            "  property bool outputWindowsEnabled: true\n"
            "  property var barMonitors: []\n",
        ),
        (
            "    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || \"\")\n",
            "    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || \"\")\n"
            "    const configuredMonitors = Array.isArray(config.monitors)\n"
            "      ? config.monitors\n"
            "      : (Array.isArray(config.barMonitors) ? config.barMonitors : [])\n"
            "    barMonitors = configuredMonitors\n",
        ),
        (
            "    layoutConfig = nextLayout\n"
            "  }\n",
            "    layoutConfig = nextLayout\n"
            "  }\n\n"
            "  function showBarOnScreen(name) {\n"
            "    const names = Array.isArray(barMonitors) ? barMonitors : []\n"
            "    if (names.length === 0) return true\n"
            "    return names.indexOf(String(name || \"\")) >= 0\n"
            "  }\n",
        ),
        (
            "    delegate: Component {\n"
            "      Core.BarPanel {\n"
            "        required property var modelData\n"
            "        bar: root\n"
            "        screen: modelData\n"
            "      }\n"
            "    }\n",
            "    delegate: Component {\n"
            "      Item {\n"
            "        required property var modelData\n"
            "\n"
            "        Loader {\n"
            "          active: root.showBarOnScreen(String(modelData && modelData.name || \"\"))\n"
            "          sourceComponent: Core.BarPanel {\n"
            "            bar: root\n"
            "            screen: modelData\n"
            "          }\n"
            "        }\n"
            "      }\n"
            "    }\n",
        ),
    ]
else:
    replacements = [
        (
            "  property bool barHidden: false\n",
            "  property bool barHidden: false\n"
            "  property var barMonitors: []\n",
        ),
        (
            "    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || \"\")\n",
            "    centerAnchor = Util.canonicalWidgetId(config.centerAnchor || \"\")\n"
            "    barMonitors = Array.isArray(config.monitors)\n"
            "      ? config.monitors\n"
            "      : (Array.isArray(config.barMonitors) ? config.barMonitors : [])\n",
        ),
        (
            "    layoutConfig = next\n"
            "    barConfigSerial++\n"
            "  }\n",
            "    layoutConfig = next\n"
            "    barConfigSerial++\n"
            "  }\n\n"
            "  function showBarOnScreen(name) {\n"
            "    var names = Array.isArray(barMonitors) ? barMonitors : []\n"
            "    if (names.length === 0) return true\n"
            "    return names.indexOf(String(name || \"\")) >= 0\n"
            "  }\n",
        ),
        (
            "    delegate: Component {\n"
            "      BarPanel {\n"
            "        required property var modelData\n"
            "\n"
            "        screen: modelData\n"
            "      }\n"
            "    }\n",
            "    delegate: Component {\n"
            "      Item {\n"
            "        required property var modelData\n"
            "\n"
            "        Loader {\n"
            "          active: root.showBarOnScreen(String(modelData && modelData.name || \"\"))\n"
            "          sourceComponent: BarPanel {\n"
            "            screen: modelData\n"
            "          }\n"
            "        }\n"
            "      }\n"
            "    }\n",
        ),
    ]

missing = []
for i, (old, _new) in enumerate(replacements):
    if old not in s:
        missing.append(str(i))

if missing:
    sys.stderr.write("BarDisplay: anchors missing after an update: " + ", ".join(missing) + "\n")
    sys.exit(1)

for old, new in replacements:
    s = s.replace(old, new, 1)

with open(path, "w") as f:
    f.write(s)
PY
then
  cp -f "$BACKUP" "$BAR_FILE"
  say "error"
  say "The bar layout changed after an update; $BAR_FILE was left untouched. Backup: $BACKUP"
  exit 1
fi

if grep -qF "$MARKER_SHOW" "$BAR_FILE"; then
  say "patched"
  say "Backup kept at: $BACKUP"
  exit 0
fi

cp -f "$BACKUP" "$BAR_FILE"
say "error"
say "Patch verification failed; $BAR_FILE was restored from $BACKUP"
exit 1
