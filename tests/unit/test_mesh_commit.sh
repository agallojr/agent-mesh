#!/usr/bin/env bash
# Unit test of skills/mesh-on/mesh-commit.sh (plan section 2.3, R4): it stages
# and commits only the paths it names, never records a submodule pin, applies
# the git gate's rules itself, and pushes with a pull-rebase retry.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MC="$SKILLS/mesh-on/mesh-commit.sh"

mk_product product
mk_bus bus
allow_repo "$BUS"

# --- the R4 scene: stale product checkout with a stray staged change inside,
# a stale gitlink staged in the bus index, and another file modified.
stale_product
echo "operator edit" >> "$BUS/README.md"
mkdir -p "$BUS/agents"
printf 'agent_id: x\n' > "$BUS/agents/x.yaml"
before=$(g -C "$BUS" rev-parse HEAD)

out=$(bash "$MC" "$BUS" "t" agents/x.yaml); rc=$?
check "named path commit exits 0" eq "$rc" 0
check "output is COMMITTED then PUSHED" \
  eq "$(printf '%s\n' "$out" | sed 's/^COMMITTED [0-9a-f]\{7\}$/COMMITTED sha/')" \
  "$(printf 'COMMITTED sha\nPUSHED')"
check "one new commit" eq "$(g -C "$BUS" rev-list --count "$before..HEAD")" 1
check "the commit changes only agents/x.yaml" \
  eq "$(changed_paths "$BUS" HEAD)" "agents/x.yaml"
check "HEAD:product is still the pin" eq "$(g -C "$BUS" rev-parse HEAD:product)" "$PIN"
check "the stale gitlink is still staged" \
  eq "$(g -C "$BUS" diff --cached --ignore-submodules=none --name-only)" "product"
check "the staged gitlink is still the stale commit" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
check "the other modified file is still modified and unstaged" \
  eq "$(g -C "$BUS" diff --name-only -- README.md)" "README.md"
check "the stray change inside the submodule is still staged there" \
  eq "$(g -C "$BUS/product" diff --cached --name-status)" "$(printf 'D\tREADME.md')"
check "origin has the commit" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main)" "$(g -C "$BUS" rev-parse HEAD)"
check "the printed sha is HEAD" \
  eq "$(printf '%s\n' "$out" | sed -n 's/^COMMITTED //p')" \
  "$(g -C "$BUS" rev-parse HEAD | cut -c1-7)"

# --- naming the submodule is refused and commits nothing
head=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MC" "$BUS" "t" product); rc=$?
check "naming the submodule exits 1" eq "$rc" 1
check "naming the submodule prints one REFUSED line" \
  eq "$(printf '%s\n' "$out" | grep -c '^REFUSED ')$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "11"
check "naming the submodule commits nothing" eq "$(g -C "$BUS" rev-parse HEAD)" "$head"
check "the gitlink is left staged as it was" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
out=$(bash "$MC" "$BUS" "t" product/README.md); rc=$?
check "a path inside the submodule is refused" eq "$rc:${out%% *}" "1:REFUSED"
out=$(bash "$MC" "$BUS" "t" ./product/); rc=$?
check "the submodule spelled ./product/ is refused" eq "$rc:${out%% *}" "1:REFUSED"
out=$(bash "$MC" "$BUS" "t" agents/x.yaml product); rc=$?
check "a submodule among good paths refuses the whole commit" \
  eq "$rc:${out%% *}:$(g -C "$BUS" rev-parse HEAD)" "1:REFUSED:$head"

# --- a repo off the gate's allowlist is refused and commits nothing
MAIN_BUS="$BUS"; MAIN_ORIGIN="$BUS_ORIGIN"
mk_bus offbus
printf 'agent_id: y\n' > "$BUS/agents/y.yaml"
head=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MC" "$BUS" "t" agents/y.yaml); rc=$?
check "a repo off the allowlist exits 1" eq "$rc" 1
check "a repo off the allowlist prints REFUSED" eq "${out%% *}" "REFUSED"
check "a repo off the allowlist commits nothing" eq "$(g -C "$BUS" rev-parse HEAD)" "$head"
check "a repo off the allowlist stages nothing" \
  eq "$(g -C "$BUS" diff --cached --name-only)" ""
check "a repo off the allowlist pushes nothing" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main)" "$head"
BUS="$MAIN_BUS"; BUS_ORIGIN="$MAIN_ORIGIN"

# --- no allowlist at all fails closed
mv "$CLAUDE_CONFIG_DIR/mesh-git-allowlist.txt" "$T/allowlist.saved"
printf 'agent_id: z\n' > "$BUS/agents/z.yaml"
out=$(bash "$MC" "$BUS" "t" agents/z.yaml); rc=$?
check "no allowlist file is refused" eq "$rc:${out%% *}" "1:REFUSED"
mv "$T/allowlist.saved" "$CLAUDE_CONFIG_DIR/mesh-git-allowlist.txt"
rm -f "$BUS/agents/z.yaml"

# --- path rules
head=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MC" "$BUS" "t"); rc=$?
check "no path is refused" eq "$rc:${out%% *}" "1:REFUSED"
out=$(bash "$MC" "$BUS" "t" "$BUS/agents/x.yaml"); rc=$?
check "an absolute path is refused" eq "$rc:${out%% *}" "1:REFUSED"
out=$(bash "$MC" "$BUS" "t" agents/../README.md); rc=$?
check "a .. segment is refused" eq "$rc:${out%% *}" "1:REFUSED"
mkdir -p "$T/elsewhere"
echo "secret" > "$T/elsewhere/leak.txt"
ln -s "$T/elsewhere" "$BUS/outbox/link"
out=$(bash "$MC" "$BUS" "t" outbox/link/leak.txt); rc=$?
check "a path that leaves the repo through a link is refused" eq "$rc:${out%% *}" "1:REFUSED"
rm -f "$BUS/outbox/link"
out=$(bash "$MC" "$BUS" "t" agents/never-existed.yaml); rc=$?
check "a path that is neither present nor tracked is refused" eq "$rc:${out%% *}" "1:REFUSED"
printf 'x' > "$BUS/outbox/data.npy"
out=$(bash "$MC" "$BUS" "t" outbox/data.npy); rc=$?
check "a blob-class file is refused by the gate's blob rule" eq "$rc:${out%% *}" "1:REFUSED"
mkdir -p "$BUS/outbox/res-files"
echo "ok" > "$BUS/outbox/res-files/a.txt"
printf 'x' > "$BUS/outbox/res-files/b.npz"
out=$(bash "$MC" "$BUS" "t" outbox/res-files); rc=$?
check "a blob-class file inside a named folder is refused" eq "$rc:${out%% *}" "1:REFUSED"
rm -rf "$BUS/outbox/res-files" "$BUS/outbox/data.npy"
mkdir -p "$BUS/outbox/nested"
g init -q "$BUS/outbox/nested"
echo n > "$BUS/outbox/nested/n.txt"
out=$(bash "$MC" "$BUS" "t" outbox); rc=$?
check "a folder holding a nested repo is refused" eq "$rc:${out%% *}" "1:REFUSED"
rm -rf "$BUS/outbox/nested"
out=$(bash "$MC" "$BUS" "$(printf 'two\nlines')" agents/x.yaml); rc=$?
check "a message of two lines is refused" eq "$rc:${out%% *}" "1:REFUSED"
check "no refused case committed" eq "$(g -C "$BUS" rev-parse HEAD)" "$head"
check "no refused case staged a path" \
  eq "$(g -C "$BUS" diff --cached --ignore-submodules=none --name-only)" "product"
out=$(bash "$MC" 2>/dev/null); rc=$?
check "no arguments is a usage error" eq "$rc" 2
out=$(bash "$MC" "$BUS" 2>/dev/null); rc=$?
check "no message is a usage error" eq "$rc" 2

# --- nothing to commit
out=$(bash "$MC" "$BUS" "t" agents/x.yaml); rc=$?
check "an unchanged path prints NOTHING TO COMMIT and exits 0" \
  eq "$rc:$out" "0:NOTHING TO COMMIT"

# --- a deleted file and a folder of result files
mkdir -p "$BUS/outbox/x/r1-files/sub"
echo "one" > "$BUS/outbox/x/r1-files/a.txt"
echo "two" > "$BUS/outbox/x/r1-files/sub/b.txt"
echo "result" > "$BUS/outbox/x/r1-result.md"
out=$(bash "$MC" "$BUS" "result r1" outbox/x/r1-result.md outbox/x/r1-files); rc=$?
check "a result with its files folder commits" eq "$rc" 0
check "the result commit holds the result and its files only" \
  eq "$(changed_paths "$BUS" HEAD | tr '\n' ' ')" \
  "outbox/x/r1-files/a.txt outbox/x/r1-files/sub/b.txt outbox/x/r1-result.md "
rm -f "$BUS/agents/x.yaml"
out=$(bash "$MC" "$BUS" "drop x" agents/x.yaml); rc=$?
check "a deleted file commits its removal" eq "$rc" 0
check "the removal commit holds only that path" \
  eq "$(changed_paths "$BUS" HEAD)" "agents/x.yaml"
check "the removal reached origin" \
  eq "$(g -C "$BUS_ORIGIN" ls-tree --name-only main agents/x.yaml)" ""

# --- a rejected push: pull --rebase --autostash, push again; the rebased
# commit must still hold only the named path and no gitlink, even though
# the index holds a staged gitlink while the rebase runs.
OTHER="$T/other"
g clone -q "$BUS_ORIGIN" "$OTHER" 2>/dev/null
echo "other" > "$OTHER/other.txt"
g -C "$OTHER" add other.txt
g -C "$OTHER" commit -q -m "other node"
g -C "$OTHER" push -q origin main 2>/dev/null
printf 'agent_id: w\n' > "$BUS/agents/w.yaml"
out=$(bash "$MC" "$BUS" "t" agents/w.yaml); rc=$?
check "a rejected push is retried and pushed" eq "$rc:$(printf '%s\n' "$out" | tail -1)" "0:PUSHED"
check "origin has both commits" \
  eq "$(g -C "$BUS_ORIGIN" log --format=%s -2 main | tr '\n' '|')" "t|other node|"
check "the rebased commit changes only agents/w.yaml" \
  eq "$(changed_paths "$BUS_ORIGIN" main)" "agents/w.yaml"
check "origin still pins the product at the pin" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged after the rebase" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
check "the printed sha is the rebased HEAD" \
  eq "$(printf '%s\n' "$out" | sed -n 's/^COMMITTED //p')" \
  "$(g -C "$BUS" rev-parse HEAD | cut -c1-7)"

# The same with the staged gitlink as the only local change. Under
# ignore = all git sees a clean tree, makes no autostash, and a plain rebase
# would write the staged gitlink into the rebased commit.
g -C "$BUS" checkout -q -- README.md
g -C "$OTHER" pull -q --rebase 2>/dev/null
echo "other two" > "$OTHER/other2.txt"
g -C "$OTHER" add other2.txt
g -C "$OTHER" commit -q -m "other node two"
g -C "$OTHER" push -q origin main 2>/dev/null
check "the other node pushed first" \
  eq "$(g -C "$BUS_ORIGIN" log -1 --format=%s main)" "other node two"
printf 'agent_id: s\n' > "$BUS/agents/s.yaml"
out=$(bash "$MC" "$BUS" "t2" agents/s.yaml); rc=$?
check "a rejected push with only a staged gitlink is pushed" \
  eq "$rc:$(printf '%s\n' "$out" | tail -1)" "0:PUSHED"
check "that rebased commit changes only agents/s.yaml" \
  eq "$(changed_paths "$BUS_ORIGIN" main)" "agents/s.yaml"
check "origin still pins the product at the pin after it" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged after that rebase" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
echo "operator edit" >> "$BUS/README.md"

# --- a push that cannot succeed: COMMITTED then PUSH FAILED, exit 3
g -C "$BUS" remote set-url origin "$T/no-such-origin.git"
printf 'agent_id: v\n' > "$BUS/agents/v.yaml"
out=$(bash "$MC" "$BUS" "t" agents/v.yaml 2>/dev/null); rc=$?
check "an unreachable origin exits 3" eq "$rc" 3
check "an unreachable origin prints COMMITTED then PUSH FAILED" \
  eq "$(printf '%s\n' "$out" | sed 's/^COMMITTED [0-9a-f]\{7\}$/COMMITTED sha/')" \
  "$(printf 'COMMITTED sha\nPUSH FAILED')"
check "the commit stays local and holds only its path" \
  eq "$(changed_paths "$BUS" HEAD)" "agents/v.yaml"
g -C "$BUS" remote set-url origin "$BUS_ORIGIN"

# --- white-box: the post-commit check undoes a commit that holds a path it
# was not given, or a gitlink, and leaves the index as it was. The pre-checks
# keep the public surface from reaching this branch, so drive it directly.
. "$MC"
REPO="$BUS"
echo "extra" > "$BUS/extra.txt"
printf 'agent_id: u\n' > "$BUS/agents/u.yaml"
g -C "$BUS" add -- extra.txt
cp "$(mc_index_path)" "$T/index.before"
head=$(g -C "$BUS" rev-parse HEAD)
mc_save_index
g -C "$BUS" add -- agents/u.yaml
g -C "$BUS" commit -q -m "bad" -- agents/u.yaml extra.txt
NAMED="agents/u.yaml"
if mc_verify_or_undo "$head" >/dev/null; then
  fail "verify passed a commit holding an unnamed path"
else
  ok "verify rejects a commit holding an unnamed path"
fi
check "the bad commit is undone" eq "$(g -C "$BUS" rev-parse HEAD)" "$head"
check "the index is as it was before staging" \
  cmp -s "$(mc_index_path)" "$T/index.before"
g -C "$BUS" reset -q -- extra.txt
rm -f "$BUS/extra.txt" "$BUS/agents/u.yaml"

head=$(g -C "$BUS" rev-parse HEAD)
mc_save_index
g -C "$BUS" commit -q -m "gitlink" -- product
NAMED="product"
if mc_verify_or_undo "$head" >/dev/null; then
  fail "verify passed a commit holding a gitlink"
else
  ok "verify rejects a commit holding a gitlink"
fi
check "the gitlink commit is undone" eq "$(g -C "$BUS" rev-parse HEAD:product)" "$PIN"
check "the stale gitlink is staged again" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"

unit_done
