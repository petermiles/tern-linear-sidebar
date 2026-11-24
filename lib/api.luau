-- Linear GraphQL client (host half). Every function is asynchronous and calls its callback exactly once
-- with (result, nil) or (nil, error). Neither the key nor the request ever reaches a message or a log.

local api = {}

export type ApiError = { kind: "auth" | "notfound" | "rate" | "network" | "server", message: string }

export type Comment = { body: string, author: string?, createdAt: string }
export type Attachment = { title: string, url: string, subtitle: string? }
export type Issue = {
	identifier: string,
	title: string,
	url: string,
	description: string?,
	stateName: string?,
	stateType: string?,
	stateColor: string?,
	assignee: string?,
	priority: number,
	priorityLabel: string?,
	project: string?,
	parent: { identifier: string, title: string, url: string }?,
	attachments: { Attachment },
	comments: { Comment },
}
export type Viewer = { name: string?, urlKey: string?, orgName: string?, teamKey: string? }

local REQUEST_TIMEOUT_MS = 20000

local ISSUE_QUERY = [[
query Issue($id: String!) {
  issue(id: $id) {
    identifier
    title
    url
    description
    priority
    priorityLabel
    state { name type color }
    assignee { name }
    project { name }
    parent { identifier title url }
    attachments(first: 25) { nodes { title url subtitle } }
    comments(last: 5) { nodes { body createdAt user { name } } }
  }
}
]]

local VIEWER_QUERY = [[
query Viewer {
  viewer {
    name
    organization { name urlKey }
    teams(first: 1) { nodes { key } }
  }
}
]]

local function failure(kind: string, message: string): ApiError
	return { kind = kind, message = message } :: any
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function nodes(connection: any): { any }
	if type(connection) == "table" and type(connection.nodes) == "table" then
		return connection.nodes
	end
	return {}
end

local function authorization(key: string): string
	if string.sub(key, 1, 10) == "lin_oauth_" then
		return "Bearer " .. key
	end
	return key
end

-- Turns an HTTP response into `data` or an ApiError.
local function classify(res: any): (any?, ApiError?)
	if res.error ~= nil then
		if res.timed_out then
			return nil, failure("network", "Linear did not respond in time.")
		end
		return nil, failure("network", "Could not reach Linear. Check your connection.")
	end
	local status: number = res.status
	local decoded, doc = pcall(tern.json.decode, res.body)
	if not decoded or type(doc) ~= "table" then
		doc = nil
	end
	if status == 401 then
		return nil, failure("auth", "Linear rejected the API key. Check that it is valid and has not been revoked.")
	end
	if status == 429 then
		return nil, failure("rate", "Linear rate limit reached. Try again in a minute.")
	end
	local errors = if doc ~= nil and type(doc.errors) == "table" then doc.errors else nil
	if errors ~= nil and errors[1] ~= nil then
		local entry: any = errors[1]
		local ext: any = if type(entry) == "table" and type(entry.extensions) == "table" then entry.extensions else {}
		local code = str(ext.code) or ""
		local raw = if type(entry) == "table" then str(entry.message) or "" else ""
		local friendly = str(ext.userPresentableMessage) or raw
		if code == "RATELIMITED" then
			return nil, failure("rate", "Linear rate limit reached. Try again in a minute.")
		end
		if code == "AUTHENTICATION_ERROR" or code == "FORBIDDEN" then
			return nil, failure("auth", "Linear rejected the API key or it may not read this workspace.")
		end
		if code == "ENTITY_NOT_FOUND" or string.find(string.lower(raw), "not found", 1, true) ~= nil then
			return nil, failure("notfound", "Linear can't find that issue with this key.")
		end
		return nil, failure("server", if friendly ~= "" then "Linear error: " .. friendly else "Linear returned an error.")
	end
	if status >= 400 or doc == nil then
		return nil, failure("server", "Linear returned HTTP " .. tostring(status) .. ".")
	end
	return doc.data, nil
end

local function post(
	cfg: { key: string, endpoint: string },
	operation: string,
	query: string,
	variables: { [string]: any }?,
	cb: (data: any?, err: ApiError?) -> ()
)
	local body: { [string]: any } = { query = query, operationName = operation }
	if variables ~= nil then
		body.variables = variables
	end
	local sent = pcall(function()
		tern.fetch(cfg.endpoint, {
			method = "POST",
			headers = { ["Content-Type"] = "application/json", Authorization = authorization(cfg.key) },
			body = tern.json.encode(body),
			timeout_ms = REQUEST_TIMEOUT_MS,
		}, function(res)
			local data, err = classify(res)
			cb(data, err)
		end)
	end)
	if not sent then
		cb(nil, failure("network", "Could not send the request. Check the Linear API URL."))
	end
end

local function normalizeIssue(raw: any): Issue?
	if type(raw) ~= "table" then
		return nil
	end
	local identifier, title, url = str(raw.identifier), str(raw.title), str(raw.url)
	if identifier == nil or title == nil or url == nil then
		return nil
	end
	local state: any = if type(raw.state) == "table" then raw.state else {}
	local parent: any = raw.parent
	local issue: Issue = {
		identifier = identifier,
		title = title,
		url = url,
		description = str(raw.description),
		stateName = str(state.name),
		stateType = str(state.type),
		stateColor = str(state.color),
		assignee = if type(raw.assignee) == "table" then str(raw.assignee.name) else nil,
		priority = if type(raw.priority) == "number" then raw.priority else 0,
		priorityLabel = str(raw.priorityLabel),
		project = if type(raw.project) == "table" then str(raw.project.name) else nil,
		parent = nil,
		attachments = {},
		comments = {},
	}
	if type(parent) == "table" and str(parent.identifier) ~= nil and str(parent.url) ~= nil then
		issue.parent = {
			identifier = parent.identifier,
			title = str(parent.title) or "",
			url = parent.url,
		}
	end
	for _, node in nodes(raw.attachments) do
		if type(node) == "table" and str(node.url) ~= nil then
			table.insert(issue.attachments, {
				title = str(node.title) or node.url,
				url = node.url,
				subtitle = str(node.subtitle),
			})
		end
	end
	for _, node in nodes(raw.comments) do
		if type(node) == "table" and str(node.body) ~= nil then
			table.insert(issue.comments, {
				body = node.body,
				author = if type(node.user) == "table" then str(node.user.name) else nil,
				createdAt = str(node.createdAt) or "",
			})
		end
	end
	-- ISO-8601 timestamps sort as text; show the oldest of the latest comments first.
	table.sort(issue.comments, function(a, b)
		return a.createdAt < b.createdAt
	end)
	return issue
end

function api.issue(cfg: { key: string, endpoint: string }, identifier: string, cb: (Issue?, ApiError?) -> ())
	post(cfg, "Issue", ISSUE_QUERY, { id = identifier }, function(data, err)
		if err ~= nil then
			cb(nil, err)
			return
		end
		local raw: any = if type(data) == "table" then data.issue else nil
		local issue = normalizeIssue(raw)
		if issue == nil then
			cb(nil, failure("notfound", "Linear can't find that issue with this key."))
			return
		end
		cb(issue, nil)
	end)
end

function api.viewer(cfg: { key: string, endpoint: string }, cb: (Viewer?, ApiError?) -> ())
	post(cfg, "Viewer", VIEWER_QUERY, nil, function(data, err)
		if err ~= nil then
			cb(nil, err)
			return
		end
		local raw: any = if type(data) == "table" then data.viewer else nil
		if type(raw) ~= "table" then
			cb(nil, failure("server", "Linear sent a response this plugin could not read."))
			return
		end
		local org: any = if type(raw.organization) == "table" then raw.organization else {}
		local firstTeam: any = nodes(raw.teams)[1]
		cb({
			name = str(raw.name),
			urlKey = str(org.urlKey),
			orgName = str(org.name),
			teamKey = if type(firstTeam) == "table" then str(firstTeam.key) else nil,
		}, nil)
	end)
end

return api
