local Input = {}

-- Editing positions are code-point boundaries; only the view uses UTF-16.
local function byteAt(text, position)
	return utf8.offset(text, position + 1) or (#text + 1)
end

function Input.valid(text)
	local ok, length = pcall(utf8.len, text)
	if not ok or length == nil then
		return false
	end
	for _, code in utf8.codes(text) do
		if code < 32 or (code >= 127 and code <= 159) or code == 0x2028 or code == 0x2029 then
			return false
		end
	end
	return true
end

function Input.new(text)
	text = text or ""
	if not Input.valid(text) then
		text = ""
	end
	return { text = text, cursor = utf8.len(text), anchor = nil }
end

local function utf16(text, position)
	local units, count = 0, 0
	for _, code in utf8.codes(text) do
		if count >= position then
			break
		end
		units += if code > 0xFFFF then 2 else 1
		count += 1
	end
	return units
end

function Input.props(field)
	return {
		text = field.text,
		cursor = utf16(field.text, field.cursor),
		anchor = if field.anchor ~= nil then utf16(field.text, field.anchor) else nil,
	}
end

local function bounds(field)
	local anchor = field.anchor or field.cursor
	return math.min(anchor, field.cursor), math.max(anchor, field.cursor)
end

function Input.selection(field)
	local first, last = bounds(field)
	return string.sub(field.text, byteAt(field.text, first), byteAt(field.text, last) - 1)
end

local function replace(field, text)
	local first, last = bounds(field)
	field.text = string.sub(field.text, 1, byteAt(field.text, first) - 1)
		.. text .. string.sub(field.text, byteAt(field.text, last))
	field.cursor = first + utf8.len(text)
	field.anchor = nil
end

local function move(field, position, shift)
	if shift then
		field.anchor = field.anchor or field.cursor
	else
		field.anchor = nil
	end
	field.cursor = position
end

function Input.key(field, key)
	local length = utf8.len(field.text)
	if key.meta and string.lower(key.name) == "a" then
		field.anchor, field.cursor = 0, length
	elseif key.name == "home" or (key.meta and key.name == "left") then
		move(field, 0, key.shift)
	elseif key.name == "end" or (key.meta and key.name == "right") then
		move(field, length, key.shift)
	elseif key.name == "left" or key.name == "right" then
		local first, last = bounds(field)
		local position
		if not key.shift and first ~= last then
			position = if key.name == "left" then first else last
		else
			position = math.clamp(field.cursor + (if key.name == "left" then -1 else 1), 0, length)
		end
		move(field, position, key.shift)
	elseif key.name == "backspace" or key.name == "delete" then
		local first, last = bounds(field)
		if first == last then
			field.anchor = if key.name == "backspace" then math.max(0, field.cursor - 1)
				else math.min(length, field.cursor + 1)
		end
		replace(field, "")
	elseif key.text and (key.name == "paste" or not (key.ctrl or key.meta)) then
		if not Input.valid(key.text) then
			return true, "Use a single line without control characters."
		end
		replace(field, key.text)
	else
		return false
	end
	return true
end

return Input
