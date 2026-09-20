--[[--
EasyTier 组网插件 —— 配置模型（纯逻辑，不依赖 KOReader 界面模块）

职责：
  * 默认值与持久化（写进 KOReader 的全局设置 G_reader_settings，键名 easytier）
  * 配置校验
  * 把配置翻译成 easytier-core 的命令行参数

命令行的每一项都对照 EasyTier 官方文档核对过（-i/--ipv4、-p/--peers、-r/--rpc-portal、
-l/--listeners、-n/--proxy-networks、-m/--instance-name、--daemon、--no-tun 等）。
注意：-d 是 --dhcp 而不是守护进程。
--]]

local _ = require("gettext")

local Config = {}

Config.SETTINGS_KEY = "easytier"
Config.CORE_NAME = "easytier-core"
Config.CLI_NAME = "easytier-cli"

-- 查找可执行文件的目录（按顺序）。Kindle 用户区 /mnt/us 是主战场。
Config.BIN_SEARCH_DIRS = {
    "/mnt/us/easytier/bin",
    "/mnt/us/easytier",
    "/mnt/us/koreader/easytier",
    "/mnt/onboard/.adds/easytier/bin",
    "/mnt/onboard/.adds/easytier",
    "/usr/local/bin",
    "/usr/bin",
    "/opt/bin",
}

Config.DEFAULTS = {
    -- 网络标识
    network_name = "",
    network_secret = "",
    peers = {},                -- 初始节点（服务器）：填自己的节点或别人分享的公共共享节点
    external_node = "",        -- 已弃用：等价于 peers，仅为兼容旧设置保留（load 时会并入 peers）
    -- 运行模式
    mode = "tun",              -- "tun" 创建 TUN 设备（全局路由）；"proxy" 不建 TUN，只开 SOCKS5
    ipv4 = "",                 -- 本节点虚拟 IPv4
    dhcp = true,               -- 由 EasyTier 自动分配 IP
    socks5_port = 1080,        -- proxy 模式下的 SOCKS5 端口
    -- 进阶
    proxy_networks = {},       -- -n 把本机可达的子网共享给网络里的其他节点
    listeners = {},            -- -l 监听地址，如 tcp://0.0.0.0:11010
    no_listener = false,       -- --no-listener 只连不监听
    port_forwards = {},        -- --port-forward tcp://127.0.0.1:8080/10.126.126.1:80
    rpc_portal = "127.0.0.1:15888",
    instance_name = "kindle",
    hostname = "",
    dev_name = "easytier0",
    mtu = 0,                   -- 0 = 使用 EasyTier 默认值
    default_protocol = "",     -- 如 udp / tcp / ws
    enable_kcp_proxy = false,  -- 丢包严重的 Wi-Fi 上打开可明显改善
    disable_p2p = false,
    latency_first = false,
    accept_dns = false,        -- 魔法 DNS（会改系统 DNS，谨慎）
    extra_args = "",           -- 原样追加的额外参数
    custom_bin_dir = "",       -- 手动指定 easytier-core 所在目录
    -- 行为
    autostart = false,         -- 随 KOReader 启动
    start_on_wifi = false,     -- 连上 Wi-Fi 后启动
    watchdog = true,           -- 掉线/被系统杀掉后自动拉起
    fix_firewall = true,       -- Kindle 防火墙放行 TUN 接口
    log_level = "info",        -- trace/debug/info/warn/error
    active = false,            -- 运行意图（供掉线重启用，不是用户选项）
}

-- 以列表形式存储、界面上用逗号/换行分隔输入的字段
Config.LIST_FIELDS = {
    peers = true,
    proxy_networks = true,
    listeners = true,
    port_forwards = true,
}

local function settings()
    -- 方便在 KOReader 之外做单元测试
    return rawget(_G, "G_reader_settings")
end

local function copy_defaults()
    local cfg = {}
    for k, v in pairs(Config.DEFAULTS) do
        if type(v) == "table" then
            local t = {}
            for i, item in ipairs(v) do t[i] = item end
            cfg[k] = t
        else
            cfg[k] = v
        end
    end
    return cfg
end

--- 读取配置（合并默认值），返回配置表
function Config.load()
    local cfg = copy_defaults()
    local s = settings()
    local stored = s and s:readSetting(Config.SETTINGS_KEY)
    if type(stored) == "table" then
        for k, v in pairs(stored) do
            if cfg[k] ~= nil then
                if type(cfg[k]) == "table" and type(v) == "table" then
                    local t = {}
                    for i, item in ipairs(v) do t[i] = tostring(item) end
                    cfg[k] = t
                elseif type(cfg[k]) ~= "table" then
                    cfg[k] = v
                end
            end
        end
    end

    -- 历史字段迁移：--external-node(-e) 在 core 里和 --peers 走的是同一段代码
    -- （同样构造 PeerConfig、塞进同一个 peers 列表），唯一差别是它只能填一个值。
    -- 为了让界面只留一个「初始节点」，旧值并入 peers，插件不再单独输出 -e。
    if cfg.external_node ~= "" then
        local dup = false
        for _i, p in ipairs(cfg.peers) do
            if p == cfg.external_node then dup = true end
        end
        if not dup then table.insert(cfg.peers, cfg.external_node) end
        cfg.external_node = ""
    end

    return cfg
end

--- 保存配置
function Config.save(cfg)
    local s = settings()
    if s then s:saveSetting(Config.SETTINGS_KEY, cfg) end
end

--- 删除全部设置（插件被「删除设置」时调用）
function Config.clear()
    local s = settings()
    if s then s:delSetting(Config.SETTINGS_KEY) end
end

--- 把列表字段转成界面上的一行文本
function Config.list_to_text(list)
    if type(list) ~= "table" then return "" end
    return table.concat(list, ", ")
end

--- 把界面输入的一行文本解析成列表（逗号、分号、空白、换行都算分隔符）
function Config.text_to_list(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for token in text:gmatch("[^,;%s]+") do
        table.insert(out, token)
    end
    return out
end

--- 单引号包裹，供 shell 使用（配置里的内容会进 root shell，必须转义）
function Config.shquote(s)
    s = tostring(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- 解析额外参数（支持单/双引号分组）
function Config.split_args(text)
    local out = {}
    if type(text) ~= "string" then return out end
    local cur, quote = {}, nil
    local function flush()
        if #cur > 0 then
            table.insert(out, table.concat(cur))
            cur = {}
        end
    end
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if quote then
            if c == quote then
                quote = nil
            else
                table.insert(cur, c)
            end
        elseif c == "'" or c == '"' then
            quote = c
        elseif c:match("%s") then
            flush()
        else
            table.insert(cur, c)
        end
        i = i + 1
    end
    flush()
    return out
end

local function is_ipv4(s)
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _i, o in ipairs({ a, b, c, d }) do
        if #o > 3 or tonumber(o) > 255 then return false end
    end
    return true
end

--- 允许 10.144.144.2 或 10.144.144.2/24
local function is_ipv4_or_cidr(s)
    local addr, prefix = s:match("^([^/]+)/(%d+)$")
    if addr then
        return is_ipv4(addr) and tonumber(prefix) <= 32
    end
    return is_ipv4(s)
end

--- 初始节点/监听地址这类地址：必须是 url crate 认的完整形式（scheme://host[:port]）。
--- EasyTier 用 url::Url::try_from 解析，没写协议前缀会在启动时报错，所以在插件里就拦住。
local function is_uri(s)
    if s == "" or s:find("%s") then return false end
    local scheme, rest = s:match("^(%a[%w+%-%.]*)://(%S+)$")
    if not scheme then return false end
    return rest ~= "" and rest ~= "/"
end

--- 形如 1.2.3.4:11010 / node.example.com:11010：缺协议前缀，给个针对性的提示
function Config.missing_scheme(s)
    return type(s) == "string" and s:match("^[%w%._%-]+:%d+$") ~= nil
end

local function is_cidr(s)
    local addr, prefix = s:match("^([^/]+)/(%d+)$")
    if not addr or not is_ipv4(addr) then return false end
    return tonumber(prefix) <= 32
end

--- 校验配置：返回 ok, 错误信息, 警告信息
function Config.validate(cfg)
    local warn = nil
    if cfg.network_name == "" then
        warn = _("未填写网络名称：所有未命名节点会落在同一个默认网络里，建议填写。")
    end
    if cfg.mode == "tun" then
        if not cfg.dhcp then
            if cfg.ipv4 == "" then
                return false, _("TUN 模式下需要填写本节点 IP，或改用 DHCP 自动分配。")
            end
            if not is_ipv4_or_cidr(cfg.ipv4) then
                return false, _("节点 IP 格式不对：") .. cfg.ipv4 .. _("\n示例：10.144.144.2")
            end
        end
    else
        if not tonumber(cfg.socks5_port) then
            return false, _("SOCKS5 端口必须是数字。")
        end
    end

    for _i, p in ipairs(cfg.peers) do
        if not is_uri(p) then
            local extra = _("\n示例：tcp://public.easytier.top:11010")
            if Config.missing_scheme(p) then
                extra = _("\n缺少协议前缀。要写成：tcp://") .. p
            end
            return false, _("初始节点格式不对：") .. p .. extra
        end
    end
    for _i, net in ipairs(cfg.proxy_networks) do
        local from = net:match("^([^>]+)->")
        local target = from and net:match("->(.+)$") or net
        if not (is_cidr(from or net) and is_cidr(target)) then
            return false, _("子网格式不对：") .. net .. _("\n示例：192.168.1.0/24")
        end
    end
    for _i, l in ipairs(cfg.listeners) do
        -- 允许三种官方写法：纯端口号、scheme://url、proto:port
        local ok_listener = l:match("^%d+$") or is_uri(l) or l:match("^%a+:%d+$") ~= nil
        if not ok_listener then
            return false, _("监听地址格式不对：") .. l .. _("\n示例：tcp://0.0.0.0:11010 或 11010")
        end
    end
    for _i, f in ipairs(cfg.port_forwards) do
        local proto, src, dst = f:match("^(%a+)://([^/]+)/(.+)$")
        if not (proto and src and dst) then
            return false, _("端口转发格式不对：") .. f
                .. _("\n示例：tcp://127.0.0.1:8080/10.126.126.1:80")
        end
    end
    if cfg.rpc_portal ~= "" and not cfg.rpc_portal:match("^%d+$")
        and not cfg.rpc_portal:match("^[%w%._%-]+:%d+$") then
        return false, _("RPC 端口格式不对：") .. cfg.rpc_portal .. _("\n示例：127.0.0.1:15888")
    end
    if cfg.dev_name ~= "" and #cfg.dev_name > 15 then
        return false, _("TUN 接口名不能超过 15 个字符（内核限制）。")
    end
    -- 主机名会用于魔法 DNS（<hostname>.et.net），实例名用于同一台机器上区分多个实例，
    -- 两者带空格都会带来麻烦（启动参数、展示、DNS 名字都不友好）
    if cfg.hostname:find("%s") then
        return false, _("主机名里不要有空格：") .. cfg.hostname .. _("\n示例：kindle-kpw6")
    end
    if cfg.instance_name:find("%s") then
        return false, _("实例名里不要有空格：") .. cfg.instance_name .. _("\n示例：kindle-kpw6")
    end
    if tonumber(cfg.mtu) and tonumber(cfg.mtu) > 0 and tonumber(cfg.mtu) < 576 then
        return false, _("MTU 太小了，建议留空或填 1280 以上。")
    end
    return true, nil, warn
end

-- 需要跟一个值的开关：值为空时必须整对跳过，否则会把后面的参数名吞掉当成自己的值
local VALUE_FLAGS = {
    "--network-name", "--network-secret", "--instance-name", "--hostname", "--rpc-portal",
    "--socks5", "--dev-name", "--mtu", "--ipv4", "--peers",
    "--proxy-networks", "--listeners", "--port-forward", "--default-protocol", "--console-log-level",
}

--- 生成 easytier-core 的参数列表（不含可执行文件本身）
function Config.build_argv(cfg)
    local argv = {}

    local function flag(name)
        table.insert(argv, name)
    end

    --- 带值参数：值非空才成对写入
    local function opt(name, value)
        if value == nil then return end
        value = tostring(value)
        if value == "" then return end
        table.insert(argv, name)
        table.insert(argv, value)
    end

    opt("--network-name", cfg.network_name)
    opt("--network-secret", cfg.network_secret)
    opt("--instance-name", cfg.instance_name)
    opt("--hostname", cfg.hostname)
    opt("--rpc-portal", cfg.rpc_portal)

    if cfg.mode == "proxy" then
        flag("--no-tun")
        opt("--socks5", cfg.socks5_port)
    else
        opt("--dev-name", cfg.dev_name)
        if tonumber(cfg.mtu) and tonumber(cfg.mtu) > 0 then
            opt("--mtu", cfg.mtu)
        end
        if cfg.dhcp then
            flag("--dhcp")
        else
            opt("--ipv4", cfg.ipv4)
        end
    end

    for _i, p in ipairs(cfg.peers) do opt("--peers", p) end
    for _i, n in ipairs(cfg.proxy_networks) do opt("--proxy-networks", n) end
    if cfg.no_listener then
        flag("--no-listener")
    else
        for _i, l in ipairs(cfg.listeners) do opt("--listeners", l) end
    end
    for _i, f in ipairs(cfg.port_forwards) do opt("--port-forward", f) end

    opt("--default-protocol", cfg.default_protocol)
    if cfg.enable_kcp_proxy then flag("--enable-kcp-proxy") end
    if cfg.disable_p2p then flag("--disable-p2p") end
    if cfg.latency_first then flag("--latency-first") end
    if cfg.accept_dns then flag("--accept-dns") end

    opt("--console-log-level", cfg.log_level)

    for _i, a in ipairs(Config.split_args(cfg.extra_args)) do
        table.insert(argv, a)
    end

    return argv
end

--- 该开关是否需要跟一个值（自检 / 测试用）
function Config.needs_value(arg)
    return VALUE_FLAGS[arg] == true
end

--- 按字节裁剪但保证不切断 UTF-8 字符
local function cut_utf8(s, n)
    if #s <= n then return s end
    local cut = n
    for _ = 1, 4 do
        local b = s:byte(cut)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

--- 限制文本体积：太长的行先截断，总量超限就不再往下要（避免把巨大文本塞给界面控件）
function Config.clip_text(text, max_bytes, max_line)
    max_bytes = max_bytes or 64 * 1024
    max_line = max_line or 400
    local out, total, clipped = {}, 0, false
    for raw_line in tostring(text):gmatch("[^\n]*") do
        local line = raw_line
        if #line > max_line then
            line = cut_utf8(line, max_line) .. "…"
        end
        total = total + #line + 1
        if total > max_bytes then
            clipped = true
            break
        end
        out[#out + 1] = line
    end
    local joined = table.concat(out, "\n")
    if clipped then
        joined = joined .. "\n\n…（内容过长，已截断）"
    end
    return joined
end

--- 供状态页显示的一行摘要
function Config.summary(cfg)
    local lines = {}
    table.insert(lines, _("模式：") .. (cfg.mode == "tun" and _("TUN（全局路由）") or _("代理（无 TUN，SOCKS5 :") .. tostring(cfg.socks5_port) .. ")"))
    table.insert(lines, _("网络名称：") .. (cfg.network_name ~= "" and cfg.network_name or _("(未设置)")))
    table.insert(lines, _("节点 IP：") .. (cfg.mode == "proxy" and "-" or (cfg.dhcp and _("DHCP 自动") or cfg.ipv4)))
    table.insert(lines, _("主机名：") .. (cfg.hostname ~= "" and cfg.hostname or _("(系统主机名)"))
        .. "  |  " .. _("实例名：") .. cfg.instance_name)
    table.insert(lines, _("对等节点：") .. (#cfg.peers > 0 and table.concat(cfg.peers, " ") or _("(无)")))
    if #cfg.proxy_networks > 0 then
        table.insert(lines, _("共享子网：") .. table.concat(cfg.proxy_networks, " "))
    end
    if #cfg.port_forwards > 0 then
        table.insert(lines, _("端口转发：") .. table.concat(cfg.port_forwards, " "))
    end
    return table.concat(lines, "\n")
end

return Config
