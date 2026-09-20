--[[--
EasyTier 组网插件 —— 自带的翻译层

为什么要自己搞一层：
KOReader 的 gettext 只加载主目录的 `l10n/<lang>/koreader.mo`，第三方插件没法往那里塞自己的
翻译文件，所以插件的英文字符串不会因为界面语言是中文就变成中文。

做法：**英文作源语言**（也就是 gettext 的 msgid，各文件里照常写成 `_("English source")`），
下面这张表给出中文。语言为中文时用表里的译文，其余语言直接用英文源串。

新增/修改字符串时：改完跑 `python tools/i18n_extract.py --missing`，把缺的条目补进下面的表。
--]]

local _ = require("gettext")

local zh = {
    ------------------------------------------------------------------ 插件名
    ["EasyTier mesh networking"] =
        "EasyTier 异地组网",
    ["\nControl a standalone EasyTier (easytier-core) node from your e-reader: start/stop, configure, and inspect peers and routes.\n\nYou need to provide the easytier-core / easytier-cli binaries (official Linux armv7 static build)."] =
        "\n在阅读器上控制独立运行的 EasyTier（easytier-core）节点：启停、配置、查看节点与路由。\n\n需要自行提供 easytier-core / easytier-cli 可执行文件（官方 Linux armv7 静态包）。",
    ["Start EasyTier"] =
        "启动 EasyTier",
    ["Start EasyTier mesh"] =
        "启动 EasyTier 组网",
    ["Stop EasyTier mesh"] =
        "停止 EasyTier 组网",
    ["Stop EasyTier (PID %d)"] =
        "停止 EasyTier（PID %d）",
    ["Toggle EasyTier"] =
        "EasyTier 组网开关",
    ["Status"] =
        "连接状态",
    ["EasyTier status"] =
        "EasyTier 连接状态",
    ["Tools"] =
        "工具",
    ["Settings"] =
        "配置",
    ["Advanced"] =
        "进阶",
    ["Automation"] =
        "自动化",
    ["Info"] =
        "信息",
    ["Working…"] =
        "处理中…",
    ["OK"] =
        "确定",
    ["Cancel"] =
        "取消",
    ["Save"] =
        "保存",
    ["Kill"] =
        "清理",
    ["Restore"] =
        "恢复",
    ["supported"] =
        "支持",
    ["(none)"] =
        "(无)",
    ["(not set)"] =
        "(未设置)",
    ["(default)"] =
        "(默认)",
    ["(auto)"] =
        "(自动)",
    ["(auto-detected)"] =
        "(自动搜索)",
    ["(system hostname)"] =
        "(系统主机名)",
    ["(log is empty)"] =
        "(日志为空)",
    ["(No log yet)\n\nStart EasyTier once and easytier-core's output will show up here."] =
        "(暂无日志)\n\n启动一次之后这里会有 easytier-core 的输出。",
    ["32-bit"] =
        "32 位",
    ["64-bit"] =
        "64 位",
    ["statically linked"] =
        "静态链接",
    ["dynamically linked"] =
        "动态链接",
    ["hard-float ABI"] =
        "硬浮点 ABI",
    ["soft-float ABI"] =
        "软浮点 ABI",
    ["Not an ELF executable"] =
        "不是 ELF 可执行文件",
    ["Cannot open the file"] =
        "无法打开文件",

    ------------------------------------------------------------------ 启停与运行状态
    ["EasyTier is already running."] =
        "EasyTier 已经在运行了。",
    ["EasyTier stopped."] =
        "EasyTier 已停止。",
    ["EasyTier is not running."] =
        "EasyTier 当前没有运行。",
    ["Starting EasyTier…"] =
        "正在启动 EasyTier…",
    ["Stopping EasyTier…"] =
        "正在停止 EasyTier…",
    ["Restarting EasyTier…"] =
        "正在重启 EasyTier…",
    ["Collecting diagnostics…"] =
        "正在收集诊断信息…",
    ["EasyTier connected (PID %s).\n\nOpen Status to see the virtual IP, peers and routes."] =
        "EasyTier 已连接（PID %s）。\n\n点「连接状态」可以看到虚拟 IP、对端列表和路由。",
    ["EasyTier is running (PID %s) but easytier-cli was not found, so peer and route info cannot be read.\n\nPut easytier-cli in the same directory as easytier-core."] =
        "EasyTier 已在运行（PID %s），但没找到 easytier-cli，读不到节点状态。\n\n把 easytier-cli 放在 easytier-core 同一个目录里即可。",
    ["easytier-core is running (PID %s) but its RPC port is not answering.\n\nUsual causes: network name/secret mismatch with the peers, unreachable peer address, or the RPC port being taken.\n\nEnd of the log:\n%s"] =
        "EasyTier 进程在运行（PID %s），但 RPC 端口没有响应。\n\n常见原因：网络名称/密钥与对端不一致、对等节点地址不可达、RPC 端口被占用。\n\n日志末尾：\n%s",
    ["easytier-core exited shortly after starting, so it is not running.\n\nEnd of the log:\n"] =
        "EasyTier 进程启动后很快退出了，所以没有进入运行状态。\n\n日志末尾：\n",
    ["See Tools → Diagnostics for the environment (TUN, architecture, binaries), or Tools → Log for the full output."] =
        "可到「工具 → 运行诊断」看环境（TUN、架构、二进制），或到「工具 → 查看日志」看完整输出。",
    ["There is a problem with the settings:\n\n"] =
        "配置有问题：\n\n",
    ["Could not stop it completely: "] =
        "没能完全停掉：",
    ["\nYou can force it from Tools → Kill leftover processes."] =
        "\n可以到「工具 → 清理残留进程」强制处理。",
    ["Process did not exit, PID "] =
        "进程没有退出，PID ",
    ["Killed %d process(es)."] =
        "已清理 %d 个进程。",
    ["This kills every easytier-core process on the device, including ones started outside this plugin. Continue?"] =
        "会杀掉设备上所有 easytier-core 进程（包括不是本插件启动的）。继续？",
    ["Kill leftover easytier-core processes"] =
        "清理残留 easytier-core 进程",
    ["easytier-core executable not found"] =
        "没找到 easytier-core 可执行文件",
    ["easytier-core not found. Put the binaries on the device first (see Installation)."] =
        "找不到 easytier-core。请先按「安装说明」把二进制放到设备上。",
    ["Show installation help"] =
        "看安装说明",
    ["Show diagnostics"] =
        "看诊断信息",
    ["Run diagnostics"] =
        "运行诊断",
    ["Restart EasyTier"] =
        "重启组网",
    ["View log"] =
        "查看日志",
    ["Clear log"] =
        "清空日志",
    ["Log cleared."] =
        "日志已清空。",
    ["EasyTier log"] =
        "EasyTier 日志",
    ["EasyTier diagnostics"] =
        "EasyTier 诊断",
    ["Installation"] =
        "安装说明",
    ["View KOReader crash.log"] =
        "查看 KOReader 崩溃日志",
    ["KOReader crash.log (tail)"] =
        "KOReader 崩溃日志（末尾）",
    ["Could not read the crash log: \n"] =
        "没有读到崩溃日志：\n",
    ["\n\n(Empty if nothing crashed yet, or if the log was cleared.)"] =
        "\n\n（如果这次没有崩过，或日志被清理过，这里就是空的）",
    ["File: "] =
        "文件：",
    ["Restore default settings"] =
        "恢复默认设置",
    ["Reset all EasyTier plugin settings to their defaults?"] =
        "把所有 EasyTier 插件设置恢复为默认值？",
    ["Settings restored to defaults."] =
        "已恢复默认设置。",

    ------------------------------------------------------------------ 页面与提示
    ["Failed to build the page content:\n"] =
        "生成页面内容时出错：\n",
    ["\n\n(Details were written to KOReader's crash.log.)"] =
        "\n\n（详情已写入 KOReader 的 crash.log）",
    ["Could not open the viewer widget; showing plain text instead:\n\n"] =
        "打不开页面控件，先按纯文本显示：\n\n",
    ["Failed to show the page:\n"] =
        "页面显示失败：\n",
    ["\n\n… (truncated)"] =
        "\n\n…（内容过长，已截断）",

    ------------------------------------------------------------------ 网络与节点
    ["Network name"] =
        "网络名称",
    ["Network name: "] =
        "网络名称：",
    ["Network name: %s"] =
        "网络名称：%s",
    ["Every node in the network must use exactly the same network name and secret."] =
        "同一网络内所有节点必须使用完全相同的网络名称和密钥。",
    ["e.g. my-vpn-net"] =
        "例如 my-vpn-net",
    ["No network name set: unnamed nodes all end up in the same default network, so it is worth setting one."] =
        "未填写网络名称：所有未命名节点会落在同一个默认网络里，建议填写。",
    ["Network secret"] =
        "网络密钥",
    ["Network secret: %s"] =
        "网络密钥：%s",
    ["Acts as a password — make it long and do not keep the default."] =
        "相当于密码，建议设长一点，别用默认值。",
    ["e.g. secret-1234567890"] =
        "例如 secret-1234567890",
    ["Initial node (server)"] =
        "初始节点（服务器）",
    ["Initial nodes: %s"] =
        "初始节点：%s",
    ["Nodes to connect to on start, comma separated.\n"] =
        "启动时主动去连的节点，多个用逗号分隔。\n",
    ["You can use your own node, or a public shared node someone else runs — EasyTier has no server/client split, so reaching any node joins the network.\n\nPublic shared node example: tcp://public.easytier.top:11010"] =
        "可以填自己的节点，也可以填别人分享的公共共享节点——EasyTier 不分服务端/客户端，能连上任何一个节点就能入网。\n\n公共共享节点示例：tcp://public.easytier.top:11010",
    ["Bad initial node: "] =
        "初始节点格式不对：",
    ["\nExample: tcp://public.easytier.top:11010"] =
        "\n示例：tcp://public.easytier.top:11010",
    ["\nMissing the protocol prefix. Write it as: tcp://"] =
        "\n缺少协议前缀。要写成：tcp://",
    ["Mode"] =
        "运行模式",
    ["Mode: "] =
        "模式：",
    ["Mode: %s"] =
        "运行模式：%s",
    ["TUN (full routing)"] =
        "TUN（全局路由）",
    ["Proxy (no TUN)"] =
        "代理（无 TUN）",
    ["Proxy (no TUN, SOCKS5 :"] =
        "代理（无 TUN，SOCKS5 :",
    ["TUN: create a virtual interface and route the whole device"] =
        "TUN：创建虚拟网卡，整个设备走虚拟网络",
    ["Proxy: no virtual interface, SOCKS5 only (for devices without TUN)"] =
        "代理：不建虚拟网卡，只开 SOCKS5（需要 TUN 驱动的设备用）",
    ["Assign the node IP automatically with DHCP (turn off to set it yourself)"] =
        "DHCP 自动分配 IP（关闭后需自己填节点 IP）",
    ["DHCP (automatic)"] =
        "DHCP 自动",
    ["This node's virtual IP"] =
        "本节点虚拟 IP",
    ["Every node uses a different address. Required when DHCP is off."] =
        "网络内每个节点用不同的地址。关掉 DHCP 后这里必须填。",
    ["Node IP: "] =
        "节点 IP：",
    ["Node IP: %s"] =
        "节点 IP：%s",
    ["Peers: "] =
        "对等节点：",
    ["Bad node IP: "] =
        "节点 IP 格式不对：",
    ["\nExample: 10.144.144.2"] =
        "\n示例：10.144.144.2",
    ["TUN mode needs a node IP, or turn DHCP on."] =
        "TUN 模式下需要填写本节点 IP，或改用 DHCP 自动分配。",
    ["There is no /dev/net/tun on this device; the kernel may lack TUN support"] =
        "设备上没有 /dev/net/tun，内核可能没有 TUN 驱动",
    ["Switch to proxy mode (no TUN)"] =
        "改用代理模式（不建 TUN）",
    ["Switched to proxy mode: only traffic that explicitly goes through SOCKS5 or a port forward can reach the network."] =
        "已切换到代理模式：只有本机显式走 SOCKS5 或端口转发的流量能进入虚拟网络。",
    ["SOCKS5 port"] =
        "SOCKS5 端口",
    ["SOCKS5 port: %s"] =
        "SOCKS5 端口：%s",
    ["The SOCKS5 port must be a number."] =
        "SOCKS5 端口必须是数字。",
    ["Proxy mode only. Other apps can point their SOCKS5 proxy at this port on 127.0.0.1."] =
        "仅代理模式生效。其他程序可把 SOCKS5 代理指向 127.0.0.1 的这个端口。",
    ["Share this device's subnets"] =
        "共享本机所在子网",
    ["Shared local subnets: %s"] =
        "共享本机子网：%s",
    ["Subnets: "] =
        "共享子网：",
    ["Let other nodes reach this device's LAN. Comma separated."] =
        "让其他节点能访问本机所在局域网，逗号分隔。",
    ["Bad subnet: "] =
        "子网格式不对：",
    ["\nExample: 192.168.1.0/24"] =
        "\n示例：192.168.1.0/24",
    ["Port forwarding"] =
        "端口转发",
    ["Port forwards: "] =
        "端口转发：",
    ["Port forwards: %s"] =
        "端口转发：%s",
    ["Map a service from the virtual network onto a local port.\nWorks without TUN — handy for reaching Calibre/OPDS on your LAN from KOReader."] =
        "把虚拟网络里的服务映射到本机的端口。\n没有 TUN 也能用，适合让 KOReader 访问局域网里的 Calibre / OPDS。",
    ["Bad port forward: "] =
        "端口转发格式不对：",
    ["\nExample: tcp://127.0.0.1:8080/10.126.126.1:80"] =
        "\n示例：tcp://127.0.0.1:8080/10.126.126.1:80",
    ["Listeners"] =
        "监听地址",
    ["Listeners: %s"] =
        "监听地址：%s",
    ["Bad listener: "] =
        "监听地址格式不对：",
    ["\nExample: tcp://0.0.0.0:11010 or 11010"] =
        "\n示例：tcp://0.0.0.0:11010 或 11010",
    ["Do not listen on any port (outbound only)"] =
        "不监听任何端口（只出站）",
    ["RPC port"] =
        "RPC 端口",
    ["RPC portal: %s"] =
        "RPC 端口：%s",
    ["Bad RPC portal: "] =
        "RPC 端口格式不对：",
    ["\nExample: 127.0.0.1:15888"] =
        "\n示例：127.0.0.1:15888",
    ["The plugin reads node status through it; avoid clashing with other programs."] =
        "本插件通过它读取节点状态，别和别的程序冲突。",
    ["Hostname"] =
        "主机名",
    ["Hostname: "] =
        "主机名：",
    ["Hostname: %s"] =
        "主机名：%s",
    ["This is the name peers see in their node list.\n"] =
        "对端节点列表里显示的就是这个名字。\n",
    ["Leave empty to use the system hostname (usually kindle on a Kindle).\nAvoid spaces — use dashes. With magic DNS on it becomes <hostname>.et.net."] =
        "留空则用系统主机名（Kindle 上通常是 kindle）。\n不要用空格，用横线代替；开了魔法 DNS 时会作为 <主机名>.et.net 用。",
    ["Hostname must not contain spaces: "] =
        "主机名里不要有空格：",
    ["\nExample: kindle-kpw6"] =
        "\n示例：kindle-kpw6",
    ["Instance name"] =
        "实例名",
    ["Instance name: %s"] =
        "实例名：%s",
    ["Instance: "] =
        "实例名：",
    ["Only distinguishes multiple instances on this machine; peers do not see it.\n"] =
        "只用于在同一台机器上区分多个实例，对端看不到它。\n",
    ["To change the name peers see, edit Hostname above."] =
        "想改对端看到的名字，请改上面的「主机名」。",
    ["Instance name must not contain spaces: "] =
        "实例名里不要有空格：",
    ["TUN interface name"] =
        "TUN 接口名",
    ["TUN interface: %s"] =
        "TUN 接口名：%s",
    ["At most 15 characters (kernel limit)."] =
        "最多 15 个字符，内核限制。",
    ["The TUN interface name cannot exceed 15 characters (kernel limit)."] =
        "TUN 接口名不能超过 15 个字符（内核限制）。",
    ["MTU: %s"] =
        "MTU：%s",
    ["MTU"] =
        "MTU",
    ["0 keeps EasyTier's default (1360 encrypted / 1380 unencrypted)."] =
        "0 表示用 EasyTier 默认值（加密 1360 / 不加密 1380）。",
    ["MTU is too small; leave it empty or use 1280 or more."] =
        "MTU 太小了，建议留空或填 1280 以上。",
    ["Default protocol: %s"] =
        "默认协议：%s",
    ["Protocol used to reach peers"] =
        "连接对等节点使用的协议",
    ["Enable the KCP proxy (steadier on lossy Wi-Fi)"] =
        "启用 KCP 代理（丢包 Wi-Fi 上更稳）",
    ["Disable P2P (relay only)"] =
        "禁用 P2P（只走中转）",
    ["Prefer the lowest-latency route"] =
        "延迟优先路由",
    ["Magic DNS (modifies system DNS — use with care)"] =
        "魔法 DNS（会改系统 DNS，谨慎）",
    ["Log level"] =
        "日志级别",
    ["Binary directory: %s"] =
        "程序目录：%s",
    ["easytier-core directory"] =
        "easytier-core 所在目录",
    ["Leave empty to search the usual locations."] =
        "留空则自动搜索常见位置。",
    ["Extra arguments"] =
        "额外参数",
    ["Extra arguments: %s"] =
        "额外参数：%s",
    ["Appended verbatim to the easytier-core command line; use at your own risk."] =
        "原样附加到 easytier-core 命令行末尾，效果自负。",

    ------------------------------------------------------------------ 自动化
    ["Start EasyTier with KOReader"] =
        "随 KOReader 启动时自动组网",
    ["Start after Wi-Fi connects"] =
        "连上 Wi-Fi 后自动组网",
    ["Restart automatically if the process dies"] =
        "掉线/被系统中断后自动拉起",
    ["Restart EasyTier when KOReader comes back to the foreground or Wi-Fi reconnects, if it was running and the process is gone."] =
        "KOReader 恢复前台或网络重连时，如果上次是运行状态而进程已经不在了，就重新启动。",
    ["Open the Kindle firewall for the TUN interface on start"] =
        "启动时放行 Kindle 防火墙（TUN 接口）",
    ["Kindle's firewall drops packets arriving on the tunnel interface, which looks like connected but no traffic."] =
        "Kindle 系统防火墙会拦进入虚拟网卡的包，导致能连上但收不到数据。",

    ------------------------------------------------------------------ 诊断
    ["unknown (/proc/config.gz not readable)"] =
        "未知（读不到 /proc/config.gz）",
    ["Not supported (kernel has TUN disabled): "] =
        "不支持（内核关闭了 TUN）：",
    ["easytier-core failed to start. End of the log:\n\n"] =
        "easytier-core 启动失败。日志末尾：\n\n",
    ["easytier-cli not found, cannot read the status."] =
        "找不到 easytier-cli，无法读取状态。",
}

local M = {}

local lang_cache = false

--- 当前界面语言（KOReader 把它存在 G_reader_settings 的 language 里，如 "zh_CN"）
local function ui_language()
    if lang_cache ~= false then return lang_cache end
    local settings = rawget(_G, "G_reader_settings")
    local lang = settings and settings:readSetting("language")
    if type(lang) ~= "string" or lang == "" then lang = "en" end
    lang_cache = lang
    return lang_cache
end

--- 与 KOReader 的 _() 用法一致：_(英文源串) -> 当前语言下的文案。
--- 英文是源语言；界面语言是中文时查上面的表，其余语言直接返回英文。
function M.tr(msgid)
    local source = _(msgid)
    if tostring(ui_language()):match("^zh") then
        return zh[msgid] or source
    end
    return source
end

--- 已收录的中文条目数（测试与维护脚本用）
function M.zh_count()
    local n = 0
    for _ in pairs(zh) do n = n + 1 end
    return n
end

--- 测试用：清掉语言缓存
function M.reset_language_cache()
    lang_cache = false
end

return M
