--- JavaScript and TypeScript adapter. Runs user source unchanged via a
--- helper launcher with runtime stack introspection for console locations
--- and native error parsing for uncaught exceptions.
local M = {}

local event = require("itchy.event")
local framed = require("itchy.adapters.framed")
local utils = require("itchy.utils")

M.name = "javascript"

--- Encode a path as a JSON string literal for embedding in generated JS.
--- JSON encoding handles quotes, backslashes, and control characters without
--- allowing filesystem data to terminate or alter the surrounding literal.
---@param path string
---@return string
local function js_escape(path)
	return vim.json.encode(path)
end

--- Normalize a stack path for comparison (slashes + file:// variants).
---@param path string
---@return string
local function norm_path(path)
	local p = path:gsub("\\", "/")
	p = p:gsub("^file:///", ""):gsub("^file://", "")
	p = p:gsub("^/([A-Za-z]:/)", "%1")
	return p
end

--- Whether a stack frame path refers to the user's source file.
---@param frame_path string?
---@param user_file string
---@return boolean
local function is_user_frame(frame_path, user_file)
	if type(frame_path) ~= "string" or type(user_file) ~= "string" then
		return false
	end
	return norm_path(frame_path) == norm_path(user_file)
end

-- ESM launcher shared by Node, Bun and Deno. `await import()` keeps the
-- user file in its native module context (CJS `require` still works when the
-- user file is CJS; TypeScript type-stripping applies on import), and a
-- rejected import is reported as a framed error WITHOUT killing pending
-- async work the module already scheduled (letting timers finish after
-- a late top-level throw).
local ESM_HELPER = [[
// itchy.nvim JS helper (managed file, do not edit).
import { format as __itchy_fmt } from "node:util";
import __itchy_path from "node:path";
import { pathToFileURL } from "node:url";
const __ITCHY_NONCE = __ITCHY_NONCE__;
const __ITCHY_USER_RAW = __ITCHY_USER_FILE__;
const __ITCHY_HELPER_RAW = __ITCHY_HELPER_FILE__;
const __itchy_USER_ABS = __itchy_path.resolve(__ITCHY_USER_RAW);
const __itchy_USER_URL = pathToFileURL(__itchy_USER_ABS).href;
const __itchy_HELPER_URL = pathToFileURL(__itchy_path.resolve(__ITCHY_HELPER_RAW)).href;
const __itchy_write = console.log.bind(console);
function __itchy_norm(p) {
	return String(p).replace(/\\/g, "/");
}
function __itchy_framePath(stackLine) {
	let m = /\((.*):(\d+):(\d+)\)\s*$/.exec(stackLine);
	if (!m) m = /at\s+(.*):(\d+):(\d+)\s*$/.exec(stackLine);
	if (!m) return null;
	return { path: m[1], line: parseInt(m[2], 10), col: parseInt(m[3], 10) };
}
function __itchy_isHelper(path) {
	return __itchy_norm(path) === __itchy_norm(__itchy_HELPER_URL);
}
function __itchy_isUser(path) {
	const fp = __itchy_norm(path);
	if (fp === __itchy_norm(__itchy_HELPER_URL)) return false;
	let up = __itchy_norm(__itchy_USER_URL);
	up = up.replace(/^file:\/\/\//, "").replace(/^file:\/\//, "").replace(/^\/([A-Za-z]:\/)/, "$1");
	let cp = fp.replace(/^file:\/\/\//, "").replace(/^file:\/\//, "").replace(/^\/([A-Za-z]:\/)/, "$1");
	return cp === up;
}
function __itchy_firstUserFrame(stack) {
	const lines = String(stack || "").split("\n");
	for (let i = 0; i < lines.length; i++) {
		const f = __itchy_framePath(lines[i]);
		if (!f) continue;
		if (__itchy_isHelper(f.path)) continue;
		if (__itchy_isUser(f.path)) return { line: f.line, col: f.col };
	}
	return null;
}
function __itchy_bareUserLoc(stack) {
	// Node reports syntax failures as a bare "path:line" preamble with a
	// source excerpt and caret BEFORE any stack frames, and none of the
	// `at ...` frames reference the user file. Scan those preamble lines.
	const lines = String(stack || "").split("\n");
	for (let i = 0; i < lines.length; i++) {
		const t = lines[i].trim();
		if (!t || t[0] === "^") continue;
		const m = /^(.*):(\d+)(?::(\d+))?\s*$/.exec(t);
		if (!m) continue;
		if (__itchy_matchUser(m[1])) {
			return { line: parseInt(m[2], 10), col: m[3] ? parseInt(m[3], 10) : null };
		}
	}
	return null;
}
function __itchy_userBase() {
	const u = __itchy_norm(__itchy_USER_URL).replace(/^file:\/\/\//, "").replace(/^file:\/\//, "").replace(/^\/([A-Za-z]:\/)/, "$1");
	const parts = u.split("/");
	return parts[parts.length - 1];
}
function __itchy_matchUser(framePath) {
	if (__itchy_isUser(framePath)) return true;
	// Basename fallback: some runtimes render frames as relative paths or
	// otherwise decorated locations; the temp user basename is unique per
	// run and never equals the helper basename.
	const base = __itchy_norm(framePath).split("/").pop();
	const userBase = __itchy_userBase();
	const helperBase = __itchy_norm(__itchy_HELPER_URL).split("/").pop();
	if (base && userBase && base === userBase && base !== helperBase) return true;
	return false;
}
function __itchy_callerStructured() {
	try {
		if (typeof Error.captureStackTrace !== "function") return null;
		const prevPrepare = Error.prepareStackTrace;
		let frames = null;
		try {
			Error.prepareStackTrace = function (_, structured) {
				return structured;
			};
			const probe = {};
			Error.captureStackTrace(probe, __itchy_callerStructured);
			frames = probe.stack;
		} finally {
			Error.prepareStackTrace = prevPrepare;
		}
		if (!Array.isArray(frames)) return null;
		for (const f of frames) {
			let fname = null;
			try {
				fname = f.getFileName();
			} catch (e) {
				continue;
			}
			if (!fname) continue;
			if (__itchy_isHelper(fname)) continue;
			if (__itchy_matchUser(fname)) {
				let fline = null;
				let fcol = null;
				try {
					fline = f.getLineNumber();
				} catch (e) {}
				try {
					fcol = f.getColumnNumber();
				} catch (e) {}
				if (typeof fline === "number" && fline >= 1) {
					return { line: fline, col: typeof fcol === "number" && fcol >= 1 ? fcol : null };
				}
			}
		}
	} catch (e) {
		return null;
	}
	return null;
}
function __itchy_callerFallback() {
	const lines = (new Error().stack || "").split("\n");
	for (let i = 1; i < lines.length; i++) {
		const f = __itchy_framePath(lines[i]);
		if (!f) continue;
		if (__itchy_isHelper(f.path)) continue;
		if (__itchy_matchUser(f.path)) return { line: f.line, col: f.col };
	}
	return null;
}
function __itchy_caller() {
	return __itchy_callerStructured() || __itchy_callerFallback();
}
function __itchy_emit(kind, args) {
	const c = __itchy_caller();
	const evt = { kind: kind, message: __itchy_fmt(...args) };
	if (c) {
		// Omit null coordinates rather than emitting JSON null: a null
		// column decodes to vim.NIL and would fail record validation,
		// silently dropping the entire event.
		if (c.line != null) evt.line = c.line;
		if (c.col != null) evt.column = c.col;
	}
	__itchy_write("\x1eITCHY:" + __ITCHY_NONCE + ":" + JSON.stringify(evt));
}
console.log = (...args) => __itchy_emit("stdout", args);
console.info = (...args) => __itchy_emit("stdout", args);
console.debug = (...args) => __itchy_emit("stdout", args);
console.warn = (...args) => __itchy_emit("warning", args);
console.error = (...args) => __itchy_emit("error", args);
try {
	await import(__itchy_USER_URL);
} catch (__itchy_loadErr) {
	// Uncaught load failures (runtime throw or syntax error) keep their
	// native diagnostics: select the user frame when present, else the
	// bare path:line preamble Node emits for syntax failures.
	const __itchy_stack = __itchy_loadErr && __itchy_loadErr.stack;
	const c = __itchy_firstUserFrame(__itchy_stack) || __itchy_bareUserLoc(__itchy_stack);
	const msg = (__itchy_loadErr && __itchy_loadErr.message) || String(__itchy_loadErr);
	const evt = { kind: "error", message: "Error: " + msg };
	if (c) {
		if (c.line != null) evt.line = c.line;
		if (c.col != null) evt.column = c.col;
	}
	__itchy_write("\x1eITCHY:" + __ITCHY_NONCE + ":" + JSON.stringify(evt));
	try {
		process.exitCode = 1;
	} catch (e) {}
	try {
		Deno.exitCode = 1;
	} catch (e) {}
}
]]

--- Render the helper with all interpolated strings encoded as JS literals.
---@param nonce string
---@param user_path string
---@param helper_path string
---@return string
local function render_helper(nonce, user_path, helper_path)
	local helper_src = ESM_HELPER
	helper_src = helper_src:gsub("__ITCHY_NONCE__", function()
		return js_escape(nonce)
	end)
	helper_src = helper_src:gsub("__ITCHY_USER_FILE__", function()
		return js_escape(user_path)
	end)
	helper_src = helper_src:gsub("__ITCHY_HELPER_FILE__", function()
		return js_escape(helper_path)
	end)
	return helper_src
end

M._js_escape = js_escape
M._render_helper = render_helper

--- Prepare execution: unchanged user source + separate helper launcher.
---@param ctx itchy.AdapterContext
---@return itchy.PreparedExecution
function M.prepare(ctx)
	assert(ctx ~= nil, "javascript adapter requires a context")
	assert(ctx.runtime ~= nil, "javascript adapter requires ctx.runtime")
	local runtime = ctx.runtime
	local source = ctx.source or ""
	local nonce = framed.create_nonce()

	local user_path, uerr = utils.create_temp_code_file(ctx.filetype, source, utils.project_dir(ctx))
	if not user_path then
		error("javascript adapter: failed to create source file: " .. tostring(uerr))
	end

	local is_deno = runtime.cmd == "deno"
	-- Reserve the helper path first so it can be embedded for frame
	-- filtering. All paths are encoded by render_helper as JSON literals.
	local helper_path = vim.fn.tempname() .. ".mjs"
	local helper_src = render_helper(nonce, user_path, helper_path)
	local helper_file, herr = io.open(helper_path, "w")
	if not helper_file then
		utils.remove_temp_file(user_path)
		error("javascript adapter: failed to create helper file: " .. tostring(herr))
	end
	helper_file:write(helper_src)
	helper_file:close()

	-- Keep runtime flags except inline-eval selectors; file execution
	-- replaces `-e`/`eval`/`-c`. The temp user file already carries the
	-- right extension, so deno's `--ext=` (a `run`-subcommand flag that is
	-- invalid before `run`) is dropped as well.
	local cmd = { runtime.cmd }
	for _, arg in ipairs(runtime.args or {}) do
		if arg ~= "-e" and arg ~= "eval" and arg ~= "-c" and arg:sub(1, 6) ~= "--ext=" then
			table.insert(cmd, arg)
		end
	end
	if is_deno then
		-- File execution (not inline eval) needs read access for the temp
		-- user source; dynamic import of a file:// URL counts as a read.
		table.insert(cmd, "run")
		table.insert(cmd, "--allow-read")
	end
	table.insert(cmd, helper_path)

	local function cleanup()
		utils.remove_temp_file(user_path)
		utils.remove_temp_file(helper_path)
	end

	return {
		source = source,
		cmd = cmd,
		temp_file = false,
		cleanup = cleanup,
		metadata = { nonce = nonce, user_file = user_path, flavor = "esm", filetype = ctx.filetype },
	}
end

--- Extract the first user-file frame (line/column) from native stderr.
---@param stderr_text string
---@param user_file string
---@return integer?, integer?
local function find_user_frame(stderr_text, user_file)
	local found_line, found_col = nil, nil
	framed.each_line(stderr_text, function(line)
		if found_line then
			return
		end
		local path, lnum, col = line:match("%((.-):(%d+):(%d+)%)%s*$")
		if not path then
			path, lnum, col = line:match("at%s+(.-):(%d+):(%d+)%s*$")
		end
		if path and is_user_frame(path, user_file) then
			found_line = tonumber(lnum)
			found_col = tonumber(col)
		end
	end)
	if not found_line then
		-- Syntax-failure preamble: Node reports a bare "path:line"
		-- location with excerpt/caret before any `at` frames. Only an
		-- exact user-file match counts, so excerpts can never hit.
		framed.each_line(stderr_text, function(line)
			if found_line then
				return
			end
			local path, lnum, col = line:match("^(.-):(%d+):?(%d*)%s*$")
			if path and lnum and is_user_frame(path, user_file) then
				found_line = tonumber(lnum)
				found_col = col ~= "" and tonumber(col) or nil
			end
		end)
	end
	return found_line, found_col
end

--- Extract an error message from native stderr (first "Error:" tail).
---@param stderr_text string
---@return string?
local function extract_message(stderr_text)
	local message = nil
	framed.each_line(stderr_text, function(line)
		if message then
			return
		end
		local tail = line:match("Error:%s*(.+)%s*$")
		if tail and tail ~= "" then
			message = tail
		end
	end)
	if message then
		return message
	end
	-- Fallback: last non-empty line.
	framed.each_line(stderr_text, function(line)
		message = line
	end)
	return message
end

--- Match a native Node warning header without treating arbitrary stderr text as
--- a warning. The bracketed form is used by warnings such as
--- MODULE_TYPELESS_PACKAGE_JSON; the second form covers Node's named warning
--- classes such as ExperimentalWarning.
---@param line string
---@return string?, string? warning code, first message line
local function parse_node_warning_header(line)
	local code, message = line:match("^%(node:%d+%)%s+%[([%w_%-]+)%]%s+Warning:%s*(.*)$")
	if code then
		return code, message
	end
	return line:match("^%(node:%d+%)%s+([%a][%w_%-]*Warning):%s*(.*)$")
end

--- Whether a line starts a real runtime/compiler diagnostic. This is kept
--- deliberately narrow so a warning body cannot be mistaken for an error,
--- while native Error/SyntaxError and common lower-case runtime diagnostics
--- still terminate the warning envelope.
---@param line string
---@return boolean
local function starts_diagnostic(line)
	return line:match("^%s*[A-Za-z][A-Za-z0-9_]*Error%s*[:%[]") ~= nil
		or line:match("^%s*error%s*:") ~= nil
		or line:match("^%s*error%s+[A-Za-z][A-Za-z0-9_%-]*%s*:") ~= nil
		or line:match("^%s*[A-Za-z][A-Za-z0-9_%-]*%s+[Ee]rror%s*:") ~= nil
		or line:match("^%s*[A-Z][A-Z0-9_]+%d+%s*:") ~= nil
		or line:match("^%s*fatal%s*:") ~= nil
		or line:match("^%s*runtime%s+error%s*:") ~= nil
		or line:match("^%s*[Uu]ncaught%s+") ~= nil
		or line:match("^%s*[^%s]+:%d+") ~= nil
end

---@param line string
---@return boolean
local function is_warning_trace(line)
	return line:match("^%(Use `node %-%-trace%-warnings") ~= nil
end

--- Find native Node warning envelopes and return their messages together with
--- the stderr line ranges they occupy. The range tracking matters when a
--- warning and a real error share stderr: the warning must not become the
--- error fallback message, and neither diagnostic may be discarded.
---@param stderr_text string
---@return table[] warnings
---@return table[] lines remaining lines with their original indexes
local function parse_node_warnings(stderr_text)
	local lines = {}
	framed.each_line(stderr_text, function(line)
		table.insert(lines, line)
	end)

	local warnings = {}
	local consumed = {}
	local index = 1
	while index <= #lines do
		local code, first_line = parse_node_warning_header(lines[index])
		if not code then
			index = index + 1
		else
			local parts = {}
			if first_line ~= "" then
				table.insert(parts, first_line)
			end
			local finish = index
			local next_index = index + 1
			while next_index <= #lines do
				if parse_node_warning_header(lines[next_index]) or starts_diagnostic(lines[next_index]) then
					break
				end
				table.insert(parts, lines[next_index])
				finish = next_index
				if is_warning_trace(lines[next_index]) then
					next_index = next_index + 1
					break
				end
				next_index = next_index + 1
			end
			for consumed_index = index, finish do
				consumed[consumed_index] = true
			end
			if #parts > 0 then
				table.insert(warnings, {
					index = index,
					message = framed.sanitize_message(table.concat(parts, "\n")),
				})
			end
			index = next_index
		end
	end

	local remaining = {}
	for line_index, line in ipairs(lines) do
		if not consumed[line_index] then
			table.insert(remaining, { index = line_index, line = line })
		end
	end
	return warnings, remaining
end

--- Decode an executor result into normalized events.
---@param ctx itchy.AdapterContext
---@param prepared itchy.PreparedExecution
---@param result itchy.ExecutionResult
---@return itchy.Event[]
function M.decode(ctx, prepared, result)
	local metadata = (prepared and prepared.metadata) or {}
	local nonce = metadata.nonce
	local user_file = metadata.user_file
	---@type itchy.Event[]
	local events = {}

	framed.each_line(result.stdout, function(line)
		local record = framed.decode_line(line, nonce)
		if record then
			table.insert(events, event.create(record.kind, record.message, record.line, record.column))
			return
		end
		if line ~= "" then
			-- Ordinary (non-instrumented) stdout stays visible as locationless.
			table.insert(events, event.create("stdout", framed.sanitize_message(line), nil))
		end
	end)

	local stderr_text = type(result.stderr) == "string" and result.stderr or ""
	local warnings, remaining_stderr = parse_node_warnings(stderr_text)
	local remaining_lines = {}
	for _, remaining in ipairs(remaining_stderr) do
		table.insert(remaining_lines, remaining.line)
	end
	local remaining_text = table.concat(remaining_lines, "\n")
	local error_message = extract_message(remaining_text)
	local has_error = #remaining_stderr > 0 and error_message ~= nil and error_message ~= ""
	local error_line, error_column = nil, nil
	if has_error then
		-- Locations are searched in the complete native stderr so syntax
		-- preambles and stack frames retain their existing handling.
		error_line, error_column = find_user_frame(stderr_text, user_file or "")
	end

	-- Keep diagnostics in their stderr order. In particular, a warning must
	-- not replace a later Error: line, and an error appearing before a warning
	-- must not be reordered as a side effect of classification.
	local diagnostics = {}
	for _, warning in ipairs(warnings) do
		table.insert(diagnostics, {
			index = warning.index,
			kind = "warning",
			message = warning.message,
		})
	end
	if has_error then
		-- The first remaining line is the start of the native diagnostic after
		-- warning spans have been removed, and retains its original stderr
		-- position for stable ordering with warning events.
		local error_index = remaining_stderr[1].index
		table.insert(diagnostics, {
			index = error_index,
			kind = "error",
			message = framed.sanitize_message(error_message),
			line = error_line,
			column = error_column,
		})
	end
	table.sort(diagnostics, function(left, right)
		return left.index < right.index
	end)
	for _, diagnostic in ipairs(diagnostics) do
		table.insert(events, event.create(diagnostic.kind, diagnostic.message, diagnostic.line, diagnostic.column))
	end

	return events
end

return M
