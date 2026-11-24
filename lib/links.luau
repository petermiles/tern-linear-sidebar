-- Recognises Linear issue links and builds the plugin's internal command links.
-- Shared by both halves; pure string work, no `tern` calls.

local links = {}

-- `https://linear.app/<workspace>/issue/<IDENT>[/<slug>][?query][#fragment]` -> workspace, IDENT.
-- IDENT is upper-cased (`abc-12` -> `ABC-12`), which is how Linear's API wants it.
function links.parse(url: string): (string?, string?)
	if type(url) ~= "string" then
		return nil, nil
	end
	local rest = string.match(url, "^[Hh][Tt][Tt][Pp][Ss]?://(.*)$")
	if rest == nil then
		return nil, nil
	end
	local host, path = string.match(rest, "^([^/?#]+)(/[^?#]*)")
	if host == nil or path == nil or string.lower(host) ~= "linear.app" then
		return nil, nil
	end
	local workspace, team, number, tail = string.match(path, "^/([^/]+)/issue/(%a[%w]*)%-(%d+)(.*)$")
	if workspace == nil or team == nil or number == nil or tail == nil then
		return nil, nil
	end
	if tail ~= "" and string.sub(tail, 1, 1) ~= "/" then
		return nil, nil
	end
	return workspace, string.upper(team) .. "-" .. number
end

-- Percent-encodes everything but unreserved characters.
function links.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function links.decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16) :: number)
	end))
end

-- The block asks its window half to do things only a window can (dock a browser, open a URL past the
-- link routes) by opening a `tern-linear-sidebar:<op>?k=v&...` link, which the window's route claims.
local SCHEME = "tern-linear-sidebar:"

function links.command(op: string, params: { [string]: string }): string
	local keys = {}
	for key in params do
		table.insert(keys, key)
	end
	table.sort(keys)
	local pairs_ = {}
	for _, key in keys do
		table.insert(pairs_, key .. "=" .. links.encode(params[key]))
	end
	return SCHEME .. op .. "?" .. table.concat(pairs_, "&")
end

function links.parseCommand(url: string): (string?, { [string]: string }?)
	if string.sub(url, 1, #SCHEME) ~= SCHEME then
		return nil, nil
	end
	local op, query = string.match(string.sub(url, #SCHEME + 1), "^([%w%-]+)%??(.*)$")
	if op == nil then
		return nil, nil
	end
	local params: { [string]: string } = {}
	for key, value in string.gmatch(query or "", "([^&=]+)=([^&]*)") do
		params[key] = links.decode(value)
	end
	return op, params
end

return links
