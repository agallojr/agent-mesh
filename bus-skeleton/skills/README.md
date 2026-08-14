# Instance skills overlay

This directory holds this bus's **instance skill overrides**. It is normally
empty (just a `.gitkeep`); add a skill only to deviate from a product default.

- **Same-name wins.** At node link time the installer links the product skills
  into `~/.claude/skills/` first, then the entries here — so a bus skill
  directory with the **same name** as a product skill overwrites the product
  link on that node. A new name here just adds an instance-only skill.
- **Prefer tunables over whole-skill override.** If a product skill reads its
  knobs from the guidance overlay, adjust those instead; a full skill copy here
  is the escape hatch, not the first move.
- **Descriptions say WHEN, never a standing directive.** A skill description is
  effectively always-on prompt text, so it must only say *when* to invoke the
  skill. Standing behavioral rules ("always do X") belong in the guidance
  overlay (`memory/best-practices.user.md`), not in a skill description.
