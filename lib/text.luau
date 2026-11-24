-- Text helpers (host half): an editable field Tern draws from `text`/`cursor`/`anchor` in UTF-16 units,
-- Markdown clean-up for Linear's description and comments, and relative timestamps.

local text = {}

-- ─── Editable field ─────────────────────────────────────────────────────────

export type Field = { text: string, cursor: number, anchor: number? }

local function width(codepoint: number): number
	return if codepoint > 0xFFFF then 2 else 1
end

function text.len16(s: string): number
	local n = 0
	for _, cp in utf8.codes(s) do
		n += width(cp)
	end
	return n
end

-- Byte index of the code point starting at UTF-16 offset `units`; #s + 1 past the end.
local function byteAt(s: string, units: number): number
	local acc = 0
	for pos, cp in utf8.codes(s) do
		local w = width(cp)
		if acc + w > units then
			return pos
		end
		acc += w
	end
	return #s + 1
end

local function clamp(value: number, low: number, high: number): number
	return math.max(low, math.min(high, value))
end

function text.newField(): Field
	return { text = "", cursor = 0, anchor = nil }
end

function text.clearField(f: Field)
	f.text = ""
	f.cursor = 0
	f.anchor = nil
end

-- Applies an `edit` event (`from`, `to`, `text`, `len`, optional `cursor`); false when it does not match the
-- field's current content (a stale event).
function text.applyEdit(f: Field, ev: { [string]: any }): boolean
	local from, to, inserted, len = ev.from, ev.to, ev.text, ev.len
	if type(from) ~= "number" or type(to) ~= "number" or type(inserted) ~= "string" or type(len) ~= "number" then
		return false
	end
	if len ~= text.len16(f.text) then
		return false
	end
	local low = clamp(math.min(from, to), 0, len)
	local high = clamp(math.max(from, to), 0, len)
	f.text = string.sub(f.text, 1, byteAt(f.text, low) - 1) .. inserted .. string.sub(f.text, byteAt(f.text, high))
	local newLen = text.len16(f.text)
	local cursor = ev.cursor
	f.cursor = clamp(if type(cursor) == "number" then cursor else low + text.len16(inserted), 0, newLen)
	f.anchor = nil
	return true
end

local function splice(f: Field, from: number, to: number, inserted: string)
	f.text = string.sub(f.text, 1, byteAt(f.text, from) - 1) .. inserted .. string.sub(f.text, byteAt(f.text, to))
	f.cursor = from + text.len16(inserted)
	f.anchor = nil
end

-- UTF-16 offsets of the code point boundary before and the one after `units`.
local function neighbours(s: string, units: number): (number, number)
	local previous, after, acc = 0, text.len16(s), 0
	for _, cp in utf8.codes(s) do
		local w = width(cp)
		if acc < units then
			previous = acc
		end
		if acc >= units then
			after = acc + w
			break
		end
		acc += w
	end
	return previous, after
end

-- Applies a key press to the field (typed text, paste, backspace, delete, arrows); false when it is none
-- of those. Used where Tern delivers keystrokes as `key` events instead of `edit` events.
function text.applyKey(f: Field, key: { [string]: any }): boolean
	local len = text.len16(f.text)
	local cursor = clamp(f.cursor, 0, len)
	local low, high = cursor, cursor
	if f.anchor ~= nil and f.anchor ~= cursor then
		low, high = math.min(f.anchor, cursor), math.max(f.anchor, cursor)
	end
	local typed = key.text
	if key.name == "paste" and type(typed) == "string" then
		splice(f, low, high, (string.gsub(typed, "[\r\n]", "")))
		return true
	end
	if type(typed) == "string" and typed ~= "" and not key.ctrl and not key.alt and not key.meta then
		splice(f, low, high, typed)
		return true
	end
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local previous, after = neighbours(f.text, cursor)
	if key.name == "backspace" then
		if low ~= high then
			splice(f, low, high, "")
		elseif cursor > 0 then
			splice(f, previous, cursor, "")
		end
		return true
	elseif key.name == "delete" then
		if low ~= high then
			splice(f, low, high, "")
		elseif cursor < len then
			splice(f, cursor, after, "")
		end
		return true
	elseif key.name == "left" then
		f.cursor = if low ~= high then low else previous
		f.anchor = nil
		return true
	elseif key.name == "right" then
		f.cursor = if low ~= high then high else math.min(after, len)
		f.anchor = nil
		return true
	elseif key.name == "home" then
		f.cursor, f.anchor = 0, nil
		return true
	elseif key.name == "end" then
		f.cursor, f.anchor = len, nil
		return true
	end
	return false
end

-- ─── Markdown ───────────────────────────────────────────────────────────────

local MAX_MARKDOWN_BYTES = 6000

-- Linear markdown may carry images (the renderer would fetch them) and raw HTML. Images become links
-- labelled "image: <alt>"; text inside fenced code is left alone. Long text is cut on a line boundary,
-- closing a fence that the cut left open.
function text.cleanMarkdown(source: string): string
	local out = {}
	local fence: string? = nil
	local used = 0
	local cut = false
	for line in string.gmatch(source .. "\n", "(.-)\n") do
		if used + #line > MAX_MARKDOWN_BYTES then
			cut = true
			break
		end
		local marker = string.match(line, "^%s*(```+)") or string.match(line, "^%s*(~~~+)")
		local converted = line
		if marker ~= nil then
			if fence == nil then
				fence = string.sub(marker, 1, 1)
			elseif string.sub(marker, 1, 1) == fence then
				fence = nil
			end
		elseif fence == nil then
			converted = string.gsub(line, "!%[([^%]]*)%]%(", function(alt)
				return "[image: " .. (if alt ~= "" then alt else "attachment") .. "]("
			end)
		end
		table.insert(out, converted)
		used += #line + 1
	end
	if cut then
		if fence ~= nil then
			table.insert(out, string.rep(fence, 3))
		end
		table.insert(out, "")
		table.insert(out, "… (cut; open in the browser for the rest)")
	end
	return table.concat(out, "\n")
end

-- ─── Time ───────────────────────────────────────────────────────────────────

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function epochOf(iso: string): number?
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if y == nil then
		return nil
	end
	return daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ (tonumber(s) :: number)
end

-- "just now", "5m ago", "3h ago", "2d ago", else the date.
function text.ago(iso: string, now: number): string
	local then_ = epochOf(iso)
	if then_ == nil then
		return ""
	end
	local seconds = now - then_
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m ago"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. "h ago"
	elseif seconds < 30 * 86400 then
		return math.floor(seconds / 86400) .. "d ago"
	end
	return string.sub(iso, 1, 10)
end

return text
