--!strict
--!native
--!optimize 2

--[=[
	FuzzySearch: filters names by typed text, best match first, and forgives a few typos when no name holds the text. A
	lower score is a better match

	Return type: the FuzzySearch module table
	Example usage:
		local Order = FuzzySearch.Search("sah256", Names)
--]=]

local TIER = 4096
local EXACT = 0
local BEGINS = 1 * TIER
local HOLDS = 2 * TIER
local IN_ORDER = 3 * TIER
local NEAR_MISS = 4 * TIER

local MID_WORD = TIER / 2
local PER_EDIT = 256

local ONE_EDIT_FROM = 3
local TWO_EDITS_FROM = 8
local LONGEST_NEAR_MISS = 32

local OTHER = 0
local LOWER = 1
local UPPER = 2
local DIGIT = 3

local MASKS = buffer.create(256 * 4)

local FuzzySearch = {}

local function EditLimit(Length: number): number
	if Length < ONE_EDIT_FROM or Length > LONGEST_NEAR_MISS then
		return 0
	end
	return if Length < TWO_EDITS_FROM then 1 else 2
end

local function ClassOf(Byte: number): number
	if Byte >= 97 and Byte <= 122 or Byte >= 128 then
		return LOWER
	elseif Byte >= 65 and Byte <= 90 then
		return UPPER
	elseif Byte >= 48 and Byte <= 57 then
		return DIGIT
	end
	return OTHER
end

local function StartsWord(Before: number, Here: number): boolean
	if Here == OTHER then
		return false
	end
	if Before == OTHER then
		return true
	end
	if Here == UPPER then
		return Before ~= UPPER
	end
	return (Here == DIGIT) ~= (Before == DIGIT)
end

local function InOrderSpan(Text: string, TextLength: number, Name: string, NameLength: number): number?
	local Matched = 0
	local Last = 0
	while Matched < TextLength do
		Last += 1
		if Last > NameLength then
			return nil
		end
		if string.byte(Name, Last) == string.byte(Text, Matched + 1) then
			Matched += 1
		end
	end

	local First = Last
	local Unmatched = TextLength
	while Unmatched > 0 do
		if string.byte(Name, First) == string.byte(Text, Unmatched) then
			Unmatched -= 1
		end
		First -= 1
	end
	return Last - First
end

local function MatchScore(Text: string, TextLength: number, Name: string, Lowered: string): number?
	local NameLength = string.len(Lowered)

	local Found = string.find(Lowered, Text, 1, true)
	if Found == 1 then
		return if NameLength == TextLength then EXACT else BEGINS + math.min(NameLength - TextLength, TIER - 1)
	end
	if Found then
		local At: number? = Found
		while At do
			if StartsWord(ClassOf(string.byte(Name, At - 1)), ClassOf(string.byte(Name, At))) then
				return HOLDS + math.min(At, MID_WORD - 1)
			end
			At = string.find(Lowered, Text, At + 1, true)
		end
		return HOLDS + MID_WORD + math.min(Found, MID_WORD - 1)
	end

	local Span = InOrderSpan(Text, TextLength, Lowered, NameLength)
	if Span then
		return IN_ORDER + math.min(Span - TextLength, TIER - 1)
	end
	return nil
end

local function SetMasks(Text: string, TextLength: number)
	local Masks = MASKS
	buffer.fill(Masks, 0, 0)
	for Position = 1, TextLength do
		local At = string.byte(Text, Position) * 4
		buffer.writeu32(Masks, At, bit32.bor(buffer.readu32(Masks, At), bit32.lshift(1, Position - 1)))
	end
end

local function EditsToBegin(TextLength: number, Lowered: string, Start: number, Stop: number): number
	local Masks = MASKS
	local ToTopBit = 2 ^ (32 - TextLength)

	local Rises, Falls = 0xFFFFFFFF, 0
	local Unchanged, SameBefore = 0, 0
	local Edits = TextLength
	local Fewest = TextLength
	for Position = Start, Stop do
		local Same = buffer.readu32(Masks, string.byte(Lowered, Position) * 4)
		local Swapped = bit32.band(bit32.lshift(bit32.band(bit32.bnot(Unchanged), Same), 1), SameBefore)
		Unchanged = bit32.bor(bit32.bxor(bit32.band(Same, Rises) + Rises, Rises), Same, Falls, Swapped)

		local Grows = bit32.bor(Falls, bit32.bnot(bit32.bor(Unchanged, Rises)))
		local Shrinks = bit32.band(Unchanged, Rises)
		Edits += bit32.rshift(Grows * ToTopBit, 31) - bit32.rshift(Shrinks * ToTopBit, 31)
		Fewest = math.min(Fewest, Edits)

		Grows = bit32.bor(bit32.lshift(Grows, 1), 1)
		Shrinks = bit32.lshift(Shrinks, 1)
		Rises = bit32.bor(Shrinks, bit32.bnot(bit32.bor(Unchanged, Grows)))
		Falls = bit32.band(Grows, Unchanged)
		SameBefore = Same
	end
	return Fewest
end

local function CanBeginNear(Lowered: string, NameLength: number, Start: number, Limit: number): boolean
	local FirstTyped = bit32.lshift(2, Limit) - 1
	for Position = Start, math.min(Start + Limit * 2, NameLength) do
		if bit32.btest(buffer.readu32(MASKS, string.byte(Lowered, Position) * 4), FirstTyped) then
			return true
		end
	end
	return false
end

local function NearMissScore(TextLength: number, Limit: number, Name: string, Lowered: string): number?
	local NameLength = string.len(Lowered)
	local Best: number? = nil
	local Word = 0
	local Before = OTHER
	for Start = 1, NameLength do
		local Here = ClassOf(string.byte(Name, Start))
		local IsStart = StartsWord(Before, Here)
		Before = Here
		if IsStart then
			Word += 1
		end
		if IsStart and CanBeginNear(Lowered, NameLength, Start, Limit) then
			local Stop = math.min(Start + TextLength + Limit - 1, NameLength)
			local Edits = EditsToBegin(TextLength, Lowered, Start, Stop)
			if Edits <= Limit then
				local Score = NEAR_MISS + Edits * PER_EDIT + math.min(Word, PER_EDIT - 1)
				Best = if Best then math.min(Best, Score) else Score
			end
		end
	end
	return Best
end

function FuzzySearch.Score(Text: string, Name: string): number?
	local Typed = string.lower(Text)
	local TypedLength = string.len(Typed)
	local Lowered = string.lower(Name)

	local Matched = MatchScore(Typed, TypedLength, Name, Lowered)
	local Limit = EditLimit(TypedLength)
	if Matched or Limit == 0 then
		return Matched
	end

	SetMasks(Typed, TypedLength)
	return NearMissScore(TypedLength, Limit, Name, Lowered)
end

function FuzzySearch.Search(Text: string, Names: { string }): { number }
	local Typed = string.lower(Text)
	local TypedLength = string.len(Typed)
	local Count = #Names

	local Order: { number } = {}
	if TypedLength == 0 then
		for Index = 1, Count do
			Order[Index] = Index
		end
		return Order
	end

	local Keys: { number } = {}
	local Unmatched: { number } = {}
	local UnmatchedLowered: { string } = {}
	local Stride = Count + 1
	local IsHeld = false
	for Index = 1, Count do
		local Name = Names[Index]
		local Lowered = string.lower(Name)
		local Score = MatchScore(Typed, TypedLength, Name, Lowered)
		if Score then
			IsHeld = IsHeld or Score < IN_ORDER
			table.insert(Keys, Score * Stride + Index)
		else
			table.insert(Unmatched, Index)
			table.insert(UnmatchedLowered, Lowered)
		end
	end

	local Limit = EditLimit(TypedLength)
	if not IsHeld and Limit > 0 then
		SetMasks(Typed, TypedLength)
		for Position, Index in Unmatched do
			local Score = NearMissScore(TypedLength, Limit, Names[Index], UnmatchedLowered[Position])
			if Score then
				table.insert(Keys, Score * Stride + Index)
			end
		end
	end
	table.sort(Keys)

	for Position, Key in Keys do
		Order[Position] = Key % Stride
	end
	return Order
end

return FuzzySearch
