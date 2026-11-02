#!/bin/bash
# One-time setup on a new Mac: checks the tools, builds VideoFilmer.app.
#   ./setup.sh                  build the app
#   ./setup.sh --with-remotion  also install Remotion's official agent skills
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "✗ $1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "VideoFilmer is a macOS app."
sw=$(sw_vers -productVersion | cut -d. -f1)
(( sw >= 14 )) || fail "macOS 14 (Sonoma) or newer is needed; this Mac has $(sw_vers -productVersion)."
command -v swift >/dev/null || fail "Swift is missing. Install Xcode from the App Store (or run: xcode-select --install)."
command -v node >/dev/null || fail "Node.js is missing (needed for the MCP server). Install Node 18+ from https://nodejs.org."
node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 18 )) || fail "Node 18+ is needed; found $(node -v)."
echo "✓ macOS $(sw_vers -productVersion), $(swift --version 2>&1 | head -1 | sed 's/.*Swift version \([0-9.]*\).*/Swift \1/'), Node $(node -v)"

./build.sh

if [[ "${1:-}" == "--with-remotion" ]]; then
  echo "Installing Remotion agent skills (see remotion.dev/license for commercial use)…"
  npx -y skills add remotion-dev/skills
fi

cat <<'EOF'

✓ Done.
  • Open the app:   open build/VideoFilmer.app   (allow camera + microphone when asked)
  • In Claude Code: approve the "videofilmer" MCP server when prompted,
    then ask e.g. "make a Tuelang video about the A1 cohort".
  • Recommended project settings (auto-approve the server, enable HyperFrames): docs/MCP-SETUP.md
EOF
