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
local _ = require("gettext")

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
        UI.info(_("EasyTier 已经在运行了。"), 3)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end

    local ok, err, warn = Config.validate(self.cfg)
    if not ok then
        UI.info(_("配置有问题：\n\n") .. err, 10)
        return
    end

    if not Proc.find(Config.CORE_NAME, self.cfg) then
        UI.choose(_("没找到 easytier-core 可执行文件"), {
            { text = _("看安装说明"), callback = function() self:show_install_help() end },
            { text = _("运行诊断"), callback = function() self:show_diagnostics() end },
        })
        return
    end

    if self.cfg.mode == "tun" then
        local state = Proc.tun_state()
        if state == "missing" then
            UI.choose(_("设备上没有 /dev/net/tun，内核可能没有 TUN 驱动"), {
                {
                    text = _("改用代理模式（不建 TUN）"),
                    callback = function()
                        self.cfg.mode = "proxy"
                        Config.save(self.cfg)
                        UI.info(_("已切换到代理模式：只有本机显式走 SOCKS5 或端口转发的流量能进入虚拟网络。"), 6)
                        self:start(touchmenu_instance)
                    end,
                },
                { text = _("看诊断信息"), callback = function() self:show_diagnostics() end },
            })
            return
        end
    end

    local busy = UI.busy(_("正在启动 EasyTier…"))
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
        local msg = _("EasyTier 进程启动后很快退出了，所以没有进入运行状态。\n\n日志末尾：\n")
            .. ((detail ~= nil and detail ~= "") and detail or _("(日志为空)"))
            .. "\n\n" .. _("可到「工具 → 运行诊断」看环境（TUN、架构、二进制），或到「工具 → 查看日志」看完整输出。")
        UI.info(msg, 20)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end

    local pid = Proc.pid(self.cfg) or res
    local msg
    if reason == "rpc" then
        msg = string.format(_("EasyTier 已连接（PID %s）。\n\n点「连接状态」可以看到虚拟 IP、对端列表和路由。"), tostring(pid))
    elseif reason == "no_cli" then
        msg = string.format(_("EasyTier 已在运行（PID %s），但没找到 easytier-cli，读不到节点状态。\n\n把 easytier-cli 放在 easytier-core 同一个目录里即可。"), tostring(pid))
    else
        msg = string.format(_("EasyTier 进程在运行（PID %s），但 RPC 端口没有响应。\n\n常见原因：网络名称/密钥与对端不一致、对等节点地址不可达、RPC 端口被占用。\n\n日志末尾：\n%s"),
            tostring(pid), (detail ~= nil and detail ~= "") and detail or _("(日志为空)"))
    end
    if warn then msg = msg .. "\n\n" .. warn end
    UI.info(msg, reason == "rpc" and 6 or 15)
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

function EasyTier:stop(touchmenu_instance, force)
    if not Proc.is_running(self.cfg) then
        self.cfg.active = false
        Config.save(self.cfg)
        UI.info(_("EasyTier 当前没有运行。"), 3)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        return
    end
    local busy = UI.busy(_("正在停止 EasyTier…"))
    local ok, err = Proc.stop(self.cfg, force)
    UIManager:close(busy)
    self.cfg.active = false
    Config.save(self.cfg)
    if ok then
        UI.info(_("EasyTier 已停止。"), 3)
    else
        UI.info(_("没能完全停掉：") .. tostring(err) .. _("\n可以到「工具 → 清理残留进程」强制处理。"), 10)
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
    local busy = UI.busy(_("正在重启 EasyTier…"))
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
        for _i, q in ipairs(queries) do
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
        title = _("EasyTier 连接状态"),
        build = function() return self:status_text() end,
    }
end

function EasyTier:show_log()
    UI.show_text{
        title = _("EasyTier 日志"),
        build = function()
            local text = Proc.tail_log(250)
            if text == "" then
                text = _("(暂无日志)\n\n启动一次之后这里会有 easytier-core 的输出。")
            end
            return text
        end,
    }
end

function EasyTier:show_diagnostics()
    local busy = UI.busy(_("正在收集诊断信息…"))
    -- 收集过程整段 pcall：中途出错也只是弹提示，不能让异常冒进菜单回调
    local ok, report = pcall(Proc.diagnostics, self.cfg)
    -- 不管成功失败都要把提示框收掉，否则它会一直挂在屏幕上
    pcall(UIManager.close, UIManager, busy)
    if not ok then
        logger.err("EasyTier: 收集诊断信息出错：" .. tostring(report))
        UI.info(_("收集诊断信息时出错：\n") .. tostring(report)
            .. _("\n\n（详情已写入 KOReader 的 crash.log）"), 20)
        return
    end
    UI.show_text{
        title = _("EasyTier 诊断"),
        build = function() return report end,
    }
end

--- 实测 easytier-core 版本。
--- 会真的执行一次二进制（自解压包在阅读器上要几秒），所以单独做成一个动作，不塞进诊断页。
function EasyTier:show_core_version()
    local path = Proc.find(Config.CORE_NAME, self.cfg)
    if not path then
        UI.info(_("找不到 easytier-core。请先按「安装说明」把二进制放到设备上。"), 10)
        return
    end
    local busy = UI.busy(_("正在读取版本…"))
    local ok, ver = pcall(Proc.version, path)
    pcall(UIManager.close, UIManager, busy)
    if not ok then
        logger.err("EasyTier: 读取 core 版本出错：" .. tostring(ver))
        UI.info(_("读取版本时出错：\n") .. tostring(ver), 15)
        return
    end
    if ver then
        UI.info(path .. "\n\n" .. _("版本：") .. ver, 10)
    else
        UI.info(_("这个二进制不给版本号（--version / --help 都没读到输出）。\n\n")
            .. path, 10)
    end
end

--- KOReader 自己的崩溃日志（插件出错时，原因通常写在这里）
function EasyTier:show_crash_log()
    UI.show_text{
        title = _("KOReader 崩溃日志（末尾）"),
        build = function()
            local path = Proc.crash_log_path()
            local text = Proc.tail_file(path, 120)
            if text == "" then
                return _("没有读到崩溃日志：\n") .. path
                    .. _("\n\n（如果这次没有崩过，或日志被清理过，这里就是空的）")
            end
            return _("文件：") .. path .. "\n\n" .. text
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
        title = _("安装说明"),
        build = function() return table.concat(lines, "\n") end,
        monospace = false,
    }
end

function EasyTier:cleanup_stale()
    UI.confirm(
        _("会杀掉设备上所有 easytier-core 进程（包括不是本插件启动的）。继续？"),
        function()
            local n = Proc.kill_all(true)
            UI.info(string.format(_("已清理 %d 个进程。"), n), 4)
        end,
        _("清理")
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
    Dispatcher:registerAction("easytier_toggle", { category = "none", event = "EasyTierToggle", title = _("EasyTier 组网开关"), general = true })
    Dispatcher:registerAction("easytier_start", { category = "none", event = "EasyTierStart", title = _("启动 EasyTier 组网"), general = true })
    Dispatcher:registerAction("easytier_stop", { category = "none", event = "EasyTierStop", title = _("停止 EasyTier 组网"), general = true })
    Dispatcher:registerAction("easytier_status", { category = "none", event = "EasyTierStatus", title = _("EasyTier 连接状态"), general = true, separator = true })
end

function EasyTier:onEasyTierToggle() self:toggle() end
function EasyTier:onEasyTierStart() self:start() end
function EasyTier:onEasyTierStop() self:stop() end
function EasyTier:onEasyTierStatus() self:show_status() end

function EasyTier:addToMainMenu(menu_items)
    local cfg = self.cfg

    local log_levels = { "trace", "debug", "info", "warn", "error" }
    local log_level_items = {}
    for _i, level in ipairs(log_levels) do
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
        text = _("EasyTier 异地组网"),
        sub_item_table = {
            {
                text_func = function()
                    local pid = Proc.pid(self.cfg)
                    if pid then return string.format(_("停止 EasyTier（PID %d）"), pid) end
                    return _("启动 EasyTier")
                end,
                checked_func = function() return Proc.is_running(self.cfg) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance) self:toggle(touchmenu_instance) end,
            },
            {
                text = _("连接状态"),
                keep_menu_open = true,
                callback = function() self:show_status() end,
            },
            {
                text = _("配置"),
                sub_item_table = {
                    {
                        text_func = function()
                            return string.format(_("网络名称：%s"), self.cfg.network_name ~= "" and self.cfg.network_name or _("(未设置)"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "network_name", {
                                title = _("网络名称"),
                                hint = _("例如 my-vpn-net"),
                                description = _("同一网络内所有节点必须使用完全相同的网络名称和密钥。"),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local masked = self.cfg.network_secret ~= "" and "******" or _("(未设置)")
                            return string.format(_("网络密钥：%s"), masked)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "network_secret", {
                                title = _("网络密钥"),
                                hint = _("例如 secret-1234567890"),
                                description = _("相当于密码，建议设长一点，别用默认值。"),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            return string.format(_("运行模式：%s"), self.cfg.mode == "tun" and _("TUN（全局路由）") or _("代理（无 TUN）"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UI.choose(_("运行模式"), {
                                {
                                    text = _("TUN：创建虚拟网卡，整个设备走虚拟网络"),
                                    callback = function()
                                        self.cfg.mode = "tun"
                                        self:save_cfg(touchmenu_instance)
                                    end,
                                },
                                {
                                    text = _("代理：不建虚拟网卡，只开 SOCKS5（需要 TUN 驱动的设备用）"),
                                    callback = function()
                                        self.cfg.mode = "proxy"
                                        self:save_cfg(touchmenu_instance)
                                    end,
                                },
                            })
                        end,
                    },
                    {
                        text = _("DHCP 自动分配 IP（关闭后需自己填节点 IP）"),
                        checked_func = function() return self.cfg.dhcp end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "dhcp") end,
                    },
                    {
                        text_func = function()
                            return string.format(_("节点 IP：%s"), self.cfg.ipv4 ~= "" and self.cfg.ipv4 or _("(未设置)"))
                        end,
                        enabled_func = function() return not self.cfg.dhcp end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "ipv4", {
                                title = _("本节点虚拟 IP"),
                                hint = "10.144.144.2",
                                description = _("网络内每个节点用不同的地址。关掉 DHCP 后这里必须填。"),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            return string.format(_("初始节点：%s"), Config.list_to_text(self.cfg.peers) ~= "" and Config.list_to_text(self.cfg.peers) or _("(无)"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "peers", {
                                title = _("初始节点（服务器）"),
                                is_list = true,
                                hint = "tcp://public.easytier.top:11010",
                                description = _("启动时主动去连的节点，多个用逗号分隔。\n"
                                    .. "可以填自己的节点，也可以填别人分享的公共共享节点——\n"
                                    .. "EasyTier 不分服务端/客户端，能连上任何一个节点就能入网。\n\n"
                                    .. "公共共享节点示例：tcp://public.easytier.top:11010"),
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local name = self.cfg.hostname ~= ""
                                and self.cfg.hostname
                                or (Proc.sys_hostname() or _("(系统主机名)"))
                            return string.format(_("主机名：%s"), name)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:edit_field(touchmenu_instance, "hostname", {
                                title = _("主机名"),
                                hint = "kindle-kpw6",
                                description = _("对端节点列表里显示的就是这个名字，所以常改就放在这里。\n"
                                    .. "留空则用系统主机名（Kindle 上通常是 kindle）。\n"
                                    .. "不要用空格，用横线代替；开了魔法 DNS 时会作为 <主机名>.et.net 用。"),
                            })
                        end,
                    },
                    {
                        text = _("进阶"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    return string.format(_("SOCKS5 端口：%s"), tostring(self.cfg.socks5_port))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "socks5_port", {
                                        title = _("SOCKS5 端口"),
                                        number = true,
                                        hint = "1080",
                                        description = _("仅代理模式生效。其他程序可把 SOCKS5 代理指向 127.0.0.1 的这个端口。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.proxy_networks)
                                    return string.format(_("共享本机子网：%s"), v ~= "" and v or _("(无)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "proxy_networks", {
                                        title = _("共享本机所在子网"),
                                        is_list = true,
                                        hint = "192.168.1.0/24",
                                        description = _("让其他节点能访问本机所在局域网，逗号分隔。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.port_forwards)
                                    return string.format(_("端口转发：%s"), v ~= "" and v or _("(无)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "port_forwards", {
                                        title = _("端口转发"),
                                        is_list = true,
                                        hint = "tcp://127.0.0.1:8080/10.126.126.1:80",
                                        description = _("把虚拟网络里的服务映射到本机的端口。\n没有 TUN 也能用，适合让 KOReader 访问局域网里的 Calibre / OPDS。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    local v = Config.list_to_text(self.cfg.listeners)
                                    return string.format(_("监听地址：%s"), v ~= "" and v or _("(默认)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "listeners", {
                                        title = _("监听地址"),
                                        is_list = true,
                                        hint = "tcp://0.0.0.0:11010, udp://0.0.0.0:11010",
                                    })
                                end,
                            },
                            {
                                text = _("不监听任何端口（只出站）"),
                                checked_func = function() return self.cfg.no_listener end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "no_listener") end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("RPC 端口：%s"), self.cfg.rpc_portal)
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "rpc_portal", {
                                        title = _("RPC 端口"),
                                        hint = "127.0.0.1:15888",
                                        description = _("本插件通过它读取节点状态，别和别的程序冲突。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("实例名：%s"), self.cfg.instance_name)
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "instance_name", {
                                        title = _("实例名"),
                                        hint = "kindle",
                                        description = _("只用于在同一台机器上区分多个实例，对端看不到它。\n"
                                            .. "想改对端看到的名字，请改「配置 → 主机名」。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("TUN 接口名：%s"), self.cfg.dev_name)
                                end,
                                enabled_func = function() return self.cfg.mode == "tun" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "dev_name", {
                                        title = _("TUN 接口名"),
                                        hint = "easytier0",
                                        description = _("最多 15 个字符，内核限制。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("MTU：%s"), tonumber(self.cfg.mtu) > 0 and tostring(self.cfg.mtu) or _("(默认)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "mtu", {
                                        title = _("MTU"),
                                        number = true,
                                        hint = "0",
                                        description = _("0 表示用 EasyTier 默认值（加密 1360 / 不加密 1380）。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("默认协议：%s"), self.cfg.default_protocol ~= "" and self.cfg.default_protocol or _("(自动)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "default_protocol", {
                                        title = _("连接对等节点使用的协议"),
                                        hint = "udp / tcp / ws / wss",
                                    })
                                end,
                            },
                            {
                                text = _("启用 KCP 代理（丢包 Wi-Fi 上更稳）"),
                                checked_func = function() return self.cfg.enable_kcp_proxy end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "enable_kcp_proxy") end,
                            },
                            {
                                text = _("禁用 P2P（只走中转）"),
                                checked_func = function() return self.cfg.disable_p2p end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "disable_p2p") end,
                            },
                            {
                                text = _("延迟优先路由"),
                                checked_func = function() return self.cfg.latency_first end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "latency_first") end,
                            },
                            {
                                text = _("魔法 DNS（会改系统 DNS，谨慎）"),
                                checked_func = function() return self.cfg.accept_dns end,
                                callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "accept_dns") end,
                            },
                            {
                                text = _("日志级别"),
                                sub_item_table = log_level_items,
                            },
                            {
                                text_func = function()
                                    return string.format(_("程序目录：%s"), self.cfg.custom_bin_dir ~= "" and self.cfg.custom_bin_dir or _("(自动搜索)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "custom_bin_dir", {
                                        title = _("easytier-core 所在目录"),
                                        hint = "/mnt/us/easytier/bin",
                                        description = _("留空则自动搜索常见位置。"),
                                    })
                                end,
                            },
                            {
                                text_func = function()
                                    return string.format(_("额外参数：%s"), self.cfg.extra_args ~= "" and self.cfg.extra_args or _("(无)"))
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self:edit_field(touchmenu_instance, "extra_args", {
                                        title = _("额外参数"),
                                        hint = "--private-mode --compression zstd",
                                        description = _("原样附加到 easytier-core 命令行末尾，效果自负。"),
                                    })
                                end,
                            },
                        },
                    },
                },
            },
            {
                text = _("自动化"),
                sub_item_table = {
                    {
                        text = _("随 KOReader 启动时自动组网"),
                        checked_func = function() return self.cfg.autostart end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "autostart") end,
                    },
                    {
                        text = _("连上 Wi-Fi 后自动组网"),
                        checked_func = function() return self.cfg.start_on_wifi end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "start_on_wifi") end,
                    },
                    {
                        text = _("掉线/被系统中断后自动拉起"),
                        help_text = _("KOReader 恢复前台或网络重连时，如果上次是运行状态而进程已经不在了，就重新启动。"),
                        checked_func = function() return self.cfg.watchdog end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "watchdog") end,
                    },
                    {
                        text = _("启动时放行 Kindle 防火墙（TUN 接口）"),
                        help_text = _("Kindle 系统防火墙会拦进入虚拟网卡的包，导致能连上但收不到数据。"),
                        checked_func = function() return self.cfg.fix_firewall end,
                        callback = function(touchmenu_instance) self:toggle_field(touchmenu_instance, "fix_firewall") end,
                        separator = true,
                    },
                },
            },
            {
                text = _("工具"),
                sub_item_table = {
                    {
                        text = _("重启组网"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance) self:restart(touchmenu_instance) end,
                    },
                    {
                        text = _("查看日志"),
                        keep_menu_open = true,
                        callback = function() self:show_log() end,
                    },
                    {
                        text = _("清空日志"),
                        keep_menu_open = true,
                        callback = function()
                            Proc.clear_log()
                            UI.info(_("日志已清空。"), 3)
                        end,
                    },
                    {
                        text = _("运行诊断"),
                        keep_menu_open = true,
                        callback = function() self:show_diagnostics() end,
                    },
                    {
                        text = _("查看 core 版本"),
                        keep_menu_open = true,
                        callback = function() self:show_core_version() end,
                    },
                    {
                        text = _("查看 KOReader 崩溃日志"),
                        keep_menu_open = true,
                        callback = function() self:show_crash_log() end,
                    },
                    {
                        text = _("清理残留 easytier-core 进程"),
                        keep_menu_open = true,
                        callback = function() self:cleanup_stale() end,
                    },
                    {
                        text = _("安装说明"),
                        keep_menu_open = true,
                        callback = function() self:show_install_help() end,
                    },
                    {
                        text = _("恢复默认设置"),
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            UI.confirm(_("把所有 EasyTier 插件设置恢复为默认值？"), function()
                                self:deletePluginSettings()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                UI.info(_("已恢复默认设置。"), 3)
                            end, _("恢复"))
                        end,
                    },
                },
            },
        },
    }
end

return EasyTier
