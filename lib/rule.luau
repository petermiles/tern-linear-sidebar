-- The agent rule: the one line that makes coding agents write Linear tickets as links this plugin claims,
-- and the idempotent add / remove of that line in agent instruction files (host half).

local rule = {}

local START = "<!-- tern-linear-sidebar-rule:start -->"
local END = "<!-- tern-linear-sidebar-rule:end -->"

export type Target = { path: string, present: boolean }

-- `workspace` is the workspace's URL key, `teamKey` any team key used as the example identifier.
function rule.text(workspace: string?, teamKey: string?): string
	local ws = workspace or "your-workspace"
	local team = teamKey or "ABC"
	return string.format(
		"Write Linear tickets as Markdown links: [%s-123](https://linear.app/%s/issue/%s-123).",
		team,
		ws,
		team
	)
end

local function block(text: string): string
	return START .. "\n" .. text .. "\n" .. END
end

-- Byte range of the marked block in `content`, or nil.
local function find(content: string): (number?, number?)
	local startAt = string.find(content, START, 1, true)
	if startAt == nil then
		return nil, nil
	end
	local endAt, endLast = string.find(content, END, startAt + #START, true)
	if endAt == nil then
		return nil, nil
	end
	return startAt, endLast
end

function rule.present(content: string): boolean
	return find(content) ~= nil
end

-- Appends the block once; an existing block is rewritten in place so the text stays current.
function rule.addTo(content: string, text: string): string
	local first, last = find(content)
	if first ~= nil and last ~= nil then
		return string.sub(content, 1, first - 1) .. block(text) .. string.sub(content, last + 1)
	end
	local body = content
	if body ~= "" and string.sub(body, -1) ~= "\n" then
		body ..= "\n"
	end
	if body ~= "" then
		body ..= "\n"
	end
	return body .. block(text) .. "\n"
end

-- Deletes exactly the marked block, plus the blank line `addTo` put before it and the newline after it.
function rule.removeFrom(content: string): string
	local first, last = find(content)
	if first == nil or last == nil then
		return content
	end
	local before = string.sub(content, 1, first - 1)
	local after = string.sub(content, last + 1)
	if string.sub(after, 1, 1) == "\n" then
		after = string.sub(after, 2)
	end
	if string.sub(before, -2) == "\n\n" then
		before = string.sub(before, 1, -2)
	end
	return before .. after
end

local function home(): string?
	local dir = tern.getenv("HOME")
	if dir == nil or dir == "" then
		dir = tern.getenv("USERPROFILE")
	end
	if dir == nil or dir == "" then
		return nil
	end
	return (string.gsub(dir, "[/\\]+$", ""))
end

local CANDIDATES = { "/.omp/agent/AGENTS.md", "/.claude/CLAUDE.md", "/.codex/AGENTS.md" }

-- The instruction files that exist, with whether they already hold the block.
function rule.targets(): { Target }
	local dir = home()
	local out: { Target } = {}
	if dir == nil then
		return out
	end
	for _, candidate in CANDIDATES do
		local path = dir .. candidate
		local existsOk, exists = pcall(tern.fs.exists, path)
		if existsOk and exists then
			local present = false
			local readOk, content = pcall(tern.fs.read, path, 4 * 1024 * 1024)
			if readOk then
				present = rule.present(content)
			end
			table.insert(out, { path = path, present = present })
		end
	end
	return out
end

function rule.add(path: string, text: string): (boolean, string?)
	local readOk, content = pcall(tern.fs.read, path, 4 * 1024 * 1024)
	if not readOk then
		return false, "Could not read " .. path .. "."
	end
	local writeOk = pcall(tern.fs.write, path, rule.addTo(content, text))
	if not writeOk then
		return false, "Could not write " .. path .. "."
	end
	return true, nil
end

function rule.remove(path: string): (boolean, string?)
	local readOk, content = pcall(tern.fs.read, path, 4 * 1024 * 1024)
	if not readOk then
		return false, "Could not read " .. path .. "."
	end
	local writeOk = pcall(tern.fs.write, path, rule.removeFrom(content))
	if not writeOk then
		return false, "Could not write " .. path .. "."
	end
	return true, nil
end

return rule
