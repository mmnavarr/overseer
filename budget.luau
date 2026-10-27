--!nonstrict
-- Tern gives every plugin callback 50 ms. One overrun switches that hook
-- (`timer`, `process`, `canvas_action`, …) off until the plugin reloads, and
-- the overrun can't be caught: the callback just stops. Overruns can't be
-- prevented either: a callback doing almost nothing still overruns when Tern
-- stalls inside one of its calls while busy.
--
-- So Overseer does its work in timer callbacks started by `later`, keeps
-- every other hook trivial, and reloads itself when a hook it depends on has
-- stopped: `checkTimers` (called from every other hook) notices a dead timer
-- hook, `checkProcesses` (called from the tick) a dead process hook.
local M = {}

-- A callback this slow is logged: it was close to being cut short.
local SLOW_MS = 30
-- The tick runs every 750 ms; this long without any timer callback is suspect.
-- Only suspect: Tern doesn't run plugin timers while its window idles without
-- events, and the event that wakes it may arrive before the overdue timers
-- run. So a suspect timer hook gets a probe timer; unfired this much later,
-- the hook is off.
local STALL_MS = 5000
local PROBE_MS = 1000
-- A process Tern hasn't reported this long after its own timeout was reported
-- to a switched-off process hook. Counted in ticks, not wall time, since an
-- idle window runs no ticks.
local PROCESS_GRACE_MS = 10000
local TICK_GAP_CAP_MS = 2000
-- Never reload more often than this, so a plugin that keeps overrunning
-- can't reload in a loop. Persisted: a reload resets everything in memory.
local RELOAD_COOLDOWN_S = 30

local lastTimer = tern.now()
-- The timer callback started last. Never cleared: a callback Tern cuts short
-- is the last one the dead timer hook ever starts, so this names the culprit.
local lastStarted = nil
local probeSince = nil
-- Started processes Tern hasn't reported yet: token -> { label, limit, waited },
-- in milliseconds of ticking.
local processes = {}
local lastProcessCheck = nil
local lastReload = tonumber(tern.kv.get("self-reload")) or 0
local reloading = false

-- Tern's CLI, which reloads plugins through the session daemon: that hands
-- the open Projects panel to the reloaded plugin. The window's own
-- `reload_plugins` action leaves it behind as an ownerless, empty canvas.
local function ternCli()
	local home = tern.getenv("HOME") or ""
	for _, path in {
		"/Applications/Tern.app/Contents/MacOS/tern", home .. "/Applications/Tern.app/Contents/MacOS/tern",
		home .. "/.local/bin/tern", "/opt/homebrew/bin/tern", "/usr/local/bin/tern",
	} do
		if tern.fs.exists(path) then return path end
	end
	return nil
end

local function reload(cx, why)
	if reloading or os.time() - lastReload < RELOAD_COOLDOWN_S then return end
	reloading, lastReload = true, os.time()
	tern.log.warn("Overseer is reloading itself: " .. why)
	pcall(tern.kv.set, "self-reload", lastReload)
	local cli = ternCli()
	-- No callback work: the process hook may be the one that's off.
	local started = cli ~= nil and pcall(tern.process.run, { cli, "plugin", "reload" }, { timeout_ms = 15000 }, function() end)
	if not started then cx:action("reload_plugins") end
end

-- Runs fn(cx) in a timer callback of its own after `ms`, labelled for the log.
-- Errors are logged, never raised; `fn` reports anything the user must see.
function M.later(label, ms, fn)
	return tern.timer(ms, function(cx)
		local started = tern.now()
		lastTimer, lastStarted = started, label
		local ok, err = pcall(fn, cx)
		local took = tern.now() - started
		if took >= SLOW_MS then
			tern.log.warn(string.format("Overseer: %s took %.0f ms of its 50 ms budget.", label, took))
		end
		if not ok then tern.log.warn("Overseer: " .. label .. " failed: " .. tostring(err)) end
	end)
end

-- Starts argv now and hands its result to fn(result, cx) in a timer callback,
-- so the process hook itself does nothing that could overrun. Raises when the
-- process can't start.
function M.process(label, argv, options, fn)
	local token = {}
	local timeout = options and options.timeout_ms
	processes[token] = {
		label = label, waited = 0,
		limit = if timeout then timeout + PROCESS_GRACE_MS else math.huge,
	}
	local ok, err = pcall(tern.process.run, argv, options, function(result, cx)
		processes[token] = nil
		if cx then M.checkTimers(cx) end
		M.later(label, 0, function(laterCx) fn(result, laterCx) end)
	end)
	if not ok then
		processes[token] = nil
		error(err, 0)
	end
end

-- From every hook but timers: reloads once the timer hook is confirmed off.
function M.checkTimers(cx)
	local now = tern.now()
	if now - lastTimer < STALL_MS then
		probeSince = nil
		return
	end
	if not probeSince then
		probeSince = now
		local ok = pcall(tern.timer, 0, function() lastTimer = tern.now() end)
		if ok then return end
	elseif now - probeSince < PROBE_MS then
		return
	end
	local culprit = if lastStarted then " (" .. lastStarted .. " was cut short)" else ""
	reload(cx, "Tern switched its timer hook off after a callback overran 50 ms" .. culprit .. ".")
end

-- From the tick: reloads when a process result is long overdue.
function M.checkProcesses(cx)
	local now = tern.now()
	local step = if lastProcessCheck then math.min(now - lastProcessCheck, TICK_GAP_CAP_MS) else 0
	lastProcessCheck = now
	for _, process in processes do
		process.waited += step
		if process.waited > process.limit then
			reload(cx, "Tern switched its process hook off after a callback overran 50 ms (" .. process.label .. " never reported back).")
			return
		end
	end
end

return M
