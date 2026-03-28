-- Adds up/down swipe for page navigation in CoverBrowser views
-- (History, Collections). Swipe up = next page, swipe down = previous
-- page — more natural than left/right in list views.

local BD = require("ui/bidi")
local Menu = require("ui/widget/menu")

local orig_onSwipe = Menu.onSwipe

function Menu:onSwipe(arg, ges_ev)
    if not self._coverbrowser_overridden then
        return orig_onSwipe(self, arg, ges_ev)
    end

    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)

    if direction == "north" then
        self:onNextPage()
        return true
    elseif direction == "south" then
        self:onPrevPage()
        return true
    end

    return orig_onSwipe(self, arg, ges_ev)
end
