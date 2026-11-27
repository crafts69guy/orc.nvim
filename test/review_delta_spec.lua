local review_delta = require("orc.review_delta")
local runtime = require("orc.runtime")

local function modification(path, patch)
	return "diff --git a/"
		.. path
		.. " b/"
		.. path
		.. "\nindex 1234567..7654321 100644\n--- a/"
		.. path
		.. "\n+++ b/"
		.. path
		.. "\n"
		.. patch
end

local function deletion(path, ...)
	local lines = { ... }
	return modification(
		path,
		"@@ -2," .. #lines .. " +1,0 @@\n-" .. table.concat(lines, "\n-") .. "\n"
	)
end

Test.test("review delta accepts complete comment runs across supported source files", function()
	local patch = deletion("src/current.ts", "  // explain", "\t", "  /**", "   * details", "   */")
		.. deletion("src/init.lua", "-- explain", "--[=[", "-- details", "--]=]")
		.. deletion("src/main.mts", "/* note */ /* another note */", "/*", "//*/")
		.. deletion("src/main.cts", "// plain comment\r")
		.. modification("tools/end.lua", "@@ -1 +0,0 @@\n--- last line\n\\ No newline at end of file\n")
	Test.eq(review_delta.comment_only(patch), true)
end)

for _, example in ipairs({
	{ "Lua block terminator", deletion("a.lua", "--]]") },
	{ "Lua leveled block terminator", deletion("a.lua", "-- ends ]=]") },
	{ "TypeScript block toggle", deletion("a.ts", "//*/") },
	{ "TypeScript triple-slash reference", deletion("a.ts", '/// <reference types="node" />') },
	{ "TSX child text", deletion("a.tsx", "    // Status: ready") },
	{ "JS child text", deletion("a.js", "    /* Status: ready */") },
	{ "JSX child text", deletion("a.jsx", "    // Status: ready") },
	{ "ES module JavaScript", deletion("a.mjs", "// explanation") },
	{ "CommonJS JavaScript", deletion("a.cjs", "// explanation") },
	{ "TypeScript line separator", deletion("a.ts", "// note\226\128\168doWork()") },
	{ "TypeScript paragraph separator", deletion("a.ts", "// note\226\128\169doWork()") },
	{ "TypeScript bare carriage return", deletion("a.ts", "// note\rdoWork()") },
	{ "Lua bare carriage return", deletion("a.lua", "-- note\rprint(1)") },
	{ "extra carriage return before CRLF", deletion("a.ts", "// note\r\r") },
	{
		"TypeScript spaced triple-slash reference",
		deletion("a.ts", '///  <reference path="./g.d.ts" />'),
	},
	{
		"TypeScript unspaced triple-slash reference",
		deletion("a.ts", '///<reference path="./g.d.ts" />'),
	},
	{ "Lua annotation with two spaces", deletion("a.lua", "---  @param x string") },
	{ "Ruby frozen string literal", deletion("a.rb", "# frozen_string_literal: true") },
	{ "Go cgo preamble", deletion("main.go", "// static int two(void) { return 2; }") },
	{ "Go build tag separator", deletion("tag.go", "") },
	{ "Go example output", deletion("ex_test.go", "\t// Output: 2") },
	{ "Java Unicode escape", deletion("A.java", '// \\u000a System.out.println("hi");') },
	{ "shell continuation", deletion("a.sh", "# note") },
	{ "C continuation", deletion("a.c", "// c") },
	{ "Python coverage pragma", deletion("a.py", "# pragma: no cover") },
	{ "Rust doc comment", deletion("a.rs", "/// Verbose output") },
	{ "CSS stylelint directive", deletion("a.css", "/* stylelint-disable */") },
}) do
	Test.test("review delta refuses repro for " .. example[1], function()
		local accepted, reason = review_delta.comment_only(example[2])
		assert(not accepted and reason, example[1] .. " should be refused with a reason")
	end)
end

for _, example in ipairs({
	{ "TypeScript Deno lint", deletion("a.ts", "// Deno-Lint-ignore no-explicit-any") },
	{ "TypeScript TSLint", deletion("a.ts", "// tslint:disable-next-line") },
	{ "Flow suppression", deletion("a.ts", "// $FlowFixMe") },
	{ "TypeScript internal annotation", deletion("a.ts", "/** @Internal */") },
	{ "TypeScript source map", deletion("a.ts", "//# sourceMappingURL=a.js.map") },
	{ "Lua spaced annotation", deletion("a.lua", "--- @param value string") },
}) do
	Test.test("review delta refuses directive for " .. example[1], function()
		Test.eq({ review_delta.comment_only(example[2]) }, { false, "removed directive" })
	end)
end

Test.test("review delta refuses additions, code, directives and partial comments", function()
	local examples = {
		{ "added comment", modification("src.ts", "@@ -2 +2 @@\n-// before\n+// after\n") },
		{ "partial JSDoc", deletion("src.ts", " * details") },
		{ "open block", deletion("src.ts", "/**", " * details") },
		{ "open outer block", deletion("src.rs", "/* outer /* inner */", "// details") },
		{ "block with trailing code", deletion("src.ts", "/* explanation */ const value = 1") },
		{ "code", deletion("src.ts", "const value = 1") },
		{ "mixed", deletion("src.ts", "// explanation", "const value = 1") },
		{ "shebang", deletion("tool.sh", "#!/bin/sh") },
		{ "hash bracket", deletion("tool.py", "#[special]") },
		{ "linter directive", deletion("src.ts", "// ESLINT-disable-next-line") },
		{ "build directive", deletion("src.go", "//go:build special") },
		{ "Lua annotation", deletion("init.lua", "---@param value string") },
		{ "block directive", deletion("src.ts", "/**", " * @LICENSE MIT", " */") },
		{ "Lua block body without markers", deletion("init.lua", "--[[", "details", "--]]") },
		{ "CSS slash line", deletion("main.css", "// code") },
		{ "line splice", deletion("main.c", "// explanation \\") },
		{ "Markdown", deletion("notes.md", "# Heading") },
		{ "YAML", deletion("values.yaml", "# explanation") },
		{ "split block", modification("src.ts", "@@ -1 +0,0 @@\n-/*\n@@ -4 +2,0 @@\n-*/\n") },
		{ "truncated hunk", modification("src.ts", "@@ -2,2 +1,0 @@\n-// explanation\n") },
		{ "NUL in text diff", deletion("src.ts", "// text\0data") },
	}
	for _, example in ipairs(examples) do
		local accepted, reason = review_delta.comment_only(example[2])
		assert(not accepted and reason, example[1] .. " should be refused with a reason")
	end
end)

Test.test("review delta refuses file additions, deletions, modes, binaries and renames", function()
	for _, patch in ipairs({
		"new file mode 100644\nindex 0000000..1234567\n--- /dev/null\n+++ b/src.ts\n@@ -0,0 +1 @@\n+// new\n",
		"deleted file mode 100644\nindex 1234567..0000000\n--- a/src.ts\n+++ /dev/null\n@@ -1 +0,0 @@\n-// old\n",
		"old mode 100644\nnew mode 100755\n",
		"index 1234567..7654321 100644\nBinary files a/src.ts and b/src.ts differ\n",
		"similarity index 100%\nrename from src.ts\nrename to current.ts\n",
		"index 1234567..7654321 120000\n--- a/src.ts\n+++ b/src.ts\n@@ -1 +0,0 @@\n-// old target\n",
	}) do
		local accepted, reason = review_delta.comment_only(
			deletion("first.ts", "// allowed") .. "diff --git a/src.ts b/src.ts\n" .. patch
		)
		assert(not accepted and reason, patch)
	end
end)

Test.test(
	"review delta snapshots working files and cleans its index without touching the real one",
	function()
		local path = Test.temp()
		local rt = runtime.new({ cwd = path, env = { HOME = path, GIT_CONFIG_NOSYSTEM = "1" } })
		local exec, indexes = rt.exec, {}
		rt.exec = function(argv, opts)
			local index = opts and opts.env and opts.env.GIT_INDEX_FILE
			if type(index) == "string" then
				indexes[index] = true
			end
			return exec(argv, opts)
		end
		local function git(...)
			local result = rt.exec({ "git", ... })
			assert(result.code == 0, result.stderr)
		end
		git("init", "-q")
		Test.eq(review_delta.snapshot(rt, path), nil)
		local source = rt.abspath("source.ts")
		rt.write(source, "const value = 1\n")
		git("add", "-A")
		Test.eq(review_delta.snapshot(rt, path), nil)
		git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
		rt.write(source, "const value = 2\n")
		git("add", "-A")
		local real_index = rt.abspath(".git/index")
		local staged = assert(rt.read(real_index))
		rt.write(source, "// working copy\nconst value = 3\n")
		local added = rt.abspath("untracked.ts")
		rt.write(added, "// untracked\n")
		local reviewed = assert(review_delta.snapshot(rt, path))
		Test.eq({ review_delta.compare(rt, path, reviewed) }, { true })
		vim.uv.fs_unlink(added)
		Test.eq(review_delta.compare(rt, path, reviewed), false)
		rt.write(added, "// untracked\n")
		rt.write(source, "const value = 3\n")
		Test.eq({ review_delta.compare(rt, path, reviewed) }, { true, true })
		for _, failure in ipairs({ "--name-only", "cat-file blob" }) do
			local run = rt.exec
			Test.replace(rt, "exec", function(argv, opts)
				local result = run(argv, opts)
				if table.concat(argv, "\0"):find(failure, 1, true) then
					assert(result.code == 0, result.stderr)
					result.code = 1
				end
				return result
			end, function()
				Test.eq({ review_delta.compare(rt, path, reviewed) }, { false })
			end)
		end
		for _, ending in ipairs({ "\r", "\r\r" }) do
			rt.write(source, "// working copy" .. ending .. "\nconst value = 3\n")
			local tree = assert(review_delta.snapshot(rt, path))
			rt.write(source, "const value = 3\n")
			Test.eq(review_delta.compare(rt, path, tree), ending == "\r")
		end
		Test.eq(rt.read(real_index), staged)
		assert(next(indexes))
		for index in pairs(indexes) do
			Test.eq(vim.uv.fs_stat(vim.fs.dirname(index)), nil)
		end
		assert(vim.uv.fs_unlink(real_index))
		Test.eq(review_delta.snapshot(rt, path), nil)
	end
)

Test.test("review delta refuses working edits to a force-added ignored file", function()
	local path = Test.temp()
	local rt = runtime.new({ cwd = path, env = { HOME = path, GIT_CONFIG_NOSYSTEM = "1" } })
	local function git(...)
		local result = rt.exec({ "git", ... })
		assert(result.code == 0, result.stderr)
	end
	git("init", "-q")
	git("config", "core.trustctime", "false")
	git("config", "core.checkStat", "minimal")
	rt.write(rt.abspath(".gitignore"), "generated.ts\n")
	local source = rt.abspath("source.ts")
	rt.write(source, "// explanation\nexport const value = 1\n")
	git("add", "-A")
	git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
	local generated = rt.abspath("generated.ts")
	rt.write(generated, "export const generated = 1\n")
	local mtime = 1600000000
	assert(vim.uv.fs_utime(generated, mtime, mtime))
	git("add", "-f", "--", "generated.ts")
	assert(vim.uv.fs_utime(rt.abspath(".git/index"), mtime, mtime))

	local reviewed = assert(review_delta.snapshot(rt, path))
	rt.write(generated, "export const generated = 2\n")
	assert(vim.uv.fs_utime(generated, mtime, mtime))
	rt.write(source, "export const value = 1\n")
	Test.eq(review_delta.compare(rt, path, reviewed), false)
end)

local function source_change(label, extension, prefix, removed, suffix, accepted)
	Test.test("review delta compares source for " .. label, function()
		local path = Test.temp()
		local rt = runtime.new({ cwd = path, env = { HOME = path, GIT_CONFIG_NOSYSTEM = "1" } })
		local function git(...)
			local result = rt.exec({ "git", ... })
			assert(result.code == 0, result.stderr)
		end
		local name = "source " .. extension .. "." .. extension
		local source = rt.abspath(name)
		local safe = rt.abspath("a quote ' and\r\n.ts")
		Test.eq(review_delta.comment_only(deletion(name, unpack(removed))), true)
		git("init", "-q")
		rt.write(source, prefix .. table.concat(removed, "\n") .. "\n" .. suffix)
		rt.write(safe, "// details\nrun();\n")
		git("add", "-A")
		git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
		local reviewed = assert(review_delta.snapshot(rt, path))
		rt.write(source, prefix .. suffix)
		rt.write(safe, "run();\n")
		Test.eq({ review_delta.compare(rt, path, reviewed) }, accepted and { true, true } or { false })
	end)
end

source_change("Lua long string", "lua", "return [[\n", { "-- text" }, "]]\n", false)
source_change("Lua leveled long string", "lua", "return [==[\n", { "-- text" }, "]==]\n", false)
source_change("Lua outer block closer", "lua", "--[[ a\n", { "--[[ b ]]" }, "run()\n--]]\n", false)
source_change("Lua syntax error", "lua", "local = 1\n", { "-- explanation" }, "", false)
source_change(
	"Lua function comments",
	"lua",
	"return function()\n",
	{ "-- explanation", "--[[", "-- detail", "--]]" },
	"return 1\nend\n",
	true
)
source_change("TypeScript template", "ts", "const value = `\n", { "// text" }, "`;\n", false)
source_change(
	"TypeScript nested template",
	"mts",
	'const value = `${{ x: `nested ${"}"}\n',
	{ "// text" },
	"` }.x}`;\n",
	false
)
source_change(
	"TypeScript outer block closer",
	"ts",
	"/* a\n",
	{ "/* b */" },
	"run();\n/* c */\n",
	false
)
source_change(
	"TypeScript string continuation",
	"cts",
	'const value = "\\\n',
	{ '// text"' },
	";\n",
	false
)
source_change(
	"TypeScript unterminated template",
	"ts",
	"const value = `\n",
	{ "// text" },
	"",
	false
)
source_change(
	"TypeScript unterminated comment",
	"ts",
	"/* unterminated\n",
	{ "// text" },
	"",
	false
)
source_change("TypeScript JSDoc", "ts", "", { "/**", " * details", " */" }, "run();\n", true)
source_change(
	"TypeScript regular expressions",
	"ts",
	[[const first = /[/"'`]/; function second() { return /a\/\*b/g; }]] .. "\n",
	{ "// explanation" },
	"run();\n",
	true
)
source_change(
	"TypeScript division",
	"ts",
	"const number = a / b / c;\n",
	{ "// explanation" },
	"run();\n",
	true
)
source_change(
	"TypeScript template substitution",
	"ts",
	[[const value = `\${raw\` ${ {x: 1}.x /* } ` */ // } `
 }`;]] .. "\n",
	{ "// explanation" },
	"run();\n",
	true
)
source_change(
	"TypeScript complete block",
	"ts",
	"run();\n",
	{ "/* complete */" },
	"stop();\n",
	true
)
source_change(
	"TypeScript template after Unicode line separator",
	"ts",
	"// note\226\128\168const value = `\n",
	{ "// text" },
	"`;\n",
	false
)
source_change(
	"TypeScript template after an ambiguous regex",
	"ts",
	'if (ok) /[/*]/.test("a");\nconst value = `\n',
	{ "// text" },
	"`;\nrun(); /* note */\n",
	false
)
source_change(
	"TypeScript outer block closer after ambiguous division",
	"ts",
	"const value = {} / number /* a\n",
	{ "/* b */" },
	"+ other\n/* c */\n",
	false
)
source_change(
	"TypeScript escaped CRLF inside a string",
	"ts",
	"const café = 'first\\\r\nsecond';\n",
	{ "// explanation" },
	"run();\n",
	true
)
source_change(
	"TypeScript escaped newline inside an unterminated regex",
	"ts",
	"const value = /first\\\n",
	{ "// explanation" },
	"run();\n",
	false
)
source_change(
	"TypeScript slash desynchronization after an if condition",
	"ts",
	'const s = "a=b";\nif (s) /=/.test(s) && console.log(`/\n',
	{ "// x" },
	"`);\n// `\n",
	false
)
source_change(
	"TypeScript slash desynchronization after a for header",
	"ts",
	"for (;;) /a,/.exec(`/\n",
	{ "// x" },
	"`);\n// `\n",
	false
)
source_change(
	"TypeScript slash desynchronization after export default",
	"ts",
	"export default /=/.test(`/\n",
	{ "// x" },
	"`);\n// `\n",
	false
)
source_change(
	"TypeScript slash desynchronization after an object literal",
	"ts",
	"const v = {} / (a, /x.`/) + `\n",
	{ "// x" },
	"`;\n// `\n",
	false
)
source_change(
	"TypeScript division before a Unicode line separator",
	"ts",
	"(a + b) / 2; // half\226\128\168const t = `kept`;\n",
	{ "// explanation" },
	"run();\n",
	true
)
source_change(
	"TypeScript template after a hashbang",
	"ts",
	"#!node `\nconst t = `\n",
	{ "// x" },
	"`;\n// `\n",
	false
)
source_change(
	"TypeScript template after a BOM and hashbang",
	"ts",
	"\239\187\191#!node `\nconst t = `\n",
	{ "// x" },
	"`;\n// `\n",
	false
)
source_change(
	"TypeScript plain comment after a hashbang",
	"ts",
	"#!/usr/bin/env node\n",
	{ "// x" },
	"run();\n",
	true
)

local emit_tag = "const emit = (parts: TemplateStringsArray) => (console.log(parts[0]), 1);\n"
source_change(
	"TypeScript slash ambiguity carries across a regex class with slashes",
	"ts",
	emit_tag .. "if (true) /[//]/.source.length\n  / emit`/\n",
	{ "// x" },
	"`;\n// `\n",
	false
)
source_change(
	"TypeScript slash ambiguity carries across a regex at line end",
	"ts",
	emit_tag .. "if (true) /a/\n  / emit`/\n",
	{ "// x" },
	"`;\n// `\n",
	false
)
source_change(
	"TypeScript division after a line with an ambiguous slash",
	"ts",
	"if (x) /a/.test(y);\nconst z = a / b;\n",
	{ "// x" },
	"",
	true
)
source_change(
	"TypeScript assignment clears slash ambiguity from an earlier line",
	"ts",
	"if (x) /a/.test(y);\n" .. [[const z = /["'`]/;]] .. "\n",
	{ "// x" },
	"",
	true
)
