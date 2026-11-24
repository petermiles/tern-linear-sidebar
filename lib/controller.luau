-- The `view` block: one Linear issue, read-only. Loading, the setup and settings screens, the browser
-- fallback and every UI event live here (host half).

local api = require("./api")
local credentials = require("./credentials")
local links = require("./links")
local rule = require("./rule")
local text = require("./text")
local view = require("./view")

local controller = {}

local VIEWER_KEY = "viewer"

local function render(state: any)
	-- The pane may be gone by the time a request answers.
	pcall(function()
		state.cx:render()
	end)
end

local function loadCachedViewer(): api.Viewer?
	local ok, cached = pcall(tern.kv.get, VIEWER_KEY)
	if ok and type(cached) == "table" then
		return cached
	end
	return nil
end

local function storeViewer(viewer: api.Viewer)
	pcall(tern.kv.set, VIEWER_KEY, viewer)
end

local function newState(cx: any, url: string?): any
	local workspace, ident = links.parse(url or "")
	return {
		cx = cx,
		url = url,
		workspace = workspace,
		ident = ident,
		phase = if ident == nil then "empty" else "loading",
		issue = nil,
		error = nil,
		refreshing = false,
		note = nil,
		fallbackKind = nil,
		browserOpen = false,
		loadError = nil,
		setupKey = text.newField(),
		setupError = nil,
		connecting = false,
		viewer = loadCachedViewer(),
		keySource = nil,
		onboarding = false,
		ruleText = "",
		targets = {},
		ruleError = nil,
		gen = 0,
	}
end

-- ─── Window requests ────────────────────────────────────────────────────────
-- A block cannot dock a browser or open a URL past the link routes; its window half can. The block asks by
-- opening an internal link the window's route claims. Deferred a beat so a brand-new pane is known there.

local function askWindow(state: any, op: string, params: { [string]: string })
	tern.timer(150, function()
		pcall(function()
			state.cx:open(links.command(op, params))
		end)
	end)
end

local function showBrowser(state: any)
	if state.url == nil then
		return
	end
	state.browserOpen = true
	askWindow(state, "browser", { pane = tostring(state.cx.pane), url = state.url })
end

local function hideBrowser(state: any)
	if not state.browserOpen then
		return
	end
	state.browserOpen = false
	askWindow(state, "unbrowser", { pane = tostring(state.cx.pane) })
end

-- ─── Rule text and targets ──────────────────────────────────────────────────

local function refreshRule(state: any)
	local viewer = state.viewer
	local workspace = if viewer ~= nil and viewer.urlKey ~= nil then viewer.urlKey else state.workspace
	local teamKey = if viewer ~= nil and viewer.teamKey ~= nil then viewer.teamKey else nil
	if teamKey == nil and state.ident ~= nil then
		teamKey = string.match(state.ident, "^(%a[%w]*)%-")
	end
	state.ruleText = rule.text(workspace, teamKey)
	state.targets = rule.targets()
end

-- Fills in the workspace key and a team key for the rule once, when a key is available.
local function fetchViewer(state: any)
	if state.viewer ~= nil then
		return
	end
	local cfg = credentials.resolve()
	if cfg == nil then
		return
	end
	api.viewer(cfg, function(viewer)
		if viewer ~= nil then
			state.viewer = viewer
			storeViewer(viewer)
			refreshRule(state)
			render(state)
		end
	end)
end

-- ─── Loading ────────────────────────────────────────────────────────────────

local function enterFallback(state: any, kind: string, note: string)
	state.phase = "fallback"
	state.fallbackKind = kind
	state.note = note
	state.refreshing = false
	showBrowser(state)
	render(state)
end

local function load(state: any)
	state.gen += 1
	local gen = state.gen
	state.error = nil
	state.loadError = nil
	if state.ident == nil then
		state.phase = "empty"
		render(state)
		return
	end
	local cfg, rejected = credentials.resolve()
	if cfg == nil then
		state.keySource = nil
		state.issue = nil
		enterFallback(state, "nokey", rejected or "No Linear API key yet. Showing it in a browser.")
		return
	end
	state.keySource = credentials.source()
	if state.issue ~= nil and state.issue.identifier ~= state.ident then
		state.issue = nil
	end
	if state.phase == "fallback" then
		hideBrowser(state)
	end
	if state.phase ~= "settings" and state.phase ~= "setup" then
		state.phase = if state.issue ~= nil then "ready" else "loading"
	end
	state.refreshing = true
	render(state)
	api.issue(cfg, state.ident, function(issue, err)
		if gen ~= state.gen then
			return
		end
		state.refreshing = false
		if issue ~= nil then
			state.issue = issue
			state.error = nil
			if state.phase == "loading" or state.phase == "ready" or state.phase == "fallback" then
				state.phase = "ready"
			end
			render(state)
			return
		end
		local message = if err ~= nil then err.message else "Could not load the issue."
		state.loadError = { kind = if err ~= nil then err.kind else "server", message = message }
		if state.phase == "settings" or state.phase == "setup" then
			render(state)
		elseif state.issue ~= nil then
			-- A refresh failed: keep what is on screen and say why.
			state.error = message
			render(state)
		else
			enterFallback(state, if err ~= nil and err.kind == "auth" then "nokey" else "error", message .. " Showing it in a browser.")
		end
	end)
end

local function navigate(state: any, url: string)
	local workspace, ident = links.parse(url)
	if ident == nil then
		return
	end
	state.url = url
	state.workspace = workspace
	state.ident = ident
	state.onboarding = false
	if state.phase == "settings" or state.phase == "setup" then
		state.phase = "loading"
	end
	load(state)
end

-- ─── Setup, settings ────────────────────────────────────────────────────────

local function focusSetupField(state: any)
	tern.timer(0, function()
		pcall(function()
			state.cx:frame({ { "focus", view.SETUP_FIELD_ID } })
		end)
	end)
end

local function enterSetup(state: any)
	hideBrowser(state)
	text.clearField(state.setupKey)
	state.setupError = nil
	state.ruleError = nil
	refreshRule(state)
	state.phase = "setup"
	render(state)
	focusSetupField(state)
end

local function enterSettings(state: any)
	state.keySource = credentials.source()
	refreshRule(state)
	state.ruleError = nil
	state.phase = "settings"
	fetchViewer(state)
	render(state)
end

-- Leaves setup or settings for whatever the block was showing.
local function leaveSettings(state: any)
	state.onboarding = false
	if state.issue ~= nil then
		state.phase = "ready"
		render(state)
	elseif state.loadError ~= nil then
		enterFallback(state, if state.loadError.kind == "auth" then "nokey" else "error", state.loadError.message .. " Showing it in a browser.")
	else
		load(state)
	end
end

local function connect(state: any)
	if state.connecting then
		return
	end
	local key = credentials.clean(state.setupKey.text)
	if key == "" then
		state.setupError = "Paste a Linear API key first."
		render(state)
		return
	end
	local endpoint, rejected = credentials.endpoint()
	if endpoint == nil then
		state.setupError = rejected
		render(state)
		return
	end
	state.connecting = true
	state.setupError = nil
	render(state)
	api.viewer({ key = key, endpoint = endpoint }, function(viewer, err)
		if viewer == nil then
			state.connecting = false
			state.setupError = if err ~= nil and err.kind == "auth" then "Linear rejected the API key." else (if err ~= nil then err.message else "Could not reach Linear.")
			render(state)
			return
		end
		credentials.save(key, function(ok, reason)
			state.connecting = false
			if not ok then
				state.setupError = reason or "Could not store the API key."
				render(state)
				return
			end
			state.viewer = viewer
			storeViewer(viewer)
			text.clearField(state.setupKey)
			state.setupError = nil
			state.onboarding = true
			state.phase = "settings"
			load(state)
			state.keySource = credentials.source()
			refreshRule(state)
			render(state)
		end)
	end)
end

local function signOut(state: any)
	if state.keySource ~= "file" then
		return
	end
	local cleared, reason = credentials.clear()
	if not cleared then
		state.ruleError = reason
		render(state)
		return
	end
	state.issue = nil
	state.viewer = nil
	pcall(tern.kv.set, VIEWER_KEY, nil)
	state.keySource = nil
	state.phase = "loading"
	load(state)
end

local function ruleFile(state: any, index: string?, adding: boolean)
	local target = state.targets[tonumber(index or "") or 0]
	if target == nil then
		return
	end
	local ok, reason
	if adding then
		ok, reason = rule.add(target.path, state.ruleText)
	else
		ok, reason = rule.remove(target.path)
	end
	state.ruleError = if ok then nil else reason
	state.targets = rule.targets()
	render(state)
end

-- ─── Events ─────────────────────────────────────────────────────────────────

local function onAction(state: any, ev: any)
	local act, value = ev.act, ev.value
	if act == "goto" then
		if type(value) == "string" then
			navigate(state, value)
		end
	elseif act == "refresh" then
		load(state)
	elseif act == "open" then
		if state.url ~= nil then
			-- The window half opens it past the link routes, in Tern's own browser handling.
			state.cx:open(links.command("open", { url = state.url }))
		end
	elseif act == "copy" then
		if state.url ~= nil then
			state.cx:copy(state.url)
			state.cx:toast("success", "Link copied")
		end
	elseif act == "settings" then
		enterSettings(state)
	elseif act == "setup" then
		enterSetup(state)
	elseif act == "back" then
		leaveSettings(state)
	elseif act == "connect" then
		connect(state)
	elseif act == "signout" then
		signOut(state)
	elseif act == "rule-copy" then
		state.cx:copy(state.ruleText)
		state.cx:toast("success", "Agent rule copied")
	elseif act == "rule-add" then
		ruleFile(state, if type(value) == "string" then value else nil, true)
	elseif act == "rule-remove" then
		ruleFile(state, if type(value) == "string" then value else nil, false)
	end
end

local function handleEvent(state: any, ev: any, _cx: any)
	if ev.ev == "action" then
		onAction(state, ev)
	elseif ev.ev == "edit" and ev.id == view.SETUP_FIELD_ID then
		if text.applyEdit(state.setupKey, ev) then
			state.setupError = nil
		end
	end
end

local function handleKey(state: any, key: any, _cx: any): boolean?
	if state.phase ~= "setup" then
		return false
	end
	if key.name == "enter" then
		connect(state)
		return true
	end
	if text.applyKey(state.setupKey, key) then
		state.setupError = nil
		return true
	end
	return false
end

-- ─── Block definition ───────────────────────────────────────────────────────

local def: any = {
	font = "sans",
	features = { "edit" },
	init = function(cx, args, saved)
		local url = args[1]
		if url == nil and type(saved) == "table" then
			url = saved.url
		end
		local state = newState(cx, url)
		if state.ident ~= nil then
			load(state)
		end
		return state
	end,
	view = function(state, _cx)
		return view.render(state)
	end,
	title = function(state)
		if state.ident ~= nil then
			return "Linear · " .. state.ident
		end
		return "Linear issue"
	end,
	key = handleKey,
	event = handleEvent,
	save = function(state)
		return { url = state.url }
	end,
}

controller.def = def

return controller
