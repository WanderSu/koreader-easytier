--[[--
菜单与插件骨架的冒烟测试：用桩件把 KOReader 运行时顶掉，真正加载 main.lua，
然后遍历整棵菜单树，把 text_func / checked_func / enabled_func 全部执行一遍。

目的是在没碰真机之前，把「菜单里某个 text_func 报错」「字段名写错」「变量被遮蔽」
这类问题逼出来。

    lua tests/test_menu.lua
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

--==== 打桩 ====--

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end

local lfs_calls = { attributes = 0, dir = 0 }
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() lfs_calls.attributes = lfs_calls.attributes + 1 return nil end,
        dir = function(p) lfs_calls.dir = lfs_calls.dir + 1 error("no " .. tostring(p) .. " in test") end,
    }
end

package.preload["datastorage"] = function()
    return { getFullDataDir = function() return "/tmp/koreader" end }
end

package.preload["ffi/util"] = function()
    return { sleep = function() end }
end

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

package.preload["util"] = function()
    return {
        pathExists = function(p)
            local f = io.open(p, "r")
            if f then f:close() return true end
            return false
        end,
    }
end

package.preload["device"] = function()
    return {
        isAndroid = function() return false end,
        isKindle = function() return true end,
        isSDL = function() return false end,
    }
end

local registered_actions = {}
package.preload["dispatcher"] = function()
    return {
        registerAction = function(_, name, spec)
            registered_actions[#registered_actions + 1] = { name = name, spec = spec }
        end,
    }
end

local scheduled = {}
package.preload["ui/uimanager"] = function()
    local noop = function() end
    return {
        scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
        show = noop,
        close = noop,
        forceRePaint = noop,
        nextTick = noop,
    }
end

-- WidgetContainer: 只用到 extend
package.preload["ui/widget/container/widgetcontainer"] = function()
    local base = {}
    function base:extend(t)
        t = t or {}
        return setmetatable(t, { __index = self })
    end
    return base
end

for _, mod in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "ui/widget/inputdialog",
    "ui/widget/textviewer",
}) do
    package.preload[mod] = function()
        local t = {}
        t.new = function() return setmetatable({}, { __index = t }) end
        return t
    end
end

-- G_reader_settings：够用的 LuaSettings 替身
local store = {}
_G.G_reader_settings = {
    readSetting = function(_, k, default)
        local v = store[k]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(_, k, v) store[k] = v end,
    delSetting = function(_, k) store[k] = nil end,
    isTrue = function(_, k) return store[k] == true end,
    nilOrFalse = function(_, k) return store[k] end,
    flipNilOrFalse = function(_, k) store[k] = not (store[k] == true) end,
    makeFalse = function(_, k) store[k] = false end,
}

--==== 加载插件 ====--

local ok, EasyTier = pcall(dofile, "easytier.koplugin/main.lua")
check("main.lua 能加载", ok, EasyTier)
check("main.lua 返回插件表", type(EasyTier) == "table", type(EasyTier))
check("插件名是 easytier", EasyTier and EasyTier.name == "easytier", EasyTier and EasyTier.name)
check("插件不是 doc_only", EasyTier and EasyTier.is_doc_only == false)
check("声明了 settings_key", EasyTier and EasyTier.settings_key == "easytier")
check("有 stopPlugin（插件被禁用时停进程）", type(EasyTier.stopPlugin) == "function")
check("有 deletePluginSettings", type(EasyTier.deletePluginSettings) == "function")
check("有事件处理 onNetworkConnected", type(EasyTier.onNetworkConnected) == "function")
check("有事件处理 onResume", type(EasyTier.onResume) == "function")

--==== init（含菜单注册） ====--

local menu_registered = false
local fake_ui = {
    menu = {
        registerToMainMenu = function(_, obj)
            menu_registered = (obj == EasyTier)
        end,
    },
}
EasyTier.ui = fake_ui
local ok_init, err_init = pcall(EasyTier.init, EasyTier)
check("init 能跑通", ok_init, err_init)
check("init 注册了主菜单", menu_registered)
check("init 读到了配置表", type(EasyTier.cfg) == "table", type(EasyTier.cfg))
check("Dispatcher 动作注册了 4 个", #registered_actions == 4, #registered_actions)
for _, a in ipairs(registered_actions) do
    check("action " .. a.name .. " 有 event", type(a.spec.event) == "string", a.spec.event)
    check("action " .. a.name .. " 有 title", type(a.spec.title) == "string")
end

--==== 遍历菜单树 ====--

local menu_items = {}
EasyTier:addToMainMenu(menu_items)
check("菜单里有 easytier 项", menu_items.easytier ~= nil)
check("菜单项挂在 network 分组", menu_items.easytier and menu_items.easytier.sorting_hint == "network")

local leaves, groups = 0, 0
local function walk(item, path)
    check(path .. " 是表", type(item) == "table")
    if item.sub_item_table then
        groups = groups + 1
        check(path .. " 有文字标题", type(item.text) == "string" or type(item.text_func) == "function")
        for idx, sub in ipairs(item.sub_item_table) do
            walk(sub, path .. "[" .. idx .. "]")
        end
    else
        leaves = leaves + 1
        check(path .. " 有 callback", type(item.callback) == "function")
        check(path .. " 有文字标题", type(item.text) == "string" or type(item.text_func) == "function")
    end
    for _, fname in ipairs({ "text_func", "checked_func", "enabled_func" }) do
        local f = item[fname]
        if type(f) == "function" then
            local cok, res = pcall(f)
            check(path .. "." .. fname .. " 不报错", cok, res)
            if cok and fname == "text_func" then
                check(path .. ".text_func 返回字符串", type(res) == "string", type(res))
            elseif cok then
                check(path .. "." .. fname .. " 返回布尔", type(res) == "boolean", type(res))
            end
        end
    end
end

walk(menu_items.easytier, "easytier")
check("菜单树有内容", leaves > 20, leaves)
print(string.format("菜单：%d 个叶子项，%d 个分组", leaves, groups))

--==== 主机名要放在「配置」一级（常用项，不要藏进「进阶」）====--

local function menu_title(item)
    if type(item.text) == "string" then return item.text end
    local ok, res = pcall(item.text_func)
    return ok and type(res) == "string" and res or nil
end

local function find_item(parent, title)
    for _, item in ipairs((parent and parent.sub_item_table) or {}) do
        if menu_title(item) == title then return item end
    end
    return nil
end

local cfg_menu = find_item(menu_items.easytier, "配置")
check("找到「配置」菜单", cfg_menu ~= nil)
local adv_menu = cfg_menu and find_item(cfg_menu, "进阶")
check("找到「进阶」子菜单", adv_menu ~= nil)

local function lists_hostname(menu)
    for _, item in ipairs((menu and menu.sub_item_table) or {}) do
        local title = menu_title(item) or ""
        if title:find("主机名：", 1, true) then return true end
    end
    return false
end
check("主机名在「配置」一级", lists_hostname(cfg_menu))
check("「进阶」里不再有主机名", not lists_hostname(adv_menu))

--==== 其它入口不能炸 ====--

check("stopPlugin 在未运行时返回 true", EasyTier:stopPlugin(false) == true)
check("status_text 能生成文本", (function()
    local sok, text = pcall(EasyTier.status_text, EasyTier)
    return sok and type(text) == "string" and #text > 20
end)())
local ok_del = pcall(EasyTier.deletePluginSettings, EasyTier)
check("deletePluginSettings 能跑通", ok_del)
check("删除设置后配置回到默认", EasyTier.cfg.network_name == "" and EasyTier.cfg.mode == "tun")

--==== 事件处理（不真的起进程） ====--

EasyTier.cfg.start_on_wifi = true
scheduled = {}
local ok_ev = pcall(EasyTier.onNetworkConnected, EasyTier)
check("onNetworkConnected 不报错", ok_ev)
check("连上 Wi-Fi 后安排了启动任务", #scheduled == 1, #scheduled)

EasyTier.cfg.start_on_wifi = false
EasyTier.cfg.watchdog = false
EasyTier.cfg.active = true
scheduled = {}
pcall(EasyTier.onResume, EasyTier)
check("看门狗关闭时不安排任务", #scheduled == 0, #scheduled)

EasyTier.cfg.watchdog = true
pcall(EasyTier.onResume, EasyTier)
check("看门狗打开且进程不在时安排任务", #scheduled == 1, #scheduled)

--==== 页面出错不许把 KOReader 拖崩 ====--
do
    local UI = require("et_ui")
    local tv_stub = package.loaded["ui/widget/textviewer"]

    check("build 抛错被吞掉（不崩 KOReader）",
        pcall(UI.show_text, { title = "崩溃测试", build = function() error("boom") end }) == true)
    check("text 为 nil 不报错",
        pcall(UI.show_text, { title = "空内容" }) == true)
    check("build 返回非字符串也不报错",
        pcall(UI.show_text, { title = "怪内容", build = function() return nil end }) == true)

    -- 控件创建失败 → 降级成 InfoMessage，而不是崩
    local real_new = tv_stub.new
    tv_stub.new = function() error("widget creation failed") end
    check("控件创建失败时降级不崩",
        pcall(UI.show_text, { title = "控件失败", build = function() return "hello" end }) == true)
    tv_stub.new = real_new

    check("正常文本能显示",
        pcall(UI.show_text, { title = "正常", text = "一行\n两行" }) == true)
end

--==== 启动时到底该不该自动拉起 ====--
do
    local ConfigMod = require("et_config")
    local function init_with(opts)
        local cfg = ConfigMod.load()
        for k, v in pairs(opts) do cfg[k] = v end
        G_reader_settings:saveSetting("easytier", cfg) -- 模拟上次会话留下的状态
        EasyTier.cfg = cfg
        scheduled = {}
        EasyTier:init()
        return #scheduled
    end

    check("自启打开时会安排启动",
        init_with({ autostart = true, watchdog = true, active = true }) == 1)
    check("自启关闭时不安排启动（哪怕上次在运行、看门狗开着）",
        init_with({ autostart = false, watchdog = true, active = true }) == 0)
    check("自启关闭时运行意图被清掉", EasyTier.cfg.active == false, tostring(EasyTier.cfg.active))
    check("自启关闭时看门狗在本会话里也不会自己拉起",
        (function()
            scheduled = {}
            EasyTier.cfg.watchdog = true
            EasyTier.cfg.active = false
            EasyTier:onResume()
            return #scheduled == 0
        end)())
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
