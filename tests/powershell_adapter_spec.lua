local ps = require 'itchy.adapters.powershell'
local adapters = require 'itchy.adapters'
local assert = require 'luassert'

local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local function ctx_for(source, cmd)
	return {
		runtime = {
			cmd = cmd or 'pwsh',
			args = { '-NoLogo', '-NoProfile', '-NonInteractive', '-Command' },
			offset = 0,
		},
		filetype = 'ps1',
		source = source,
		buf = 1,
		cwd = '.',
	}
end

local function with_cleanup(prepared, extra, fn)
	local ok, err = pcall(fn)
	pcall(function()
		prepared.cleanup()
	end)
	if extra then
		pcall(extra)
	end
	if not ok then
		error(err, 0)
	end
end

local function run_cmd(prepared)
	return vim.system(prepared.cmd, { text = true, timeout = 60000 }):wait()
end

describe('itchy.adapters.powershell', function()
	it('resolves by name through the registry', function()
		eq(adapters.resolve({ adapter = 'powershell' }).name, 'powershell')
	end)

  it('prepare() keeps user lines stable with an appended trap', function()
    local source = 'Write-Output "one"\nfunction Foo {\n  Write-Host "inside"\n}\nFoo\n'
    local prepared = ps.prepare(ctx_for(source))
    with_cleanup(prepared, nil, function()
      local f = io.open(prepared.metadata.user_file, 'r')
      assert(f ~= nil)
      local content = f:read '*a'
      f:close()
      -- Same-scope resilience trap is appended AFTER the code: the user
      -- prefix is byte-identical, so native lines never shift.
      eq(content:sub(1, #source), source)
      truthy(content:find('trap {', 1, true) ~= nil)
			-- File execution replaces inline -Command.
			eq(prepared.cmd[1], 'pwsh')
			eq(prepared.cmd[#prepared.cmd - 1], '-File')
			eq(prepared.temp_file, false)
			truthy(type(prepared.cleanup) == 'function')
		end)
	end)

	it('decodes framed output/warning/error with native locations', function()
		local ctx = ctx_for('')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local nonce = prepared.metadata.nonce
			local function frame(kind, line, msg)
				return '\30ITCHY:' .. nonce .. ':{"kind":"' .. kind .. '","line":' .. line .. ',"message":"' .. msg .. '"}'
			end
			local result = {
				code = 0,
				signal = 0,
				stdout = frame('stdout', 1, 'hello')
					.. '\n'
					.. frame('stdout', 2, 'host-hi')
					.. '\n'
					.. frame('warning', 3, 'warn-hi')
					.. '\n'
					.. frame('error', 4, 'err-hi')
					.. '\n',
				stderr = '',
			}
			local events = ps.decode(ctx, prepared, result)
			eq(#events, 4)
			eq(events[1].kind, 'stdout')
			eq(events[1].line, 1)
			eq(events[2].message, 'host-hi')
			eq(events[3].kind, 'warning')
			eq(events[3].line, 3)
			eq(events[4].kind, 'error')
			eq(events[4].line, 4)
		end)
	end)

	it('parses native throw locations from stderr', function()
		local ctx = ctx_for('')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local user_file = prepared.metadata.user_file
			local result = {
				code = 1,
				signal = 0,
				stdout = '',
				stderr = 'Exception: ' .. user_file .. ':2\nLine |\n   2 |  throw "boom-exploded"\n     |  ~~~~~~~~~~~~~~~~~~~~~\n     |  boom-exploded\n',
			}
			local events = ps.decode(ctx, prepared, result)
			eq(#events, 1)
			eq(events[1].kind, 'error')
			eq(events[1].line, 2)
			truthy(events[1].message:find('boom-exploded', 1, true) ~= nil)
		end)
	end)

	it('parses native command-not-found locations from stderr', function()
		local ctx = ctx_for('')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local user_file = prepared.metadata.user_file
			local result = {
				code = 0,
				signal = 0,
				stdout = '',
				stderr = 'Invoke-NoSuchCommandXYZ: ' .. user_file .. ':2\nLine |\n   2 |  Invoke-NoSuchCommandXYZ\n     |  ~~~~~~~~~~~~~~~~~~~~~~~\n     |  The term is not recognized\n',
			}
			local events = ps.decode(ctx, prepared, result)
			eq(#events, 1)
			eq(events[1].line, 2)
			truthy(events[1].message:find('not recognized', 1, true) ~= nil)
		end)
	end)

	it('does not manufacture LINE<n> errors', function()
		local ctx = ctx_for('')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local result = { code = 1, signal = 0, stdout = '', stderr = 'something broke\n' }
			local events = ps.decode(ctx, prepared, result)
			for _, e in ipairs(events) do
				falsy(e.message:match('^LINE%d+') ~= nil)
			end
		end)
	end)

	it('executes all four output commands end to end with exact lines', function()
		if vim.fn.executable('pwsh') ~= 1 then
			return
		end
		local src = table.concat({
			'Write-Output "hello"',
			'Write-Host "host-hi"',
			'Write-Warning "warn-hi"',
			'Write-Error "err-hi"',
			'',
		}, '\n')
		local ctx = ctx_for(src)
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local by_line = {}
			for _, e in ipairs(events) do
				by_line[e.line or 0] = by_line[e.line or 0] or {}
				table.insert(by_line[e.line or 0], e)
			end
			eq(by_line[1][1].kind, 'stdout')
			eq(by_line[1][1].message, 'hello')
			eq(by_line[2][1].message, 'host-hi')
			eq(by_line[3][1].kind, 'warning')
			eq(by_line[3][1].message, 'warn-hi')
			eq(by_line[4][1].kind, 'error')
			eq(by_line[4][1].message, 'err-hi')
		end)
	end)

	it('resolves output inside functions to the call line', function()
		if vim.fn.executable('pwsh') ~= 1 then
			return
		end
		local src = table.concat({
			'function Greet {',
			'  Write-Output "inside"',
			'}',
			'Write-Output "first"',
			'Greet',
			'Write-Output "last"',
			'',
		}, '\n')
		local ctx = ctx_for(src)
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local messages = {}
			for _, e in ipairs(events) do
				messages[e.line or 0] = e.message
			end
			eq(messages[4], 'first')
			-- Call inside Foo reports line 2 (the Write-Output), not the helper.
			eq(messages[2], 'inside')
			eq(messages[6], 'last')
		end)
	end)

	it('ignores output command names in comments and strings', function()
		if vim.fn.executable('pwsh') ~= 1 then
			return
		end
    local src = table.concat({
      '# Write-Output "comment"',
      "$s = 'Write-Host \"str\"'",
      'Write-Output "real"',
      '',
    }, '\n')
		local ctx = ctx_for(src)
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local located = {}
			for _, e in ipairs(events) do
				if e.line ~= nil then
					table.insert(located, e)
				end
			end
			eq(#located, 1)
			eq(located[1].line, 3)
			eq(located[1].message, 'real')
		end)
	end)

  it('reports thrown exceptions end to end', function()
    if vim.fn.executable('pwsh') ~= 1 then
      return
    end
    local src = table.concat({
      'Write-Output "before"',
      'throw "boom-exploded"',
      'Write-Output "after"',
      '',
    }, '\n')
    local ctx = ctx_for(src)
    local prepared = ps.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = run_cmd(prepared)
      local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      -- The launcher trap reports terminating errors with native locations
      -- and continues, so output after the throw still runs.
      local messages = {}
      for _, e in ipairs(events) do
        messages[e.line or 0] = messages[e.line or 0] or {}
        table.insert(messages[e.line or 0], e)
      end
      eq(messages[1][1].kind, 'stdout')
      eq(messages[1][1].message, 'before')
      eq(messages[2][1].kind, 'error')
      truthy(messages[2][1].message:find('boom-exploded', 1, true) ~= nil)
      eq(messages[3][1].message, 'after')
    end)
  end)

	it('reports parse errors end to end', function()
		if vim.fn.executable('pwsh') ~= 1 then
			return
		end
		local src = table.concat({
			'Write-Output "hi"',
			'if ($true {',
			'  Write-Output "bad"',
			'}',
			'',
		}, '\n')
		local ctx = ctx_for(src)
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local found = nil
			for _, e in ipairs(events) do
				if e.kind == 'error' then
					found = e
				end
			end
			assert(found ~= nil)
			eq(found.line, 2)
		end)
	end)

  it('handles multiline pipelines end to end', function()
    if vim.fn.executable('pwsh') ~= 1 then
      return
    end
    local src = table.concat({
      '"hello" |',
      '  Write-Output',
      '',
    }, '\n')
    local ctx = ctx_for(src)
    local prepared = ps.prepare(ctx)
    with_cleanup(prepared, nil, function()
      local out = run_cmd(prepared)
      local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
      local found = nil
      for _, e in ipairs(events) do
        if e.kind == 'stdout' then
          found = e
        end
      end
      assert(found ~= nil)
      -- Native call metadata attributes a multiline pipeline to the start of
      -- the statement (line 1), consistent with how native errors locate the
      -- same construct. The message still carries the piped value.
      eq(found.line, 1)
      eq(found.message, 'hello')
    end)
  end)

	it('renders padded selection sources on original buffer lines', function()
		if vim.fn.executable('pwsh') ~= 1 then
			return
		end
		-- Visual selection starting at buffer line 3: pad omitted lines.
		local ctx = ctx_for('\n\nWrite-Output "sel"\n')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local found = nil
			for _, e in ipairs(events) do
				if e.kind == 'stdout' then
					found = e
				end
			end
			assert(found ~= nil)
			eq(found.line, 3)
			eq(found.message, 'sel')
		end)
	end)

	it('runs under Windows PowerShell where available', function()
		if vim.fn.executable('powershell') ~= 1 then
			return
		end
		local ctx = ctx_for('Write-Output "winps"\n', 'powershell')
		local prepared = ps.prepare(ctx)
		with_cleanup(prepared, nil, function()
			eq(prepared.cmd[1], 'powershell')
			local out = run_cmd(prepared)
			local events = ps.decode(ctx, prepared, { code = out.code, signal = 0, stdout = out.stdout, stderr = out.stderr })
			local found = nil
			for _, e in ipairs(events) do
				if e.kind == 'stdout' then
					found = e
				end
			end
			assert(found ~= nil)
			eq(found.line, 1)
			eq(found.message, 'winps')
		end)
	end)
end)
