--[[--
翻译层测试：英文是源语言，界面语言为中文时用 et_i18n.lua 里的对照表。

    lua tests/test_i18n.lua
--]]

package.path = "./easytier.koplugin/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (extra ~= nil and ("  ->  " .. tostring(extra)) or ""))
    end
end

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end

-- 可以切换语言的 G_reader_settings 替身
local language = nil
_G.G_reader_settings = {
    readSetting = function(_, key)
        if key == "language" then return language end
        return nil
    end,
}

local i18n = require("et_i18n")

local function with_language(lang, fn)
    language = lang
    i18n.reset_language_cache()
    local ok, res = pcall(fn)
    language = nil
    i18n.reset_language_cache()
    return ok, res
end

--==== 英文是源语言 ====--
local ok, res = with_language("en", function() return i18n.tr("Start EasyTier") end)
check("英文界面返回英文源串", ok and res == "Start EasyTier", tostring(res))

ok, res = with_language(nil, function() return i18n.tr("Start EasyTier") end)
check("没设语言时也返回英文", ok and res == "Start EasyTier", tostring(res))

--==== 中文界面走对照表 ====--
ok, res = with_language("zh_CN", function() return i18n.tr("Start EasyTier") end)
check("zh_CN 返回中文", ok and res == "启动 EasyTier", tostring(res))

ok, res = with_language("zh_CN", function() return i18n.tr("Status") end)
check("zh_CN 短词也翻", ok and res == "连接状态", tostring(res))

ok, res = with_language("zh_CN", function() return i18n.tr("Stop EasyTier (PID %d)") end)
check("带格式符的条目保留 %d", ok and res:find("%%d") ~= nil, tostring(res))

ok, res = with_language("zh_CN", function() return i18n.tr("Some untranslated string") end)
check("表里没有的条目回落英文", ok and res == "Some untranslated string", tostring(res))

--==== 表本身的完整性 ====--
check("中文条目数量合理", i18n.zh_count() > 150, i18n.zh_count())

--==== 真实调用点：插件里的 _(...) 现在都是英文源串 ====--
local Config = require("et_config")
ok, res = with_language("en", function()
    return Config.summary({ mode = "tun", network_name = "abc", ipv4 = "10.0.0.2", dhcp = false,
        peers = { "tcp://a:11010" }, proxy_networks = {}, port_forwards = {}, instance_name = "kindle",
        hostname = "" })
end)
check("英文下 summary 是英文", ok and res:find("Mode:", 1, true) ~= nil and not res:find("模式", 1, true), tostring(res))

ok, res = with_language("zh_CN", function()
    return Config.summary({ mode = "tun", network_name = "abc", ipv4 = "10.0.0.2", dhcp = false,
        peers = { "tcp://a:11010" }, proxy_networks = {}, port_forwards = {}, instance_name = "kindle",
        hostname = "" })
end)
check("中文下 summary 是中文", ok and res:find("模式：", 1, true) ~= nil, tostring(res))

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
