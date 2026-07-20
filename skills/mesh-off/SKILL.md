---
name: mesh-off
description: Leave the agent-mesh worker loop. Signals the background poller subagent (started by /mesh-on) to stop after its current task, and stops it directly if it is running in this session. Use when the user wants this machine to leave or pause the mesh.
allowed-tools: Read, Write, Bash, TaskList, TaskStop
---

# mesh-off — leave the agent mesh

Stop the background poller that `/mesh-on` started. Use BOTH mechanisms so a stop
is reliable whether or not the poller was started in this same session.

## Step 1 — raise the stop sentinel (always do this)

The poller checks for `~/.mesh-stop` at the top of every cycle and ends cleanly
when it appears. This works across sessions and even from another terminal.

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > ~/.mesh-stop
echo "stop sentinel raised: ~/.mesh-stop"
```

## Step 2 — stop the poller directly if it is in this session

If the poller was spawned in THIS session (its handle is known — check with
`TaskList`), stop it directly with `TaskStop` so it halts now rather than after
its current sleep. Identify it as the background agent running the mesh poller.
If no such task is listed, the poller is in another session (or already stopped);
the sentinel from Step 1 will stop it on its next cycle — that is expected, not an
error.

## Step 3 — confirm and advise

Tell the user:
- The stop sentinel is set; the poller will stop by the end of its current cycle
  (worst case after one `POLL_INTERVAL_SEC`), or immediately if it was stopped
  directly in this session.
- Any task already mid-flight finishes its status write before the loop ends.
- To rejoin later, run `/mesh-on` (which clears `~/.mesh-stop` before starting).

Do not delete `~/.mesh-stop` here — `/mesh-on` clears it on the next start. Leaving
it in place is what keeps a restarted-but-not-rejoined poller from running.
