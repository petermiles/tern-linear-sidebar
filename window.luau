-- Window half: claims Linear issue links and keeps one read-only sidebar per tab.
--
-- The sidebar slot is shared with the github-sidebar plugin: a tab holds at most one block of either kind.
-- A click while the slot holds this plugin's block re-points it; while it holds the other plugin's block,
-- this one takes its place; otherwise the block opens to the right of the pane that held the link.

local links = require("./lib/links")

local THIS = "linear-sidebar.view"
local OTHER = "github-sidebar.view"
local RATIO = 0.38
-- Cells the docked fallback browser grows by, so the explanatory block above it stays a short strip.
local BROWSER_GROWTH = 14

-- sidebar pane id -> the browser pane docked under it while Linear data is unavailable. Kept in the plugin's
-- kv so a reload or a restart (which re-opens the block and asks again) finds the browser it already docked
-- instead of docking a second one. Pane ids are stable across both.
local BROWSERS_KEY = "browsers"

local function trackedBrowser(owner: number): number?
	local map: any = tern.kv.get(BROWSERS_KEY)
	if type(map) ~= "table" then
		return nil
	end
	local block = map[tostring(owner)]
	return if type(block) == "number" then block else nil
end

local function track(owner: number, block: number?)
	local map: any = tern.kv.get(BROWSERS_KEY)
	if type(map) ~= "table" then
		map = {}
	end
	map[tostring(owner)] = block
	tern.kv.set(BROWSERS_KEY, map)
end

-- The GitHub plugin docks a plain browser on a pull request page where its block was when `gh` is not
-- available; that browser holds the sidebar slot too.
local function isGithubFallback(info: any): boolean
	return info.kind == "browser"
		and type(info.url) == "string"
		and string.sub(info.url, 1, 19) == "https://github.com/"
		and string.find(info.url, "/pull/", 1, true) ~= nil
end

local function slotIn(cx: any, pane: number): any?
	local tab = cx.session:tab_of(pane)
	if tab == nil then
		return nil
	end
	local found: any? = nil
	local fallback: any? = nil
	for _, info in cx.session:panes() do
		if info.tab == tab then
			local isBlock = info.kind == "plugin" and (info.block == THIS or info.block == OTHER)
			if isBlock or isGithubFallback(info) then
				-- The pane that held the click wins when it is itself a sidebar.
				if info.pane == pane then
					return info
				end
				if isBlock then
					found = found or info
				else
					fallback = fallback or info
				end
			end
		end
	end
	return found or fallback
end

local function claim(req: any, cx: any): any?
	local slot = slotIn(cx, req.pane)
	if slot ~= nil and slot.block == THIS then
		cx.session:event(slot.pane, { ev = "action", id = "main", act = "goto", value = req.url })
		return { handled = true }
	end
	if slot ~= nil then
		-- The other plugin's block: take its slot, then close it.
		local replacement = cx:new_block(THIS, { req.url }, "over", { target = slot.pane, focus = false })
		if replacement == nil then
			return nil
		end
		cx.layout:close(slot.pane)
		return { handled = true }
	end
	local opened = cx:new_block(THIS, { req.url }, "beside", { target = req.pane, dir = "right", ratio = RATIO, focus = false })
	if opened == nil then
		return nil
	end
	return { handled = true }
end

local function paneExists(cx: any, pane: number, kind: string): boolean
	local info = cx.session:pane(pane)
	return info ~= nil and info.kind == kind
end

-- Shows `url` in a browser docked below the sidebar block `owner` (reusing the one already there).
local function dockBrowser(cx: any, owner: number, url: string)
	local existing = trackedBrowser(owner)
	if existing ~= nil and paneExists(cx, existing, "browser") then
		cx.browser:call({ op = "goto", block = existing, url = url })
		return
	end
	track(owner, nil)
	local before = cx.session:focused()
	cx.browser:call({ op = "open", owner = owner, url = url }):next(function(res: any, _err: any, cx2: any)
		local block = if res ~= nil and res.ok ~= nil then res.ok.block else nil
		if cx2 == nil or block == nil then
			return
		end
		track(owner, block)
		cx2.layout:move(block, owner, "down", { focus = false })
		cx2.layout:resize(block, "up", BROWSER_GROWTH)
		if before ~= nil then
			cx2.layout:focus(before)
		end
	end)
end

local function closeBrowser(cx: any, owner: number)
	local block = trackedBrowser(owner)
	track(owner, nil)
	if block ~= nil and paneExists(cx, block, "browser") then
		cx.layout:close(block)
	end
end

local function runCommand(op: string, params: { [string]: string }, cx: any): any?
	if op == "browser" then
		local owner = tonumber(params.pane or "")
		if owner ~= nil and params.url ~= nil then
			dockBrowser(cx, owner, params.url)
		end
	elseif op == "unbrowser" then
		local owner = tonumber(params.pane or "")
		if owner ~= nil then
			closeBrowser(cx, owner)
		end
	elseif op == "open" then
		if params.url ~= nil then
			-- `cx:open` from a window skips the link routes: Tern's own handling of the URL.
			cx:open(params.url)
		end
	end
	return { handled = true }
end

tern.route.link(function(req: any, cx: any)
	local op, params = links.parseCommand(req.url)
	if op ~= nil and params ~= nil then
		return runCommand(op, params, cx)
	end
	-- Alt hands the click back to Tern's built-in handling.
	if req.mods.alt then
		return nil
	end
	local _, ident = links.parse(req.url)
	if ident == nil then
		return nil
	end
	return claim(req, cx)
end)

-- A sidebar that closes takes its fallback browser with it.
tern.on("pane_closed", function(ev: any, cx: any)
	if trackedBrowser(ev.pane) ~= nil then
		closeBrowser(cx, ev.pane)
	end
end)
