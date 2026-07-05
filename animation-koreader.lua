--[[--
ALL-IN-ONE screen animation patch for e-ink devices (Cleaned & Optimized).
Default Linear Wipe animation engine for transitions and page turns.
--]]--

local Device = require("device")
local Event = require("ui/event")
local ReaderPaging = require("apps/reader/modules/readerpaging")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local Menu = require("ui/widget/menu")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local Screensaver = require("ui/screensaver")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local dbg = require("dbg")
local userpatch = require("userpatch")
local _ = require("gettext")
local PageTurns = require("ui/elements/page_turns")

local DEBUG = false -- Cambiar a true si necesitas depurar en la terminal

-- ============================================================================
-- Configuración y llaves de ajustes
-- ============================================================================
local DEFAULT_STEPS = 8
local DEFAULT_DELAY_MS = 20
local SETTING_KEY_STEPS = "page_turn_animation_steps"
local SETTING_KEY_DELAY = "page_turn_animation_delay_ms"
local SETTING_SCREENS = "page_turn_animation_screens"
local SETTING_LOCK = "page_turn_animation_lock_unlock"
local SETTING_BOOK = "page_turn_animation_open_close"

local function getSteps()
    return G_reader_settings:readSetting(SETTING_KEY_STEPS, DEFAULT_STEPS)
end

local function getDelayUs()
    return G_reader_settings:readSetting(SETTING_KEY_DELAY, DEFAULT_DELAY_MS) * 1000
end

local function screensAnimEnabled()
    return G_reader_settings:isTrue("swipe_animations") and G_reader_settings:nilOrTrue(SETTING_SCREENS)
end

local function lockAnimEnabled()
    return G_reader_settings:isTrue("swipe_animations") and G_reader_settings:nilOrTrue(SETTING_LOCK)
end

local function bookAnimEnabled()
    return G_reader_settings:isTrue("swipe_animations") and G_reader_settings:nilOrTrue(SETTING_BOOK)
end

-- ============================================================================
-- 1) EL MOTOR DE ANIMACIÓN (WIPE)
-- ============================================================================

Screen.beforePaint = function(self)
    if not self.painting then
        self.painting = true
        if self.swipe_animations then
            if self.saved_bb then self.saved_bb:free() end
            self.saved_bb = self.bb:copy()
        end
    end
end

Screen.afterPaint = function(self)
    self.painting = false
end

Screen.setSwipeAnimations = function(self, enabled)
    self.swipe_animations = enabled
end

Screen.setSwipeDirection = function(self, direction)
    self.swipe_forward = direction
end

local function armWipe(forward)
    Screen:setSwipeAnimations(true)
    Screen:setSwipeDirection(forward)
end

local hardware_animate = Device.canDoSwipeAnimation()
Device.canDoSwipeAnimation = function() return true end

local orig_repaint = UIManager._repaint
local refresh_methods = userpatch.getUpValue(orig_repaint, "refresh_methods")
local update_dither = userpatch.getUpValue(orig_repaint, "update_dither")

-- Renderizador por defecto: Barrido lineal eficiente (Wipe)
UIManager.renderSwipeAnimation = function(self, saved_bb, new_bb, forward, steps, delay_us)
    local screen_w = Screen.bb:getWidth()
    local screen_h = Screen.bb:getHeight()
    local prev_dx = 0

    for i = 1, steps do
        local progress = i / steps
        local dx = math.floor(screen_w * progress)
        local strip_w = dx - prev_dx

        if forward then
            -- Derecha a izquierda (Avance)
            Screen.bb:blitFrom(saved_bb, 0, 0, 0, 0, screen_w - dx, screen_h)
            Screen.bb:blitFrom(new_bb, screen_w - dx, 0, screen_w - dx, 0, dx, screen_h)

            if i < steps then
                if strip_w > 0 then
                    Screen:refreshUI(screen_w - dx, 0, strip_w, screen_h)
                    self:yieldToEPDC(delay_us)
                end
            else
                Screen:refreshUI(0, 0, screen_w, screen_h)
            end
        else
            -- Izquierda a derecha (Retroceso)
            Screen.bb:blitFrom(new_bb, 0, 0, 0, 0, dx, screen_h)
            Screen.bb:blitFrom(saved_bb, dx, 0, dx, 0, screen_w - dx, screen_h)

            if i < steps then
                if strip_w > 0 then
                    Screen:refreshUI(prev_dx, 0, strip_w, screen_h)
                    self:yieldToEPDC(delay_us)
                end
            else
                Screen:refreshUI(0, 0, screen_w, screen_h)
            end
        end
        prev_dx = dx
    end
end

UIManager._repaint = function(self)
    local dirty = false
    local dithered = false

    local start_idx = 1
    for i = #self._window_stack, 1, -1 do
        if self._window_stack[i].widget.covers_fullscreen then
            start_idx = i
            break
        end
    end

    for i = start_idx, #self._window_stack do
        local window = self._window_stack[i]
        local widget = window.widget
        if dirty or self._dirty[widget] then
            Screen:beforePaint()
            widget:paintTo(Screen.bb, window.x, window.y, self._dirty[widget])
            self._dirty[widget] = nil
            dirty = true
            if widget.dithered then dithered = true end
        end
    end

    for _, refreshfunc in ipairs(self._refresh_func_stack) do
        local refreshtype, region, dither = refreshfunc()
        dither = update_dither(dither, dithered)
        if refreshtype then self:_refresh(refreshtype, region, dither) end
    end
    self._refresh_func_stack = {}

    if dirty and not self._refresh_stack[1] then
        self:_refresh("partial")
    end

    local software_animate = not hardware_animate

    if software_animate then
        Screen.swipe_animations = false
        local saved_bb = Screen.saved_bb
        Screen.saved_bb = nil
        if saved_bb then
            local new_bb = Screen.bb:copy()
            local steps = getSteps()
            local swipe_forward = Screen.swipe_forward

            self:renderSwipeAnimation(saved_bb, new_bb, swipe_forward, steps, getDelayUs())

            local kept_refreshes = {}
            for _, refresh in ipairs(self._refresh_stack) do
                if refresh.mode == "full" then
                    table.insert(kept_refreshes, refresh)
                end
            end
            self._refresh_stack = kept_refreshes

            new_bb:free()
            saved_bb:free()
        end
    end

    for _, refresh in ipairs(self._refresh_stack) do
        refresh.dither = update_dither(refresh.dither, dithered)
        if not Screen.hw_dithering then refresh.dither = nil end
        dbg:v("triggering refresh", refresh)
        refresh_methods[refresh.mode](Screen, refresh.region.x, refresh.region.y, refresh.region.w, refresh.region.h, refresh.dither)
    end

    if dirty then Screen:afterPaint() end

    self._refresh_stack = {}
    self.refresh_counted = false
end

-- ============================================================================
-- 2) TRANSICIONES Y CAPTURAS
-- ============================================================================

-- Documentos de maquetación fija (PDF, DjVu...)
function ReaderPaging:_gotoPage(number, orig_mode)
    if number == self.current_page or not number then
        self.view.footer:onUpdateFooter(self.view.footer_visible)
        return true
    end
    if number > self.number_of_pages then
        number = self.number_of_pages
    elseif number < 1 then
        number = 1
    end
    if self.current_page then
        self.ui:handleEvent(Event:new("PageChangeAnimation", number > self.current_page))
    end
    self.ui:handleEvent(Event:new("PageUpdate", number, orig_mode))
    return true
end

-- Documentos en modo paginado (EPUB, FB2, TXT...)
local orig_rolling_gotoPage = ReaderRolling._gotoPage
ReaderRolling._gotoPage = function(self, new_page, ...)
    if self.view.view_mode == "page" and new_page and self.current_page and new_page ~= self.current_page then
        self.ui:handleEvent(Event:new("PageChangeAnimation", new_page > self.current_page))
    end
    return orig_rolling_gotoPage(self, new_page, ...)
end

-- Páginas de menús / listas (Administrador de archivos)
local orig_onGotoPage = Menu.onGotoPage
Menu.onGotoPage = function(self, page)
    if screensAnimEnabled() and page and self.page and page ~= self.page then
        armWipe(page > self.page)
    end
    return orig_onGotoPage(self, page)
end

-- Cambio de pantalla Home <-> Library
local FORWARD_ON_SHOW = {
    homescreen = true,
    FileManager = true,
}

local function isBookWidget(widget)
    return widget ~= nil and (widget.name == "ReaderUI" or widget == FileManager.instance)
end

local pending_bb = nil
local pending_token = 0

local function clearPendingBB()
    if pending_bb then
        pending_bb:free()
        pending_bb = nil
    end
end

-- Ganchos unificados de visualización y cierre
local orig_show = UIManager.show
UIManager.show = function(self, widget, ...)
    if widget then
        if bookAnimEnabled() and isBookWidget(widget) then
            if pending_bb then
                Screen.saved_bb = pending_bb
                pending_bb = nil
            end
            armWipe(widget.name == "ReaderUI")
        elseif lockAnimEnabled() and widget == Screensaver.screensaver_widget then
            armWipe(false)
        elseif screensAnimEnabled() and widget.name and FORWARD_ON_SHOW[widget.name] then
            armWipe(true)
        end
    end
    return orig_show(self, widget, ...)
end

local orig_close = UIManager.close
UIManager.close = function(self, widget, ...)
    if widget then
        if bookAnimEnabled() and isBookWidget(widget) then
            clearPendingBB()
            pending_bb = Screen.bb:copy()
            pending_token = pending_token + 1
            local token = pending_token
            UIManager:scheduleIn(3, function()
                if pending_bb and token == pending_token then
                    clearPendingBB()
                end
            end)
        elseif lockAnimEnabled() and widget == Screensaver.screensaver_widget then
            armWipe(true)
        end
    end
    return orig_close(self, widget, ...)
end

-- ============================================================================
-- 3) MENÚ DE AJUSTES EN INTERFAZ
-- ============================================================================

table.insert(PageTurns.sub_item_table, {
    text = _("Software page turn animation"),
    sub_item_table = {
        {
            text = _("Enable animation"),
            checked_func = function() return G_reader_settings:isTrue("swipe_animations") end,
            callback = function() G_reader_settings:flipNilOrFalse("swipe_animations") end,
        },
        {
            keep_menu_open = true,
            text_func = function()
                local T = require("ffi/util").template
                return T(_("Number of steps: %1"), getSteps())
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Animation steps"),
                    info_text = _("More steps = smoother animation but slower.\nFewer steps = faster but choppier."),
                    value = getSteps(),
                    value_min = 2,
                    value_max = 24,
                    value_step = 1,
                    default_value = DEFAULT_STEPS,
                    precision = "%d",
                    callback = function(spin)
                        G_reader_settings:saveSetting(SETTING_KEY_STEPS, spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            keep_menu_open = true,
            text_func = function()
                local T = require("ffi/util").template
                return T(_("Animation speed: %1 ms/step"), G_reader_settings:readSetting(SETTING_KEY_DELAY, DEFAULT_DELAY_MS))
            end,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new {
                    title_text = _("Animation speed"),
                    info_text = _("How long (in milliseconds) each frame stays on screen.\nLower = faster animation. Higher = slower."),
                    value = G_reader_settings:readSetting(SETTING_KEY_DELAY, DEFAULT_DELAY_MS),
                    value_min = 5,
                    value_max = 100,
                    value_step = 5,
                    default_value = DEFAULT_DELAY_MS,
                    precision = "%d",
                    unit = "ms",
                    callback = function(spin)
                        G_reader_settings:saveSetting(SETTING_KEY_DELAY, spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
    },
})

table.insert(PageTurns.sub_item_table, {
    text = _("Animate library / home screen changes"),
    checked_func = function() return G_reader_settings:nilOrTrue(SETTING_SCREENS) end,
    callback = function() G_reader_settings:flipNilOrTrue(SETTING_SCREENS) end,
})

table.insert(PageTurns.sub_item_table, {
    text = _("Animate lock / unlock"),
    checked_func = function() return G_reader_settings:nilOrTrue(SETTING_LOCK) end,
    callback = function() G_reader_settings:flipNilOrTrue(SETTING_LOCK) end,
})

table.insert(PageTurns.sub_item_table, {
    text = _("Animate opening / closing a book"),
    checked_func = function() return G_reader_settings:nilOrTrue(SETTING_BOOK) end,
    callback = function() G_reader_settings:flipNilOrTrue(SETTING_BOOK) end,
})
