# Mesh product guidance -- self-contained product chain

This is the product's own guidance chain. It is **self-contained**: every include
below points at a file inside this product repo, and nothing here reaches outside
the product (no machine-local path, no bus path). That keeps the product complete
and publishable on its own.

In a deployment, this is NOT the node entry point. The **bus** owns composition:
the bus's own `guidance/CLAUDE.md` (at the bus root, generated at install time)
`@`-includes the product base plus the deployment's user overlay, in order:

```
@product/guidance/best-practices.base.md
@memory/best-practices.user.md            <- the bus's private overlay (may be absent)
@product/guidance/agent-operating.md
@product/guidance/permissions.md
```

The `mesh-on` skill is the operational entry point: a human starts Claude on a
node and invokes `/mesh-on`, which reads the bus chain above and enters the worker
loop. See `spec/PROTOCOL.md` §4.4.

The product chain, for working on or reading the product standalone (base rules
only — the user overlay is a bus concern and is layered in by the bus entry
point, never from here):

@best-practices.base.md
@agent-operating.md
@permissions.md
