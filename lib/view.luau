-- The block's `main` region. Pure: reads state, builds nodes, mutates nothing.
-- Node ids are `<parent id>.<key>` from the region root; the setup field keeps the id `main.setup.key`.

local text = require("./text")

local ui = tern.ui

local view = {}

export type State = any

view.KEY_URL = "https://linear.app/settings/account/security"
view.SETUP_FIELD_ID = "main.setup.key"

local STATE_TONES: { [string]: string } = {
	triage = "info",
	backlog = "muted",
	unstarted = "neutral",
	started = "warning",
	completed = "success",
	canceled = "muted",
	duplicate = "muted",
}

local PRIORITY_TONES: { [number]: string } = {
	[1] = "error",
	[2] = "warning",
	[3] = "info",
	[4] = "muted",
}

local function with(node: any, props: { [string]: any }): any
	local merged: { [string]: any } = node.p or {}
	for name, value in props do
		merged[name] = value
	end
	node.p = merged
	return node
end

local function paragraph(key: string, spans: any): any
	return with(ui.text(spans), { key = key })
end

local function button(key: string, label: string?, action: string, props: { [string]: any }?): any
	local merged: { [string]: any } = { key = key, size = "sm", actions = { click = action } }
	if props ~= nil then
		for name, value in props do
			merged[name] = value
		end
	end
	return ui.button(label, merged)
end

local function shorten(path: string): string
	local home = tern.getenv("HOME")
	if home ~= nil and home ~= "" and string.sub(path, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
end

local function heading(key: string, label: string): any
	return with(ui.text({ ui.span(label, "strong") }), { key = key, mark = "heading" })
end

local function banner(key: string, tone: string, icon: string, message: string): any
	return ui.node("row", { key = key, tone = tone, gap = "sm" }, {
		ui.node("icon", { key = "icon", name = icon, tone = tone }),
		ui.node("text", { key = "text", spans = { message }, grow = 1 }),
	})
end

-- ─── Toolbar ────────────────────────────────────────────────────────────────

local function toolbar(state: State): any
	local busy = state.refreshing == true
	return ui.node("row", { key = "bar", gap = "sm", wrap = true }, {
		button("refresh", "Refresh", "refresh", { icon = "repeat", busy = busy }),
		button("open", "Open in browser", "open", { icon = "link" }),
		button("copy", "Copy link", "copy", { icon = "copy" }),
		button("settings", "Settings", "settings", { variant = "quiet", on = state.phase == "settings" }),
	})
end

-- ─── Issue ──────────────────────────────────────────────────────────────────

local function properties(issue: any): any
	local chips: { any } = {}
	if issue.stateName ~= nil then
		table.insert(
			chips,
			with(ui.badge(issue.stateName, STATE_TONES[issue.stateType or ""] or "neutral"), { key = "state" })
		)
	end
	if issue.priority > 0 and issue.priorityLabel ~= nil then
		table.insert(
			chips,
			with(ui.badge(issue.priorityLabel, PRIORITY_TONES[issue.priority] or "muted"), { key = "priority" })
		)
	end
	if issue.assignee ~= nil then
		table.insert(chips, with(ui.badge(issue.assignee, "neutral"), { key = "assignee", title = "Assignee" }))
	end
	if issue.project ~= nil then
		table.insert(chips, with(ui.badge(issue.project, "neutral"), { key = "project", title = "Project" }))
	end
	return ui.node("row", { key = "props", gap = "sm", wrap = true }, chips)
end

local function attachments(issue: any): any?
	if #issue.attachments == 0 then
		return nil
	end
	local rows: { any } = {}
	for index, attachment in issue.attachments do
		local spans: { any } = { ui.link(attachment.title, attachment.url) }
		if attachment.subtitle ~= nil then
			table.insert(spans, ui.span("  " .. attachment.subtitle, "muted"))
		end
		table.insert(rows, paragraph("attachment-" .. index, spans))
	end
	return ui.node("col", { key = "attachments", gap = "xs" }, {
		ui.rule("Attachments"),
		ui.node("col", { key = "list", gap = "xs" }, rows),
	})
end

local function comments(issue: any, now: number): any?
	if #issue.comments == 0 then
		return nil
	end
	local rows: { any } = {}
	for index, comment in issue.comments do
		local who = comment.author or "Someone"
		local when = text.ago(comment.createdAt, now)
		local head = if when ~= "" then who .. " · " .. when else who
		table.insert(
			rows,
			ui.node("col", { key = "comment-" .. index, gap = "xs" }, {
				paragraph("head", { ui.span(head, "muted") }),
				with(ui.md(text.cleanMarkdown(comment.body), { run = false }), { key = "body" }),
			})
		)
	end
	return ui.node("col", { key = "comments", gap = "sm" }, {
		ui.rule("Latest comments"),
		ui.node("col", { key = "list", gap = "md" }, rows),
	})
end

local function issueNodes(state: State, now: number): { any }
	local issue = state.issue
	local nodes: { any } = {
		toolbar(state),
		paragraph("id", { ui.span(issue.identifier, "muted") }),
		paragraph("title", { ui.span(issue.title, "strong") }),
		properties(issue),
	}
	if issue.parent ~= nil then
		table.insert(
			nodes,
			paragraph("parent", {
				ui.span("Sub-issue of ", "muted"),
				ui.link(issue.parent.identifier .. " " .. issue.parent.title, issue.parent.url),
			})
		)
	end
	if issue.description ~= nil then
		table.insert(nodes, ui.rule("Description"))
		table.insert(nodes, with(ui.md(text.cleanMarkdown(issue.description), { run = false }), { key = "description" }))
	end
	local files = attachments(issue)
	if files ~= nil then
		table.insert(nodes, files)
	end
	local thread = comments(issue, now)
	if thread ~= nil then
		table.insert(nodes, thread)
	end
	if state.error ~= nil then
		table.insert(nodes, 2, banner("error", "error", "x-circle", state.error))
	end
	return nodes
end

-- ─── Not available: the browser sits below, this explains why ───────────────

local function fallbackNodes(state: State): { any }
	local buttons: { any } = {}
	if state.fallbackKind == "nokey" then
		table.insert(buttons, button("setup", "Set up", "setup", { variant = "primary" }))
	end
	table.insert(buttons, button("retry", "Retry", "refresh", { icon = "repeat", busy = state.refreshing == true }))
	table.insert(buttons, button("open", "Open in browser", "open", { icon = "link" }))
	table.insert(buttons, button("copy", "Copy link", "copy", { icon = "copy" }))
	table.insert(buttons, button("settings", "Settings", "settings", { variant = "quiet" }))
	return {
		paragraph("note", { ui.span(state.note or "Linear data is not available.", "muted") }),
		ui.node("row", { key = "bar", gap = "sm", wrap = true }, buttons),
	}
end

local ruleNodes: (State) -> { any }

-- ─── Setup ──────────────────────────────────────────────────────────────────

local function setupNodes(state: State): { any }
	local field = state.setupKey
	local children: { any } = {
		heading("head", "Connect Linear"),
		paragraph("create", {
			"Create a personal API key at ",
			ui.link(view.KEY_URL, view.KEY_URL),
			" (read access is enough), then paste it here.",
		}),
		paragraph("storage", {
			ui.span(
				"The key is stored in this plugin's data folder in a file only you can read. "
					.. "Setting LINEAR_API_KEY in Tern's environment works too and is never stored.",
				"muted"
			),
		}),
		ui.node("input", {
			key = "key",
			text = field.text,
			cursor = field.cursor,
			anchor = field.anchor,
			placeholder = "lin_api_…",
			secret = true,
			mono = true,
			variant = "field",
		}),
	}
	if state.setupError ~= nil then
		table.insert(children, with(ui.text({ ui.span(state.setupError, "error") }), { key = "error", tone = "error" }))
	end
	table.insert(
		children,
		ui.node("row", { key = "buttons", gap = "sm" }, {
			button("connect", "Connect", "connect", {
				variant = "primary",
				size = "md",
				keys = { "enter" },
				busy = state.connecting == true,
			}),
			button("cancel", "Back", "back", { size = "md" }),
		})
	)
	for _, node in ruleNodes(state) do
		table.insert(children, node)
	end
	return { ui.node("col", { key = "setup", gap = "md" }, children) }
end

-- ─── Settings and the agent rule ────────────────────────────────────────────

local function connectionLine(state: State): string
	local who = ""
	local viewer = state.viewer
	if viewer ~= nil and viewer.name ~= nil then
		who = viewer.name .. (if viewer.orgName ~= nil then " (" .. viewer.orgName .. ")" else "")
	end
	if state.keySource == "env" then
		return "Using LINEAR_API_KEY from Tern's environment" .. (if who ~= "" then " as " .. who else "") .. "."
	elseif state.keySource == "file" then
		return "Connected" .. (if who ~= "" then " as " .. who else "") .. " with the stored API key."
	end
	return "Not connected."
end

function ruleNodes(state: State): { any }
	local ruleText = state.ruleText
	local rows: { any } = {
		ui.rule("Agent rule"),
		paragraph("what", {
			ui.span(
				"Add this line to your coding agents' instructions so they write tickets as links this sidebar opens.",
				"muted"
			),
		}),
		with(ui.code(ruleText, "markdown"), { key = "rule" }),
		ui.node("row", { key = "rule-actions", gap = "sm", wrap = true }, {
			button("rule-copy", "Copy rule", "rule-copy", { icon = "copy" }),
		}),
	}
	local fileButtons: { any } = {}
	for index, target in state.targets do
		local label = (if target.present then "Remove from " else "Add to ") .. shorten(target.path)
		table.insert(
			fileButtons,
			button("rule-file-" .. index, label, (if target.present then "rule-remove=" else "rule-add=") .. index, {
				variant = if target.present then "danger" else "default",
			})
		)
	end
	if #fileButtons == 0 then
		table.insert(rows, paragraph("nofiles", {
			ui.span("No ~/.omp/agent/AGENTS.md, ~/.claude/CLAUDE.md or ~/.codex/AGENTS.md found; use Copy rule.", "muted"),
		}))
	else
		table.insert(rows, ui.node("col", { key = "rule-files", gap = "xs", align = "start" }, fileButtons))
	end
	if state.ruleError ~= nil then
		table.insert(rows, with(ui.text({ ui.span(state.ruleError, "error") }), { key = "rule-error", tone = "error" }))
	end
	return rows
end

local function settingsNodes(state: State): { any }
	local children: { any } = {}
	if state.onboarding then
		table.insert(children, heading("head", "Connected to Linear"))
		table.insert(children, paragraph("done", { "Issue links now open in this sidebar." }))
	else
		table.insert(children, heading("head", "Linear sidebar settings"))
		table.insert(children, paragraph("connection", { connectionLine(state) }))
	end
	local actions: { any } = {}
	if state.keySource == "file" and not state.onboarding then
		table.insert(actions, button("signout", "Sign out", "signout", { variant = "danger" }))
	elseif state.keySource == nil then
		table.insert(actions, button("setup", "Set up", "setup", { variant = "primary" }))
	end
	table.insert(actions, button("back", if state.onboarding then "Continue" else "Done", "back", {
		variant = if state.onboarding then "primary" else "default",
	}))
	table.insert(children, ui.node("row", { key = "bar", gap = "sm", wrap = true }, actions))
	for _, node in ruleNodes(state) do
		table.insert(children, node)
	end
	return { ui.node("col", { key = "settings", gap = "md" }, children) }
end

-- ─── Public ─────────────────────────────────────────────────────────────────

local function loadingNodes(state: State): { any }
	return {
		toolbar(state),
		ui.node("row", { key = "loading", gap = "sm" }, {
			ui.node("spinner", { key = "spinner", style = "braille" }),
			ui.node("text", { key = "label", spans = { ui.span("Loading " .. (state.ident or "issue") .. "…", "muted") } }),
		}),
	}
end

function view.render(state: State): { main: any }
	local children: { any }
	local phase = state.phase
	if phase == "ready" then
		children = issueNodes(state, os.time())
	elseif phase == "fallback" then
		children = fallbackNodes(state)
	elseif phase == "setup" then
		children = setupNodes(state)
	elseif phase == "settings" then
		children = settingsNodes(state)
	elseif phase == "empty" then
		children = { paragraph("empty", { ui.span("Open a Linear issue link to see it here.", "muted") }) }
	else
		children = loadingNodes(state)
	end
	return { main = ui.node("col", { gap = "md" }, children) }
end

return view
