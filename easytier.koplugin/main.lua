--[[--
EasyTier 异地组网 —— KOReader 插件主模块

设计取舍：插件不内嵌 EasyTier，只负责拉起/停掉独立运行的 easytier-core 进程，
并把配置翻译成命令行。这样 TUN、权限、架构、功耗的问题都留在 core 侧，
插件本体只是「遥控器」：启停 + 配置 + 看状态。

安装、二进制准备、Kindle 注意事项见插件目录下的 README.md。
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("et_i18n").tr

local Config = require("et_config")
local Proc = require("et_proc")
local UI = require("et_ui")

-- Android 上这套做法不适用（没有 /mnt/us 这套路径，也拿不到 root 去建 TUN）
if Device:isAndroid() then
    return { disabled = true }
end

local EasyTier = WidgetContainer:extend{
    name = "easytier",
    is_doc_only = false,
    settings_key = Config.SETTINGS_KEY,
}

--==========================================================================
-- 生命周期
--==========================================================================

function EasyTier:init()
    self.cfg = Config.load()

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- 只有「随 KOReader 启动」这一个开关决定 KOReader 启动时要不要把 core 拉起来。
    -- 看门狗只负责本次会话内（恢复前台 / 网络重连）把意外掉下去的进程补回来，
    -- 不跨会话自作主张——否则用户明明关掉了自启，它还是会在下次启动时跑起来。
    if self.cfg.autostart then
        self.cfg.active = true
        Config.save(self.cfg)
        UIManager:scheduleIn(3, function() self:auto_start("koreader-start") end)
    elseif self.cfg.active then
        -- 上次是运行状态但用户没开自启：本次会话从「不想要它运行」开始
        self.cfg.active = false
        Config.save(self.cfg)
    end
end

--- 插件被禁用 / KOReader 退出时调用（PluginLoader 会找这个方法）
function EasyTier:stopPlugin(force)
    if not Proc.is_running(self.cfg) then return true end
    local ok, err = Proc.stop(self.cfg, force)
    self.cfg.active = false
    Config.save(self.cfg)
    return ok, err
end

--- 插件设置里的「删除设置」会用 settings_key，这里再显式实现一次
function EasyTier:deletePluginSettings()
    Config.clear()
    self.cfg = Config.load()
end

--==========================================================================
-- 启停
--==========================================================================

function EasyTier:auto_start(reason)
    if Proc.is_running(self.cfg) then return end
    local ok = Config.validate(self.cfg)
    if not ok then
        logger.warn("EasyTier auto start skipped: invalid config")
        return
    end
    if not Proc.find(Config.CORE_NAME, self.cfg) then
        logger.warn("EasyTier auto start skipped: binary not found")
        return
    end
    if self.cfg.mode == "tun" and Proc.tun_state() == "missing" then
        logger.warn("EasyTier auto start skipped: no /dev/net/tun")
        return
    end
    local started, res = Proc.start(self.cfg)
    logger.info("EasyTier auto start (" .. tostring(reason) .. "):", started, res)
    if started then
        self.cfg.active = true
        Config.save(self.cfg)
        local ok2, why = Proc.verify_started(self.cfg, 8)
        logger.info("EasyTier auto start verify:", ok2, why)
        if not ok2 then
            -- 起来就崩的配置不要反复重试，免得阅读器上一直重启进程
            self.cfg.active = false
            Config.save(self.cfg)
        end
    end
end

function EasyTier:start(touchmenu_instance)
    if Proc.is_running(self.cfg) then
        UI.info(_("EasyTier is already running."), 3)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end

    local ok, err, warn = Config.validate(self.cfg)
    if not ok then
        UI.info(_("There is a problem with the settings:\n\n") .. err, 10)
        return
    end

    if not Proc.find(Config.CORE_NAME, self.cfg) then
        UI.choose(_("easytier-core executable not found"), {
            { text = _("Show installation help"), callback = function() self:show_install_help() end },
            { text = _("Run diagnostics"), callback = function() self:show_diagnostics() end },
        })
        return
    end

    if self.cfg.mode == "tun" then
        local state = Proc.tun_state()
        if state == "missing" then
            UI.choose(_("There is no /dev/net/tun on this device; the kernel may lack TUN support"), {
                {
                    text = _("Switch to proxy mode (no TUN)"),
                    callback = function()
                        self.cfg.mode = "proxy"
                        Config.save(self.cfg)
                        UI.info(_("Switched to proxy mode: only traffic that explicitly goes through SOCKS5 or a port forward can reach the network."), 6)
                        self:start(touchmenu_instance)
                    end,
                },
                { text = _("Show diagnostics"), callback = function() self:show_diagnostics() end },
            })
            return
        end
    end

    local busy = UI.busy(_("Starting EasyTier…"))
    local started, res = Proc.start(self.cfg)
    UIManager:close(busy)

    if not started then
        UI.info(tostring(res), 12)
        return
    end

    self.cfg.active = true
    Config.save(self.cfg)

    -- 只看「启动命令发出去了」不作数：要连续几秒确认进程还在，并且 RPC 真的应答
    local ok2, reason, detail = Proc.verify_started(self.cfg, 8)
    if not ok2 then
        self.cfg.active = false
        Config.save(self.cfg)
        local msg = _("easytier-core exited shortly after starting, so it is not running.\n\nEnd of the log:\n")
            .. ((detail ~= nil and detail ~= "") and detail or _("(log is empty)"))
            .. "\n\n" .. _("See Tools → Diagnostics for the environment (TUN, architecture, binaries), or Tools → Log for the full output.")
        UI.info(msg, 20)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end

    local pid = Proc.pid(self.cfg) or res
    local msg
    if reason == "rpc" then
        msg = string.format(_("EasyTier connected (PID %s).\n\nOpen Status to see the virtual IP, peers and routes."), tostring(pid))
    elseif reason == "no_cli" then
        msg = string.format(_("EasyTier is running (PID %s) but easytier-cli was not found, so peer and route info cannot be read.\n\nPut easytier-cli in the same directory as easytier-core."), tostring(pid))
    else
        msg = string.format(_("easytier-core is running (PID %s) but its RPC port is not answering.\n\nUsual causes: network name/secret mismatch with the peers, unreachable peer address, or the RPC port being taken.\n\nEnd of the log:\n%s"),
            tostring(pid), (detail ~= nil and detail ~= "") and detail or _("(log is empty)"))
    end
    if warn then msg = msg .. "\n\n" .. warn end
    UI.info(msg, reason == "rpc" and 6 or 15)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function EasyTier:stop(touchmenu_instance, force)
    if not Proc.is_running(self.cfg) then
        self.cfg.active = false
        Config.save(self.cfg)
        UI.info(_("EasyTier is not running."), 3)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end
    local busy = UI.busy(_("Stopping EasyTier…"))
    local ok, err = Proc.stop(self.cfg, force)
    UIManager:close(busy)
    self.cfg.active = false
    Config.save(self.cfg)
    if ok then
        UI.info(_("EasyTier stopped."), 3)
    else
        UI.info(_("Could not stop it completely: ") .. tostring(err) .. _("\nYou can force it from Tools → Kill leftover processes."), 10)
    end
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function EasyTier:toggle(touchmenu_instance)
    if Proc.is_running(self.cfg) then
        self:stop(touchmenu_instance)
    else
        self:start(touchmenu_instance)
    end
end

function EasyTier:restart(touchmenu_instance)
    local busy = UI.busy(_("Restarting EasyTier…"))
    Proc.stop(self.cfg, true)
    UIManager:close(busy)
    self:start(touchmenu_instance)
end

--==========================================================================
-- 事件
--==========================================================================

function EasyTier:onNetworkConnected()
    if self.cfg.start_on_wifi or (self.cfg.watchdog and self.cfg.active) then
        -- 等 DHCP 把地址落下来一点再动手
        UIManager:scheduleIn(3, function() self:auto_start("wifi-connected") end)
    end
end

function EasyTier:onNetworkDisconnected()
    -- EasyTier 自己会重试打洞并在网络恢复后继续可用，这里默认不打断它。
    -- 需要「断网即停」的话，用户可以在菜单里手动停。
end

function EasyTier:onResume()
    if self.cfg.watchdog and self.cfg.active and not Proc.is_running(self.cfg) then
        UIManager:scheduleIn(5, function() self:auto_start("resume-watchdog") end)
    end
end

--==========================================================================
-- 状态 / 日志 / 诊断
--==========================================================================

function EasyTier:status_text()
    local cfg = self.cfg
    local L = {}

    local function put(s) L[#L + 1] = s end

    put("== 当前配置 ==")
    put(Config.summary(cfg))
    put("")
    put("== 进程 ==")
    local pid = Proc.pid(cfg)
    if pid then
        put(string.format("运行中，PID %d", pid))
        if cfg.mode == "tun" then
            put(string.format("接口 %s 防火墙放行：%s", cfg.dev_name,
                Proc.firewall_rule_present(cfg.dev_name) and "是" or "否"))
        end
    else
        put("未运行")
        put("（如果刚点过启动，可能还在和节点协商）")
    end

    if cfg.mode == "tun" then
        put(string.format("/dev/net/tun：%s", util.pathExists("/dev/net/tun") and "存在" or "不存在"))
    end

    local core = Proc.find(Config.CORE_NAME, cfg)
    put(string.format("easytier-core：%s", core or "未找到"))

    if pid then
        local queries = {
            { label = "本机节点", args = { "node", "info" } },
            { label = "对等节点", args = { "peer" } },
            { label = "路由表", args = { "route" } },
        }
        for _, q in ipairs(queries) do
            put("")
            put("== " .. q.label .. " ==")
            local ok, out = Proc.cli(cfg, q.args)
            out = tostring(out or ""):gsub("%s+$", "")
            if ok and out ~= "" then
                put(out)
            else
                put("(读取失败)")
                if out ~= "" then put(out) end
            end
        end
    end

    return table.concat(L, "\n")
end

function EasyTier:show_status()
    UI.show_text{
        title = _("EasyTier status"),
        build = function() return self:status_text() end,
    }
end

function EasyTier:show_log()
    UI.show_text{
        title = _("EasyTier log"),
        build = function()
            local text = Proc.tail_log(250)
            if text == "" then
                text = _("(No log yet)\n\nStart EasyTier once and easytier-core's output will show up here.")
            end
            return text
        end,
    }
end

function EasyTier:show_diagnostics()
    local busy = UI.busy(_("Collecting diagnostics…"))
    local report = Proc.diagnostics(self.cfg)
    UIManager:close(busy)
    UI.show_text{
        title = _("EasyTier diagnostics"),
        build = function() return report end,
    }
end

--- KOReader 自己的崩溃日志（插件出错时，原因通常写在这里）
function EasyTier:show_crash_log()
    UI.show_text{
        title = _("KOReader crash.log (tail)"),
        build = function()
            local path = Proc.crash_log_path()
            local text = Proc.tail_file(path, 120)
            if text == "" then
                return _("Could not read the crash log: \n") .. path
                    .. _("\n\n(Empty if nothing crashed yet, or if the log was cleared.)")
            end
            return _("File: ") .. path .. "\n\n" .. text
        end,
    }
end

function EasyTier:show_install_help()
    local dir = Proc.data_dir()
    local lines = {
        "1) 在电脑上下载 EasyTier 官方发布包（Linux armv7，静态链接，无需额外库）：",
        "   https://github.com/EasyTier/EasyTier/releases",
        "   例如 easytier-linux-armv7-v2.6.4.zip",
        "",
        "2) 解出 easytier-core 与 easytier-cli，放到 Kindle 的：",
        "   /mnt/us/easytier/bin/",
        "   （整个 easytier-linux-armv7/ 目录直接拷进 /mnt/us/easytier/ 也能被识别）",
        "",
        "3) 用法：菜单 → 网络 → EasyTier 异地组网 → 启动 EasyTier",
        "",
        "== 当前搜索到的位置 ==",
        Proc.search_report(self.cfg),
        "",
        "== 数据目录 ==",
        dir,
        "   配置文件：插件设置（KOReader 的 settings 里，键名 easytier）",
        "   日志文件：" .. Proc.log_path(),
        "",
        "== Kindle 提示 ==",
        "· 需要越狱环境，KOReader 以 root 运行才能建 TUN、改路由。",
        "· /dev/net/tun 必须存在；不存在时插件会提示改用代理模式。",
        "· Kindle 的系统防火墙可能拦进入 TUN 的包，插件启动时会自动加一条 iptables 放行规则。",
    }
    UI.show_text{
        title = _("Installation"),
        build = function() return table.concat(lines, "\n") end,
        monospace = false,
    }
end

function EasyTier:cleanup_stale()
    UI.confirm(
        _("This kills every easytier-core process on the device, including ones started outside this plugin. Continue?"),
        function()
            local n = Proc.kill_all(true)
            UI.info(string.format(_("Killed %d process(es)."), n), 4)
        end,
        _("Kill")
    )
end

--==========================================================================
-- 设置编辑
--==========================================================================

function EasyTier:save_cfg(touchmenu_instance)
    Config.save(self.cfg)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function EasyTier:edit_field(touchmenu_instance, key, opts)
    local value = self.cfg[key]
    if opts.is_list then
        value = Config.list_to_text(value)
    else
        value = tostring(value or "")
    end
    UI.input_text{
        title = opts.title,
        value = value,
        hint = opts.hint,
        description = opts.description,
        number = opts.number,
        on_save = function(text)
            local v = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if opts.is_list then
                self.cfg[key] = Config.text_to_list(v)
            elseif opts.number then
                self.cfg[key] = tonumber(v) or 0
            else
                self.cfg[key] = v
            end
            self:save_cfg(touchmenu_instance)
        end,
    }
end

function EasyTier:toggle_field(touchmenu_instance, key)
    self.cfg[key] = not self.cfg[key]
    self:save_cfg(touchmenu_instance)
end

--==========================================================================
-- 菜单
--==========================================================================

function EasyTier:onDispatcherRegisterActions()
    Dispatcher:registerAction("easytier_toggle", { category = "none", event = "EasyTierToggle", title = _("Toggle EasyTier"), general = true })
    Dispatcher:registerAction("easytier_start", { category = "none", event = "EasyTierStart", title = _("Start EasyTier mesh"), general = true })
    Dispatcher:registerAction("easytier_stop", { category = "none", event = "EasyTierStop", title = _("Stop EasyTier mesh"), general = true })
    Dispatcher:registerAction("easytier_status", { category = "none", event = "EasyTierStatus", title = _("EasyTier status"), general = true, separator = true })
end

function EasyTier:onEasyTierToggle() self:toggle() end
function EasyTier:onEasyTierStart() self:start() end
function EasyTier:onEasyTierStop() self:stop() end
function EasyTier:onEasyTierStatus() self:show_status() end

function EasyTier:addToMainMenu(menu_items)
    local cfg = self.cfg

    local log_levels = { "trace", "debug", "info", "warn", "error" }
    local log_level_items = {}
    for _, level in ipairs(log_levels) do
        log_level_items[#log_level_items + 1] = {
            text = level,
            checked_func = function() return self.cfg.log_level == level end,
            callback = function(touchmenu_instance)
                self.cfg.log_level = level
                self:save_cfg(touchmenu_instance)
            end,
        }
    end

    menu_items.easytier = {
        sorting_hint = "network",
        text = _("EasyTier mesh networking"),
        sub_item_table = {
            {
                text_func = function()
                    local pid = Proc.pid(self.cfg)
                    if pid then return string.format(_("Stop EasyTier (PID %d)"), pid) end
                    return _("Start EasyTier")
                end,
                checked_func = function() return Proc.is_running(self.cfg) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:toggle(touchmenu_instance) end,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function() self:show_status() end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return string.format(_("Network name: %s"), self.cfg.network_name ~= "" and self.cfg.network_name or _("(not set)"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "network_name", {
                                title = _("Network name"),
                                hint = _("e.g. my-vpn-net"),
                                description = _("Every node in the network must use exactly the same network name and secret."),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local masked = self.cfg.network_secret ~= "" and "******" or _("(not set)")
                            return string.format(_("Network secret: %s"), masked)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "network_secret", {
                                title = _("Network secret"),
                                hint = _("e.g. secret-1234567890"),
                                description = _("Acts as a password — make it long and do not keep the default."),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            return string.format(_("Mode: %s"), self.cfg.mode == "tun" and _("TUN (full routing)") or _("Proxy (no TUN)"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UI.choose(_("Mode"), {
                                {
                                    text = _("TUN: create a virtual interface and route the whole device"),
                                    callback = function()
                                        self.cfg.mode = "tun"
                                        self:save_cfg(touchmenu_instance)
                                    end,
                                },
                                {
                                    text = _("Proxy: no virtual interface, SOCKS5 only (for devices without TUN)"),
                                    callback = function()
                                        self.cfg.mode = "proxy"
                                        self:save_cfg(touchmenu_instance)
                                    end,
                                },
                            })
                        end,
                    },
                    {
                        text = _("Assign the node IP automatically with DHCP (turn off to set it yourself)"),
                        checked_func = function() return self.cfg.dhcp end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "dhcp") end,
                    },
                    {
                        text_func = function()
                            return string.format(_("Node IP: %s"), self.cfg.ipv4 ~= "" and self.cfg.ipv4 or _("(not set)"))
                        end,
                        enabled_func = function() return not self.cfg.dhcp end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "ipv4", {
                                title = _("This node's virtual IP"),
                                hint = "10.144.144.2",
                                description = _("Every node uses a different address. Required when DHCP is off."),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            return string.format(_("Initial nodes: %s"), Config.list_to_text(self.cfg.peers) ~= "" and Config.list_to_text(self.cfg.peers) or _("(none)"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "peers", {
                                title = _("Initial node (server)"),
                                is_list = true,
                                hint = "tcp://public.easytier.top:11010",
                                description = _("Nodes to connect to on start, comma separated.\n"
                                    .. "可以填自己的节点，也可以填别人分享的公共共享节点——\n"
                                    .. "EasyTier 不分服务端/客户端，能连上任何一个节点就能入网。\n\n"
                                    .. "公共共享节点示例：tcp://public.easytier.top:11010"),
                            })
                        end,
                    },
                    {
                        text = _("Advanced"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return string.format(_("SOCKS5 port: %s"), tostring(self.cfg.socks5_port))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "socks5_port", {
                                        title = _("SOCKS5 port"),
                                        number = true,
                                        hint = "1080",
                                        description = _("Proxy mode only. Other apps can point their SOCKS5 proxy at this port on 127.0.0.1."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.proxy_networks)
                                    return string.format(_("Shared local subnets: %s"), v ~= "" and v or _("(none)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "proxy_networks", {
                                        title = _("Share this device's subnets"),
                                        is_list = true,
                                        hint = "192.168.1.0/24",
                                        description = _("Let other nodes reach this device's LAN. Comma separated."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.port_forwards)
                                    return string.format(_("Port forwards: %s"), v ~= "" and v or _("(none)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "port_forwards", {
                                        title = _("Port forwarding"),
                                        is_list = true,
                                        hint = "tcp://127.0.0.1:8080/10.126.126.1:80",
                                        description = _("Map a service from the virtual network onto a local port.\nWorks without TUN — handy for reaching Calibre/OPDS on your LAN from KOReader."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.listeners)
                                    return string.format(_("Listeners: %s"), v ~= "" and v or _("(default)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "listeners", {
                                        title = _("Listeners"),
                                        is_list = true,
                                        hint = "tcp://0.0.0.0:11010, udp://0.0.0.0:11010",
                                    })
                                end,
                            },
                            {
                                text = _("Do not listen on any port (outbound only)"),
                                checked_func = function() return self.cfg.no_listener end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "no_listener") end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("RPC portal: %s"), self.cfg.rpc_portal)
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "rpc_portal", {
                                        title = _("RPC port"),
                                        hint = "127.0.0.1:15888",
                                        description = _("The plugin reads node status through it; avoid clashing with other programs."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local name = self.cfg.hostname ~= ""
                                        and self.cfg.hostname
                                        or (Proc.sys_hostname() or _("(system hostname)"))
                                    return string.format(_("Hostname: %s"), name)
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "hostname", {
                                        title = _("Hostname"),
                                        hint = "kindle-kpw6",
                                        description = _("This is the name peers see in their node list.\n"
                                            .. "留空则用系统主机名（Kindle 上通常是 kindle）。\n"
                                            .. "不要用空格，用横线代替；开了魔法 DNS 时会作为 <主机名>.et.net 用。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("Instance name: %s"), self.cfg.instance_name)
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "instance_name", {
                                        title = _("Instance name"),
                                        hint = "kindle",
                                        description = _("Only distinguishes multiple instances on this machine; peers do not see it.\n"
                                            .. "想改对端看到的名字，请改上面的「主机名」。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("TUN interface: %s"), self.cfg.dev_name)
                                end,
                                enabled_func = function() return self.cfg.mode == "tun" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "dev_name", {
                                        title = _("TUN interface name"),
                                        hint = "easytier0",
                                        description = _("At most 15 characters (kernel limit)."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("MTU: %s"), tonumber(self.cfg.mtu) > 0 and tostring(self.cfg.mtu) or _("(default)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "mtu", {
                                        title = _("MTU"),
                                        number = true,
                                        hint = "0",
                                        description = _("0 keeps EasyTier's default (1360 encrypted / 1380 unencrypted)."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("Default protocol: %s"), self.cfg.default_protocol ~= "" and self.cfg.default_protocol or _("(auto)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "default_protocol", {
                                        title = _("Protocol used to reach peers"),
                                        hint = "udp / tcp / ws / wss",
                                    })
                                end,
                            },
                            {
                                text = _("Enable the KCP proxy (steadier on lossy Wi-Fi)"),
                                checked_func = function() return self.cfg.enable_kcp_proxy end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "enable_kcp_proxy") end,
                            },
                            {
                                text = _("Disable P2P (relay only)"),
                                checked_func = function() return self.cfg.disable_p2p end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "disable_p2p") end,
                            },
                            {
                                text = _("Prefer the lowest-latency route"),
                                checked_func = function() return self.cfg.latency_first end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "latency_first") end,
                            },
                            {
                                text = _("Magic DNS (modifies system DNS — use with care)"),
                                checked_func = function() return self.cfg.accept_dns end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "accept_dns") end,
                            },
                            {
                                text = _("Log level"),
                                sub_item_table = log_level_items,
                            },
                            {
                                text_func = function()
                                    return string.format(_("Binary directory: %s"), self.cfg.custom_bin_dir ~= "" and self.cfg.custom_bin_dir or _("(auto-detected)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "custom_bin_dir", {
                                        title = _("easytier-core directory"),
                                        hint = "/mnt/us/easytier/bin",
                                        description = _("Leave empty to search the usual locations."),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("Extra arguments: %s"), self.cfg.extra_args ~= "" and self.cfg.extra_args or _("(none)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "extra_args", {
                                        title = _("Extra arguments"),
                                        hint = "--private-mode --compression zstd",
                                        description = _("Appended verbatim to the easytier-core command line; use at your own risk."),
                                    })
                                end,
                            },
                        },
                    },
                },
            },
            {
                text = _("Automation"),
                sub_item_table = {
                    {
                        text = _("Start EasyTier with KOReader"),
                        checked_func = function() return self.cfg.autostart end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "autostart") end,
                    },
                    {
                        text = _("Start after Wi-Fi connects"),
                        checked_func = function() return self.cfg.start_on_wifi end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "start_on_wifi") end,
                    },
                    {
                        text = _("Restart automatically if the process dies"),
                        help_text = _("Restart EasyTier when KOReader comes back to the foreground or Wi-Fi reconnects, if it was running and the process is gone."),
                        checked_func = function() return self.cfg.watchdog end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "watchdog") end,
                    },
                    {
                        text = _("Open the Kindle firewall for the TUN interface on start"),
                        help_text = _("Kindle's firewall drops packets arriving on the tunnel interface, which looks like connected but no traffic."),
                        checked_func = function() return self.cfg.fix_firewall end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "fix_firewall") end,
                        separator = true,
                    },
                },
            },
            {
                text = _("Tools"),
                sub_item_table = {
                    {
                        text = _("Restart EasyTier"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance) self:restart(touchmenu_instance) end,
                    },
                    {
                        text = _("View log"),
                        keep_menu_open = true,
                        callback = function() self:show_log() end,
                    },
                    {
                        text = _("Clear log"),
                        keep_menu_open = true,
                        callback = function()
                            Proc.clear_log()
                            UI.info(_("Log cleared."), 3)
                        end,
                    },
                    {
                        text = _("Run diagnostics"),
                        keep_menu_open = true,
                        callback = function() self:show_diagnostics() end,
                    },
                    {
                        text = _("View KOReader crash.log"),
                        keep_menu_open = true,
                        callback = function() self:show_crash_log() end,
                    },
                    {
                        text = _("Kill leftover easytier-core processes"),
                        keep_menu_open = true,
                        callback = function() self:cleanup_stale() end,
                    },
                    {
                        text = _("Installation"),
                        keep_menu_open = true,
                        callback = function() self:show_install_help() end,
                    },
                    {
                        text = _("Restore default settings"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UI.confirm(_("Reset all EasyTier plugin settings to their defaults?"), function()
                                self:deletePluginSettings()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                UI.info(_("Settings restored to defaults."), 3)
                            end, _("Restore"))
                        end,
                    },
                },
            },
        },
    }
end

return EasyTier
