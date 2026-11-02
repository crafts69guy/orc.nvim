# Lua benchmark series: cron, JSON Schema subset and expressions

Each independent `src/<name>.lua` returns the documented module table.
Use Lua 5.1 and Neovim built-ins, without dependencies or shared implementation.
Write own tests in `test/*_spec.lua`; each file returns `function(t)` using
`t.test`, `t.eq` and `t.error(kind,fn)`. Run `nvim --clean -l test/run.lua`.

Errors are tables `{ kind, message, position? }` with nonempty messages.
Use TypeError, SyntaxError, RangeError or ReferenceError as specified.
JSON null is `vim.NIL`, arrays are list tables, and empty objects are
`vim.empty_dict()`. This is a fresh Lua benchmark series with its own baseline.

## cron.lua

`parse(text)` returns sorted, distinct integer arrays named `minute`, `hour`,
`dayOfMonth`, `month`, `dayOfWeek`.
Require five space/tab-separated fields with ranges 0–59, 0–23, 1–31, 1–12 and
0–7 respectively. Weekday 7 normalizes to Sunday 0.

Each field is a comma-separated list of `*`, `V`, `A-B`, `*/S` or `A-B/S`.
Steps are positive ASCII integers starting at the range minimum.
Allow case-insensitive JAN–DEC and SUN–SAT in their corresponding fields.
Support lower-case macros `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`,
`@midnight`, `@hourly` with conventional five-field expansion.

Non-string input raises TypeError. Wrong field count, unknown macro/name,
empty list entries, malformed range/step or bare-value step raise SyntaxError.
Out-of-bound values, reversed ranges and zero steps raise RangeError.

`next(text, from)` accepts finite Unix epoch milliseconds and returns the earliest
matching whole UTC minute strictly afterward. If both day fields are not exactly
`*`, match day-of-month OR day-of-week; otherwise require both.
Return `vim.NIL` if no match occurs within eight years, including impossible dates
such as February 30, in well under a second. Skip whole days rather than scan every
minute. Invalid `from` raises TypeError. The starting timestamp must be within
UTC years 0001–9991 so the eight-year horizon remains representable; other finite
timestamps raise RangeError.

## schema.lua

`validate(value, schema)` returns an array of `{ path, keyword, message }` errors;
empty means valid. Paths are JSON Pointers with zero-based array indices and
`~`/`/` escaped as `~0`/`~1`. Error ordering is unspecified.

A schema is an object or boolean. True accepts all; false adds one `false` error.
Invalid reached schemas raise TypeError. Ignore unknown keywords. Check every
applicable keyword, and ignore keywords that do not apply to the value's type.

Supported keywords:

- `type`: one name or array from null, boolean, object, array, number, integer, string.
- `enum`, `const`: deep JSON equality, ignoring object key order.
- `required`: one error per missing key, at the object's path.
- `properties`: validate present listed properties at their child pointers.
- `additionalProperties`: false rejects each extra key at the object's path;
  a schema validates each extra value at its child pointer.
- `items`: one schema for every array element.
- `minLength`, `maxLength`: Unicode code-point length, inclusive.
- `minItems`, `maxItems`, `minimum`, `maximum`: inclusive bounds.
- `pattern`: an unanchored **Lua pattern**, intentionally not JavaScript RegExp.
- `allOf`: report every subschema error.
- `anyOf`: one error when no subschema accepts, without nested errors.
- `oneOf`: one error unless exactly one subschema accepts.
- `$ref`: `#/definitions/<name>` resolves against root definitions and ignores
  sibling keywords. Support recursive tree schemas. Unresolved references raise ReferenceError.

## expr.lua

`evaluate(source, variables?)` returns a number or boolean. Variables default to `{}`;
lookup only own table keys and require finite numbers or booleans.
Unknown variables/functions raise ReferenceError; invalid arguments/operands raise TypeError.

Lex the whole input first. Tokens are optional whitespace, ASCII numbers matching
digits with optional fractional digits and exponent, identifiers, true/false, and
`( ) , ? : || && == != < <= > >= + - * / % ! ^`.
Reject `.5`, `1.`, lone `=` or `&`, and unknown characters.

Precedence, weakest to strongest:
ternary `?:` (right), `||`, `&&`, `== !=`, comparisons, `+ -`, `* / %`,
prefix `- !` (right), power `^` (right).
Power binds tighter than a prefix on its left and permits prefix on its right:
`-2^2=-4`, `2^-1=0.5`, `2^3^2=512`.

Arithmetic/comparison operands must be numbers. Equality accepts two numbers or two
booleans. Logical operators and ternary conditions require booleans and short-circuit.
Remainder keeps the dividend's sign. Division/remainder by zero raise RangeError.
Functions: abs, floor, ceil, sqrt, round (one argument), min/max (one or more).
Round halves away from zero; negative sqrt raises RangeError. Wrong arity raises TypeError.

Syntax errors include zero-based byte `position`: the first unlexable character,
otherwise the first unexpected token or input length at premature end.
