-- Overseer's omp half (omp/: the overseer-subworktree skill, the
-- overseer-worktrees rule and the overseer-rails extension) is an omp plugin
-- package, overseer-omp. Each time the plugin loads, Overseer makes sure omp
-- has it linked to this copy, so installing Overseer is all it takes.
--
-- Nothing happens without omp. A link to this copy is left alone, and so is
-- whether it's enabled: `omp plugin disable overseer-omp` sticks. A link to
-- another copy (an older frozen install, another checkout) is pointed here,
-- keeping it disabled if it was. Once linked, the hand-made symlinks earlier
-- READMEs asked for are removed, or omp would load the skill, rule and
-- extension twice; only symlinks into an Overseer checkout are touched.
local budget = require("./budget")
local wt = require("./worktrunk")
local oplog = require("./oplog")

local M = {}

local PACKAGE = "overseer-omp"
local TIMEOUT_MS = 30000

-- Each old symlink under ~, and the end of the path it pointed at.
local LEGACY = {
	{ ".omp/agent/skills/overseer-subworktree", "/skills/overseer-subworktree" },
	{ ".omp/agent/rules/overseer-worktrees.md", "/omp/rules/overseer-worktrees.md" },
	{ ".omp/agent/extensions/overseer-rails", "/omp/overseer-rails" },
}

local function warn(event, detail)
	oplog.write("warn", { op = "omp link", event = event, detail = detail })
end

-- Runs argv and calls fn(result) once it exits 0; anything else is logged.
local function run(event, argv, fn)
	local ok, err = pcall(budget.process, "omp link " .. event, argv, { timeout_ms = TIMEOUT_MS }, function(result)
		if result.timed_out then
			warn(event, argv[1] .. " timed out")
		elseif result.status ~= 0 then
			local stderr = string.gsub(result.stderr or "", "%s+$", "")
			warn(event, if stderr ~= "" then stderr else "exit status " .. tostring(result.status))
		else
			fn(result)
		end
	end)
	if not ok then warn(event, tostring(err)) end
end

local function removeLegacy()
	local home = tern.getenv("HOME")
	if not home or home == "" then return end
	-- $1 is home, then pairs of (path under home, expected link target suffix).
	local program = 'home=$1; shift; while [ $# -gt 1 ]; do p="$home/$1"; '
		.. 'if [ -L "$p" ]; then case "$(readlink "$p")" in *"$2") rm -f -- "$p" && printf "%s\\n" "$p";; esac; fi; '
		.. "shift 2; done"
	local argv = { "/bin/bash", "-c", program, "overseer", home }
	for _, legacy in LEGACY do
		table.insert(argv, legacy[1])
		table.insert(argv, legacy[2])
	end
	run("cleanup", argv, function(result)
		for removed in string.gmatch(result.stdout or "", "[^\n]+") do
			oplog.write("info", { op = "omp link", event = "removed old symlink", path = removed })
		end
	end)
end

local function link(omp, source, wasDisabled)
	run("link", { omp, "plugin", "link", source }, function()
		oplog.write("info", { op = "omp link", event = "linked", path = source })
		if wasDisabled then
			-- Linking enables the package; put back the person's choice.
			run("disable", { omp, "plugin", "disable", PACKAGE }, function() end)
		end
		removeLegacy()
	end)
end

function M.ensure()
	local omp = wt.find_executable("omp")
	if not omp then return end
	local source = tern.plugin.dir .. "/omp"
	run("list", { omp, "plugin", "list", "--json" }, function(result)
		-- `{ npm = [...], marketplace = [...] }`; linked packages are listed under npm.
		local parsed, listing = pcall(tern.json.decode, result.stdout or "")
		if not parsed or type(listing) ~= "table" or type(listing.npm) ~= "table" then
			warn("list", "omp plugin list --json returned no npm plugin list")
			return
		end
		local entry
		for _, plugin in listing.npm do
			if type(plugin) == "table" and plugin.name == PACKAGE then entry = plugin end
		end
		if not entry or type(entry.path) ~= "string" then
			link(omp, source, false)
			return
		end
		-- Compare where both paths really lead; Tern may hand us a symlinked dir.
		local resolve = 'for p in "$@"; do (cd -P -- "$p" 2>/dev/null && pwd -P) || echo; done'
		run("resolve", { "/bin/bash", "-c", resolve, "overseer", source, entry.path }, function(resolved)
			local lines = {}
			for line in string.gmatch((resolved.stdout or "") .. "\n", "(.-)\n") do table.insert(lines, line) end
			if lines[1] ~= nil and lines[1] ~= "" and lines[1] == lines[2] then
				removeLegacy()
			else
				link(omp, source, entry.enabled == false)
			end
		end)
	end)
end

return M
