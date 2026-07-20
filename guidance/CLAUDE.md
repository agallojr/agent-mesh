# Mesh agent guidance -- well-known entry point

This is the single well-known guidance file for every mesh node, hub or worker.
It lives in the repo so one `git pull` gives every node byte-identical,
version-controlled instructions. Nothing here may depend on a machine-local path
a remote node does not have.

The `mesh-on` skill is the operational entry point: a human starts Claude
normally on a node and invokes `/mesh-on`, which reads this guidance chain and
enters the worker loop. The chain, in order:

@best-practices.md
@agent-operating.md
@permissions.md
