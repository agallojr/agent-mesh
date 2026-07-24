# Best practices (base)

Universal agent + coding conventions that ship with the mesh product.
Deployment-specific overrides live in the bus library
(`memory/best-practices.user.md`) and are layered on top by the bus's
`guidance/CLAUDE.md`.

IMPORTANT: Be maximally autonomous. Never ask for permission or confirmation
unless the action is truly irreversible AND destructive. Do not narrate what you
are about to do — just do it. Do not ask "shall I proceed?" or "would you like
me to..." or "should I go ahead?" — the answer is always yes. If something fails,
fix it and move on. Only stop to ask if you are genuinely blocked on a decision
that requires human judgment (e.g. a design fork with real tradeoffs).

When interacting with me, please adhere to the following guidelines:

1. Don't use exclamation marks in your messages or other flattering punctuation.

2. Be concise and to the point in your questions and requests.

3. When inserting code, do not use trailing whitespace. Lines with no content
   should be completely empty. Always fit code to the suggest 88 character line
   width.

4. Adhere to all PEP 8 guidelines when writing Python code. Keep imports in the
   right order, line lengths <= 88 characters, and use proper naming conventions.

5. Don't write your own test modules unless explicitly told to do so. This does not mean "don't test", it means don't leave test files around unless asked.

6. CRITICAL: Always use the local venv when running Python. Check for ./venv or
   .venv first. ALWAYS invoke python and pip directly from the venv (e.g.
   ./venv/bin/python, ./venv/bin/pip) — never use system python or a bare
   `python`/`pip` command. This applies even after context resets or new
   sessions.

7. Put all includes at the top of the module unless there is a very good reason
   not to.

8. Group the includes. Standard libs first. Then 3rd party. Then local imports.

9. Run commands freely without asking — assume blanket permission for everything
   except: running as sudo, push/force-push to git remotes, or executing
   untrusted scripts/binaries downloaded from the internet. Everything else is
   pre-approved: building, testing, installing packages, creating files,
   overwriting files, deleting files, patching, grepping, piping, running
   Python/Node scripts, git operations (except push), killing processes, chmod,
   etc. Do NOT ask "shall I proceed?" or "would you like me to..." — just do it.

10. Keep your code comments especially at the top of the module concise and to
    the point. We don't need long per-arg docstrings unless the function is
    particularly complex.

11. Use strong typing where appropriate in Python code. Show the types of
    function arguments and return values.

12. Compilation is not a test.

13. Don't produce separate files for specs unless asked for it.

14. When resizing images, always preserve the aspect ratio unless explicitly
    told otherwise.

15. Never run git add, git commit, or git push unless explicitly asked to do so.

16. Always read and follow these Best-Practices guidelines at the start of every
    session and conversation. Load them before doing any work.

17. Keep test runs short. Run only the relevant unit tests for the code you
    changed (e.g. a single test file or test class). Do NOT run the full test
    suite or slow/integration tests unless explicitly asked. If a test takes more
    than 60 seconds, skip it.

18. Pre-approved safe operations — NEVER ask or prompt about these; just do them
    silently (covered by rule 9):
    - Shell navigation and builtins: cd, pwd, pushd/popd, ls, echo.
    - Simple expansions: glob (*.toml), brace, tilde (~), and variable expansion.
    - Any other read-only or trivially-reversible shell operation (grep, find,
      cat, wc, stat, file moves/renames within the workspace, mkdir, etc.).
    You ask too often. Default to acting.

19. Do NOT use multi-option clarifying questions (AskUserQuestion) for low-stakes
    or reversible choices. Pick the sensible default, state it in one line, and
    proceed. Reserve questions for genuinely irreversible actions or real design
    forks with material tradeoffs. A reorg, a file layout, a naming choice — just
    pick the obvious option and do it; the user will redirect if they disagree.

20. `python3 -c "..."` (and venv-python `-c "..."`) for read-only inspection —
    loading a JSON/result file, printing a few fields, checking a value — is
    always OK. It is a trivially-reversible read; never prompt about it.

21. BLANKET TOOL AUTHORIZATION. I have pre-authorized, at the harness level
    (~/.claude/settings.json permissions.allow), every Bash command and every
    Read/Edit/Write/Glob/Grep/WebFetch/WebSearch call. You will not see an
    approval prompt for these, and you must never wait for one or ask me to
    confirm a routine command. Just run it. The ONLY commands still fenced off
    (harness deny list) are: sudo, git push, git commit, git add. These four
    plus the carve-outs below are the complete set of things that still need my
    say-so — everything else is yours to run.

22. STILL OFF-LIMITS without my explicit say-so (harness deny rules are
    prefix-only and cannot catch these, so honor them yourself):
    - Piping a downloaded script straight into a shell (curl … | bash, wget …
      | sh, or running any untrusted binary fetched from the net).
    - Recursive force-deletes of anything outside the workspace or /tmp
      (rm -rf on $HOME, /, system paths, or broad globs you're unsure about).
    - Long-running operations (anything expected to run for a long time); do not
      launch these without explicit approval, and not in the background either.
    When in doubt on one of THESE specific cases, ask. For anything else, act.

23. Don't branch in a git repo unless asked to do so.
