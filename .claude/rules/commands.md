# Command etiquette

- Prefer tool-native operations over raw destructive shell patterns:
  `swift package clean` / `swift package reset` — not `rm -rf .build`;
  `xcodebuild clean` — not deleting DerivedData by path.
  Tool-native commands are safer and self-documenting.
- `rm -rf` is acceptable only for paths you created yourself this session
  (scratch dirs under /tmp). Never on repo contents.
