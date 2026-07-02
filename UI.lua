-- GuildBankWatch UI: lazily created window (Log / Totals / Watchlist views),
-- CSV export dialog, and slash commands. No frames are allocated until the
-- window is first opened.

local ADDON_NAME, ns = ...
local TYPE = ns.TYPE

local window, exportFrame
local logView, totalsView, watchView
local logBox, totalsBox, watchBox
local nameBox, idBox, minBox
local currentView = "log"
local typeFilterIndex = 1
local nameFilter = ""
local classColors = {}

local Refresh -- forward declaration
local ShowView -- forward declaration

local RETAIN_SCROLL = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or nil

local TYPE_FILTERS = {
	{ label = "All", codes = nil },
	{ label = "Withdrawals", codes = {
		[TYPE.ITEM_WITHDRAW] = true, [TYPE.GOLD_WITHDRAW] = true,
		[TYPE.REPAIR] = true, [TYPE.UNATTRIBUTED] = true,
	} },
	{ label = "Deposits", codes = {
		[TYPE.ITEM_DEPOSIT] = true, [TYPE.GOLD_DEPOSIT] = true,
	} },
	{ label = "Gold only", codes = {
		[TYPE.GOLD_WITHDRAW] = true, [TYPE.GOLD_DEPOSIT] = true, [TYPE.REPAIR] = true,
	} },
}

local ACTION_TEXT = {
	[TYPE.ITEM_WITHDRAW] = "|cffff5555Withdrew|r",
	[TYPE.ITEM_DEPOSIT] = "|cff55ff55Deposited|r",
	[TYPE.GOLD_WITHDRAW] = "|cffff5555Gold out|r",
	[TYPE.GOLD_DEPOSIT] = "|cff55ff55Gold in|r",
	[TYPE.REPAIR] = "|cffff9933Repair|r",
	[TYPE.UNATTRIBUTED] = "|cffffcc00ALERT|r",
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function MoneyText(copper)
	if GetMoneyString then
		return GetMoneyString(copper or 0, true)
	end
	return ns.FormatCopper(copper)
end

local function BuildClassColors()
	wipe(classColors)
	if not GetNumGuildMembers then
		return
	end
	for i = 1, GetNumGuildMembers() or 0 do
		local fullName, _, _, _, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
		if fullName and classFile then
			classColors[Ambiguate(fullName, "guild")] = classFile
		end
	end
end

local function ColorName(name)
	if not name or name == "" then
		return "?"
	end
	local classFile = classColors[name] or classColors[Ambiguate(name, "guild")]
	local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if color and color.colorStr then
		return ("|c%s%s|r"):format(color.colorStr, name)
	end
	return name
end

local function AddHeader(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

local function AddEmptyText(view, text)
	local fs = view:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	fs:SetPoint("CENTER", 0, 0)
	fs:SetText(text)
	fs:Hide()
	view.empty = fs
end

local function CreateList(parent, rowInit, extent)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	box:SetPoint("TOPLEFT", 0, 0)
	box:SetPoint("BOTTOMRIGHT", -20, 0)
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPRIGHT", -4, 0)
	bar:SetPoint("BOTTOMRIGHT", -4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(extent or 22)
	view:SetElementInitializer("Button", rowInit)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
	return box
end

local function SetListData(box, list)
	box:SetDataProvider(CreateDataProvider(list), RETAIN_SCROLL)
end

-------------------------------------------------------------------------------
-- Data builders
-------------------------------------------------------------------------------

local function BuildLogList()
	local list = {}
	local g = ns.GetGuildData(false)
	if not g then
		return list
	end
	local filter = TYPE_FILTERS[typeFilterIndex].codes
	local needle = nameFilter ~= "" and nameFilter:lower() or nil
	for _, rec in ipairs(g.records or {}) do
		local epoch, code, player, itemID, itemName, count, copper, tab = ns.DecodeRecord(rec)
		if epoch and code and (not filter or filter[code])
			and (not needle or (player and player:lower():find(needle, 1, true))) then
			list[#list + 1] = {
				epoch = epoch, code = code, player = player, itemID = itemID,
				itemName = itemName, count = count, copper = copper, tab = tab,
			}
		end
	end
	table.sort(list, function(a, b) return a.epoch > b.epoch end)
	return list
end

local function BuildTotalsList()
	local list = {}
	local g = ns.GetGuildData(false)
	if not g then
		return list
	end
	local per = {}
	for _, rec in ipairs(g.records or {}) do
		local _, code, player, _, _, count, copper = ns.DecodeRecord(rec)
		if code and code ~= TYPE.UNATTRIBUTED and player and player ~= "" then
			local p = per[player]
			if not p then
				p = { player = player, itemsOut = 0, itemsIn = 0, goldOut = 0, goldIn = 0 }
				per[player] = p
			end
			if code == TYPE.ITEM_WITHDRAW then
				p.itemsOut = p.itemsOut + (count or 0)
			elseif code == TYPE.ITEM_DEPOSIT then
				p.itemsIn = p.itemsIn + (count or 0)
			elseif code == TYPE.GOLD_WITHDRAW or code == TYPE.REPAIR then
				p.goldOut = p.goldOut + (copper or 0)
			elseif code == TYPE.GOLD_DEPOSIT then
				p.goldIn = p.goldIn + (copper or 0)
			end
		end
	end
	for _, p in pairs(per) do
		list[#list + 1] = p
	end
	table.sort(list, function(a, b)
		if a.goldOut ~= b.goldOut then return a.goldOut > b.goldOut end
		if a.itemsOut ~= b.itemsOut then return a.itemsOut > b.itemsOut end
		return a.player < b.player
	end)
	return list
end

local function BuildWatchList()
	local list = {}
	local g = ns.GetGuildData(false)
	if not g or not g.watch then
		return list
	end
	local totals = g.snapshot and g.snapshot.totals
	for itemID, minCount in pairs(g.watch) do
		list[#list + 1] = {
			itemID = itemID,
			min = minCount,
			have = totals and (totals[itemID] or 0) or nil,
			name = g.watchNames and g.watchNames[itemID],
		}
	end
	table.sort(list, function(a, b)
		return (a.name or tostring(a.itemID)) < (b.name or tostring(b.itemID))
	end)
	return list
end

-------------------------------------------------------------------------------
-- Row initializers
-------------------------------------------------------------------------------

local function EnsureLogRowWidgets(row)
	if row.timeText then
		return
	end
	row.timeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.timeText:SetPoint("LEFT", 6, 0)
	row.timeText:SetWidth(106)
	row.timeText:SetJustifyH("LEFT")
	row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.nameText:SetPoint("LEFT", 118, 0)
	row.nameText:SetWidth(132)
	row.nameText:SetJustifyH("LEFT")
	row.actionText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.actionText:SetPoint("LEFT", 256, 0)
	row.actionText:SetWidth(88)
	row.actionText:SetJustifyH("LEFT")
	row.detailText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.detailText:SetPoint("LEFT", 350, 0)
	row.detailText:SetPoint("RIGHT", -4, 0)
	row.detailText:SetJustifyH("LEFT")
	row:SetHyperlinksEnabled(true)
	row:SetScript("OnHyperlinkEnter", function(self, link)
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetHyperlink(link)
		GameTooltip:Show()
	end)
	row:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	row:SetScript("OnHyperlinkClick", function(self, link, text, button)
		SetItemRef(link, text, button, self)
	end)
end

local function InitLogRow(row, data)
	EnsureLogRowWidgets(row)
	row.timeText:SetText(date("%Y-%m-%d %H:%M", data.epoch))
	row.actionText:SetText(ACTION_TEXT[data.code] or "?")
	if data.code == TYPE.UNATTRIBUTED then
		row.nameText:SetText("|cffffcc00?|r")
		row.detailText:SetText("|cffffcc00" .. (data.itemName or "Unattributed changes") .. "|r")
	elseif data.code == TYPE.GOLD_WITHDRAW or data.code == TYPE.GOLD_DEPOSIT or data.code == TYPE.REPAIR then
		row.nameText:SetText(ColorName(data.player))
		row.detailText:SetText(MoneyText(data.copper or 0))
	else
		row.nameText:SetText(ColorName(data.player))
		local shown
		if data.itemID then
			local _, link = C_Item.GetItemInfo(data.itemID)
			shown = link or ("[" .. (data.itemName or ("item " .. data.itemID)) .. "]")
		else
			shown = "[" .. (data.itemName or "Unknown item") .. "]"
		end
		if data.count and data.count > 1 then
			shown = shown .. " x" .. data.count
		end
		row.detailText:SetText(shown)
	end
end

local function InitTotalsRow(row, data)
	if not row.nameText then
		local cols = {
			{ "nameText", 6, 150 },
			{ "itemsOutText", 162, 80 },
			{ "itemsInText", 248, 80 },
			{ "goldOutText", 334, 140 },
			{ "goldInText", 480, 140 },
		}
		for _, c in ipairs(cols) do
			local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("LEFT", c[2], 0)
			fs:SetWidth(c[3])
			fs:SetJustifyH("LEFT")
			row[c[1]] = fs
		end
	end
	row.nameText:SetText(ColorName(data.player))
	row.itemsOutText:SetText(data.itemsOut > 0 and ("|cffff5555" .. data.itemsOut .. "|r") or "0")
	row.itemsInText:SetText(tostring(data.itemsIn))
	row.goldOutText:SetText(data.goldOut > 0 and ("|cffff5555" .. MoneyText(data.goldOut) .. "|r") or "-")
	row.goldInText:SetText(data.goldIn > 0 and MoneyText(data.goldIn) or "-")
end

local function InitWatchRow(row, data)
	if not row.icon then
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 6, 0)
		row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.nameText:SetPoint("LEFT", 32, 0)
		row.nameText:SetWidth(316)
		row.nameText:SetJustifyH("LEFT")
		row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.countText:SetPoint("LEFT", 356, 0)
		row.countText:SetWidth(180)
		row.countText:SetJustifyH("LEFT")
		row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
		row.remove:SetSize(20, 20)
		row.remove:SetPoint("RIGHT", -6, 0)
		row.remove:SetScript("OnClick", function(btn)
			ns.RemoveWatch(btn:GetParent().itemID)
		end)
	end
	row.itemID = data.itemID
	local icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(data.itemID)
	row.icon:SetTexture(icon or 134400) -- question mark icon fallback
	local name = data.name
	if not name then
		name = "item " .. data.itemID
		if C_Item.DoesItemExistByID(data.itemID) then
			local item = Item:CreateFromItemID(data.itemID)
			item:ContinueOnItemLoad(function()
				local g = ns.GetGuildData(false)
				if g then
					g.watchNames = g.watchNames or {}
					g.watchNames[data.itemID] = item:GetItemName()
				end
				if window and window:IsShown() and currentView == "watch" then
					Refresh()
				end
			end)
		end
	end
	row.nameText:SetText(name)
	if data.have == nil then
		row.countText:SetText("|cff888888? / " .. data.min .. " (no bank scan yet)|r")
	elseif data.have < data.min then
		row.countText:SetText(("|cffff5555%d / %d — low!|r"):format(data.have, data.min))
	else
		row.countText:SetText(("|cff55ff55%d / %d|r"):format(data.have, data.min))
	end
end

-------------------------------------------------------------------------------
-- Views
-------------------------------------------------------------------------------

local function CreateLogView(content)
	logView = CreateFrame("Frame", nil, content)
	logView:SetAllPoints()

	local filterButton = CreateFrame("Button", nil, logView, "UIPanelButtonTemplate")
	filterButton:SetSize(130, 22)
	filterButton:SetPoint("TOPLEFT", 0, 0)
	filterButton:SetText("Filter: All")
	filterButton:SetScript("OnClick", function(self)
		typeFilterIndex = typeFilterIndex % #TYPE_FILTERS + 1
		self:SetText("Filter: " .. TYPE_FILTERS[typeFilterIndex].label)
		Refresh()
	end)

	local nameLabel = logView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nameLabel:SetPoint("LEFT", filterButton, "RIGHT", 14, 0)
	nameLabel:SetText("Character:")
	nameBox = CreateFrame("EditBox", nil, logView, "InputBoxTemplate")
	nameBox:SetSize(140, 20)
	nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnTextChanged", function(self)
		nameFilter = self:GetText() or ""
		Refresh()
	end)
	nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	AddHeader(logView, "Time", 8, -32)
	AddHeader(logView, "Character", 120, -32)
	AddHeader(logView, "Action", 258, -32)
	AddHeader(logView, "Item / Gold", 352, -32)

	local listFrame = CreateFrame("Frame", nil, logView)
	listFrame:SetPoint("TOPLEFT", 0, -48)
	listFrame:SetPoint("BOTTOMRIGHT", 0, 0)
	logBox = CreateList(listFrame, InitLogRow, 22)
	AddEmptyText(logView, "Nothing recorded yet — visit your guild bank to scan its log.")
end

local function CreateTotalsView(content)
	totalsView = CreateFrame("Frame", nil, content)
	totalsView:SetAllPoints()
	AddHeader(totalsView, "Character", 6, 0)
	AddHeader(totalsView, "Items out", 162, 0)
	AddHeader(totalsView, "Items in", 248, 0)
	AddHeader(totalsView, "Gold out", 334, 0)
	AddHeader(totalsView, "Gold in", 480, 0)
	local listFrame = CreateFrame("Frame", nil, totalsView)
	listFrame:SetPoint("TOPLEFT", 0, -16)
	listFrame:SetPoint("BOTTOMRIGHT", 0, 0)
	totalsBox = CreateList(listFrame, InitTotalsRow, 22)
	AddEmptyText(totalsView, "Nothing recorded yet — visit your guild bank to scan its log.")
end

local function CreateWatchView(content)
	watchView = CreateFrame("Frame", nil, content)
	watchView:SetAllPoints()
	AddHeader(watchView, "Tracked item", 32, 0)
	AddHeader(watchView, "In bank / Minimum", 356, 0)

	local listFrame = CreateFrame("Frame", nil, watchView)
	listFrame:SetPoint("TOPLEFT", 0, -16)
	listFrame:SetPoint("BOTTOMRIGHT", 0, 34)
	watchBox = CreateList(listFrame, InitWatchRow, 24)
	AddEmptyText(watchView, "No tracked items. Add one below using its item ID from wowhead.com.")

	local idLabel = watchView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	idLabel:SetPoint("BOTTOMLEFT", 2, 12)
	idLabel:SetText("Item ID:")
	idBox = CreateFrame("EditBox", nil, watchView, "InputBoxTemplate")
	idBox:SetSize(80, 20)
	idBox:SetPoint("LEFT", idLabel, "RIGHT", 10, 0)
	idBox:SetAutoFocus(false)
	idBox:SetNumeric(true)
	local minLabel = watchView:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	minLabel:SetPoint("LEFT", idBox, "RIGHT", 12, 0)
	minLabel:SetText("Minimum:")
	minBox = CreateFrame("EditBox", nil, watchView, "InputBoxTemplate")
	minBox:SetSize(50, 20)
	minBox:SetPoint("LEFT", minLabel, "RIGHT", 10, 0)
	minBox:SetAutoFocus(false)
	minBox:SetNumeric(true)
	local addButton = CreateFrame("Button", nil, watchView, "UIPanelButtonTemplate")
	addButton:SetSize(60, 22)
	addButton:SetPoint("LEFT", minBox, "RIGHT", 14, 0)
	addButton:SetText("Add")

	local function DoAdd()
		local id = idBox:GetText()
		if id and id ~= "" then
			ns.AddWatch(id, minBox:GetText())
			idBox:SetText("")
			minBox:SetText("")
			Refresh()
		end
	end
	addButton:SetScript("OnClick", DoAdd)
	idBox:SetScript("OnEnterPressed", DoAdd)
	minBox:SetScript("OnEnterPressed", DoAdd)
	idBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	minBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	local hint = watchView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", addButton, "RIGHT", 14, 0)
	hint:SetText("Type an item ID from wowhead.com, or shift-click an item link.")

	-- Shift-clicked item links land in the ID box while this view is open.
	if type(ChatEdit_InsertLink) == "function" then
		hooksecurefunc("ChatEdit_InsertLink", function(text)
			if window and window:IsShown() and currentView == "watch" and type(text) == "string" then
				local id = text:match("item:(%d+)")
				if id then
					idBox:SetText(id)
				end
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

Refresh = function()
	if not window or not window:IsShown() then
		return
	end
	if currentView == "log" and logBox then
		local list = BuildLogList()
		SetListData(logBox, list)
		logView.empty:SetShown(#list == 0)
	elseif currentView == "totals" and totalsBox then
		local list = BuildTotalsList()
		SetListData(totalsBox, list)
		totalsView.empty:SetShown(#list == 0)
	elseif currentView == "watch" and watchBox then
		local list = BuildWatchList()
		SetListData(watchBox, list)
		watchView.empty:SetShown(#list == 0)
	end
end

ns.RefreshUI = function()
	Refresh()
end

ShowView = function(name)
	currentView = name
	if name == "log" and not logView then CreateLogView(window.content) end
	if name == "totals" and not totalsView then CreateTotalsView(window.content) end
	if name == "watch" and not watchView then CreateWatchView(window.content) end
	if logView then logView:SetShown(name == "log") end
	if totalsView then totalsView:SetShown(name == "totals") end
	if watchView then watchView:SetShown(name == "watch") end
	for viewName, btn in pairs(window.viewButtons) do
		btn:SetEnabled(viewName ~= name)
	end
	Refresh()
end

local function GetWindow()
	if window then
		return window
	end
	window = CreateFrame("Frame", "GuildBankWatchFrame", UIParent, "BasicFrameTemplateWithInset")
	window:SetSize(720, 480)
	window:SetPoint("CENTER")
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	window:SetClampedToScreen(true)
	window:SetToplevel(true)
	window:Hide()
	tinsert(UISpecialFrames, "GuildBankWatchFrame")

	if window.TitleText then
		window.TitleText:SetText("GuildBankWatch")
	else
		local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -5)
		title:SetText("GuildBankWatch")
	end

	window.viewButtons = {}
	local defs = { { "log", "Log" }, { "totals", "Totals" }, { "watch", "Watchlist" } }
	local prev
	for _, def in ipairs(defs) do
		local btn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
		btn:SetSize(80, 22)
		if prev then
			btn:SetPoint("LEFT", prev, "RIGHT", 6, 0)
		else
			btn:SetPoint("TOPLEFT", 12, -30)
		end
		btn:SetText(def[2])
		btn:SetScript("OnClick", function() ShowView(def[1]) end)
		window.viewButtons[def[1]] = btn
		prev = btn
	end

	local exportButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	exportButton:SetSize(90, 22)
	exportButton:SetPoint("TOPRIGHT", -12, -30)
	exportButton:SetText("Export CSV")
	exportButton:SetScript("OnClick", function() ns.OpenExport() end)

	window.content = CreateFrame("Frame", nil, window)
	window.content:SetPoint("TOPLEFT", 12, -58)
	window.content:SetPoint("BOTTOMRIGHT", -12, 12)

	window:SetScript("OnShow", function()
		if C_GuildInfo and C_GuildInfo.GuildRoster then
			C_GuildInfo.GuildRoster()
		end
		BuildClassColors()
		Refresh()
	end)

	ShowView(currentView)
	return window
end

function ns.ToggleWindow(filterName)
	local f = GetWindow()
	if filterName and filterName ~= "" then
		ShowView("log")
		f:Show()
		nameBox:SetText(filterName) -- OnTextChanged refreshes
	elseif f:IsShown() then
		f:Hide()
	else
		f:Show()
	end
end

-------------------------------------------------------------------------------
-- CSV export
-------------------------------------------------------------------------------

local function CsvField(v)
	v = v == nil and "" or tostring(v)
	if v:find('[",\r\n]') then
		v = '"' .. v:gsub('"', '""') .. '"'
	end
	return v
end

function ns.BuildCSV(g)
	local rows = { "DateTimeUTC,Guild,Character,Action,ItemID,ItemName,Count,GoldCopper,Tab,Unattributed" }
	local sorted = {}
	for _, rec in ipairs(g.records or {}) do
		sorted[#sorted + 1] = rec
	end
	table.sort(sorted, function(a, b)
		return (tonumber(a:match("^%d+")) or 0) < (tonumber(b:match("^%d+")) or 0)
	end)
	local guildName = g.name or ""
	for _, rec in ipairs(sorted) do
		local epoch, code, player, itemID, itemName, count, copper, tab = ns.DecodeRecord(rec)
		if epoch and code then
			rows[#rows + 1] = table.concat({
				CsvField(date("!%Y-%m-%d %H:%M", epoch)),
				CsvField(guildName),
				CsvField(player),
				CsvField(ns.ACTION_LABELS[code] or code),
				CsvField(itemID),
				CsvField(itemName),
				CsvField(count),
				CsvField(copper and ("%.0f"):format(copper) or ""),
				CsvField(tab),
				CsvField(code == TYPE.UNATTRIBUTED and 1 or 0),
			}, ",")
		end
	end
	return table.concat(rows, "\n")
end

local function GetExportFrame()
	if exportFrame then
		return exportFrame
	end
	exportFrame = CreateFrame("Frame", "GuildBankWatchExportFrame", UIParent, "BasicFrameTemplateWithInset")
	exportFrame:SetSize(560, 420)
	exportFrame:SetPoint("CENTER")
	exportFrame:SetFrameStrata("DIALOG")
	exportFrame:SetMovable(true)
	exportFrame:EnableMouse(true)
	exportFrame:RegisterForDrag("LeftButton")
	exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
	exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
	exportFrame:SetClampedToScreen(true)
	exportFrame:Hide()
	tinsert(UISpecialFrames, "GuildBankWatchExportFrame")

	if exportFrame.TitleText then
		exportFrame.TitleText:SetText("GuildBankWatch — CSV Export")
	end
	local hint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hint:SetPoint("TOP", 0, -28)
	hint:SetText("Press Ctrl+C to copy, then paste into a spreadsheet.")

	local scroll = CreateFrame("ScrollFrame", nil, exportFrame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -46)
	scroll:SetPoint("BOTTOMRIGHT", -32, 14)
	local editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetFontObject(ChatFontNormal)
	editBox:SetWidth(500)
	editBox:SetAutoFocus(false)
	editBox:SetMaxLetters(0)
	editBox:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
	scroll:SetScrollChild(editBox)
	exportFrame.editBox = editBox
	return exportFrame
end

function ns.OpenExport()
	local g = ns.GetGuildData(false)
	if not g or not g.records or #g.records == 0 then
		ns.Print("Nothing recorded yet for this guild — visit the guild bank first.")
		return
	end
	local f = GetExportFrame()
	f.editBox:SetText(ns.BuildCSV(g))
	f:Show()
	f.editBox:SetFocus()
	f.editBox:HighlightText()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

StaticPopupDialogs["GBW_CONFIRM_PURGE"] = {
	text = "Delete ALL GuildBankWatch data recorded for this guild?",
	button1 = YES,
	button2 = NO,
	OnAccept = function() ns.PurgeGuild() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

SLASH_GUILDBANKWATCH1 = "/gbw"
SLASH_GUILDBANKWATCH2 = "/guildbankwatch"
SlashCmdList.GUILDBANKWATCH = function(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	local lower = cmd:lower()
	if lower == "" then
		ns.ToggleWindow()
	elseif lower == "export" then
		ns.OpenExport()
	elseif lower == "track" then
		local id, minCount = rest:match("^(%d+)%s*(%d*)$")
		if id then
			ns.AddWatch(id, minCount ~= "" and minCount or nil)
		else
			ns.Print("Usage: /gbw track <itemID> [minimum] — find item IDs on wowhead.com")
		end
	elseif lower == "untrack" then
		ns.RemoveWatch(rest:match("^(%d+)"))
	elseif lower == "purge" then
		StaticPopup_Show("GBW_CONFIRM_PURGE")
	elseif lower == "help" or lower == "?" then
		ns.Print("Commands:")
		ns.Print("  /gbw — toggle the window")
		ns.Print("  /gbw <character> — open the log filtered to a character")
		ns.Print("  /gbw track <itemID> [minimum] — watch an item for low stock")
		ns.Print("  /gbw untrack <itemID> — stop watching an item")
		ns.Print("  /gbw export — open the CSV export window")
		ns.Print("  /gbw purge — delete this guild's recorded data")
	else
		ns.ToggleWindow(msg)
	end
end
