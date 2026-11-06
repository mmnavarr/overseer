-- Delivers Overseer's messages to omp sessions through pi-intercom's command
-- line client, under the sender name "overseer". An omp session's intercom
-- address is its omp session id; which session a Tern pane runs comes from
-- `tern inspect` (each agent block's omp_session_file).
local budget = require("./budget")
local wt = require("./worktrunk")
local M = {}

local TIMEOUT_MS = 20000

-- pi-intercom's client, as installed for omp (or pi); nil when neither is.
local function client()
	local home = wt.home() or ""
	for _, candidate in {
		home .. "/.omp/plugins/node_modules/pi-intercom/cli.ts",
		home .. "/.pi/agent/npm/node_modules/pi-intercom/cli.ts",
	} do
		if tern.fs.exists(candidate) then return candidate end
	end
	return nil
end

-- The omp session id in `tern inspect --json` output for `pane`, or nil.
local function sessionIdOf(inspected, pane)
	local stack = { inspected }
	while #stack > 0 do
		local node = table.remove(stack)
		if type(node) == "table" then
			if node.pane == pane and type(node.omp_session_file) == "string" then
				return string.match(node.omp_session_file, "_([%x%-]+)%.jsonl$")
			end
			for _, child in node do
				if type(child) == "table" then table.insert(stack, child) end
			end
		end
	end
	return nil
end

local function fail(done, label, reason)
	budget.later(label, 0, function(cx) done(nil, reason, cx) end)
end

-- Sends `text` to the omp session in `pane` of the window `windowKey`.
-- done(true, nil, cx) once delivered, else done(nil, reason, cx); always in a
-- callback of its own.
function M.send(windowKey, pane, text, done)
	local cli, bun = client(), wt.find_executable("bun")
	if not cli or not bun then
		fail(done, "intercom unavailable", if cli then "bun was not found on Tern's PATH" else "pi-intercom is not installed for omp")
		return
	end
	local inspect = { wt.tern_executable(), "inspect", "--json", "--window", windowKey }
	local ok, err = pcall(budget.process, "intercom resolve", inspect, { timeout_ms = 5000 }, function(found)
		local parsed, inspected = pcall(tern.json.decode, found.stdout or "")
		local id = found.status == 0 and parsed and sessionIdOf(inspected, pane)
		if not id then
			fail(done, "intercom resolve", "the pane runs no omp session Tern knows of")
			return
		end
		local argv = { bun, cli, "send", "--name", "overseer", "--to", id, "--text", text, "--json" }
		-- The receiver sees the sender's directory; from the plugin dir, agents
		-- mistook it for a repository to inspect.
		local options = { timeout_ms = TIMEOUT_MS, cwd = wt.home() }
		local started, startErr = pcall(budget.process, "intercom send", argv, options, function(result, cx)
			local decoded, value = pcall(tern.json.decode, result.stdout or "")
			if result.status == 0 and decoded and type(value) == "table" and value.delivered == true then
				done(true, nil, cx)
			else
				local reason = decoded and type(value) == "table" and (value.reason or value.error) or result.stderr
				done(nil, tostring(reason or "delivery failed"), cx)
			end
		end)
		if not started then fail(done, "intercom start", tostring(startErr)) end
	end)
	if not ok then fail(done, "intercom resolve", tostring(err)) end
end

return M
