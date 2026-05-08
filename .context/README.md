# `.context` for `garmiand`

This folder is the repository's canonical context layer for humans and AI agents.
It is not imported by the runtime application. Its job is to explain the system shape,
engineering rules, and decisions that are easy to miss when reading only code.

## Read Order

1. `SYSTEM_OVERVIEW.md`
2. `TECH_STACK.md`
3. `ADR_LOG.md`
4. Open one specialized document only for the area you are changing

## File Map

- `SYSTEM_OVERVIEW.md` - system purpose, modules, runtime boundaries, main flows
- `TECH_STACK.md` - languages, frameworks, libraries, and non-negotiable conventions
- `ADR_LOG.md` - architecture decisions that should not be changed casually
- `API_CONTRACTS.md` - Connect IQ phone-app message envelope and message kinds
- `CONFIGURATION.md` - constants (watch app id, ports, sizes, timeouts) and where they live
- `USER_STORIES.md` - end-to-end workflows the app supports
- `MAP_RENDERING.md` - tile choice, Web Mercator projection, polyline overlay
- `CONNECT_IQ_NOTES.md` - GCM proxy behavior, response codes, hard constraints learned the painful way
- `arch_code_style_guide.md` - implementation, logging, and testing rules
- `BUILD_AND_DEPLOY.md` - build the watch `.prg`, sideload, build the APK
- `bug_fixes.md` - regression-sensitive areas and bug-fix rules

## Update Policy

- Update `.context` in the same branch when architecture or contracts change.
- Keep docs short, high-signal, and grounded in actual code.
- If code and docs disagree, fix the docs or the code immediately; do not leave the mismatch unresolved.
