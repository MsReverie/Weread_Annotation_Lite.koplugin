--[[--
Thought popup widget (centered rounded frame).

Renders review items with XText into a bitmap viewport that scrolls.
Tap inside the frame turns pages; tap outside closes it. No dim overlay.
--]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local PageRenderer = require("ui.thought_popup_renderer")
local ScrollContainer = require("ui.thought_popup_scroll")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local OUTER_MARGIN = Screen:scaleBySize(24)
local FRAME_PAD_V = Size.padding.large
local FRAME_PAD_H = Size.padding.small
local FRAME_BORDER = Size.border.window or Size.line.medium
local SCROLLBAR_W = math.min(math.ceil(Screen:scaleBySize(20) * 2 / 5), Screen:scaleBySize(10))

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_size = Screen:scaleBySize(22),
    doc_margins = {
        left = Screen:scaleBySize(10),
        right = Screen:scaleBySize(10),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.74,
    close_callback = nil,

    _pages = nil,
    _scroll_container = nil,
}

function ThoughtPopupWidget:init()
    self.width = math.max(1, Screen:getWidth() - 2 * OUTER_MARGIN)
    self.height = math.min(
        math.floor(Screen:getHeight() * self.height_ratio),
        math.max(1, Screen:getHeight() - 2 * OUTER_MARGIN))

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
            -- Match KOReader's ScrollTextWidget event name. This keeps
            -- vertical swipes in the standard scroll dispatch path instead
            -- of relying on the popup close handler to reinterpret them.
            ScrollText = {
                GestureRange:new{
                    ges = "swipe",
                    range = function()
                        return self._scroll_container and self._scroll_container.dimen or range
                    end,
                }
            },
            PanScroll = {
                GestureRange:new{
                    ges = "pan",
                    range = function()
                        return self.container and self.container.dimen or range
                    end,
                }
            },
            PanReleaseScroll = {
                GestureRange:new{
                    ges = "pan_release",
                    range = function()
                        return self.container and self.container.dimen or range
                    end,
                }
            },
        }
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        content_width = self:_innerWidth(),
    }
    self._pages:ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:_innerWidth()
    return math.max(1, self.width - 2 * FRAME_PAD_H - 2 * FRAME_BORDER)
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    self.items = opts.items or {}
    self.close_callback = opts.close_callback
    self.width = math.max(1, Screen:getWidth() - 2 * OUTER_MARGIN)
    self.height = math.min(
        math.floor(Screen:getHeight() * self.height_ratio),
        math.max(1, Screen:getHeight() - 2 * OUTER_MARGIN))

    self._pages:setContent(self.items, self.doc_font_size,
        self.doc_margins, self:_innerWidth())
    self:_buildLayout()
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    local text_w = self._pages.text_w
    local content_h = self._pages.content_h
    local inner_w = self:_innerWidth()
    local chrome = 2 * FRAME_PAD_V + 2 * FRAME_BORDER
    local max_h = math.max(1, Screen:getHeight() - 2 * OUTER_MARGIN)
    local ratio_h = math.min(math.floor(Screen:getHeight() * self.height_ratio), max_h)
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(22)) * 1.2)

    local viewport_h
    if content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = content_h
        self.height = content_h + chrome
    else
        viewport_h = math.max(1, ratio_h - chrome)
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    local scroll = ScrollContainer:new{
        content_h = content_h,
        viewport_h = viewport_h,
        box_w = inner_w,
        scrollbar_w = SCROLLBAR_W,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self,
        boundaries = self._pages.boundaries,
        page_bb_getter = function(page_idx)
            local pages = self._scroll_container and self._scroll_container.pages
            return self._pages:renderPage(page_idx, pages)
        end,
    }
    self._scroll_container = scroll

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = FRAME_BORDER,
        radius = Size.radius.default,
        margin = 0,
        padding = FRAME_PAD_V,
        padding_left = FRAME_PAD_H,
        padding_right = FRAME_PAD_H,
        width = self.width,
        VerticalGroup:new{
            scroll,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.container
    }
end

function ThoughtPopupWidget:onCloseWidget()
    UIManager:setDirty(self, function()
        return "partial", self.container.dimen
    end)
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback()
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTap(_, ges)
    local frame = self.container and self.container.dimen
    if not frame then return true end
    if ges.pos:notIntersectWith(frame) then
        UIManager:close(self)
        return true
    end
    if self._scroll_container then
        self._scroll_container:scrollToPage(1)
    end
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)

    local scroll_dimen = self._scroll_container and self._scroll_container.dimen

    -- 只处理内容区域内的滑动
    if not scroll_dimen or not ges.pos:intersectWith(scroll_dimen) then
        return false
    end

    -- 左右滑动 → 关闭弹窗
    if direction == "west" or direction == "east" then
        UIManager:close(self)
        return true
    end

    -- 上下滑动 → 滚动内容
    if direction == "north" or direction == "up" then
        return self._scroll_container:onScrollText(nil, ges)
    elseif direction == "south" or direction == "down" then
        return self._scroll_container:onScrollText(nil, ges)
    end

    return false
end

function ThoughtPopupWidget:onScrollText(_, ges)
    if not self._scroll_container then return false end
    return self._scroll_container:onScrollText(nil, ges)
end

function ThoughtPopupWidget:onPanScroll(_, ges)
    return self._scroll_container:onPanText(nil, ges)
end

function ThoughtPopupWidget:onPanReleaseScroll(_, ges)
    return self._scroll_container:onPanReleaseText(nil, ges)
end

return ThoughtPopupWidget
