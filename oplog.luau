-- What Overseer did, when, and how it ended, so a creation that looked stuck
-- or a relay that never arrived can be traced afterwards.
--
-- ops.log (plugin data dir): one JSON object per line, newest last, capped at
-- MAX_BYTES by dropping its oldest half. Each entry also goes to Tern's log:
-- info for routine starts and finishes, warn for anything you'd want to look
-- at. **Show Overseer's operation log** shows the newest entries (`recent`).
local M = {}

local MAX_BYTES = 256 * 1024
-- Terminal reads are capped by Tern at 2000 lines and 64000 characters.
M.READ_LINES = 2000
local READ_CHARS = 64000

function M.path()
	return tern.plugin.data .. "/ops.log"
end

-- Appends `entry` (its `at` is set here) and mirrors it to Tern's log at
-- `level` ("info" or "warn").
function M.write(level, entry)
	entry.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local ok, line = pcall(tern.json.encode, entry)
	if not ok then return end
	local path = M.path()
	local existing = ""
	if tern.fs.exists(path) then
		-- A file over the cap (written by something else) is started over.
		local read, text = pcall(tern.fs.read, path, MAX_BYTES)
		existing = if read then text else ""
	end
	if #existing + #line + 1 > MAX_BYTES then
		local cut = string.find(existing, "\n", #existing // 2, true)
		existing = if cut then string.sub(existing, cut + 1) else ""
	end
	pcall(tern.fs.write, path, existing .. line .. "\n")
	local parts = { "Overseer:", entry.op, entry.event }
	for _, key in { "project", "branch", "path" } do
		if entry[key] then table.insert(parts, tostring(entry[key])) end
	end
	local message = table.concat(parts, " ")
	if entry.detail then message ..= " — " .. tostring(entry.detail) end
	if level == "warn" then tern.log.warn(message) else tern.log.info(message) end
end

-- The newest `limit` entries, newest first; lines that aren't JSON objects are skipped.
function M.recent(limit)
	local path = M.path()
	if not tern.fs.exists(path) then return {} end
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	if not ok or type(text) ~= "string" then return {} end
	local lines = string.split(text, "\n")
	local entries = {}
	for index = #lines, 1, -1 do
		if #entries >= limit then break end
		if lines[index] ~= "" then
			local parsed, entry = pcall(tern.json.decode, lines[index])
			if parsed and type(entry) == "table" then table.insert(entries, entry) end
		end
	end
	return entries
end

-- The lines a terminal pane shows (scrollback included when asked); nil when it can't be read.
function M.readPane(cx, pane, lines, scrollback)
	local ok, read = pcall(function()
		return cx.session:read(pane, { lines = lines, scrollback = scrollback, max_chars = READ_CHARS })
	end)
	if ok and type(read) == "table" and type(read.lines) == "table" then return read.lines end
	return nil
end

-- Lines of a run's output that look like trouble: Worktrunk's ▲ and ✗ marks,
-- and "warn:", "warning:" or "error:" labels. Worktrunk echoes each hook's
-- command indented under its "◎ Running" or "○" line; that echo is the
-- command's text, not its output, so it never counts. Neither does the ▲
-- header of a hook approval prompt: it asks, it doesn't report trouble.
function M.warnings(lines)
	local found = {}
	local echo = false
	for _, raw in lines do
		local line = string.gsub(raw, "%s+$", "")
		if string.find(line, "^◎ ") or string.find(line, "^○ ") then
			echo = true
		elseif echo and string.find(line, "^  %S") then
			-- Still the echoed command.
		else
			echo = false
			local lower = string.lower(line)
			local approval = string.find(line, "^%s*▲") ~= nil and string.find(line, "needs approval", 1, true) ~= nil
			if not approval and (string.find(line, "^%s*▲") or string.find(line, "^%s*✗")
				or string.find(lower, "%f[%w]warn%a*%s*:") or string.find(lower, "%f[%w]error%s*:")) then
				table.insert(found, (string.gsub(line, "^%s+", "")))
			end
		end
	end
	return found
end

-- What a creation is doing, from the last lines of its terminal: its newest
-- "◎ Running …" step (without the path), else the last line it printed.
-- `asking` is true when the last line asks a question (Worktrunk's approval
-- prompt ends in "[y/N]").
function M.progress(lines)
	local step, last = nil, nil
	for _, raw in lines do
		local line = string.gsub(string.gsub(raw, "%s+$", ""), "^%s+", "")
		if line ~= "" then
			last = line
			local running = string.match(line, "^◎%s+(.+)$")
			if running then step = (string.gsub(running, " @ .*$", "")) end
		end
	end
	local asking = last ~= nil and (string.find(last, "%[[yY]/[nN]") ~= nil
		or string.find(last, "%([yY]/[nN]%)") ~= nil or string.find(last, "needs approval") ~= nil)
	return step or last, asking
end

return M
