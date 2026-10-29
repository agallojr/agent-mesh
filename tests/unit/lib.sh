# lib.sh -- shared fixture helpers for the agent-mesh unit tests. Sourced, not
# run (run.sh only runs test_* files).
#
# unit_setup makes a temporary folder, points HOME, the Claude config dir and
# git's global config into it, and removes it on exit, so a test never reads
# or writes the real ~/.mesh-stop, ~/.agent-identity.env, ~/.claude or bus.
# mk_bus builds a throwaway bus: a local bare repo as origin and a node clone
# with a product submodule (ignore = all, as real buses set it).

UNIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SKILLS="$UNIT_ROOT/skills"

unit_setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/mesh-unit.XXXXXX")
  T=$(cd "$T" && pwd -P)
  trap 'rm -rf "$T"' EXIT
  export HOME="$T/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  unset CLAUDE_CODE_CONFIG_DIR MESH_PRODUCT_TRACK MESH_MAX_WAIT_SEC
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=unit GIT_AUTHOR_EMAIL=unit@example.invalid
  export GIT_COMMITTER_NAME=unit GIT_COMMITTER_EMAIL=unit@example.invalid
  mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME"
  : > "$CLAUDE_CONFIG_DIR/mesh-git-allowlist.txt"
  FAILS=0
}

allow_repo() {  # allow_repo <abs path>: add it to the git gate's allowlist
  printf '%s\n' "$1" >> "$CLAUDE_CONFIG_DIR/mesh-git-allowlist.txt"
}

g() { git "$@"; }

# mk_product <name>: a bare product repo with two commits. Sets PROD_ORIGIN,
# PROD_OLD (first commit) and PROD_NEW (second commit, the pin).
mk_product() {
  PROD_ORIGIN="$T/$1.git"
  g init -q --bare "$PROD_ORIGIN"
  g -C "$PROD_ORIGIN" symbolic-ref HEAD refs/heads/main
  local w="$T/$1-work"
  g clone -q "$PROD_ORIGIN" "$w" 2>/dev/null
  g -C "$w" symbolic-ref HEAD refs/heads/main
  echo "readme" > "$w/README.md"
  mkdir -p "$w/spec"
  echo 1 > "$w/spec/LAYOUT_VERSION"
  g -C "$w" add README.md spec/LAYOUT_VERSION
  g -C "$w" commit -q -m "product one"
  PROD_OLD=$(g -C "$w" rev-parse HEAD)
  echo "v2" > "$w/VERSION"
  g -C "$w" add VERSION
  g -C "$w" commit -q -m "product two"
  PROD_NEW=$(g -C "$w" rev-parse HEAD)
  g -C "$w" push -q origin main
}

# mk_bus <name>: a bare origin and a node clone at $T/<name> with agents/,
# status/, a README and a product submodule pinned at PROD_NEW. Sets BUS,
# BUS_ORIGIN and PIN.
mk_bus() {
  BUS_ORIGIN="$T/$1.git"
  BUS="$T/$1"
  g init -q --bare "$BUS_ORIGIN"
  g -C "$BUS_ORIGIN" symbolic-ref HEAD refs/heads/main
  g clone -q "$BUS_ORIGIN" "$BUS" 2>/dev/null
  g -C "$BUS" symbolic-ref HEAD refs/heads/main
  mkdir -p "$BUS/agents" "$BUS/status" "$BUS/outbox"
  : > "$BUS/agents/.gitkeep"
  : > "$BUS/status/.gitkeep"
  echo "bus" > "$BUS/README.md"
  echo 1 > "$BUS/BUS_LAYOUT"
  g -C "$BUS" add agents status README.md BUS_LAYOUT
  g -C "$BUS" commit -q -m "bus init"
  if [ -n "${PROD_ORIGIN:-}" ]; then
    g -C "$BUS" -c protocol.file.allow=always submodule add -q \
      "file://$PROD_ORIGIN" product 2>/dev/null
    g -C "$BUS" config -f .gitmodules submodule.product.ignore all
    g -C "$BUS" add .gitmodules product
    g -C "$BUS" commit -q -m "pin product"
  fi
  g -C "$BUS" push -q -u origin main 2>/dev/null
  PIN=$(g -C "$BUS" rev-parse HEAD:product 2>/dev/null || echo none)
}

# stale_product: the lore-20261029-0003 state. The bus's product checkout is
# behind its pin with a stray staged deletion inside it, and the bus index
# holds the stale gitlink staged (as a stage-all would have recorded it).
stale_product() {
  g -C "$BUS/product" checkout -q "$PROD_OLD"
  g -C "$BUS/product" rm -q --cached README.md
  g -C "$BUS" update-index --cacheinfo "160000,$PROD_OLD,product"
}

# changed_paths <repo> <rev>: every path <rev> changes against its parent,
# gitlinks included (ignore = all would hide them from the default view).
changed_paths() {
  g -C "$1" diff-tree -r --root --no-commit-id --name-only \
    --ignore-submodules=none "$2"
}

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $*"; }

check() {  # check <description> <command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}

eq() { [ "$1" = "$2" ] || { echo "  expected [$2] got [$1]"; return 1; }; }

unit_done() {
  if [ "$FAILS" -gt 0 ]; then
    echo "$FAILS check(s) failed"
    exit 1
  fi
  exit 0
}
