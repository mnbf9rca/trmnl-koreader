--[[--
Runs inside KOReader's busted suite. From a KOReader checkout with this plugin
and this spec symlinked in (plugins/trmnl.koplugin, spec/unit/trmnl_spec.lua):

    ./kodev test front trmnl_spec.lua

Covers dashboard exit gestures and the /api/display outcomes that matter:
the API reports device and token
problems as HTTP 200 with an error body, so "no image_url" is the only signal
the plugin gets, and it has to say something useful about it.
]]

describe("TRMNL display plugin", function()
    local TrmnlDisplay

    setup(function()
        require("commonrequire")
        require("ui/network/manager").afterWifiAction = function() end
        TrmnlDisplay = dofile("plugins/trmnl.koplugin/main.lua")
    end)

    -- Drives the real _performFetch with a canned API response and returns the
    -- message the user would have been shown.
    local function message_for(response, image_path)
        local seen
        local instance = setmetatable({
            fetchScreenMetadata   = function() return response end,
            handleFetchError      = function(_, msg) seen = msg end,
            updateRefreshInterval = function() end,
            downloadImageIfNeeded = function() return image_path end,
            finalizeFetchSuccess  = function() end,
        }, { __index = TrmnlDisplay })

        instance:_performFetch()
        return seen
    end

    it("surfaces the server's error text", function()
        assert.is_equal("Device not found",
            message_for({ status = 500, error = "Device not found" }))
    end)

    it("falls back to the status when the body carries no error text", function()
        assert.is_equal("status 500", message_for({ status = 500 }))
    end)

    it("stays generic when the request itself failed", function()
        assert.is_equal("Failed to fetch screen metadata", message_for(nil))
    end)

    it("stays generic for an empty body", function()
        assert.is_equal("Failed to fetch screen metadata", message_for({}))
    end)

    it("leaves download failures to the download path", function()
        assert.is_equal("Failed to download image",
            message_for({ image_url = "https://example.invalid/a.png" }, nil))
    end)

    -- Captures the headers of a real fetchScreenMetadata call by standing in for
    -- the HTTPS transport. The response never parses, which is fine - only the
    -- outgoing request is under test.
    local function headers_for(settings, detected_mac)
        local captured
        local real_https = package.loaded["ssl.https"]
        package.loaded["ssl.https"] = {
            request = function(request) captured = request; return 1, 200 end,
        }

        settings.api_key = "test-key"
        settings.base_url = "https://example.invalid"
        local instance = setmetatable({
            settings      = settings,
            getMacAddress = function() return detected_mac end,
            showError     = function() end,
        }, { __index = TrmnlDisplay })

        instance:fetchScreenMetadata()
        package.loaded["ssl.https"] = real_https
        return captured.headers
    end

    it("sends the detected MAC under the ID header by default", function()
        assert.is_equal("AA:BB:CC:DD:EE:FF", headers_for({}, "AA:BB:CC:DD:EE:FF")["ID"])
    end)

    it("omits the header entirely when no MAC can be detected", function()
        assert.is_nil(headers_for({}, nil)["ID"])
    end)

    it("prefers a manually configured MAC over the detected one", function()
        local headers = headers_for({ mac_address = "11:22:33:44:55:66" }, "AA:BB:CC:DD:EE:FF")
        assert.is_equal("11:22:33:44:55:66", headers["ID"])
    end)

    it("honours a custom header name for BYOS servers", function()
        local headers = headers_for({ mac_header_name = "MAC Address" }, "AA:BB:CC:DD:EE:FF")
        assert.is_equal("AA:BB:CC:DD:EE:FF", headers["MAC Address"])
        assert.is_nil(headers["ID"])
    end)

    describe("dashboard gestures", function()
        local Device, UIManager, LuaSettings, Geom, instance, settings_file
        local originals

        before_each(function()
            Device = require("device")
            UIManager = require("ui/uimanager")
            LuaSettings = require("luasettings")
            Geom = require("ui/geometry")
            originals = {}
            local function replace(object, key, value)
                table.insert(originals, { object, key, object[key] })
                object[key] = value
            end
            replace(Device, "isTouchDevice", function() return true end)
            replace(Device, "hasKeys", function() return true end)
            replace(require("ui/renderimage"), "renderImageFile", function()
                return require("ffi/blitbuffer").new(Device.screen:getWidth(), Device.screen:getHeight())
            end)
            replace(UIManager, "show", function() end)
            replace(UIManager, "close", function() end)
            replace(UIManager, "setDirty", function() end)
            replace(UIManager, "unschedule", function() end)
            replace(UIManager, "allowStandby", function() end)
            settings_file = LuaSettings:wrap{ settings = {} }
            settings_file.file = os.tmpname()
            replace(LuaSettings, "open", function() return settings_file end)
            replace(require("dispatcher"), "registerAction", function() end)
            instance = TrmnlDisplay:new{
                ui = { menu = { registerToMainMenu = function() end } },
                loadApiKeyFromFile = function() end,
            }
        end)

        after_each(function()
            for i = #originals, 1, -1 do
                local entry = originals[i]
                entry[1][entry[2]] = entry[3]
            end
            os.remove(settings_file.file)
            os.remove(settings_file.file .. ".old")
        end)

        local function gesture(name)
            return { ges = name, pos = Geom:new{ x = 10, y = 10 } }
        end

        local function choices(label)
            label = label or "Exit dashboard gesture"
            local menu = {}
            instance:addToMainMenu(menu)
            for _, item in ipairs(menu.trmnl.sub_item_table) do
                if item.text == label then
                    return item.sub_item_table
                end
            end
            assert(false, label .. " menu missing")
        end

        it("keeps single tap selected and working for existing settings", function()
            assert.is_true(choices()[1].checked_func())
            assert.is_true(choices("Refresh dashboard gesture")[1].checked_func())
            instance:displayImage("test.png")
            instance.image_widget:onGesture(gesture("tap"))
            assert.is_nil(instance.image_widget)
        end)

        it("defaults fresh installs to single tap", function()
            settings_file:delSetting("settings")
            instance:init()
            assert.is_true(choices()[1].checked_func())
            assert.is_true(choices("Refresh dashboard gesture")[1].checked_func())
            instance:displayImage("test.png")
            instance.image_widget:onGesture(gesture("tap"))
            assert.is_nil(instance.image_widget)
        end)

        it("does not register touch gestures on non-touch devices", function()
            Device.isTouchDevice = function() return false end
            instance.settings.refresh_gesture = "hold"
            instance:displayImage("test.png")
            assert.is_nil(next(instance.image_widget.ges_events))
        end)

        it("ignores taps in hold mode and stops interactive refresh on hold", function()
            instance.settings.exit_gesture = "hold"
            instance.interactive_mode = true
            instance.auto_refresh_enabled = true
            instance.auto_refresh_scheduled = true
            instance.refresh_task = function() end
            instance:displayImage("test.png")
            local widget = instance.image_widget
            widget:onGesture(gesture("tap"))
            assert.is_equal(widget, instance.image_widget)
            assert.is_true(instance.auto_refresh_enabled)
            widget:onGesture(gesture("hold"))
            assert.is_nil(instance.image_widget)
            assert.is_false(instance.interactive_mode)
            assert.is_false(instance.auto_refresh_enabled)
            assert.is_false(instance.auto_refresh_scheduled)
        end)

        it("registers no exit gesture when disabled, including after refresh", function()
            instance.settings.exit_gesture = "disabled"
            for _ = 1, 2 do
                instance:displayImage("test.png")
                local widget = instance.image_widget
                assert.is_nil(next(widget.ges_events))
                widget:onGesture(gesture("tap"))
                widget:onGesture(gesture("hold"))
                assert.is_equal(widget, instance.image_widget)
            end
            assert.is_not_nil(instance.image_widget.key_events.AnyKeyPressed)
            instance.image_widget:onKeyPress(require("device/key"):new("LPgFwd", {}))
            assert.is_nil(instance.image_widget)
        end)

        it("persists the selected gesture through the existing settings mechanism", function()
            local menu = choices()
            menu[2].callback()
            assert.is_equal("hold", dofile(settings_file.file).settings.exit_gesture)
            settings_file.data = dofile(settings_file.file)
            instance:init()
            assert.is_true(menu[2].checked_func())
            assert.is_false(menu[1].checked_func())
            menu[1].callback()
            assert.is_equal("tap", dofile(settings_file.file).settings.exit_gesture)
        end)

        it("saves Disabled only after confirmation, leaving Cancel unchanged", function()
            local dialog, updated
            UIManager.show = function(_, widget) dialog = widget end
            local disabled = choices()[3]
            local menu = { updateItems = function() updated = disabled.checked_func() end }
            disabled.callback(menu)
            assert.is_equal("tap", instance.settings.exit_gesture)
            dialog.cancel_callback()
            assert.is_equal("tap", instance.settings.exit_gesture)
            disabled.callback(menu)
            dialog.ok_callback()
            assert.is_equal("disabled", dofile(settings_file.file).settings.exit_gesture)
            assert.is_true(disabled.checked_func())
            assert.is_true(updated)
        end)

        for _, refresh_gesture in ipairs({ "tap", "hold" }) do
            it("uses Fetch now on " .. refresh_gesture .. " without exiting the dashboard", function()
                local calls = 0
                instance.fetchAndDisplay = function(_, skip_debounce)
                    assert.is_true(skip_debounce)
                    calls = calls + 1
                end
                instance.settings.refresh_gesture = refresh_gesture
                instance.settings.exit_gesture = refresh_gesture == "tap" and "hold" or "tap"
                instance.interactive_mode = true
                instance.auto_refresh_enabled = true
                instance.auto_refresh_scheduled = true
                for _ = 1, 2 do
                    instance:displayImage("test.png")
                    local widget = instance.image_widget
                    assert.is_true(widget:onGesture(gesture(refresh_gesture)))
                    assert.is_equal(widget, instance.image_widget)
                end
                assert.is_equal(2, calls)
                assert.is_true(instance.interactive_mode)
                assert.is_true(instance.auto_refresh_enabled)
                assert.is_true(instance.auto_refresh_scheduled)
            end)
        end

        it("persists refresh choices and disables conflicting choices in both menus", function()
            local exit_menu = choices()
            local refresh_menu = choices("Refresh dashboard gesture")
            assert.is_false(refresh_menu[2].enabled_func()) -- tap already exits
            assert.is_true(refresh_menu[3].enabled_func())
            exit_menu[2].callback() -- hold exits
            assert.is_true(refresh_menu[2].enabled_func())
            assert.is_false(refresh_menu[3].enabled_func())
            refresh_menu[2].callback() -- tap refreshes
            assert.is_equal("tap", dofile(settings_file.file).settings.refresh_gesture)
            settings_file.data = dofile(settings_file.file)
            instance:init()
            assert.is_true(refresh_menu[2].checked_func())
            assert.is_false(exit_menu[1].enabled_func())
            assert.is_true(exit_menu[2].enabled_func())
            refresh_menu[1].callback() -- disable refresh gesture
            assert.is_equal("disabled", dofile(settings_file.file).settings.refresh_gesture)
            assert.is_true(exit_menu[1].enabled_func())
        end)

        it("keeps exit working if saved gesture settings conflict", function()
            local calls = 0
            instance.fetchAndDisplay = function() calls = calls + 1 end
            instance.settings.exit_gesture = "tap"
            instance.settings.refresh_gesture = "tap"
            instance:displayImage("test.png")
            instance.image_widget:onGesture(gesture("tap"))
            assert.is_nil(instance.image_widget)
            assert.is_equal(0, calls)
        end)
    end)
end)
