local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local _ = require("gettext")
local Screen = Device.screen

local FooterText = WidgetContainer:extend{
    name = "footertext",
    is_doc_only = true,
}

function FooterText:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
    self:buildWidget()
    self.ui.view:registerViewModule("footertext", self)
end

function FooterText:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("footertext_enabled", true)
    self.format = G_reader_settings:readSetting("footertext_format", "Page %c")
    self.font_size = G_reader_settings:readSetting("footertext_font_size", footer_settings.text_font_size)
    self.font_face_name = G_reader_settings:readSetting("footertext_font_face", "ffont")
    self.font_bold = footer_settings.text_font_bold or false
    self.vertical_offset = G_reader_settings:readSetting("footertext_vertical_offset", 35)
end

function FooterText:expandTokens(format_str)
    if not format_str:find("%%") then
        return format_str
    end

    local pageno = self.ui.view.state.page
    local doc = self.ui.document

    -- %c - current page (respects pagemap and hidden flows)
    local currentpage
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        currentpage = self.ui.pagemap:getCurrentPageLabel(true) or "N/A"
    elseif pageno and doc:hasHiddenFlows() then
        currentpage = doc:getPageNumberInFlow(pageno)
    else
        currentpage = pageno or 0
    end

    -- %t - total pages (respects hidden flows)
    local totalpages
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        totalpages = self.ui.pagemap:getLastPageLabel(true) or "N/A"
    elseif pageno and doc:hasHiddenFlows() then
        local flow = doc:getPageFlow(pageno)
        totalpages = doc:getTotalPagesInFlow(flow)
    else
        totalpages = doc:getPageCount()
    end

    -- %p - percentage
    local percent
    if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
        percent = math.floor(currentpage / totalpages * 100)
    else
        percent = 0
    end

    -- %T, %A, %S - document metadata
    local props = doc:getProps()
    local title = props.display_title or "N/A"
    local authors = props.authors or "N/A"
    local series = props.series or "N/A"
    if series ~= "N/A" and props.series_index then
        series = series .. " #" .. props.series_index
    end

    -- %h - time left in chapter, %H - time left in document
    local time_left_chapter = "N/A"
    local time_left_doc = "N/A"
    local footer = self.ui.view.footer
    local avg_time = footer and footer.getAvgTimePerPage and footer:getAvgTimePerPage()
    if avg_time and avg_time == avg_time and pageno then
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        local chapter_pages_left = self.ui.toc:getChapterPagesLeft(pageno)
            or doc:getTotalPagesLeft(pageno)
        time_left_chapter = datetime.secondsToClockDuration(
            user_duration_format, chapter_pages_left * avg_time, true)
        local doc_pages_left = doc:getTotalPagesLeft(pageno)
        time_left_doc = datetime.secondsToClockDuration(
            user_duration_format, doc_pages_left * avg_time, true)
    end

    -- %b, %B - battery
    local powerd = Device:getPowerDevice()
    local batt_lvl = powerd:getCapacity()
    local batt_symbol
    if batt_lvl then
        batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), batt_lvl) or "N/A"
    else
        batt_lvl = "N/A"
        batt_symbol = "N/A"
    end

    local replace = {
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%c"] = tostring(currentpage),
        ["%t"] = tostring(totalpages),
        ["%p"] = tostring(percent),
        ["%h"] = tostring(time_left_chapter),
        ["%H"] = tostring(time_left_doc),
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
    }
    return format_str:gsub("(%%%a)", replace)
end

function FooterText:updateText()
    local new_text = self:expandTokens(self.format)
    if new_text ~= self.current_text then
        self.current_text = new_text
        self.text_widget:setText(new_text)
        -- Update center container height to match new text size
        self.center_container.dimen.h = self.text_widget:getSize().h
    end
end

function FooterText:buildWidget()
    local screen_size = Screen:getSize()
    self.text_face = Font:getFace(self.font_face_name, self.font_size)
    self.text_widget = TextWidget:new{
        text = "",
        face = self.text_face,
        bold = self.font_bold,
    }
    self.center_container = CenterContainer:new{
        dimen = Geom:new{ w = screen_size.w, h = self.text_widget:getSize().h },
        self.text_widget,
    }
    self.bottom_container = BottomContainer:new{
        dimen = Geom:new{ w = screen_size.w, h = screen_size.h },
        self.center_container,
    }
end

function FooterText:rebuildWidget()
    if self.text_widget then
        self.text_widget:free()
    end
    self.current_text = nil
    self:buildWidget()
    UIManager:setDirty(self.ui, "ui")
end

function FooterText:updatePosition()
    local screen_size = Screen:getSize()
    self.bottom_container.dimen.w = screen_size.w
    self.bottom_container.dimen.h = screen_size.h - self.vertical_offset
    self.center_container.dimen.w = screen_size.w
end

function FooterText:onPageUpdate(pageno)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:onPosUpdate(pos)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end


function FooterText:onReaderFooterVisibilityChange()
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:onSetDimensions(dimen)
    if self.enabled then
        UIManager:setDirty(self.ui, "ui")
    end
end

function FooterText:paintTo(bb, x, y)
    if not self.enabled then return end
    self:updateText()
    self:updatePosition()
    self.bottom_container:paintTo(bb, x, y)
end

function FooterText:onCloseWidget()
    if self.text_widget then
        self.text_widget:free()
    end
end

function FooterText:addToMainMenu(menu_items)
    menu_items.footertext = {
        text = _("Footer text"),
        sorting_hint = "status_bar",
        sub_item_table = {
            {
                text = _("Enable footer text"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self.enabled = not self.enabled
                    G_reader_settings:saveSetting("footertext_enabled", self.enabled)
                    UIManager:setDirty(self.ui, "ui")
                end,
            },
            {
                text = _("Edit format string"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editFormatString()
                end,
            },
            {
                text = _("Font"),
                enabled_func = function()
                    return self.enabled
                end,
                sub_item_table = self:buildFontMenu(),
            },
            {
                text = _("Font size"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editFontSize()
                end,
            },
            {
                text = _("Vertical offset"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled
                end,
                callback = function()
                    self:editVerticalOffset()
                end,
            },
        },
    }
end

function FooterText:buildFontMenu()
    local font_choices = {
        { text = "NotoSans Regular", face = "ffont" },
        { text = "NotoSans Bold", face = "tfont" },
        { text = "DroidSans Mono", face = "infont" },
    }
    local menu = {}
    for _, choice in ipairs(font_choices) do
        table.insert(menu, {
            text = choice.text,
            checked_func = function()
                return self.font_face_name == choice.face
            end,
            callback = function()
                self.font_face_name = choice.face
                G_reader_settings:saveSetting("footertext_font_face", choice.face)
                self:rebuildWidget()
            end,
        })
    end
    return menu
end

function FooterText:editFormatString()
    local format_dialog
    format_dialog = InputDialog:new{
        title = _("Footer text format string"),
        input = self.format,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(format_dialog)
                    end,
                },
                {
                    text = _("Info"),
                    callback = function()
                        UIManager:show(InfoMessage:new{
                            text = _([[
Available tokens:
%T  title
%A  author(s)
%S  series
%c  current page number
%t  total page number
%p  percentage read
%h  time left in chapter
%H  time left in document
%b  battery level
%B  battery symbol]]),
                        })
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self.format = format_dialog:getInputText()
                        G_reader_settings:saveSetting("footertext_format", self.format)
                        UIManager:close(format_dialog)
                        UIManager:setDirty(self.ui, "ui")
                    end,
                },
            },
        },
    }
    UIManager:show(format_dialog)
    format_dialog:onShowKeyboard()
end

function FooterText:editFontSize()
    local spin = SpinWidget:new{
        value = self.font_size,
        value_min = 8,
        value_max = 36,
        default_value = self.ui.view.footer.settings.text_font_size,
        title_text = _("Footer text font size"),
        ok_text = _("Set"),
        callback = function(spin)
            self.font_size = spin.value
            G_reader_settings:saveSetting("footertext_font_size", self.font_size)
            self:rebuildWidget()
        end,
    }
    UIManager:show(spin)
end

function FooterText:editVerticalOffset()
    local spin = SpinWidget:new{
        value = self.vertical_offset,
        value_min = -100,
        value_max = 100,
        default_value = 35,
        title_text = _("Vertical offset (pixels up)"),
        ok_text = _("Set"),
        callback = function(spin)
            self.vertical_offset = spin.value
            G_reader_settings:saveSetting("footertext_vertical_offset", self.vertical_offset)
            UIManager:setDirty(self.ui, "ui")
        end,
    }
    UIManager:show(spin)
end

return FooterText
