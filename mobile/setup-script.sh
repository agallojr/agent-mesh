# --- paste this into claude.ai/code "Setup script" (runs at session start, any repo) ---
# Installs the repo-neutral `mesh-post` command onto PATH by fetching the canonical
# copy from the agent-mesh (product) repo -- NOT agent-mesh-bus, where product is a
# submodule gitlink and the Contents API would return a pointer, not the file.
# Requires GH_PAT_RESEARCH in the session env block.
set -e
mkdir -p "$HOME/.local/bin"
curl -fsSL \
  -H "Authorization: Bearer $GH_PAT_RESEARCH" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/agallojr/agent-mesh/contents/mobile/mesh-post.sh?ref=main" \
  -o "$HOME/.local/bin/mesh-post"
chmod +x "$HOME/.local/bin/mesh-post"
export PATH="$HOME/.local/bin:$PATH"
echo "mesh-post installed -> $(command -v mesh-post)"
