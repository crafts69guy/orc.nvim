# Lua benchmark series: four independent utilities

Implement `src/duration.lua`, `src/semver.lua`, `src/csv.lua` and `src/lru.lua`.
Each returns a module table and shares no implementation with the others.
Use Lua 5.1 and Neovim built-ins only. Tests in `test/*_spec.lua` return a function
receiving `t.test(name, fn)`, `t.eq(actual, expected)` and `t.error(kind, fn)`.
Run `nvim --clean -l test/run.lua`.

Raise errors as tables `{ kind = "TypeError|SyntaxError|RangeError", message = "..." }`.
Messages must be nonempty. This is a new Lua workload; old JavaScript timings and
costs are historical evidence, not a comparable baseline.

## duration.lua

Export `parseDuration(text)`, returning integer milliseconds no greater than
9007199254740991. Trim boundary whitespace; accept consecutive ASCII
digits/unit segments in strictly increasing unit order:
`d=86400000`, `h=3600000`, `m=60000`, `s=1000`, `ms=1`.
Each unit appears at most once. Zero and leading zeros are legal.
Examples: `1h30m15s` → 5415000; `250ms` → 250; `1m30s500ms` → 90500.

Non-string inputs raise TypeError; malformed/empty input, unknown/repeated/reversed
units, signs, decimals, exponents, internal whitespace and upper-case units raise
SyntaxError; overflow raises RangeError.

## semver.lua

Export `compare(a, b)` returning -1, 0 or 1 according to SemVer 2.0.0.
Require `MAJOR.MINOR.PATCH`, optionally `-prerelease` and `+build`.
Numeric core and numeric prerelease identifiers cannot have leading zeros;
build identifiers may. Identifiers contain only ASCII letters, digits and hyphens.
Lists cannot contain empty identifiers. Prefixes and boundary whitespace are invalid.

Compare core and numeric prerelease identifiers exactly even beyond floating-point
integer precision. A release outranks its prerelease; numeric prerelease identifiers
rank below alphanumeric identifiers; compare alphanumeric text in ASCII order;
a longer otherwise equal prerelease list ranks higher. Ignore build metadata.
All invalid input raises TypeError.

## csv.lua

Export `parse(text)` returning an array of arrays of strings.
Commas delimit fields; LF and CRLF delimit records; lone CR is data.
Quoted fields retain commas/newlines/CR; doubled quotes represent one quote.
Keep all whitespace, empty fields and different row widths.
Empty input returns `{}`; a final record terminator adds no extra row.
Empty interior lines are rows containing one empty string.

Unterminated quotes, quotes inside unquoted fields and data after a closing quote
raise SyntaxError. Non-string input raises TypeError.

## lru.lua

Export `new(capacity)` returning a least-recently-used cache with colon methods:
`cache:get(key)`, `cache:set(key,value)`, `cache:has(key)`, `cache:delete(key)`.
`set` returns the same cache and evicts the oldest entry only when capacity is
exceeded. Get and set mark most recent; has does not. Delete reports prior presence.
The read-only `cache.size` counts entries. Capacity must be a positive finite integer,
otherwise raise RangeError.

Support nil keys/values, NaN keys, equivalent positive/negative zero keys and table
keys by identity. `has` distinguishes stored nil from absence.
Get, set, has and delete must be O(1). Assigning cache fields raises TypeError.
