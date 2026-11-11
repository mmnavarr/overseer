--!nonstrict
-- Whether a newer Overseer is out, and the command that updates this copy to
-- it. The newest version is the one `tern plugin install` would fetch:
-- plugin.toml on the repository's default branch. The window's tick checks
-- every hour and ↻ sooner; the answer is kept in kv `update-check`
-- ({at, latest}) so a reload, or another window, doesn't fetch it again.
local budget = require("./budget")

local M = {}

M.SOURCE = "github.com/mmnavarr/overseer"
local MANIFEST_URL = "https://raw.githubusercontent.com/mmnavarr/overseer/main/plugin.toml"
local CHECK_EVERY_S = 60 * 60
-- After a failed check (offline, say), and the least gap ↻ leaves between checks.
local RETRY_S = 5 * 60

local function versionOf(manifest)
	return if type(manifest) == "string" then string.match(manifest, '\nversion%s*=%s*"([^"]+)"') else nil
end

local function stored()
	local value = tern.kv.get("update-check")
	return if type(value) == "table" then value else {}
end

local readManifest, manifest = pcall(tern.fs.read, tern.plugin.dir .. "/plugin.toml", 16384)
-- This copy's version.
M.installed = if readManifest then versionOf(manifest) else nil

-- How this copy updates: "install" for a copy `tern plugin install` made
-- (installing again with --force replaces it), "pull" for a linked Git
-- checkout, nil for anything else (a linked folder outside Git).
local function howToUpdate()
	local dir = tern.plugin.dir
	local isGit, exists = pcall(tern.fs.exists, dir .. "/.git")
	if isGit and exists then return "pull" end
	local installedDir = "/plugins/" .. tern.plugin.id
	if string.sub(dir, -#installedDir) == installedDir then return "install" end
	return nil
end
M.how = howToUpdate()

-- A version's numbers, or nil when it isn't plain dotted numbers.
local function numbers(version)
	local result = {}
	for part in string.gmatch(version, "[^.]+") do
		local n = tonumber(part)
		if not n then return nil end
		table.insert(result, n)
	end
	return if #result > 0 then result else nil
end

-- Whether version a is newer than b ("2.4.10" is newer than "2.4.9").
function M.newer(a, b)
	local x, y = numbers(a or ""), numbers(b or "")
	if not x or not y then return false end
	for i = 1, math.max(#x, #y) do
		local p, q = x[i] or 0, y[i] or 0
		if p ~= q then return p > q end
	end
	return false
end

-- The newer version this copy can update to, or nil.
function M.available()
	if not M.how or not M.installed then return nil end
	local latest = stored().latest
	return if type(latest) == "string" and M.newer(latest, M.installed) then latest else nil
end

-- The shell command that updates this copy, and the directory it runs in.
function M.command()
	if M.how == "install" then
		return '"${TERN_EXE:-tern}" plugin install ' .. M.SOURCE .. " --force", nil
	elseif M.how == "pull" then
		return "git pull --ff-only", tern.plugin.dir
	end
	return nil, nil
end

-- An update's terminal closes when it succeeds, and Tern reloads the plugin.
-- `started` remembers the version it left (kv `update-started`), so the
-- reloaded copy can say it worked; a failed one keeps its tab open instead.
function M.started()
	tern.kv.set("update-started", { from = M.installed })
end

local leftBehind = (function()
	local value = tern.kv.get("update-started")
	return if type(value) == "table" then value.from else nil
end)()

-- This copy's version, once, when it was loaded by an update Overseer started;
-- else nil.
function M.finished()
	if leftBehind == nil then return nil end
	local from = leftBehind
	leftBehind = nil
	if from == M.installed then return nil end
	tern.kv.set("update-started", nil)
	return M.installed
end

local checking = false
local failed = false
local lastTry = (function()
	local at = stored().at
	return if type(at) == "number" then at else 0
end)()

-- Fetches the newest version when a check is due (sooner `byHand`), and calls
-- changed(cx) when it differs from the one known before. Cheap when not due,
-- so the tick calls it every time.
function M.check(changed, byHand)
	if checking or not M.how then return end
	local wait = if byHand or failed then RETRY_S else CHECK_EVERY_S
	if os.time() - lastTry < wait then return end
	checking, lastTry = true, os.time()
	local started = pcall(budget.fetch, "update check", MANIFEST_URL, { timeout_ms = 15000 }, function(result, cx)
		checking = false
		local latest = if result.status == 200 then versionOf(result.body) else nil
		failed = latest == nil
		if not latest then
			tern.log.info("Overseer: couldn't check for a newer version: "
				.. (result.error or ("HTTP " .. tostring(result.status))))
			return
		end
		local before = stored().latest
		tern.kv.set("update-check", { at = os.time(), latest = latest })
		if latest ~= before and cx then changed(cx) end
	end)
	if not started then checking, failed = false, true end
end

return M
