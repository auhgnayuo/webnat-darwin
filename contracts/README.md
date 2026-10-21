# Shared Webnat contract v1

The authoritative source is **webnat-web/contracts/v1/golden.json**. The other four repositories vendor
byte-identical copies. This is a versioned contract, not a requirement to turn the five repositories into a monorepo.

## Automated fixtures

Every platform runs the same `E*` error cases, `M*` message/canonicalization cases, `R*` rejected messages,
and portable `J*` invalid-value factory cases. Tests build native invalid values locally because JSON cannot
represent NaN, cycles, undefined, functions, or platform objects directly.

- Wire error codes are signed 32-bit integers. Whole ASCII numeric strings are accepted; whitespace,
  partial parses, fractional numbers, booleans and overflow are rejected. Code **0 is preserved**.
- Alias priority is first **present** key, not first truthy/non-null key. A present canonical null cannot fall through.
- String messages, including `""`, are preserved. Finite number/Boolean messages have primitive descriptions.
  Missing/null/container messages use `Unknown Error`.
- `from` and `to` are non-empty strings. JSON null becomes native null/nil; top-level null fields are omitted
  while nested keys/positions remain. JSON text must be parsed before executing its data as JS.
- The `C*`, `B*`, `L*` scenario inventory describes stateful responsibilities. It is **not a coverage percentage**
  and not a claim that JSON golden fixtures exercise platform lifecycle behavior. Each platform's separate
  tests cover these event/timing scenarios; Web is not responsible for native broadcast winner selection.

## Editing / synchronization

Contract v1 is frozen with release **2.0.0**. Do not change its golden file or expected results in place.
Introduce a new version directory and update consumers/verifiers explicitly for future contract changes.
The sync helper may still restore identical v1 copies to adjacent checkouts, but rejects changes to the
released digest. Review and commit corresponding changes in all five repositories together.

Each repository's CI verifies the digest before running its tests. The cross-repository workflow also compares
all five byte copies and executes Electron/Web interop. Use matching refs/tags for coordinated releases.
This gate requires the initial contracts to have landed in every checkout before the first release can pass.
