--!nonstrict
-- "Visualize PR": a read-only visual outline of a pull request, drafted by omp
-- with the bundled visual-pr skill's template and diagram conventions.
local wt = require("./worktrunk")

local M = {}

local TIMEOUT_MS = 10 * 60 * 1000
local SKILL = tern.plugin.dir .. "/skills/visual-pr"
-- No shell, edit, write or extension tools: omp can read files and nothing else,
-- so it can't run git or gh, change the checkout, or touch the pull request.
local READ_ONLY = { "--no-session", "--no-extensions", "--no-skills", "--no-title", "--tools=read,grep,glob" }

local function slug(text)
	return (string.gsub(text, "[^%w%-]", "_"))
end

local function prompt(meta, dir, worktree, ticketUrl)
	return table.concat({
		"Write a visual outline of GitHub pull request #" .. tostring(meta.number) .. " (" .. meta.url .. ") to help a reviewer understand it.",
		"This is a read-only preview shown in a panel: nothing is published, and your tools can only read files.",
		"",
		"Use the visual-pr skill's description format, not its publishing workflow:",
		"- Template, followed exactly: " .. SKILL .. "/references/pr_description_template.md",
		"- Diagram and code-shape conventions: " .. SKILL .. "/references/show-me.md",
		"",
		"The pull request, fetched from GitHub:",
		"- Metadata (title, body, branches, author, changed files): " .. dir .. "/pr.json",
		"- Complete diff: " .. dir .. "/pr.diff",
		"- Your working directory is a checkout of this repository on branch " .. (worktree.branch or "(detached)")
			.. ". Read surrounding code only where the diff alone doesn't explain behaviour; it may not match the PR's head exactly.",
		if ticketUrl then "- Linear ticket: " .. ticketUrl .. " (link it in the header)" else "",
		"",
		"Reply with only the finished Markdown. Start with the level-1 heading \"# #" .. tostring(meta.number) .. " · " .. meta.title
			.. "\", then the template's sections. No preamble and no closing remarks.",
	}, "\n")
end

-- omp prints progress before its answer; the outline starts at its first heading.
local function markdown(stdout)
	local start = if string.sub(stdout, 1, 1) == "#" then 1 else string.find(stdout, "\n#", 1, true)
	if not start then return nil end
	return (string.gsub(string.sub(stdout, start), "^\n", ""))
end

local function tail(text, lines)
	local kept = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(kept, line)
		if #kept > lines then table.remove(kept, 1) end
	end
	return table.concat(kept, "\n")
end

-- done(markdown, err, cx, meta). Outlines are cached by the PR's head commit, so
-- an unchanged PR opens instantly and a new push gets a fresh outline.
function M.outline(project, worktree, number, ticketUrl, done)
	wt.pull_request_meta(project, number, function(meta, err, cx)
		if not meta then done(nil, err, cx); return end
		local root = tern.plugin.data .. "/visual-pr"
		local key = slug(project.name) .. "-" .. tostring(number) .. "-" .. string.sub(meta.headRefOid or "head", 1, 12)
		local cached = root .. "/" .. key .. ".md"
		if tern.fs.exists(cached) then done(tern.fs.read(cached, 1048576), nil, cx, meta); return end
		local omp = wt.find_executable("omp")
		if not omp then done(nil, "omp was not found", cx, meta); return end
		local dir = root .. "/" .. key
		tern.fs.mkdir(dir)
		tern.fs.write(dir .. "/pr.json", tern.json.encode(meta))
		wt.pull_request_diff(meta.repo, number, dir .. "/pr.diff", function(ok, diffErr, diffCx)
			if not ok then tern.fs.remove(dir); done(nil, diffErr, diffCx, meta); return end
			local argv = { omp, "-p" }
			for _, flag in READ_ONLY do table.insert(argv, flag) end
			table.insert(argv, prompt(meta, dir, worktree, ticketUrl))
			-- omp is a Bun script: its directory must be on PATH for `env bun`.
			local path = string.match(omp, "^(.*)/[^/]+$") .. ":" .. (tern.getenv("PATH") or "/usr/bin:/bin")
			local started, startErr = pcall(tern.process.run, argv,
				{ cwd = worktree.path, timeout_ms = TIMEOUT_MS, env = { PATH = path } },
				function(result, runCx)
					tern.fs.remove(dir)
					if result.timed_out then done(nil, "omp took longer than 10 minutes", runCx, meta); return end
					local outline = result.status == 0 and markdown(result.stdout)
					if not outline then
						local detail = tail(result.stderr ~= "" and result.stderr or result.stdout, 12)
						done(nil, "omp exited with status " .. tostring(result.status) .. "\n\n" .. detail, runCx, meta)
						return
					end
					tern.fs.write(cached, outline)
					done(outline, nil, runCx, meta)
				end)
			if not started then tern.fs.remove(dir); done(nil, "Could not start omp: " .. tostring(startErr), diffCx, meta) end
		end)
	end)
end

return M
