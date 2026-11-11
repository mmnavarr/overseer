--!nonstrict
-- Tern gives every window-half callback 50 ms of Lua; native calls (the `cx`
-- API, `tern.kv`, starting a process) don't count. A callback past it is cut
-- short and its hook pauses for 5 s (doubling on repeats, up to 5 min). Due
-- timers and process results wait out the pause instead of being dropped, so
-- nothing has to be restarted afterwards.
--
-- Overseer still does its work in labelled timer callbacks started by
-- `later`, and every other hook only queues work: a paused click hook would
-- swallow clicks for the pause, so it must stay too small to trip.
local M = {}

-- The timer callback started last: when the timer hook pauses, this names
-- the callback that ran over.
local lastStarted = nil

-- Runs fn(cx) in a timer callback of its own after `ms`, labelled for the log.
-- Errors are logged, never raised; `fn` reports anything the user must see.
function M.later(label, ms, fn)
	return tern.timer(ms, function(cx)
		lastStarted = label
		local ok, err = pcall(fn, cx)
		if not ok then tern.log.warn("Overseer: " .. label .. " failed: " .. tostring(err)) end
	end)
end

-- Starts argv and calls fn(result, cx) with its result, or raises when it
-- can't start. Errors in fn are logged under `label`.
function M.process(label, argv, options, fn)
	tern.process.run(argv, options, function(result, cx)
		local ok, err = pcall(fn, result, cx)
		if not ok then tern.log.warn("Overseer: " .. label .. " failed: " .. tostring(err)) end
	end)
end

-- Fetches url and calls fn(result, cx) with its result. Errors in fn are
-- logged under `label`.
function M.fetch(label, url, options, fn)
	tern.fetch(url, options, function(result, cx)
		local ok, err = pcall(fn, result, cx)
		if not ok then tern.log.warn("Overseer: " .. label .. " failed: " .. tostring(err)) end
	end)
end

-- The `budget` event's text for the log: which hook paused, and for a timer,
-- the callback that ran over.
function M.describe(ev)
	if ev.state ~= "paused" then return "Overseer: Tern resumed its " .. ev.hook .. " hook." end
	local culprit = if ev.hook == "timer" and lastStarted then " (" .. lastStarted .. ")" else ""
	return string.format("Overseer: Tern paused its %s hook for %.0f s after a callback%s ran over %.0f ms.",
		ev.hook, (ev.paused_ms or 0) / 1000, culprit, ev.ms or 0)
end

return M
