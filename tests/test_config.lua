--[[--
et_config / et_proc 纯逻辑测试（不依赖 KOReader，可用系统 lua 直接跑）

    lua tests/test_config.lua [easytier-core 的路径]

第二个参数可选：给一个真实的 easytier-core 可执行文件路径，
用来验证 et_proc.elf_info 的架构识别（例如官方 easytier-linux-armv7 包里的 core）。
--]]

package.path = "./easytier.koplugin/?.lua;" .. package.path

--==== 打桩：KOReader 的运行时模块 ====--
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
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
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        dir = function() error("no /proc in test") end,
    }
end

local Config = require("et_config")
local Proc = require("et_proc")

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name .. (extra and ("  ->  " .. tostring(extra)) or ""))
    end
end

local function contains(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

local function index_of(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
end

local function base_cfg(over)
    local cfg = Config.load() -- 没有 G_reader_settings 时就是默认值
    for k, v in pairs(over or {}) do cfg[k] = v end
    return cfg
end

--- 结构自检：需要跟值的开关不能变成「光杆参数」，否则会把后面的参数名吞掉
local function check_no_dangling_flag(name, argv)
    for i, a in ipairs(argv) do
        if Config.needs_value(a) then
            local v = argv[i + 1]
            check(name .. "：" .. a .. " 后面跟着值", v ~= nil and v:sub(1, 2) ~= "--", tostring(v))
        end
    end
end

--==== 默认值 ====--
do
    local cfg = Config.load()
    check("默认模式是 tun", cfg.mode == "tun", cfg.mode)
    check("默认 rpc_portal", cfg.rpc_portal == "127.0.0.1:15888", cfg.rpc_portal)
    check("默认不自动启动", cfg.autostart == false)
    check("列表字段默认是独立表", cfg.peers ~= Config.DEFAULTS.peers)
end

--==== 参数生成：TUN + DHCP ====--
do
    local cfg = base_cfg({ network_name = "abc", network_secret = "s3cr3t", ipv4 = "10.144.144.2" })
    -- 全部用长参数：短选项在不同版本间有过变动，长参数在 v2.6.4 里逐个核对过
    local argv = Config.build_argv(cfg)
    local long = {}
    for _, a in ipairs(argv) do if a:sub(1, 2) == "--" then long[a] = true end end
    check("参数里没有单字母短选项", next(long) ~= nil and (function()
        for _, a in ipairs(argv) do
            if a:match("^%-%a$") then return false end
        end
        return true
    end)())
    check("tun+dhcp 用 --dhcp", contains(argv, "--dhcp"))
    check("tun+dhcp 不带 --ipv4", index_of(argv, "--ipv4") == nil)
    check("网络名参数名正确", argv[index_of(argv, "--network-name") + 1] == "abc")
    check("密钥参数名正确", argv[index_of(argv, "--network-secret") + 1] == "s3cr3t")
    check("实例名是 --instance-name", argv[index_of(argv, "--instance-name") + 1] == "kindle")
    check("rpc 是 --rpc-portal", argv[index_of(argv, "--rpc-portal") + 1] == "127.0.0.1:15888")
    check("带 --dev-name", argv[index_of(argv, "--dev-name") + 1] == "easytier0")
    check("日志级别参数", argv[index_of(argv, "--console-log-level") + 1] == "info")
    check("没有 --no-tun", index_of(argv, "--no-tun") == nil)
    check_no_dangling_flag("默认配置", argv)
    -- 空值必须整对消失，不能留下光杆参数
    check("hostname 为空时不出现 --hostname", index_of(argv, "--hostname") == nil)
        check("不再输出 --external-node（它和 --peers 等价，插件只用 --peers）",
            index_of(argv, "--external-node") == nil)
    check("default_protocol 为空时不出现 --default-protocol", index_of(argv, "--default-protocol") == nil)
    check("extra_args 为空时不产生多余参数", #Config.split_args(cfg.extra_args) == 0)
end

--==== 参数生成：TUN + 手填 IP、对等节点、子网、监听 ====--
do
    local cfg = base_cfg({
        dhcp = false,
        ipv4 = "10.144.144.2",
        peers = { "tcp://public.easytier.top:11010", "udp://1.2.3.4:11010" },
        proxy_networks = { "192.168.1.0/24" },
        listeners = { "tcp://0.0.0.0:11010" },
        port_forwards = { "tcp://127.0.0.1:8080/10.126.126.1:80" },
        mtu = 1360,
        enable_kcp_proxy = true,
        extra_args = "--private-mode --compression zstd",
    })
    local argv = Config.build_argv(cfg)
    check("手填 IP 用 --ipv4", argv[index_of(argv, "--ipv4") + 1] == "10.144.144.2")
    check("不用 --dhcp", index_of(argv, "--dhcp") == nil)
    local peer_count = 0
    for _, a in ipairs(argv) do if a == "--peers" then peer_count = peer_count + 1 end end
    check("每个对等节点一个 --peers", peer_count == 2, peer_count)
    check("子网用 --proxy-networks", argv[index_of(argv, "--proxy-networks") + 1] == "192.168.1.0/24")
    check("监听用 --listeners", argv[index_of(argv, "--listeners") + 1] == "tcp://0.0.0.0:11010")
    check("端口转发参数", argv[index_of(argv, "--port-forward") + 1] == "tcp://127.0.0.1:8080/10.126.126.1:80")
    check("MTU 参数", argv[index_of(argv, "--mtu") + 1] == "1360")
    check("KCP 开关", contains(argv, "--enable-kcp-proxy"))
    check("额外参数被拆开", contains(argv, "--private-mode") and contains(argv, "--compression") and contains(argv, "zstd"))
    check_no_dangling_flag("完整配置", argv)
end

--==== 参数生成：代理模式 ====--
do
    local cfg = base_cfg({ mode = "proxy", socks5_port = 1081, ipv4 = "10.144.144.2" })
    local argv = Config.build_argv(cfg)
    check("代理模式 --no-tun", contains(argv, "--no-tun"))
    check("代理模式 --socks5 端口", argv[index_of(argv, "--socks5") + 1] == "1081")
    check("代理模式不建设备名", index_of(argv, "--dev-name") == nil)
    check("代理模式不发 IP", index_of(argv, "--ipv4") == nil and index_of(argv, "--dhcp") == nil)
    check_no_dangling_flag("代理模式", argv)
end

--==== 校验 ====--
do
    local ok, err = Config.validate(base_cfg({ mode = "tun", dhcp = false, ipv4 = "" }))
    check("tun 模式缺 IP 报错", ok == false and err ~= nil)

    ok = Config.validate(base_cfg({ mode = "tun", dhcp = false, ipv4 = "10.1.1.1" }))
    check("合法 IP 通过", ok == true)

    ok = Config.validate(base_cfg({ mode = "tun", dhcp = false, ipv4 = "10.1.1.999" }))
    check("非法 IP 被拦", ok == false)

    ok = Config.validate(base_cfg({ peers = { "hello world" } }))
    check("非法对等节点被拦", ok == false)

    ok = Config.validate(base_cfg({ peers = { "tcp://public.easytier.top:11010" } }))
    check("合法对等节点通过", ok == true)

    -- EasyTier 用 url::Url 解析，没协议前缀会在启动时才报错，这里必须拦住
    ok, err = Config.validate(base_cfg({ peers = { "1.2.3.4:11010" } }))
    check("缺协议前缀的初始节点被拦", ok == false, tostring(err))
    check("并且提示补协议前缀", ok == false and tostring(err):find("tcp://", 1, true) ~= nil, tostring(err))
    check("识别出缺协议前缀的形态", Config.missing_scheme("1.2.3.4:11010") == true)
    check("完整形式不算缺前缀", Config.missing_scheme("tcp://1.2.3.4:11010") == false)

    ok = Config.validate(base_cfg({ peers = { "udp://1.2.3.4:11010" } }))
    check("udp 前缀的初始节点通过", ok == true)

    ok = Config.validate(base_cfg({ proxy_networks = { "192.168.1.0/33" } }))
    check("非法子网被拦", ok == false)

    ok = Config.validate(base_cfg({ port_forwards = { "tcp://127.0.0.1:8080" } }))
    check("非法端口转发被拦", ok == false)

    ok = Config.validate(base_cfg({ dev_name = "a_very_long_interface_name" }))
    check("接口名过长被拦", ok == false)

    ok, err = Config.validate(base_cfg({ hostname = "kindle kpw6" }))
    check("主机名带空格被拦", ok == false, tostring(err))
    check("并提示用横线", ok == false and tostring(err):find("kindle-kpw6", 1, true) ~= nil, tostring(err))
    ok = Config.validate(base_cfg({ hostname = "kindle-kpw6" }))
    check("主机名用横线可以通过", ok == true)

    ok = Config.validate(base_cfg({ instance_name = "kindle kpw6" }))
    check("实例名带空格被拦", ok == false)

    ok, err, warn = Config.validate(base_cfg({ network_name = "" }))
    check("空网络名只是警告", ok == true and err == nil and type(warn) == "string", tostring(warn))

    ok = Config.validate(base_cfg({ rpc_portal = "15888" }))
    check("rpc 端口可以只写端口号", ok == true)

    ok = Config.validate(base_cfg({ rpc_portal = "abc:def" }))
    check("非法 rpc 端口被拦", ok == false)
end

--==== 旧设置迁移：external_node 并入 peers ====--
do
    local saved = _G.G_reader_settings
    _G.G_reader_settings = {
        readSetting = function() return { peers = { "tcp://a:11010" }, external_node = "tcp://shared:11010" } end,
    }
    local cfg = Config.load()
    _G.G_reader_settings = saved
    check("旧的 external_node 并入 peers", #cfg.peers == 2 and cfg.peers[2] == "tcp://shared:11010",
        Config.list_to_text(cfg.peers))
    check("迁移后 external_node 清空", cfg.external_node == "")
end

do
    local saved = _G.G_reader_settings
    _G.G_reader_settings = {
        readSetting = function() return { peers = { "tcp://shared:11010" }, external_node = "tcp://shared:11010" } end,
    }
    local cfg = Config.load()
    _G.G_reader_settings = saved
    check("迁移不会产生重复项", #cfg.peers == 1, Config.list_to_text(cfg.peers))
end

--==== 文本裁剪（界面控件保护）====--
do
    local clipped = Config.clip_text("短行\n" .. string.rep("x", 1000), 64 * 1024, 400)
    check("超长行被截断", #clipped < 1000 and clipped:find("…", 1, true) ~= nil, #clipped)

    local many = {}
    for i = 1, 5000 do many[i] = "line " .. i end
    local capped = Config.clip_text(table.concat(many, "\n"), 4096, 400)
    check("总体积受控", #capped < 6000, #capped)
    check("截断有提示", capped:find("truncated", 1, true) ~= nil, capped:sub(-60))

    local cn = Config.clip_text(string.rep("中", 1000), 64 * 1024, 100)
    check("中文按 UTF-8 边界截断", cn:find("中", 1, true) ~= nil and #cn <= 400, #cn)
end

--==== 文本与 shell 处理 ====--
do
    check("文本转列表", #Config.text_to_list("a, b\nc;d") == 4, #Config.text_to_list("a, b\nc;d"))
    check("空文本转空列表", #Config.text_to_list("") == 0)
    check("列表转文本", Config.list_to_text({ "a", "b" }) == "a, b")
    check("单引号转义", Config.shquote("a'b") == "'a'\\''b'", Config.shquote("a'b"))
    check("可执行文件路径转义", Config.shquote("/mnt/us/easytier/bin/easytier-core") == "'/mnt/us/easytier/bin/easytier-core'")

    local args = Config.split_args('--a "b c" --d=\'e f\'')
    check("split_args 数量", #args == 3, table.concat(args, "|"))
    check("split_args 双引号", args[2] == "b c", args[2])
    -- 和 shell 一致：--d='e f' 是一个词
    check("split_args 单引号", args[3] == "--d=e f", args[3])

    local summary = Config.summary(base_cfg({ network_name = "abc", ipv4 = "10.0.0.2", dhcp = false }))
    check("summary 非空", type(summary) == "string" and #summary > 10)
end

--==== ELF 识别（对真实二进制） ====--
do
    local path = arg and arg[1]
    if path then
        local info, err = Proc.elf_info(path)
        check("能读到 ELF 信息", info ~= nil, err)
        if info then
            print("ELF 识别结果: " .. info)
            check("识别为 ARM 架构", info:find("ARM", 1, true) ~= nil, info)
            check("识别为 32 位", info:find("32", 1, true) ~= nil, info)
            -- 界面语言不是中文时用英文源串（中文见 tests/test_i18n.lua）
            check("识别为静态链接", info:find("statically linked", 1, true) ~= nil, info)
        end
    else
        print("(未提供 easytier-core 路径，跳过 ELF 测试)")
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
