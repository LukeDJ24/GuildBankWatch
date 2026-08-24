-- GuildBankWatch Core: guild bank log scanning, count-aware deduplication,
-- persistence, gap detection, the low-stock watchlist, and watchlist sharing.
--
-- Zero idle cost by design: outside a guild bank session only the two
-- PLAYER_INTERACTION_MANAGER events are registered (plus two one-shot
-- startup events). All bank events are registered on bank open and
-- unregistered on close.

local ADDON_NAME, ns = ...

local MONEY_TAB = (MAX_GUILDBANK_TABS or 8) + 1
local SLOTS_PER_TAB = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local GUILD_BANKER = (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker) or 10
-- Log timestamps are hour-granularity elapsed values, so the estimated epoch
-- for the same transaction can drift between visits.
local DEDUPE_TOLERANCE = 2.5 * 3600
local STEP_TIMEOUT = 1.5
local RESCAN_DELAY = 2
local RESCAN_INTERVAL = 10
local DEFAULT_RETENTION_DAYS = 60

local TYPE = {
	ITEM_WITHDRAW = 1,
	ITEM_DEPOSIT = 2,
	GOLD_WITHDRAW = 3,
	GOLD_DEPOSIT = 4,
	REPAIR = 5,
	UNATTRIBUTED = 9,
}
ns.TYPE = TYPE

ns.ACTION_LABELS = {
	[TYPE.ITEM_WITHDRAW] = "Item Withdraw",
	[TYPE.ITEM_DEPOSIT] = "Item Deposit",
	[TYPE.GOLD_WITHDRAW] = "Gold Withdraw",
	[TYPE.GOLD_DEPOSIT] = "Gold Deposit",
	[TYPE.REPAIR] = "Repair",
	[TYPE.UNATTRIBUTED] = "Unattributed",
}

function ns.Print(msg, ...)
	if select("#", ...) > 0 then
		msg = msg:format(...)
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildBankWatch:|r " .. msg)
end

function ns.FormatCopper(copper)
	copper = copper or 0
	local neg = copper < 0
	copper = math.abs(copper)
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local c = copper % 100
	local text
	if gold > 0 then
		text = ("%dg %ds %dc"):format(gold, silver, c)
	elseif silver > 0 then
		text = ("%ds %dc"):format(silver, c)
	else
		text = ("%dc"):format(c)
	end
	return (neg and "-" or "") .. text
end

-------------------------------------------------------------------------------
-- Record format
-------------------------------------------------------------------------------
-- One pipe-delimited string per record: epoch|code|player|itemID|itemName|count|copper|tab
-- One-record-per-line SavedVariables serialization keeps the companion
-- script's parsing trivial. Item names can carry UI escape sequences (the
-- crafting-quality icon is an |A...|a atlas tag inside the link's bracket
-- text) whose pipes would corrupt the record, so names are stripped of
-- markup before encoding; DecodeRecord re-joins over-split legacy records.
-- Numbers go through %.0f: Lua 5.1 tostring() switches to scientific notation
-- on large doubles, which would corrupt copper amounts.

local function CleanName(name)
	if not name or name == "" then
		return name
	end
	name = name:gsub("|A.-|a", ""):gsub("|T.-|t", ""):gsub("|", "")
	return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function EncodeRecord(epoch, code, player, itemID, itemName, count, copper, tab)
	return table.concat({
		("%.0f"):format(epoch),
		code,
		CleanName(player) or "",
		itemID or "",
		CleanName(itemName) or "",
		count or "",
		copper and ("%.0f"):format(copper) or "",
		tab or "",
	}, "|")
end

function ns.DecodeRecord(rec)
	local parts = { strsplit("|", rec) }
	local n = #parts
	local itemName, count, copper, tab
	if n > 8 then
		-- Legacy record: markup pipes in the item name over-split it, so the
		-- name is everything between itemID and the last three fields.
		itemName = table.concat(parts, "|", 5, n - 3)
		count, copper, tab = parts[n - 2], parts[n - 1], parts[n]
	else
		itemName, count, copper, tab = parts[5], parts[6], parts[7], parts[8]
	end
	return tonumber(parts[1]), tonumber(parts[2]), parts[3], tonumber(parts[4]),
		CleanName(itemName), tonumber(count), tonumber(copper), tonumber(tab)
end

-- Matches the client's RecentTimeDate approximation for elapsed log times.
local function ElapsedToSeconds(years, months, days, hours)
	return (years or 0) * 31536000 + (months or 0) * 2592000
		+ (days or 0) * 86400 + (hours or 0) * 3600
end

local function Fingerprint(code, player, itemID, count, copper, tab)
	return table.concat({
		code,
		player or "",
		itemID or "",
		count or "",
		copper and ("%.0f"):format(copper) or "",
		tab or "",
	}, "#")
end

-- The log reports nil for the actor until the server resolves the name
-- (common right as the bank opens); those reads are stored as "Unknown".
local function IsUnknownName(player)
	return not player or player == "" or player == "Unknown"
end

-------------------------------------------------------------------------------
-- Database
-------------------------------------------------------------------------------

local function InitDB()
	GuildBankWatchDB = GuildBankWatchDB or {}
	local db = GuildBankWatchDB
	db.guilds = db.guilds or {}
	db.retentionDays = db.retentionDays or DEFAULT_RETENTION_DAYS
end

function ns.GetGuildKey()
	if not IsInGuild() then
		return nil
	end
	local clubId = C_Club and C_Club.GetGuildClubId and C_Club.GetGuildClubId()
	if clubId then
		return "club:" .. clubId
	end
	local guildName = GetGuildInfo("player")
	if guildName then
		return guildName .. " - " .. GetRealmName()
	end
end

function ns.GetGuildData(create)
	local key = ns.GetGuildKey()
	if not key or not GuildBankWatchDB then
		return nil
	end
	local g = GuildBankWatchDB.guilds[key]
	if not g and create then
		g = { records = {}, watch = {}, watchNames = {} }
		GuildBankWatchDB.guilds[key] = g
	end
	if g then
		g.records = g.records or {}
		g.watch = g.watch or {}
		local guildName = GetGuildInfo("player")
		if guildName then
			g.name = guildName .. " - " .. GetRealmName()
		end
	end
	return g
end

function ns.PurgeGuild()
	local key = ns.GetGuildKey()
	if key and GuildBankWatchDB.guilds[key] then
		GuildBankWatchDB.guilds[key] = nil
		ns.Print("Cleared all recorded data for this guild.")
		if ns.RefreshUI then ns.RefreshUI() end
	else
		ns.Print("No data recorded for this guild.")
	end
end

local function PruneRecords()
	local db = GuildBankWatchDB
	local cutoff = GetServerTime() - (db.retentionDays or DEFAULT_RETENTION_DAYS) * 86400
	for _, g in pairs(db.guilds) do
		local kept = {}
		for _, rec in ipairs(g.records or {}) do
			local epoch = tonumber(rec:match("^%d+"))
			if epoch and epoch >= cutoff then
				kept[#kept + 1] = rec
			end
		end
		g.records = kept
	end
end

-------------------------------------------------------------------------------
-- Watchlist
-------------------------------------------------------------------------------

local sessionWarned = {}

function ns.WarnLowStock(g, itemID, have, minCount, asOf)
	local function emit(display)
		if asOf then
			ns.Print("|cffff5555Low stock|r (as of last bank visit %s): %s %d/%d",
				date("%Y-%m-%d", asOf), display, have, minCount)
		else
			ns.Print("|cffff5555Low stock:|r %s %d/%d", display, have, minCount)
		end
	end
	local _, link = C_Item.GetItemInfo(itemID)
	if link then
		emit(link)
	elseif C_Item.DoesItemExistByID(itemID) then
		local item = Item:CreateFromItemID(itemID)
		item:ContinueOnItemLoad(function()
			emit(item:GetItemLink() or (g.watchNames and g.watchNames[itemID]) or ("item " .. itemID))
		end)
	else
		emit((g.watchNames and g.watchNames[itemID]) or ("item " .. itemID))
	end
end

function ns.AddWatch(itemID, minCount)
	itemID = tonumber(itemID)
	minCount = tonumber(minCount) or 1
	if not itemID or itemID <= 0 or minCount < 1 then
		ns.Print("Usage: /gbw track <itemID> [minimum]")
		return
	end
	if not C_Item.DoesItemExistByID(itemID) then
		ns.Print("Item ID %d does not exist. Look up item IDs on wowhead.com.", itemID)
		return
	end
	local g = ns.GetGuildData(true)
	if not g then
		ns.Print("You are not in a guild.")
		return
	end
	local previous = g.watch[itemID]
	g.watch[itemID] = minCount
	if previous ~= minCount then
		-- A raised threshold can put the item under it, so let the warning
		-- fire again this session instead of staying silent.
		sessionWarned[itemID] = nil
	end
	local item = Item:CreateFromItemID(itemID)
	item:ContinueOnItemLoad(function()
		g.watchNames = g.watchNames or {}
		g.watchNames[itemID] = item:GetItemName()
		local display = item:GetItemLink() or item:GetItemName() or ("item " .. itemID)
		if previous == minCount then
			ns.Print("Already tracking %s with a minimum of %d.", display, minCount)
		elseif previous then
			ns.Print("%s minimum changed from %d to %d.", display, previous, minCount)
		else
			ns.Print("Now tracking %s — warns when the bank holds fewer than %d.", display, minCount)
		end
		if ns.RefreshUI then ns.RefreshUI() end
	end)
end

-- Adjusts the threshold on an item that is already tracked, leaving the rest
-- of the watchlist alone. Returns true when the stored value actually changed.
function ns.SetWatchMinimum(itemID, minCount)
	itemID, minCount = tonumber(itemID), tonumber(minCount)
	local g = itemID and ns.GetGuildData(false)
	if not g or not g.watch or not g.watch[itemID] then
		ns.Print("Not tracking item ID %s — add it first.", tostring(itemID or "?"))
		return false
	end
	if not minCount or minCount < 1 then
		ns.Print("Minimum must be a whole number of 1 or more.")
		return false
	end
	minCount = math.floor(minCount)
	if g.watch[itemID] == minCount then
		return false
	end
	g.watch[itemID] = minCount
	sessionWarned[itemID] = nil
	local display = (g.watchNames and g.watchNames[itemID]) or ("item " .. itemID)
	local have = g.snapshot and g.snapshot.totals and g.snapshot.totals[itemID]
	if have then
		ns.Print("%s minimum is now %d (%d in the bank as of the last visit).", display, minCount, have)
	else
		ns.Print("%s minimum is now %d.", display, minCount)
	end
	if ns.RefreshUI then ns.RefreshUI() end
	return true
end

function ns.RemoveWatch(itemID)
	itemID = tonumber(itemID)
	local g = itemID and ns.GetGuildData(false)
	if not g or not g.watch or not g.watch[itemID] then
		ns.Print("Not tracking item ID %s.", tostring(itemID or "?"))
		return
	end
	local display = (g.watchNames and g.watchNames[itemID]) or ("item ID " .. itemID)
	g.watch[itemID] = nil
	if g.watchNames then
		g.watchNames[itemID] = nil
	end
	ns.Print("Stopped tracking %s.", display)
	if ns.RefreshUI then ns.RefreshUI() end
end

local function LoginChecks()
	PruneRecords()
	local g = ns.GetGuildData(false)
	if not g or not g.snapshot or not g.watch then
		return
	end
	for itemID, minCount in pairs(g.watch) do
		local have = (g.snapshot.totals and g.snapshot.totals[itemID]) or 0
		if have < minCount then
			ns.WarnLowStock(g, itemID, have, minCount, g.snapshot.time)
		end
	end
end

-------------------------------------------------------------------------------
-- Watchlist sharing
-------------------------------------------------------------------------------
-- Tracked items travel as one copy-paste string: "GBW1:<checksum>:<base64>".
-- The payload carries item IDs and their minimums and nothing else — no
-- character, guild, or transaction data — so a shared string says only "here
-- are the items I track". Item names are deliberately excluded too: they are
-- locale-specific, so the importing client resolves them from the ID instead.
--
-- Base64 keeps the string to the character set that survives a trip through
-- chat, Discord, and the in-game edit box. The checksum catches the common
-- failure of a paste that was truncated on the way.

local SHARE_PREFIX = "GBW1"
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64_CHARS do
	B64_INDEX[B64_CHARS:sub(i, i)] = i - 1
end

-- Arithmetic rather than bit ops: values stay far below 2^53, so doubles hold
-- them exactly and the addon keeps working if the bit library ever moves.
local function Base64Encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64
		out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
			.. B64_CHARS:sub(c2 + 1, c2 + 1)
			.. (b and B64_CHARS:sub(c3 + 1, c3 + 1) or "=")
			.. (c and B64_CHARS:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function Base64Decode(text)
	text = text:gsub("[^A-Za-z0-9+/]", "")
	local out = {}
	for i = 1, #text, 4 do
		local c1, c2 = B64_INDEX[text:sub(i, i)], B64_INDEX[text:sub(i + 1, i + 1)]
		if not c1 or not c2 then
			return nil -- a lone trailing character cannot encode a byte
		end
		local c3, c4 = B64_INDEX[text:sub(i + 2, i + 2)], B64_INDEX[text:sub(i + 3, i + 3)]
		local n = c1 * 262144 + c2 * 4096 + (c3 or 0) * 64 + (c4 or 0)
		out[#out + 1] = string.char(math.floor(n / 65536) % 256)
		if c3 then
			out[#out + 1] = string.char(math.floor(n / 256) % 256)
		end
		if c4 then
			out[#out + 1] = string.char(n % 256)
		end
	end
	return table.concat(out)
end

-- djb2 folded to 31 bits: still far more than enough to catch a truncated
-- paste, and small enough that "%x" is safe on any Lua integer width.
local function Checksum(s)
	local sum = 5381
	for i = 1, #s do
		sum = (sum * 33 + s:byte(i)) % 2147483648
	end
	return sum
end

-- Returns the share string and the item count, or nil plus a reason
-- ("noguild" or "empty").
function ns.ExportWatchString()
	local g = ns.GetGuildData(false)
	if not g then
		return nil, "noguild"
	end
	local ids = {}
	for itemID in pairs(g.watch or {}) do
		ids[#ids + 1] = itemID
	end
	if #ids == 0 then
		return nil, "empty"
	end
	table.sort(ids) -- the same watchlist always encodes to the same string
	local lines = {}
	for _, itemID in ipairs(ids) do
		lines[#lines + 1] = ("i %d %d"):format(itemID, g.watch[itemID])
	end
	local payload = table.concat(lines, "\n")
	return ("%s:%x:%s"):format(SHARE_PREFIX, Checksum(payload), Base64Encode(payload)), #ids
end

-- Returns a list of { itemID, min } sorted by ID, or nil plus a reason
-- ("empty", "format" or "corrupt").
function ns.ParseWatchString(text)
	if type(text) ~= "string" then
		return nil, "empty"
	end
	-- Tolerate a paste that picked up colour codes or line wrapping; no part
	-- of a valid string contains whitespace.
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s+", "")
	if text == "" then
		return nil, "empty"
	end
	local hex, encoded = text:match("^[Gg][Bb][Ww]1:(%x+):([A-Za-z0-9+/=]+)$")
	if not hex then
		return nil, "format"
	end
	local payload = Base64Decode(encoded)
	if not payload or payload == "" then
		return nil, "format"
	end
	if ("%x"):format(Checksum(payload)) ~= hex:lower() then
		return nil, "corrupt"
	end
	local items, seen = {}, {}
	for line in (payload .. "\n"):gmatch("(.-)\n") do
		-- Unknown line kinds are skipped so a future format can add fields
		-- without this version choking on them.
		local id, minCount = line:match("^i%s+(%d+)%s+(%d+)$")
		id, minCount = tonumber(id), tonumber(minCount)
		if id and minCount and id > 0 and minCount >= 1 and not seen[id] then
			seen[id] = true
			items[#items + 1] = { itemID = id, min = minCount }
		end
	end
	if #items == 0 then
		return nil, "format"
	end
	table.sort(items, function(a, b) return a.itemID < b.itemID end)
	return items
end

-- Dry run for the import preview: how the parsed list compares to what this
-- guild already tracks.
function ns.SummarizeWatchImport(items)
	local g = ns.GetGuildData(false)
	local watch = (g and g.watch) or {}
	local summary = { new = 0, changed = 0, same = 0, unknown = 0, existing = 0 }
	for _, entry in ipairs(items) do
		if not C_Item.DoesItemExistByID(entry.itemID) then
			summary.unknown = summary.unknown + 1
		else
			local current = watch[entry.itemID]
			if current == nil then
				summary.new = summary.new + 1
			elseif current ~= entry.min then
				summary.changed = summary.changed + 1
			else
				summary.same = summary.same + 1
			end
		end
	end
	for _ in pairs(watch) do
		summary.existing = summary.existing + 1
	end
	return summary
end

-- mode "merge" keeps items the string does not mention; "replace" drops them.
-- Either way the imported minimum wins for items present in both.
function ns.ApplyWatchImport(items, mode)
	local g = ns.GetGuildData(true)
	if not g then
		ns.Print("You are not in a guild.")
		return nil
	end
	g.watchNames = g.watchNames or {}
	local result = { added = 0, updated = 0, removed = 0, skipped = 0 }
	local incoming = {}
	for _, entry in ipairs(items) do
		if C_Item.DoesItemExistByID(entry.itemID) then
			incoming[entry.itemID] = entry.min
		else
			result.skipped = result.skipped + 1
		end
	end
	if mode == "replace" then
		for itemID in pairs(g.watch) do
			if not incoming[itemID] then
				g.watch[itemID] = nil
				g.watchNames[itemID] = nil
				result.removed = result.removed + 1
			end
		end
	end
	for itemID, minCount in pairs(incoming) do
		local current = g.watch[itemID]
		if current == nil then
			result.added = result.added + 1
		elseif current ~= minCount then
			result.updated = result.updated + 1
		end
		g.watch[itemID] = minCount
		if not g.watchNames[itemID] then
			local item = Item:CreateFromItemID(itemID)
			item:ContinueOnItemLoad(function()
				local data = ns.GetGuildData(false)
				if data and data.watch[itemID] then
					data.watchNames = data.watchNames or {}
					data.watchNames[itemID] = item:GetItemName()
				end
				if ns.RefreshUI then ns.RefreshUI() end
			end)
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Auctionator shopping list
-------------------------------------------------------------------------------
-- Auctionator imports lists as "<list name>^<item>^<item>...", one list per
-- line (its Source/Shopping/ImportExport.lua). An item may be a plain name or
-- an advanced search: 14 ";"-separated fields, of which we set the first (the
-- name, quoted to force an exact match) and the last (how many to buy).
--
-- Importing onto a list name that already exists replaces its contents, so the
-- stable name below means repeat exports refresh one list rather than piling
-- up duplicates.

local SHOPPING_LIST_PREFIX = "GuildBankWatch - "

-- Field order taken from Auctionator.Search.SplitAdvancedSearch. Written out
-- as a named list rather than a literal so a miscounted ";" is impossible.
local function AdvancedSearchEntry(name, quantity)
	local fields = {
		('"%s"'):format(name), -- query; the quotes are what set isExact
		"",  -- categoryKey
		"",  -- minItemLevel
		"",  -- maxItemLevel
		"",  -- minLevel
		"",  -- maxLevel
		"",  -- minCraftedLevel
		"",  -- maxCraftedLevel
		"",  -- minPrice
		"",  -- maxPrice
		"",  -- quality
		"#", -- tier; Auctionator writes "#" when unset
		"",  -- expansion
		tostring(quantity),
	}
	return table.concat(fields, ";")
end

-- Tracked items whose last-seen bank count is under their minimum, sorted by
-- name. Empty when the bank has never been scanned — stock is unknown then,
-- not low.
function ns.GetLowStockItems()
	local low = {}
	local g = ns.GetGuildData(false)
	local totals = g and g.snapshot and g.snapshot.totals
	if not g or not g.watch or not totals then
		return low
	end
	for itemID, minCount in pairs(g.watch) do
		local have = totals[itemID] or 0
		if have < minCount then
			low[#low + 1] = {
				itemID = itemID,
				min = minCount,
				have = have,
				short = minCount - have,
				name = g.watchNames and g.watchNames[itemID],
			}
		end
	end
	table.sort(low, function(a, b)
		return (a.name or tostring(a.itemID)) < (b.name or tostring(b.itemID))
	end)
	return low
end

-- Returns the import string, the item count and how many were skipped, or nil
-- plus a reason ("noguild" or "none").
function ns.BuildShoppingList()
	local g = ns.GetGuildData(false)
	if not g then
		return nil, "noguild"
	end
	local low = ns.GetLowStockItems()
	if #low == 0 then
		return nil, "none"
	end
	local entries, skipped = {}, 0
	for _, item in ipairs(low) do
		local name = item.name or C_Item.GetItemInfo(item.itemID)
		if name then
			-- "^" and ";" are the two delimiters; a name holding either would
			-- corrupt the list rather than fail loudly.
			name = name:gsub("[%^;\r\n]", " ")
			entries[#entries + 1] = AdvancedSearchEntry(name, item.short)
		else
			skipped = skipped + 1
		end
	end
	if #entries == 0 then
		return nil, "none"
	end
	local guild = GetGuildInfo("player") or g.name or "Unknown"
	local listName = (SHOPPING_LIST_PREFIX .. guild):gsub("[%^\r\n]", " ")
	return listName .. "^" .. table.concat(entries, "^"), #entries, skipped
end

-------------------------------------------------------------------------------
-- Scanner: sequential query state machine
-------------------------------------------------------------------------------
-- One step at a time: query, wait for the answering event (with a timeout),
-- read, advance. Bursting all queries at once is unreliable because the
-- responses can be throttled and the events don't say which tab answered.

local bankOpen = false
local rescanQueued = false
local rescanTicker

local scanner = {
	running = false,
	gen = 0, -- generation counter invalidates stale C_Timer callbacks
}

local function ReadLogTab(tab)
	local now = GetServerTime()
	local n = GetNumGuildBankTransactions(tab) or 0
	for i = 1, n do
		local txType, name, itemLink, count, _, _, year, month, day, hour = GetGuildBankTransaction(tab, i)
		local code = (txType == "withdraw" and TYPE.ITEM_WITHDRAW)
			or (txType == "deposit" and TYPE.ITEM_DEPOSIT)
			or nil -- "move" doesn't remove anything from the bank
		if code and itemLink then
			scanner.fresh[#scanner.fresh + 1] = {
				epoch = now - ElapsedToSeconds(year, month, day, hour),
				code = code,
				player = name or "Unknown",
				itemID = tonumber(itemLink:match("item:(%d+)")),
				itemName = itemLink:match("%[(.-)%]"),
				count = count or 1,
				tab = tab,
			}
		end
	end
end

local MONEY_CODES = {
	withdraw = TYPE.GOLD_WITHDRAW,
	deposit = TYPE.GOLD_DEPOSIT,
	repair = TYPE.REPAIR,
}

local function ReadMoneyLog()
	local now = GetServerTime()
	local n = GetNumGuildBankMoneyTransactions() or 0
	for i = 1, n do
		local txType, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
		local code = MONEY_CODES[txType] -- unknown types (e.g. buyTab) are skipped
		if code and amount then
			scanner.fresh[#scanner.fresh + 1] = {
				epoch = now - ElapsedToSeconds(years, months, days, hours),
				code = code,
				player = name or "Unknown",
				copper = amount,
			}
		end
	end
end

local function ReadTabContents(step)
	local totals = scanner.contentsTotals
	for slot = 1, SLOTS_PER_TAB do
		local link = GetGuildBankItemLink(step.tab, slot)
		if link then
			local itemID = tonumber(link:match("item:(%d+)"))
			if itemID then
				local _, count = GetGuildBankItemInfo(step.tab, slot)
				totals[itemID] = (totals[itemID] or 0) + (count or 1)
			end
		end
	end
end

local function ReadStep(step)
	if step.read then
		return
	end
	step.read = true
	if step.kind == "log" then
		ReadLogTab(step.tab)
	elseif step.kind == "money" then
		ReadMoneyLog()
	else
		ReadTabContents(step)
	end
end

local RunStep -- forward declaration
local Finalize -- forward declaration

local function FinishStep()
	scanner.stepIndex = scanner.stepIndex + 1
	RunStep()
end

RunStep = function()
	if not scanner.running then
		return
	end
	local step = scanner.steps[scanner.stepIndex]
	if not step then
		Finalize(false)
		return
	end
	scanner.gen = scanner.gen + 1
	local gen = scanner.gen
	scanner.waiting = step
	if step.kind == "log" then
		QueryGuildBankLog(step.tab)
	elseif step.kind == "money" then
		QueryGuildBankLog(MONEY_TAB)
	else
		QueryGuildBankTab(step.tab)
	end
	C_Timer.After(STEP_TIMEOUT, function()
		if scanner.running and scanner.gen == gen and scanner.waiting == step then
			if step.kind == "tab" and not step.gotEvent then
				-- Contents never arrived; the snapshot would be unreliable.
				scanner.contentsComplete = false
			end
			ReadStep(step)
			scanner.waiting = nil
			FinishStep()
		end
	end)
end

local function StartScan()
	if scanner.running or not bankOpen or not IsInGuild() then
		return
	end
	local g = ns.GetGuildData(true)
	if not g then
		return
	end
	scanner.running = true
	scanner.fresh = {}
	scanner.contentsTotals = {}
	scanner.contentsComplete = true
	scanner.steps = {}
	scanner.stepIndex = 1

	local viewable = {}
	for tab = 1, GetNumGuildBankTabs() or 0 do
		local isViewable = true
		if GetGuildBankTabInfo then
			local _, _, v = GetGuildBankTabInfo(tab)
			isViewable = not not v
		end
		if isViewable then
			viewable[#viewable + 1] = tab
			scanner.steps[#scanner.steps + 1] = { kind = "log", tab = tab }
		end
	end
	scanner.steps[#scanner.steps + 1] = { kind = "money" }
	for _, tab in ipairs(viewable) do
		scanner.steps[#scanner.steps + 1] = { kind = "tab", tab = tab }
	end
	-- Gap detection only compares snapshots taken over the same set of
	-- viewable tabs; a rank-hidden tab reads as empty and would false-flag.
	scanner.viewKey = table.concat(viewable, ",")
	RunStep()
end

Finalize = function(aborted)
	if not scanner.running then
		return
	end
	scanner.running = false
	scanner.waiting = nil
	scanner.lastFinish = GetTime()
	local g = ns.GetGuildData(true)
	if not g then
		return
	end
	local now = GetServerTime()

	-- Count-aware dedupe: each fresh transaction consumes at most one stored
	-- record with the same fingerprint inside the time tolerance, so N
	-- identical legitimate transactions survive as N records.
	local fresh = scanner.fresh
	table.sort(fresh, function(a, b) return a.epoch < b.epoch end)
	local newTx = {}
	local patched = 0
	if #fresh > 0 then
		local minEpoch = fresh[1].epoch - DEDUPE_TOLERANCE * 2
		local stored, unnamed = {}, {}
		for index, rec in ipairs(g.records) do
			local epoch, code, player, itemID, _, count, copper, tab = ns.DecodeRecord(rec)
			if epoch and epoch >= minEpoch and code ~= TYPE.UNATTRIBUTED then
				local entry = { epoch = epoch, used = false, index = index, player = player }
				local fp = Fingerprint(code, player, itemID, count, copper, tab)
				local bucket = stored[fp]
				if not bucket then
					bucket = {}
					stored[fp] = bucket
				end
				bucket[#bucket + 1] = entry
				local nfp = Fingerprint(code, "", itemID, count, copper, tab)
				bucket = unnamed[nfp]
				if not bucket then
					bucket = {}
					unnamed[nfp] = bucket
				end
				bucket[#bucket + 1] = entry
			end
		end
		local function FindBest(bucket, epoch, accept)
			local best, bestDelta
			if bucket then
				for _, s in ipairs(bucket) do
					if not s.used and (not accept or accept(s)) then
						local delta = math.abs(s.epoch - epoch)
						if delta <= DEDUPE_TOLERANCE and (not bestDelta or delta < bestDelta) then
							best, bestDelta = s, delta
						end
					end
				end
			end
			return best
		end
		for _, tx in ipairs(fresh) do
			local best = FindBest(stored[Fingerprint(tx.code, tx.player, tx.itemID, tx.count, tx.copper, tx.tab)], tx.epoch)
			if not best then
				-- The same transaction can be read with and without the
				-- actor's name resolved. Match across that difference so it
				-- is not duplicated, and back-fill the name once known.
				local nameless = unnamed[Fingerprint(tx.code, "", tx.itemID, tx.count, tx.copper, tx.tab)]
				if IsUnknownName(tx.player) then
					best = FindBest(nameless, tx.epoch)
				else
					best = FindBest(nameless, tx.epoch, function(s) return IsUnknownName(s.player) end)
					if best then
						local epoch, code, _, itemID, itemName, count, copper, tab = ns.DecodeRecord(g.records[best.index])
						g.records[best.index] = EncodeRecord(epoch, code, tx.player, itemID, itemName, count, copper, tab)
						patched = patched + 1
					end
				end
			end
			if best then
				best.used = true
			else
				newTx[#newTx + 1] = tx
			end
		end
		for _, tx in ipairs(newTx) do
			g.records[#g.records + 1] = EncodeRecord(tx.epoch, tx.code, tx.player,
				tx.itemID, tx.itemName, tx.count, tx.copper, tx.tab)
		end
	end

	if scanner.contentsComplete and not aborted then
		local totals = scanner.contentsTotals
		local gold = GetGuildBankMoney() or 0
		local old = g.snapshot

		if old and old.totals and old.viewKey == scanner.viewKey then
			-- Expected change since the old snapshot = the transactions we
			-- just recorded (older ones were already inside the old counts).
			local itemDelta, goldDelta = {}, 0
			for _, tx in ipairs(newTx) do
				if tx.epoch >= (old.time or 0) then
					if tx.code == TYPE.ITEM_WITHDRAW and tx.itemID then
						itemDelta[tx.itemID] = (itemDelta[tx.itemID] or 0) - tx.count
					elseif tx.code == TYPE.ITEM_DEPOSIT and tx.itemID then
						itemDelta[tx.itemID] = (itemDelta[tx.itemID] or 0) + tx.count
					elseif tx.code == TYPE.GOLD_DEPOSIT then
						goldDelta = goldDelta + tx.copper
					elseif tx.code == TYPE.GOLD_WITHDRAW or tx.code == TYPE.REPAIR then
						goldDelta = goldDelta - tx.copper
					end
				end
			end
			local mismatched = 0
			local seen = {}
			for itemID, count in pairs(old.totals) do
				seen[itemID] = true
				if (totals[itemID] or 0) ~= count + (itemDelta[itemID] or 0) then
					mismatched = mismatched + 1
				end
			end
			for itemID, count in pairs(totals) do
				if not seen[itemID] and count ~= (itemDelta[itemID] or 0) then
					mismatched = mismatched + 1
				end
			end
			local goldDiff = gold - ((old.gold or 0) + goldDelta)
			if mismatched > 0 or goldDiff ~= 0 then
				local summary = ("Bank changed more than the log explains: %d item type(s), %s gold difference. The 25-entry log likely rolled over since the last visit."):format(mismatched, ns.FormatCopper(goldDiff))
				g.records[#g.records + 1] = EncodeRecord(now, TYPE.UNATTRIBUTED, "", nil, summary, nil, goldDiff, nil)
				ns.Print("|cffffcc00Warning:|r %s", summary)
			end
		end

		g.snapshot = { time = now, gold = gold, totals = totals, viewKey = scanner.viewKey }

		for itemID, minCount in pairs(g.watch or {}) do
			local have = totals[itemID] or 0
			if have < minCount and not sessionWarned[itemID] then
				sessionWarned[itemID] = true
				ns.WarnLowStock(g, itemID, have, minCount)
			end
		end
	elseif #newTx > 0 then
		-- Partial data with new records: the old baseline no longer explains
		-- the bank's contents, so drop it rather than risk phantom gap
		-- warnings. A partial scan that found nothing new keeps the baseline.
		g.snapshot = nil
	end

	if #newTx > 0 then
		ns.Print("Recorded %d new guild bank transaction(s).", #newTx)
	end
	if patched > 0 then
		ns.Print("Resolved the character name on %d earlier record(s).", patched)
	end
	if ns.RefreshUI then ns.RefreshUI() end
end

-- Log or bag activity while the bank sits open (e.g. the user's own
-- withdrawal): pick it up with one short-delay rescan.
local function QueueRescan()
	if not bankOpen or scanner.running or rescanQueued
		or GetTime() - (scanner.lastFinish or 0) <= 1 then
		return
	end
	rescanQueued = true
	C_Timer.After(RESCAN_DELAY, function()
		rescanQueued = false
		if bankOpen then
			StartScan()
		end
	end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
	if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
		if arg1 == GUILD_BANKER and IsInGuild() then
			bankOpen = true
			wipe(sessionWarned)
			self:RegisterEvent("GUILDBANKLOG_UPDATE")
			self:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
			-- Small delay lets the default UI's own queries settle first.
			C_Timer.After(0.6, StartScan)
			-- The server does not push other players' log activity to an
			-- open client, so poll while (and only while) the bank is open.
			if rescanTicker then
				rescanTicker:Cancel()
			end
			rescanTicker = C_Timer.NewTicker(RESCAN_INTERVAL, function()
				if bankOpen and not scanner.running then
					StartScan()
				end
			end)
		end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		if arg1 == GUILD_BANKER and bankOpen then
			bankOpen = false
			if rescanTicker then
				rescanTicker:Cancel()
				rescanTicker = nil
			end
			self:UnregisterEvent("GUILDBANKLOG_UPDATE")
			self:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
			if scanner.running then
				Finalize(true)
			end
		end
	elseif event == "GUILDBANKLOG_UPDATE" then
		local step = scanner.waiting
		if scanner.running and step and (step.kind == "log" or step.kind == "money") then
			step.gotEvent = true
			ReadStep(step)
			scanner.waiting = nil
			FinishStep()
		else
			QueueRescan()
		end
	elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
		local step = scanner.waiting
		if scanner.running and step and step.kind == "tab" and not step.gotEvent then
			step.gotEvent = true
			local gen = scanner.gen
			-- Slot updates arrive in bursts; read shortly after the first.
			C_Timer.After(0.3, function()
				if scanner.running and scanner.gen == gen and scanner.waiting == step then
					ReadStep(step)
					scanner.waiting = nil
					FinishStep()
				end
			end)
		else
			QueueRescan()
		end
	elseif event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			InitDB()
			self:UnregisterEvent("ADDON_LOADED")
		end
	elseif event == "PLAYER_LOGIN" then
		self:UnregisterEvent("PLAYER_LOGIN")
		-- Delayed so login chat spam settles and guild/club data loads.
		C_Timer.After(8, LoginChecks)
	end
end)
