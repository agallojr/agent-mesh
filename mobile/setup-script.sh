# --- paste this into claude.ai/code "Setup script" (runs at session start, any repo) ---
# Installs the repo-neutral `mesh-post` command onto PATH by fetching the canonical
# copy from the bus repo. Requires GH_PAT_RESEARCH in the session env block.
set -e
mkdir -p "$HOME/.local/bin"
curl -fsSL \
  -H "Authorization: Bearer $GH_PAT_RESEARCH" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/agallojr/agent-mesh-bus/contents/product/mobile/mesh-post.sh?ref=main" \
  -o "$HOME/.local/bin/mesh-post"
chmod +x "$HOME/.local/bin/mesh-post"
export PATH="$HOME/.local/bin:$PATH"
echo "mesh-post installed -> $(command -v mesh-post)"
