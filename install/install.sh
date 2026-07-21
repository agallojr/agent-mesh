#!/usr/bin/env bash
#
# install.sh -- scaffold a fresh agent-mesh BUS from the product's bus-skeleton,
# pin the product as a submodule at a chosen tag, and wire the git gate + skills
# on this node.
#
# Run this FROM a clone of the agent-mesh PRODUCT repo. Network-mutating git
# steps (the bus's first commit/push) are PRINTED for the operator to run, never
# executed unattended.
#
set -euo pipefail

# --- inputs (env vars, overridable by flags) --------------------------------
PRODUCT_URL="${PRODUCT_URL:-}"
PRODUCT_TAG="${PRODUCT_TAG:-v0.1.0}"
BUS_URL="${BUS_URL:-}"
BUS_PATH="${BUS_PATH:-}"

usage() {
  cat <<'EOF'
Usage: install.sh [options]   (run from a product-repo checkout)

Scaffolds a fresh agent-mesh bus, pins the product as a submodule, and wires
the git gate + skills on this node.

Inputs (env var or flag; flag wins):
  --product-url URL   PRODUCT_URL   git URL of the agent-mesh product repo.
  --product-tag TAG   PRODUCT_TAG   product tag to pin        (default v0.1.0).
  --bus-url URL       BUS_URL       git URL of the agent-mesh-bus remote.
  --bus-path PATH     BUS_PATH      absolute path for the bus clone
                                    (e.g. $HOME/agent-mesh).
  -h, --help                        show this help.

Example:
  PRODUCT_URL=git@github.com:you/agent-mesh.git \
  BUS_URL=git@github.com:you/agent-mesh-bus.git \
  BUS_PATH="$HOME/agent-mesh" \
  ./install/install.sh --product-tag v0.1.0

Network-mutating steps (bus first commit + push) are printed for you to run,
not executed by this script.
EOF
}

# --- flag parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --product-url) PRODUCT_URL="$2"; shift 2 ;;
    --product-tag) PRODUCT_TAG="$2"; shift 2 ;;
    --bus-url)     BUS_URL="$2";     shift 2 ;;
    --bus-path)    BUS_PATH="$2";    shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
step() { printf '\n### %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- 1. sanity: resolve product root from this script's location ------------
step "Step 1: verify we are in a product checkout"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
say "script dir : ${SCRIPT_DIR}"
say "product root: ${PRODUCT_ROOT}"

[ -f "${PRODUCT_ROOT}/spec/PROTOCOL.md" ] \
  || die "spec/PROTOCOL.md not found under ${PRODUCT_ROOT}; run from a product checkout."
[ -d "${PRODUCT_ROOT}/bus-skeleton" ] \
  || die "bus-skeleton/ not found under ${PRODUCT_ROOT}; run from a product checkout."
say "product checkout confirmed."

# required inputs
[ -n "${PRODUCT_URL}" ] || die "PRODUCT_URL is required (see --help)."
[ -n "${BUS_URL}" ]     || die "BUS_URL is required (see --help)."
[ -n "${BUS_PATH}" ]    || die "BUS_PATH is required (see --help)."
case "${BUS_PATH}" in
  /*) : ;;
  *)  die "BUS_PATH must be an absolute path; got '${BUS_PATH}'." ;;
esac

say "PRODUCT_URL = ${PRODUCT_URL}"
say "PRODUCT_TAG = ${PRODUCT_TAG}"
say "BUS_URL     = ${BUS_URL}"
say "BUS_PATH    = ${BUS_PATH}"

# --- 2. scaffold the bus from the skeleton ----------------------------------
step "Step 2: scaffold the bus at ${BUS_PATH}"
if [ -d "${BUS_PATH}" ]; then
  say "bus path already exists; leaving its contents in place."
else
  say "creating ${BUS_PATH}"
  mkdir -p "${BUS_PATH}"
  say "git init"
  git -C "${BUS_PATH}" init -q
  say "copying bus-skeleton contents (incl. .gitkeep/.gitignore/.gitattributes)"
  # copy the skeleton's contents, including dotfiles, into the bus root.
  cp -R "${PRODUCT_ROOT}/bus-skeleton/." "${BUS_PATH}/"
fi

# set / update the origin remote (idempotent)
if git -C "${BUS_PATH}" remote get-url origin >/dev/null 2>&1; then
  say "origin already set; updating to ${BUS_URL}"
  git -C "${BUS_PATH}" remote set-url origin "${BUS_URL}"
else
  say "setting origin remote -> ${BUS_URL}"
  git -C "${BUS_PATH}" remote add origin "${BUS_URL}"
fi

# --- 3. add the product submodule and pin the tag ---------------------------
step "Step 3: add product submodule and pin ${PRODUCT_TAG}"
if [ -d "${BUS_PATH}/product/.git" ] || \
   git -C "${BUS_PATH}" config --file .gitmodules --get submodule.product.path \
     >/dev/null 2>&1; then
  say "product submodule already present; skipping 'submodule add'."
else
  say "git submodule add ${PRODUCT_URL} product"
  git -C "${BUS_PATH}" submodule add "${PRODUCT_URL}" product
fi

say "checking out pinned tag inside submodule: ${PRODUCT_TAG}"
git -C "${BUS_PATH}/product" fetch --tags --quiet || true
git -C "${BUS_PATH}/product" checkout "${PRODUCT_TAG}"

say "staging .gitmodules and product pointer"
git -C "${BUS_PATH}" add .gitmodules product

# --- 4. generate the bus entry point + user overlay placeholder -------------
step "Step 4: generate guidance/CLAUDE.md and memory/best-practices.user.md"
BUS_CLAUDE="${BUS_PATH}/guidance/CLAUDE.md"
if [ -f "${BUS_CLAUDE}" ]; then
  say "guidance/CLAUDE.md already exists; leaving it untouched."
else
  say "writing bus entry point ${BUS_CLAUDE}"
  cat > "${BUS_CLAUDE}" <<'EOF'
# Mesh agent guidance -- bus entry point (composes product base + user overlay)

@product/guidance/best-practices.base.md
@memory/best-practices.user.md
@product/guidance/agent-operating.md
@product/guidance/permissions.md
EOF
fi

USER_OVERLAY="${BUS_PATH}/memory/best-practices.user.md"
if [ -f "${USER_OVERLAY}" ]; then
  say "memory/best-practices.user.md already exists; leaving it untouched."
else
  say "writing placeholder ${USER_OVERLAY}"
  cat > "${USER_OVERLAY}" <<'EOF'
<!-- Add this deployment's specific rules here. This user overlay is composed
     after the product base by guidance/CLAUDE.md. -->
EOF
fi

# --- 5. wire the git gate on THIS node --------------------------------------
step "Step 5: wire the git gate on this node"
HOOKS_DST="${HOME}/.claude/hooks"
say "mkdir -p ${HOOKS_DST}"
mkdir -p "${HOOKS_DST}"
say "copy product/hooks/git-gate.py -> ${HOOKS_DST}/git-gate.py"
cp "${BUS_PATH}/product/hooks/git-gate.py" "${HOOKS_DST}/git-gate.py"
chmod +x "${HOOKS_DST}/git-gate.py"

ALLOWLIST="${HOME}/.claude/mesh-git-allowlist.txt"
if [ ! -f "${ALLOWLIST}" ]; then
  say "creating ${ALLOWLIST} from product template"
  cp "${BUS_PATH}/product/hooks/mesh-git-allowlist.txt.template" "${ALLOWLIST}"
fi
# append BUS_PATH once (exact-line match, ignore comments/blanks)
if grep -qxF "${BUS_PATH}" "${ALLOWLIST}"; then
  say "allowlist already contains ${BUS_PATH}; not duplicating."
else
  say "appending ${BUS_PATH} to ${ALLOWLIST}"
  printf '%s\n' "${BUS_PATH}" >> "${ALLOWLIST}"
fi

say "REMINDER: register the PreToolUse git-gate hook in ~/.claude/settings.json."
say "  Source snippet: ${BUS_PATH}/product/hooks/settings.snippet.json"
say "  Replace REPLACE_WITH_HOME with: ${HOME}"
say "  Remove any blanket git add/commit/push deny (keep sudo)."
say "  Merging JSON is the operator's call -- this script does NOT edit settings.json."

# --- 6. symlink skills ------------------------------------------------------
step "Step 6: symlink mesh-on / mesh-off skills"
SKILLS_DST="${HOME}/.claude/skills"
mkdir -p "${SKILLS_DST}"
say "ln -sfn ${BUS_PATH}/product/skills/mesh-on  ${SKILLS_DST}/mesh-on"
ln -sfn "${BUS_PATH}/product/skills/mesh-on"  "${SKILLS_DST}/mesh-on"
say "ln -sfn ${BUS_PATH}/product/skills/mesh-off ${SKILLS_DST}/mesh-off"
ln -sfn "${BUS_PATH}/product/skills/mesh-off" "${SKILLS_DST}/mesh-off"

# --- 7. next steps (network-mutating -> operator runs these) ----------------
step "Step 7: next steps (you run these -- network-mutating git is not automated)"
cat <<EOF

  1. Plant this node's identity + credentials from the product templates:
       cp ${BUS_PATH}/product/templates/agent-identity.env.template \\
          ${HOME}/.agent-identity.env    # chmod 644; set REPO_PATH=${BUS_PATH}
       cp ${BUS_PATH}/product/templates/agent-credentials.env.template \\
          ${HOME}/.agent-credentials.env # chmod 600; fill in secret values
     REPO_PATH MUST be the literal path ${BUS_PATH} (no \$HOME / ~ expansion),
     matching the allowlist line added in step 5.

  2. Commit and push the fresh bus (NETWORK-MUTATING -- run these yourself):
       git -C ${BUS_PATH} add -A
       git -C ${BUS_PATH} commit -m "scaffold bus"
       git -C ${BUS_PATH} push -u origin HEAD

  3. Register the git-gate hook in ~/.claude/settings.json (see step 5), then
     start the worker loop with:  /mesh-on

EOF
say "install.sh complete. Local scaffolding done; the push above is yours to run."
