-- GuildBankWatch Core: guild bank log scanning, count-aware deduplication,
-- persistence, gap detection, and the low-stock watchlist.
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
-- Pipes cannot occur in item or player names, and one-record-per-line
-- SavedVariables serialization keeps the companion script's parsing trivial.
-- Numbers go through %.0f: Lua 5.1 tostring() switches to scientific notation
-- on large doubles, which would corrupt copper amounts.

local function EncodeRecord(epoch, code, player, itemID, itemName, count, copper, tab)
	return table.concat({
		("%.0f"):format(epoch),
		code,
		player or "",
		itemID or "",
		itemName or "",
		count or "",
		copper and ("%.0f"):format(copper) or "",
		tab or "",
	}, "|")
end

function ns.DecodeRecord(rec)
	local epoch, code, player, itemID, itemName, count, copper, tab = strsplit("|", rec)
	return tonumber(epoch), tonumber(code), player, tonumber(itemID), itemName,
		tonumber(count), tonumber(copper), tonumber(tab)
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
	g.watch[itemID] = minCount
	local item = Item:CreateFromItemID(itemID)
	item:ContinueOnItemLoad(function()
		g.watchNames = g.watchNames or {}
		g.watchNames[itemID] = item:GetItemName()
		ns.Print("Now tracking %s — warns when the bank holds fewer than %d.",
			item:GetItemLink() or item:GetItemName() or ("item " .. itemID), minCount)
		if ns.RefreshUI then ns.RefreshUI() end
	end)
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
-- Scanner: sequential query state machine
-------------------------------------------------------------------------------
-- One step at a time: query, wait for the answering event (with a timeout),
-- read, advance. Bursting all queries at once is unreliable because the
-- responses can be throttled and the events don't say which tab answered.

local bankOpen = false
local rescanQueued = false

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
	if #fresh > 0 then
		local minEpoch = fresh[1].epoch - DEDUPE_TOLERANCE * 2
		local stored = {}
		for _, rec in ipairs(g.records) do
			local epoch, code, player, itemID, _, count, copper, tab = ns.DecodeRecord(rec)
			if epoch and epoch >= minEpoch and code ~= TYPE.UNATTRIBUTED then
				local fp = Fingerprint(code, player, itemID, count, copper, tab)
				local bucket = stored[fp]
				if not bucket then
					bucket = {}
					stored[fp] = bucket
				end
				bucket[#bucket + 1] = { epoch = epoch, used = false }
			end
		end
		for _, tx in ipairs(fresh) do
			local bucket = stored[Fingerprint(tx.code, tx.player, tx.itemID, tx.count, tx.copper, tx.tab)]
			local best, bestDelta
			if bucket then
				for _, s in ipairs(bucket) do
					if not s.used then
						local delta = math.abs(s.epoch - tx.epoch)
						if delta <= DEDUPE_TOLERANCE and (not bestDelta or delta < bestDelta) then
							best, bestDelta = s, delta
						end
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
	else
		-- Partial data: drop the baseline so the next complete scan starts
		-- clean instead of producing phantom gap warnings.
		g.snapshot = nil
	end

	if #newTx > 0 then
		ns.Print("Recorded %d new guild bank transaction(s).", #newTx)
	end
	if ns.RefreshUI then ns.RefreshUI() end
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
		end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		if arg1 == GUILD_BANKER and bankOpen then
			bankOpen = false
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
		elseif bankOpen and not scanner.running and not rescanQueued
			and GetTime() - (scanner.lastFinish or 0) > 1 then
			-- Log activity while the bank sits open (e.g. the user's own
			-- withdrawal): pick it up with one delayed rescan.
			rescanQueued = true
			C_Timer.After(RESCAN_DELAY, function()
				rescanQueued = false
				if bankOpen then
					StartScan()
				end
			end)
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
