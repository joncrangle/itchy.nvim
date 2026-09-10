--- Runtime adapter registry.
--- Runtime selection determines the adapter; core execution code must not
--- branch on filetype. Adapters are referenced by name to avoid circular
--- dependencies between runtimes.lua and the adapter modules.
local M = {}

---@class itchy.AdapterContext
---@field runtime itchy.Runtime
---@field filetype string
---@field source string
---@field buf integer
---@field cwd string

---@class itchy.PreparedExecution
---@field source string prepared source handed to the executor
---@field cmd? string[] full argv override; when nil the core builds argv from runtime.cmd/args
---@field env? table<string, string> env override; when nil the core falls back to runtime.env
---@field temp_file? boolean temp-file override; when nil the core falls back to runtime.temp_file
---@field cleanup? fun() optional post-render cleanup hook invoked by the core
---@field metadata? table<string, any> adapter-specific data

---@class itchy.RuntimeAdapter
---@field name string
---@field prepare fun(ctx: itchy.AdapterContext): itchy.PreparedExecution
---@field decode fun(ctx: itchy.AdapterContext, prepared: itchy.PreparedExecution, result: itchy.ExecutionResult): itchy.Event[]

--- Resolve the adapter module for a runtime definition.
--- Missing or unknown adapters fail explicitly.
---@param runtime? itchy.Runtime|{ adapter?: string|itchy.RuntimeAdapter, cmd?: string }
---@return itchy.RuntimeAdapter
function M.resolve(runtime)
	if type(runtime) ~= "table" then
		error("itchy: runtime must be a table")
	end
	local adapter = runtime.adapter
	if adapter == nil then
		error(string.format("itchy: runtime '%s' has no adapter configured", tostring(runtime.cmd or "unknown")))
	end
	if type(adapter) == "table" then
		if type(adapter.prepare) == "function" and type(adapter.decode) == "function" then
			return adapter
		end
		error("itchy: custom adapter table must implement prepare and decode functions")
	end
	if type(adapter) == "string" then
		local ok, mod = pcall(require, "itchy.adapters." .. adapter)
		if ok and mod and type(mod.prepare) == "function" and type(mod.decode) == "function" then
			return mod
		end
		error(string.format("itchy: unknown or invalid adapter '%s'", adapter))
	end
	error(string.format("itchy: invalid adapter type '%s'", type(adapter)))
end

return M

