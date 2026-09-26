# Documentation maintenance

For any change to code, configuration, tests, documentation, generated files,
or a release, consult the documentation dependency map **before editing**.
Follow applicable parent instructions and private project-memory routing first.

1. Read `docs/maintenance.md` and the `policy` in
   `docs/maintenance-map.json`. Do not reconstruct decisions from chat history.
2. Run `python3 tools/doc_impact.py --topic <topic>` or pass the planned paths.
   Read only the selected authorities and relevant evidence. For unknown scope,
   use `--list`. This lookup is required even for a documentation-only change.
3. After editing, run `python3 tools/doc_impact.py --diff <starting-commit>`
   and `python3 tools/doc_impact.py --check`. Account for **every** returned
   review target as updated, checked-no-change (with reason), or pending.
   Unmapped paths require a map update, not an assumption of no impact.
4. Preserve dated/versioned test evidence. Add a dated correction or follow-up;
   never rewrite an old observation to look like a current test.
5. Check generated commands, images and external Release bodies when selected.
   A repository push does not update a GitHub Release body or asset.
6. Record scope, starting/final commits, evidence and review dispositions in the
   private project checkpoint if available; otherwise in the task handoff.
   Keep private router names, addresses and credentials out of public files.

Keep the map and this workflow current when files, versions, publication
surfaces or dependencies change. The tool lists review obligations; it does
not prove prose correct, authorize publication, or claim tests were run.
