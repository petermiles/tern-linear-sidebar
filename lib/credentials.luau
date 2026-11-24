-- Where the Linear API key comes from (host half only).
--
-- `LINEAR_API_KEY` in the Tern daemon's environment always wins and is never stored. Otherwise a key
-- pasted on the setup screen lives in `<plugin data>/credentials.json`, created owner-only (file 600,
-- directory 700) in one shell command so it is never world-readable, not even briefly. The key travels on
-- stdin, never in argv, and nothing here logs it.

local credentials = {}

local DEFAULT_ENDPOINT = "https://api.linear.app/graphql"
local MAX_KEY_FILE_BYTES = 16384
local SAVE_TIMEOUT_MS = 5000

export type Config = { key: string, endpoint: string }

local function keyFilePath(): string
	return tern.plugin.data .. "/credentials.json"
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) or ""
end

local function nonEmpty(s: string?): string?
	if s == nil then
		return nil
	end
	local trimmed = trim(s)
	return if trimmed == "" then nil else trimmed
end

local function envKey(): string?
	return nonEmpty(tern.getenv("LINEAR_API_KEY"))
end

-- A missing, unreadable or corrupt file all mean "no key".
local function fileKey(): string?
	local path = keyFilePath()
	local existsOk, exists = pcall(tern.fs.exists, path)
	if not existsOk or not exists then
		return nil
	end
	local readOk, raw = pcall(tern.fs.read, path, MAX_KEY_FILE_BYTES)
	if not readOk then
		return nil
	end
	local decodeOk, doc = pcall(tern.json.decode, raw)
	if not decodeOk or type(doc) ~= "table" or type(doc.apiKey) ~= "string" then
		return nil
	end
	return nonEmpty(doc.apiKey)
end

local LOCAL_HOSTS = { ["127.0.0.1"] = true, ["localhost"] = true, ["[::1]"] = true }

local function allowedEndpoint(url: string): boolean
	if url == DEFAULT_ENDPOINT then
		return true
	end
	if string.find(url, "[%s%c\\]") ~= nil then
		return false
	end
	local scheme, authority = string.match(url, "^(%a+)://([^/?#]*)")
	if scheme == nil or authority == nil then
		return false
	end
	scheme = string.lower(scheme)
	if (scheme ~= "http" and scheme ~= "https") or string.find(authority, "@", 1, true) ~= nil then
		return false
	end
	local host, port = string.match(authority, "^(%[[%x:]+%])(.*)$")
	if host == nil then
		host, port = string.match(authority, "^([^:]*)(.*)$")
	end
	if host == nil or port == nil or LOCAL_HOSTS[string.lower(host)] ~= true then
		return false
	end
	return port == "" or string.match(port, "^:%d+$") ~= nil
end

-- Linear's endpoint, or `LINEAR_API_URL` when it points at this machine (for tests and proxies). Any other
-- override is refused so a hostile environment cannot redirect the key; the message never echoes it.
function credentials.endpoint(): (string?, string?)
	local url = nonEmpty(tern.getenv("LINEAR_API_URL"))
	if url == nil then
		return DEFAULT_ENDPOINT, nil
	end
	if not allowedEndpoint(url) then
		return nil,
			"LINEAR_API_URL is not an allowed endpoint, so the API key was not sent. "
				.. "Use https://api.linear.app/graphql or a local http(s) address."
	end
	return url, nil
end

-- The key and its endpoint; nil when there is no key (second value: why a key was withheld).
function credentials.resolve(): (Config?, string?)
	local key = envKey() or fileKey()
	if key == nil then
		return nil, nil
	end
	local endpoint, rejected = credentials.endpoint()
	if endpoint == nil then
		return nil, rejected
	end
	return { key = key, endpoint = endpoint }, nil
end

function credentials.source(): ("env" | "file")?
	if envKey() ~= nil then
		return "env"
	end
	if fileKey() ~= nil then
		return "file"
	end
	return nil
end

function credentials.clean(raw: string): string
	return trim(raw)
end

-- Creates the data directory (700) and the key file (600) in one shell. $1 is the key file, $2 the directory.
local POSIX_SAVE_SCRIPT =
	'umask 077 && mkdir -p "$2" && chmod 700 "$2" && cat > "$1.tmp" && mv -f "$1.tmp" "$1" && chmod 600 "$1"'

-- `cb(true)` once the key is on disk; `cb(false, message)` otherwise. The message never contains the key.
function credentials.save(key: string, cb: (ok: boolean, err: string?) -> ())
	local trimmed = trim(key)
	if trimmed == "" then
		cb(false, "Paste a Linear API key first.")
		return
	end
	local path = keyFilePath()
	local dir = tern.plugin.data
	local body = tern.json.encode({ apiKey = trimmed })

	if tern.runtime.os == "windows" then
		local written = pcall(function()
			tern.fs.mkdir(dir)
			tern.fs.write(path, body)
		end)
		if written then
			cb(true, nil)
		else
			cb(false, "Could not save the API key in the plugin data directory.")
		end
		return
	end

	local mkdirOk = pcall(tern.fs.mkdir, dir)
	if not mkdirOk then
		cb(false, "Could not create the plugin data directory.")
		return
	end
	local started, startError = pcall(function()
		tern.process.run(
			{ "/bin/sh", "-c", POSIX_SAVE_SCRIPT, "sh", path, dir },
			{ stdin = body, timeout_ms = SAVE_TIMEOUT_MS },
			function(result)
				if result.status == 0 then
					cb(true, nil)
				else
					cb(false, "Could not save the key (exit " .. tostring(result.status) .. ").")
				end
			end
		)
	end)
	if not started then
		cb(false, "Could not save the key: " .. tostring(startError))
	end
end

-- Removes the stored key; false and a message when the file is still there afterwards.
function credentials.clear(): (boolean, string?)
	local path = keyFilePath()
	pcall(function()
		if tern.fs.exists(path) then
			tern.fs.remove(path)
		end
	end)
	local existsOk, exists = pcall(tern.fs.exists, path)
	if not existsOk or exists then
		return false, "Could not delete the stored key at " .. path .. "."
	end
	return true, nil
end

return credentials
