#!/usr/bin/env bash
# Unit test of the commit scope of skills/mesh-post/mesh-post.sh (R4): its
# commit holds only the message files it wrote, never a gitlink, while other
# changes and a stale gitlink are pending in the checkout, a rejected push
# included.
set -u
. "$(dirname "$0")/lib.sh"
unit_setup
MP="$SKILLS/mesh-post/mesh-post.sh"

mk_product product
mk_bus bus
allow_repo "$BUS"
stale_product
echo "operator edit" >> "$BUS/README.md"
echo "Do the unit thing." > "$T/body.md"

before=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MP" --type task.request --title "unit task" --body-file "$T/body.md" \
  --to role:build --repo "$BUS" --from op-main 2>&1); rc=$?
check "a post exits 0" eq "$rc" 0
check "one commit" eq "$(g -C "$BUS" rev-list --count "$before..HEAD")" 1
files=$(changed_paths "$BUS" HEAD)
check "the commit holds one message file in the build queue" \
  test "$(printf '%s\n' "$files" | grep -c '^tasks/roles/build/[0-9T]*-[0-9]*-unit-task\.md$')" = 1
check "the commit holds nothing else" eq "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" 1
check "HEAD:product is still the pin" eq "$(g -C "$BUS" rev-parse HEAD:product)" "$PIN"
check "origin has the post" eq "$(g -C "$BUS_ORIGIN" rev-parse main)" "$(g -C "$BUS" rev-parse HEAD)"
check "the stale gitlink is still staged" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"
check "the other modified file is still modified and unstaged" \
  eq "$(g -C "$BUS" diff --name-only -- README.md)" "README.md"

# Fan-out: one commit, both files, nothing else.
before=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MP" --type query --title ping --body-file "$T/body.md" \
  --to n1 --to n2 --repo "$BUS" --from op-main 2>&1); rc=$?
check "a fan-out post exits 0" eq "$rc" 0
files=$(changed_paths "$BUS" HEAD)
check "the fan-out commit holds the two message files only" \
  eq "$(printf '%s\n' "$files" | sed 's#/[^/]*$##' | tr '\n' ' ')" "tasks/n1 tasks/n2 "

# A rejected push with the stale gitlink as the only local change: the
# rebased post still holds only its file, and origin keeps the pin.
g -C "$BUS" checkout -q -- README.md
OTHER="$T/other"
g clone -q "$BUS_ORIGIN" "$OTHER" 2>/dev/null
echo "other" > "$OTHER/other.txt"
g -C "$OTHER" add other.txt
g -C "$OTHER" commit -q -m "other node"
g -C "$OTHER" push -q origin main 2>/dev/null
check "the other node pushed first" eq "$(g -C "$BUS_ORIGIN" log -1 --format=%s main)" "other node"
out=$(bash "$MP" --type task.request --title "after race" --body-file "$T/body.md" \
  --to role:build --repo "$BUS" --from op-main 2>&1); rc=$?
check "a post after a rejected push exits 0" eq "$rc" 0
check "origin has both commits" \
  eq "$(g -C "$BUS_ORIGIN" log --format=%s -2 main | sed 's/ ids .*//' | tr '\n' '|')" \
  "post task.request to role:build|other node|"
check "the rebased post holds only its file" \
  test "$(changed_paths "$BUS_ORIGIN" main | grep -c 'after-race\.md$')$(changed_paths "$BUS_ORIGIN" main | wc -l | tr -d ' ')" = 11
check "origin still pins the product at the pin" \
  eq "$(g -C "$BUS_ORIGIN" rev-parse main:product)" "$PIN"
check "the stale gitlink is still staged after the rebase" \
  eq "$(g -C "$BUS" ls-files -s product | awk '{print $2}')" "$PROD_OLD"

# --dry-run stages only its own file and commits nothing.
before=$(g -C "$BUS" rev-parse HEAD)
out=$(bash "$MP" --type task.request --title "dry run" --body-file "$T/body.md" \
  --to role:build --repo "$BUS" --from op-main --dry-run 2>&1); rc=$?
check "a dry run exits 0" eq "$rc" 0
check "a dry run commits nothing" eq "$(g -C "$BUS" rev-parse HEAD)" "$before"
check "a dry run stages its file and the stale gitlink only" \
  eq "$(g -C "$BUS" diff --cached --ignore-submodules=none --name-only | sed 's#^tasks/roles/build/.*-dry-run\.md$#MSG#' | tr '\n' ' ')" \
  "product MSG "

unit_done
