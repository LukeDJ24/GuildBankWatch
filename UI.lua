-- GuildBankWatch UI: lazily created window (Log / Totals / Watchlist views),
-- CSV export, watchlist share/import dialogs, and slash commands. No frames
-- are allocated until the window is first opened.

local ADDON_NAME, ns = ...
local TYPE = ns.TYPE

local window, exportFrame, shareFrame, importFrame
local importItems -- parsed contents of the import box, nil until it validates
local editingWatchRow -- minimum box currently being typed into, if any
local refreshing = false
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

local function SetActionTooltip(widget, text)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(text, nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
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

-- Applies whatever is in a row's minimum box, or puts the stored value back
-- if it is not usable.
local function CommitWatchMin(box)
	local row = box:GetParent()
	local typed = box:GetText() or ""
	local value = tonumber(typed)
	if box.cancelled or not value or value < 1 then
		if not box.cancelled and typed ~= "" then
			ns.Print("Minimum must be a whole number of 1 or more.")
		end
		box.cancelled = nil
		box:SetText(tostring(row.currentMin or ""))
		return
	end
	value = math.floor(value)
	if row.itemID and value ~= row.currentMin then
		row.currentMin = value -- set first, so a redraw cannot re-apply it
		ns.SetWatchMinimum(row.itemID, value)
	end
end

local function InitWatchRow(row, data)
	if not row.icon then
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 6, 0)
		row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.nameText:SetPoint("LEFT", 32, 0)
		row.nameText:SetWidth(310)
		row.nameText:SetJustifyH("LEFT")
		row.haveText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.haveText:SetPoint("LEFT", 352, 0)
		row.haveText:SetWidth(48)
		row.haveText:SetJustifyH("LEFT")
		row.slashText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.slashText:SetPoint("LEFT", 404, 0)
		row.slashText:SetText("/")
		row.minBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
		row.minBox:SetSize(46, 20)
		row.minBox:SetPoint("LEFT", 418, 0)
		row.minBox:SetAutoFocus(false)
		row.minBox:SetNumeric(true)
		row.minBox:SetMaxLetters(6)
		row.minBox:SetJustifyH("CENTER")
		row.minBox:SetScript("OnEditFocusGained", function(self)
			editingWatchRow = self
			self:HighlightText()
		end)
		row.minBox:SetScript("OnEditFocusLost", function(self)
			if editingWatchRow == self then
				editingWatchRow = nil
			end
			CommitWatchMin(self)
		end)
		row.minBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		row.minBox:SetScript("OnEscapePressed", function(self)
			self.cancelled = true
			self:ClearFocus()
		end)
		SetActionTooltip(row.minBox, "Type a new minimum and press Enter. Escape cancels.")
		row.flagText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.flagText:SetPoint("LEFT", 474, 0)
		row.flagText:SetWidth(130)
		row.flagText:SetJustifyH("LEFT")
		row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
		row.remove:SetSize(20, 20)
		row.remove:SetPoint("RIGHT", -6, 0)
		row.remove:SetScript("OnClick", function(btn)
			ns.RemoveWatch(btn:GetParent().itemID)
		end)
	end
	-- Scrolling can hand this recycled frame to a different item mid-edit, so
	-- commit first, while row.itemID still points at the one being edited.
	if row.minBox:HasFocus() then
		row.minBox:ClearFocus()
	end
	row.itemID = data.itemID
	row.currentMin = data.min
	row.minBox:SetText(tostring(data.min))
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
		row.haveText:SetText("|cff888888?|r")
		row.flagText:SetText("|cff888888no bank scan yet|r")
	elseif data.have < data.min then
		row.haveText:SetText(("|cffff5555%d|r"):format(data.have))
		row.flagText:SetText("|cffff5555low!|r")
	else
		row.haveText:SetText(("|cff55ff55%d|r"):format(data.have))
		row.flagText:SetText("")
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
	AddHeader(watchView, "In bank", 352, 0)
	AddHeader(watchView, "Minimum", 420, 0)

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

	local importButton = CreateFrame("Button", nil, watchView, "UIPanelButtonTemplate")
	importButton:SetSize(70, 22)
	importButton:SetPoint("BOTTOMRIGHT", -2, 12)
	importButton:SetText("Import")
	importButton:SetScript("OnClick", function() ns.OpenWatchImport() end)

	local shareButton = CreateFrame("Button", nil, watchView, "UIPanelButtonTemplate")
	shareButton:SetSize(70, 22)
	shareButton:SetPoint("RIGHT", importButton, "LEFT", -6, 0)
	shareButton:SetText("Export")
	shareButton:SetScript("OnClick", function() ns.OpenWatchExport() end)

	local hint = watchView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", addButton, "RIGHT", 14, 0)
	hint:SetPoint("RIGHT", shareButton, "LEFT", -10, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("IDs come from wowhead.com.")

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
	-- The re-entrancy guard matters because committing an edited minimum can
	-- trigger a refresh from inside the list's own row initializer.
	if not window or not window:IsShown() or refreshing then
		return
	end
	refreshing = true
	if currentView == "log" and logBox then
		local list = BuildLogList()
		SetListData(logBox, list)
		logView.empty:SetShown(#list == 0)
	elseif currentView == "totals" and totalsBox then
		local list = BuildTotalsList()
		SetListData(totalsBox, list)
		totalsView.empty:SetShown(#list == 0)
	elseif currentView == "watch" and watchBox and not editingWatchRow then
		-- Skipped while a minimum is being typed, so a background bank scan
		-- cannot reset the value under the cursor.
		local list = BuildWatchList()
		SetListData(watchBox, list)
		watchView.empty:SetShown(#list == 0)
	end
	refreshing = false
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

-------------------------------------------------------------------------------
-- Copy-paste dialogs
-------------------------------------------------------------------------------

-- Shared shell for the three text windows: a movable frame around a scrolling
-- multi-line edit box. Callers re-anchor .scroll when they need room for
-- controls along the bottom.
local function CreateTextDialog(globalName, title, width, height)
	local f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(width, height)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:Hide()
	tinsert(UISpecialFrames, globalName)

	if f.TitleText then
		f.TitleText:SetText(title)
	end
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.hint:SetPoint("TOP", 0, -28)

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -46)
	scroll:SetPoint("BOTTOMRIGHT", -32, 14)
	local editBox = CreateFrame("EditBox", nil, scroll)
	editBox:SetMultiLine(true)
	editBox:SetFontObject(ChatFontNormal)
	editBox:SetWidth(width - 60)
	editBox:SetAutoFocus(false)
	editBox:SetMaxLetters(0)
	editBox:SetScript("OnEscapePressed", function() f:Hide() end)
	scroll:SetScrollChild(editBox)
	f.scroll = scroll
	f.editBox = editBox
	return f
end

function ns.OpenExport()
	local g = ns.GetGuildData(false)
	if not g or not g.records or #g.records == 0 then
		ns.Print("Nothing recorded yet for this guild — visit the guild bank first.")
		return
	end
	if not exportFrame then
		exportFrame = CreateTextDialog("GuildBankWatchExportFrame", "GuildBankWatch — CSV Export", 560, 420)
		exportFrame.hint:SetText("Press Ctrl+C to copy, then paste into a spreadsheet.")
	end
	exportFrame.editBox:SetText(ns.BuildCSV(g))
	exportFrame:Show()
	exportFrame.editBox:SetFocus()
	exportFrame.editBox:HighlightText()
end

-------------------------------------------------------------------------------
-- Watchlist share / import
-------------------------------------------------------------------------------

function ns.OpenWatchExport()
	local text, info = ns.ExportWatchString()
	if not text then
		if info == "noguild" then
			ns.Print("You are not in a guild.")
		else
			ns.Print("No tracked items to export — add one from the Watchlist view first.")
		end
		return
	end
	if not shareFrame then
		shareFrame = CreateTextDialog("GuildBankWatchShareFrame", "GuildBankWatch — Export Tracked Items", 560, 250)
	end
	shareFrame.hint:SetText(("%d tracked item(s) — press Ctrl+C to copy, then share the string."):format(info))
	shareFrame.editBox:SetText(text)
	shareFrame:Show()
	shareFrame.editBox:SetFocus()
	shareFrame.editBox:HighlightText()
end

-- How many currently tracked items a "replace" would drop: everything tracked
-- now that the pasted string does not mention.
local function ReplaceDropCount(summary)
	return summary.existing - (summary.changed + summary.same)
end

local function UpdateImportPreview()
	local items, reason = ns.ParseWatchString(importFrame.editBox:GetText())
	importItems = items
	importFrame.merge:SetEnabled(items ~= nil)
	importFrame.replace:SetEnabled(items ~= nil)
	if not items then
		if reason == "empty" then
			importFrame.status:SetText("|cff888888Paste a string above to see what it contains.|r")
		elseif reason == "corrupt" then
			importFrame.status:SetText("|cffff5555That string is incomplete or damaged — copy the whole thing and try again.|r")
		else
			importFrame.status:SetText("|cffff5555That does not look like a GuildBankWatch item string.|r")
		end
		return
	end
	local summary = ns.SummarizeWatchImport(items)
	local lines = {
		("|cffffffff%d item(s)|r in this string: %d new, %d with a different minimum, %d already tracked as-is.")
			:format(#items, summary.new, summary.changed, summary.same),
	}
	if summary.unknown > 0 then
		lines[#lines + 1] = ("|cffff9933%d item ID(s) are unknown to this client and will be skipped.|r")
			:format(summary.unknown)
	end
	local drops = ReplaceDropCount(summary)
	if drops > 0 then
		lines[#lines + 1] = ("|cffffcc00Replace would remove %d tracked item(s) missing from this string.|r"):format(drops)
	end
	importFrame.status:SetText(table.concat(lines, "\n"))
end

local function ApplyImport(mode)
	if not importItems then
		return
	end
	local result = ns.ApplyWatchImport(importItems, mode)
	if not result then
		return
	end
	local parts = { ("%d added"):format(result.added), ("%d updated"):format(result.updated) }
	if result.removed > 0 then
		parts[#parts + 1] = ("%d removed"):format(result.removed)
	end
	if result.skipped > 0 then
		parts[#parts + 1] = ("%d skipped"):format(result.skipped)
	end
	ns.Print("Import complete: %s.", table.concat(parts, ", "))
	importFrame:Hide()
	Refresh()
end

StaticPopupDialogs["GBW_CONFIRM_IMPORT_REPLACE"] = {
	text = "Replace this guild's tracked items with the imported list?\n\n%d item(s) you track now are missing from the string and will be removed.",
	button1 = YES,
	button2 = NO,
	OnAccept = function() ApplyImport("replace") end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function ns.OpenWatchImport()
	if not importFrame then
		importFrame = CreateTextDialog("GuildBankWatchImportFrame", "GuildBankWatch — Import Tracked Items", 560, 300)
		importFrame.hint:SetText("Paste a GuildBankWatch item string below, then choose how to apply it.")
		importFrame.scroll:SetPoint("BOTTOMRIGHT", -32, 76)

		importFrame.status = importFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		importFrame.status:SetPoint("BOTTOMLEFT", 16, 46)
		importFrame.status:SetPoint("BOTTOMRIGHT", -16, 46)
		importFrame.status:SetJustifyH("LEFT")

		importFrame.merge = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
		importFrame.merge:SetSize(150, 22)
		importFrame.merge:SetPoint("BOTTOMLEFT", 16, 14)
		importFrame.merge:SetText("Merge into list")
		importFrame.merge:SetScript("OnClick", function() ApplyImport("merge") end)
		SetActionTooltip(importFrame.merge,
			"Adds the imported items and keeps everything you already track. Where an item appears in both, the imported minimum wins.")

		importFrame.replace = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
		importFrame.replace:SetSize(150, 22)
		importFrame.replace:SetPoint("LEFT", importFrame.merge, "RIGHT", 8, 0)
		importFrame.replace:SetText("Replace list")
		importFrame.replace:SetScript("OnClick", function()
			if not importItems then
				return
			end
			local drops = ReplaceDropCount(ns.SummarizeWatchImport(importItems))
			if drops > 0 then
				StaticPopup_Show("GBW_CONFIRM_IMPORT_REPLACE", drops)
			else
				ApplyImport("replace")
			end
		end)
		SetActionTooltip(importFrame.replace,
			"Makes this guild's watchlist an exact copy of the string. Items you track that are missing from it are removed.")

		importFrame.editBox:SetScript("OnTextChanged", UpdateImportPreview)
	end
	importFrame.editBox:SetText("")
	UpdateImportPreview()
	importFrame:Show()
	importFrame.editBox:SetFocus()
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
		local what = rest:lower()
		if what == "items" or what == "list" or what == "watchlist" then
			ns.OpenWatchExport()
		else
			ns.OpenExport()
		end
	elseif lower == "import" then
		ns.OpenWatchImport()
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
	elseif lower == "version" then
		local version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
			or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
		ns.Print("Version %s", version or "unknown")
	elseif lower == "help" or lower == "?" then
		ns.Print("Commands:")
		ns.Print("  /gbw — toggle the window")
		ns.Print("  /gbw <character> — open the log filtered to a character")
		ns.Print("  /gbw track <itemID> [minimum] — watch an item for low stock")
		ns.Print("  /gbw untrack <itemID> — stop watching an item")
		ns.Print("  /gbw export — open the CSV export window")
		ns.Print("  /gbw export items — copy your tracked items as a shareable string")
		ns.Print("  /gbw import — paste a shared tracked-items string")
		ns.Print("  /gbw purge — delete this guild's recorded data")
		ns.Print("  /gbw version — show the installed addon version")
	else
		ns.ToggleWindow(msg)
	end
end
