# --- paste this into claude.ai/code "Setup script" (runs at session start, any repo) ---
# Installs the repo-neutral `mesh-post` command onto PATH by fetching the canonical
# copy from the agent-mesh (product) repo -- NOT the bus repo, where product is a
# submodule gitlink and the Contents API would return a pointer, not the file.
#
# Session env block must provide:
#   GH_PAT_RESEARCH  a PAT with Contents:read/write on your bus repo.
#   GH_PRODUCT       owner/name of the (public) product repo, e.g. you/agent-mesh.
#   GH_BUS_OWNER     owner of your bus repo (used by mesh-post at post time).
#   GH_BUS_REPO      your bus repo name, e.g. agent-mesh-bus-mymesh (used by mesh-post).
set -e
: "${GH_PRODUCT:?set GH_PRODUCT=owner/agent-mesh in the session env block}"
mkdir -p "$HOME/.local/bin"
curl -fsSL \
  -H "Authorization: Bearer $GH_PAT_RESEARCH" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/$GH_PRODUCT/contents/mobile/mesh-post.sh?ref=main" \
  -o "$HOME/.local/bin/mesh-post"
chmod +x "$HOME/.local/bin/mesh-post"
export PATH="$HOME/.local/bin:$PATH"
echo "mesh-post installed -> $(command -v mesh-post)"
