# Command etiquette

- Prefer tool-native operations over raw destructive shell patterns:
  `swift package clean` / `swift package reset` — not `rm -rf .build`;
  `xcodebuild clean` — not deleting DerivedData by path.
  Raw destructive patterns trigger approval prompts that stall unattended
  runs, and tool-native commands are safer and self-documenting.
- For clean-build evidence, the canonical command is
  `.claude/scripts/checks.sh --clean` — use it instead of hand-rolled
  delete-then-build sequences.
- `rm -rf` is acceptable only for paths you created yourself this session
  (scratch dirs under /tmp). Never on repo contents.
