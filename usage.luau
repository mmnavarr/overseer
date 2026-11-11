-- The Usage tab of Overseer Settings: what omp's sessions cost, by project and
-- worktree. usage.ts reads omp's session files in a process of its own; omp is a
-- compiled Bun program, and BUN_BE_BUN=1 makes it run usage.ts as Bun would, so
-- this needs nothing omp doesn't bring. It reads when the tab opens and on ↻.
local ui = tern.ui
local wt = require("./worktrunk")

local M = {}

local TIMEOUT_MS = 120000
local WORKTREES_SHOWN = 12
local RANGES = { { "today", "Today" }, { "week", "7 days" }, { "month", "30 days" } }

local function firstLine(text)
	return string.match(text or "", "^%s*([^\n]-)%s*\n") or string.match(text or "", "^%s*(.-)%s*$") or ""
end

-- state.usage: nil (not read yet), "loading", the decoded result, or {error = …}.
function M.load(state, projects, render)
	local omp = wt.find_executable("omp")
	if not omp then
		state.usage = { error = "Usage reads omp's session files, and omp wasn't found." }
		return
	end
	local list = {}
	for _, project in projects do
		table.insert(list, { name = project.name, path = project.path, id = project.id })
	end
	state.usage = "loading"
	local argv = { omp, tern.plugin.dir .. "/usage.ts", tern.json.encode(tern.json.array(list)) }
	local ok, err = pcall(tern.process.run, argv, { env = { BUN_BE_BUN = "1" }, timeout_ms = TIMEOUT_MS }, function(result)
		local decoded = result.status == 0 and select(2, pcall(tern.json.decode, result.stdout or ""))
		if type(decoded) == "table" and type(decoded.ranges) == "table" then
			state.usage = decoded
		elseif result.timed_out then
			state.usage = { error = "Reading omp's session files took over two minutes." }
		else
			state.usage = { error = "Couldn't read omp's session files: " .. firstLine(result.stderr) }
		end
		render()
	end)
	if not ok then state.usage = { error = "Couldn't start omp: " .. tostring(err) } end
end

-- 1234567 → "1,234,567".
local function grouped(text)
	repeat
		local next, n = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
		text = next
	until n == 0
	return text
end

local function money(value)
	return "$" .. grouped(if value >= 100 then tostring(math.floor(value + 0.5)) else string.format("%.2f", value))
end

local function count(n)
	if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
	if n >= 1e6 then return string.format("%.0fM", n / 1e6) end
	if n >= 1e4 then return string.format("%.0fk", n / 1e3) end
	return grouped(tostring(n))
end

local function share(part, whole)
	return ui.meter_cell(if whole > 0 then part / whole else 0)
end

local function percent(part, whole)
	return string.format("%.0f%%", if whole > 0 then 100 * part / whole else 0)
end

local function muted(key, text)
	return ui.node("text", { key = key, spans = { ui.span(text, "muted") } })
end

-- The tab's nodes. `heading(key, text)` is Settings' section heading.
function M.view(state, heading)
	local usage = state.usage
	if usage == "loading" or usage == nil then return { muted("loading", "Reading omp's session files…") } end
	if usage.error then
		return { ui.node("text", { key = "error", spans = { ui.span(usage.error, "error") } }) }
	end
	local range = usage.ranges[state.range] or usage.ranges.week
	local segments = {}
	for _, pair in RANGES do
		table.insert(segments, ui.button(pair[2], {
			key = "range-" .. pair[1], size = "sm", on = state.range == pair[1], actions = { click = "range=" .. pair[1] },
		}))
	end
	local nodes = {
		ui.node("row", { key = "range", gap = "sm", align = "center" }, {
			ui.node("row", { key = "segments", gap = "xs" }, segments),
			muted("since", range.since),
			ui.node("row", { key = "spacer", grow = 1 }, {}),
			muted("read", "Read at " .. usage.read),
			ui.button("", {
				key = "reload", icon = "refresh", variant = "quiet", size = "sm", title = "Read again", actions = { click = "usage-read" },
			}),
		}),
		ui.stats({
			{ label = "Spend", value = money(range.cost), sub = "estimated" },
			{ label = "Sessions", value = tostring(range.sessions), sub = count(range.replies) .. " replies" },
			{ label = "Tokens", value = count(range.tokens), sub = percent(range.cacheReads, range.tokens) .. " from cache" },
			{ label = "Subagents", value = money(range.subagents), sub = percent(range.subagents, range.cost) .. " of spend" },
		}),
	}
	if #range.repos == 0 then
		table.insert(nodes, muted("none", "No omp sessions in this time."))
		return nodes
	end

	local bars = {}
	-- Tern shows a bar's label when you point at it.
	for index, value in range.series do table.insert(bars, { range.labels[index] .. " · " .. money(value), value }) end
	table.insert(nodes, heading("chart-head", if state.range == "today" then "By hour" else "By day"))
	table.insert(nodes, ui.bars(bars))

	local repoRows, chosen = {}, nil
	for _, repo in range.repos do
		local id = "repo-" .. repo.name
		if id == state.repo then chosen = repo end
		table.insert(repoRows, {
			id = id,
			cells = {
				repo.name, money(repo.cost), share(repo.cost, range.cost), tostring(#repo.worktrees), tostring(repo.sessions),
				{ spark = { values = repo.spark } },
			},
		})
	end
	chosen = chosen or range.repos[1]
	table.insert(nodes, heading("repos-head", "By repository"))
	table.insert(nodes, ui.table({
		{ id = "repo", head = "Repository", grow = 1 },
		{ id = "cost", head = "Spend", align = "end", mono = true },
		{ id = "share", head = "Share", grow = 1 },
		{ id = "trees", head = "Worktrees", align = "end", priority = -1 },
		{ id = "sessions", head = "Sessions", align = "end", priority = -1 },
		{ id = "trend", head = "Trend", priority = -2 },
	}, repoRows, { selectable = true, selected = "repo-" .. chosen.name }))

	local treeRows, shownCost = {}, 0
	for index, tree in chosen.worktrees do
		if index > WORKTREES_SHOWN then break end
		shownCost += tree.cost
		table.insert(treeRows, {
			tree.name, money(tree.cost), share(tree.cost, chosen.cost), tostring(tree.sessions), { spark = { values = tree.spark } },
		})
	end
	local hidden = #chosen.worktrees - WORKTREES_SHOWN
	-- Other holds folders outside your projects, not worktrees.
	local unit = if chosen.name == "Other" then "Folder" else "Worktree"
	table.insert(nodes, heading("trees-head", unit .. "s in " .. chosen.name))
	table.insert(nodes, ui.table({
		{ id = "tree", head = unit, grow = 1, truncate = "middle" },
		{ id = "cost", head = "Spend", align = "end", mono = true },
		{ id = "share", head = "Share of " .. chosen.name, grow = 1 },
		{ id = "sessions", head = "Sessions", align = "end", priority = -1 },
		{ id = "trend", head = "Trend", priority = -2 },
	}, treeRows))
	if hidden > 0 then
		table.insert(nodes, muted("trees-more", string.format("%d more, %s together", hidden, money(chosen.cost - shownCost))))
	end

	local modelRows = {}
	for _, model in range.models do
		table.insert(modelRows, { model.name, money(model.cost), share(model.cost, range.cost) })
	end
	table.insert(nodes, heading("models-head", "By model"))
	table.insert(nodes, ui.table({
		{ id = "model", head = "Model", grow = 1, mono = true },
		{ id = "cost", head = "Spend", align = "end", mono = true },
		{ id = "share", head = "Share", grow = 1 },
	}, modelRows))

	local topRows = {}
	for _, session in range.top do
		table.insert(topRows, { session.title, session.project .. " · " .. session.worktree, money(session.cost) })
	end
	table.insert(nodes, heading("top-head", "Most expensive sessions"))
	table.insert(nodes, ui.table({
		{ id = "title", head = "Session", grow = 2 },
		{ id = "where", head = "Where", grow = 1, truncate = "middle" },
		{ id = "cost", head = "Spend", align = "end", mono = true },
	}, topRows))
	table.insert(nodes, muted("note",
		"Prices are omp's estimates for each reply, subagents included. On a subscription, your bill can differ."))
	return nodes
end

return M
