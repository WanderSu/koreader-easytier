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

--==== 结构自检：不许把值丢进名为 _ 的变量（会遮蔽 gettext 的 _）====--
-- 真事：Proc.kernel_tun 里 `local _, out = Proc.exec(...)` 把 gettext 的 _ 遮蔽成布尔值，
-- 于是同函数里的 _("...") 变成「调用布尔值」而抛错，把诊断页连同 KOReader 一起拖退出。
do
    local names = { "et_config.lua", "et_proc.lua", "et_ui.lua", "main.lua" }
    local bad, read = {}, 0
    for _i, fname in ipairs(names) do
        local f = io.open("easytier.koplugin/" .. fname, "r")
        if f then
            read = read + 1
            local n = 0
            for line in f:lines() do
                n = n + 1
                if not line:match('^%s*local%s+_%s*=%s*require%("gettext"%)') then
                    if line:match("^%s*local%s+_,") or line:match("^%s*for%s+_,") or line:match(",%s*_%s*=") then
                        bad[#bad + 1] = fname .. ":" .. n
                    end
                end
            end
            f:close()
        end
    end
    check("读到了全部插件源文件", read == #names, read)
    check("没有遮蔽 gettext 的 _ 的写法", #bad == 0, table.concat(bad, ", "))
end

--==== kernel_tun：以前必抛错（_ 被遮蔽），现在必须好好返回 ====--
do
    local ok, res = pcall(Proc.kernel_tun, 3)
    check("kernel_tun 不抛错", ok, res)
    check("kernel_tun 返回字符串", ok and type(res) == "string" and #res > 0, tostring(res))
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

--==== 归一化：类型被写坏 / 缺字段 / 老配置都不能让插件崩 ====--
do
    -- 一个被写坏的设置：字符串字段里是数字、布尔是字符串、列表是字符串，还夹着不认识的字段
    local broken = {
        network_name = 12345,
        hostname = 678,              -- 以前会让 validate 里的 hostname:find 直接抛错
        instance_name = { "x" },     -- 表
        mode = "proxy",
        dhcp = "yes",
        socks5_port = "1080",
        mtu = "1400",
        peers = "tcp://a:11010, udp://b:11010",
        listeners = { "tcp://0.0.0.0:11010", 11010, "" },
        watchdog = "false",
        log_level = nil,
        unknown_field = "x",
    }
    local cfg = Config.normalize(broken)
    check("字符串字段被收紧成字符串", cfg.network_name == "12345", tostring(cfg.network_name))
    check("数字形式的 hostname 也变成字符串",
        type(cfg.hostname) == "string" and cfg.hostname == "678", tostring(cfg.hostname))
    check("表形式的字符串字段退回默认值", type(cfg.instance_name) == "string", type(cfg.instance_name))
    check("yes 这样的字符串被认成真", cfg.dhcp == true, tostring(cfg.dhcp))
    check("false 字符串被认成假", cfg.watchdog == false, tostring(cfg.watchdog))
    check("数字字符串变成数字", cfg.socks5_port == 1080 and cfg.mtu == 1400,
        tostring(cfg.socks5_port) .. "/" .. tostring(cfg.mtu))
    check("列表字段的字符串被切开", #cfg.peers == 2 and cfg.peers[1] == "tcp://a:11010",
        table.concat(cfg.peers, " "))
    check("列表里的空串和非字符串被丢掉", #cfg.listeners == 2 and cfg.listeners[2] == "11010",
        table.concat(cfg.listeners, " "))
    check("缺字段用默认值", cfg.log_level == Config.DEFAULTS.log_level, tostring(cfg.log_level))
    check("不认识的字段被丢掉", cfg.unknown_field == nil)
    check("归一化后的配置能被校验（不抛错）", pcall(Config.validate, cfg))
    check("归一化不改默认值表本身", Config.DEFAULTS.peers ~= cfg.peers)
    check("归一化保留 external_node（迁移要用它，再由 load 并进 peers）",
        Config.normalize({ external_node = "tcp://a:11010" }).external_node == "tcp://a:11010")
end

--==== 归一化 + 迁移一起走：旧设置里的 external_node 必须并进 peers ====--
do
    local old = { external_node = "tcp://old:11010", peers = "tcp://new:11010", hostname = 42 }
    local cfg = Config.normalize(old)
    check("归一化保留 external_node 供迁移使用", cfg.external_node == "tcp://old:11010", cfg.external_node)
    check("归一化把 peers 字符串切开", #cfg.peers == 1 and cfg.peers[1] == "tcp://new:11010")
    cfg.external_node = ""
    local argv = Config.build_argv(cfg)
    local has_e = false
    for _i, a in ipairs(argv) do
        if a == "-e" or a == "--external-node" then has_e = true end
    end
    check("插件不再输出 -e/--external-node", has_e == false, table.concat(argv, " "))
    check("旧值已经变成 --peers", contains(argv, "--peers") and contains(argv, "tcp://new:11010"))
end

--==== 光杆参数：needs_value 必须真的认得这些开关（曾因数组/集合写法永久空转）====--
do
    for _i, f in ipairs({ "--network-name", "--peers", "--rpc-portal", "--console-log-level" }) do
        check("needs_value 认得 " .. f, Config.needs_value(f) == true)
    end
    check("纯开关不需要值",
        Config.needs_value("--dhcp") == false and Config.needs_value("--no-tun") == false
            and Config.needs_value("--no-listener") == false)

    -- 空字段不许留下光杆开关（否则会把后面的参数名吞掉）
    local cfg = base_cfg({
        network_name = "", network_secret = "", hostname = "", mode = "tun", dhcp = true,
        default_protocol = "", log_level = "",
    })
    check_no_dangling_flag("空字符串字段不产生光杆参数", Config.build_argv(cfg))

    local cfg2 = base_cfg({ mode = "proxy", socks5_port = 1080, peers = { "tcp://a:11010" }, log_level = "warn" })
    check_no_dangling_flag("代理模式不产生光杆参数", Config.build_argv(cfg2))

    local cfg3 = base_cfg({ mode = "tun", dhcp = false, ipv4 = "10.144.144.2", log_level = "info" })
    check_no_dangling_flag("手填 IP 模式不产生光杆参数", Config.build_argv(cfg3))
end

--==== 校验提示必须回答「哪里不对 + 怎么改」 ====--
do
    local _, err1 = Config.validate(base_cfg({ mode = "tun", dhcp = false, ipv4 = "" }))
    check("缺 IP：给出两种改法", err1 and err1:find("DHCP", 1, true) ~= nil
        and err1:find("10.144", 1, true) ~= nil, err1)

    local _, err2 = Config.validate(base_cfg({ mode = "tun", dhcp = false, ipv4 = "abc" }))
    check("IP 格式错：带正确示例", err2 and err2:find("10.144.144.2", 1, true) ~= nil, err2)

    local _, err3 = Config.validate(base_cfg({ mode = "proxy", socks5_port = "abc" }))
    check("端口不是数字：带当前值和示例",
        err3 and err3:find("1080", 1, true) ~= nil and err3:find("abc", 1, true) ~= nil, err3)

    local _, err4 = Config.validate(base_cfg({ dev_name = string.rep("x", 20) }))
    check("接口名过长：说出当前长度", err4 and err4:find("20", 1, true) ~= nil, err4)

    local _, err5 = Config.validate(base_cfg({ mtu = 100 }))
    check("MTU 太小：给出建议值", err5 and err5:find("1280", 1, true) ~= nil, err5)

    local _, err6 = Config.validate(base_cfg({ peers = { "192.168.1.10:11010" } }))
    check("缺协议前缀：直接告诉你补 tcp://", err6 and err6:find("tcp://", 1, true) ~= nil, err6)

    local ok7, err7, warn7 = Config.validate(base_cfg({ network_name = "" }))
    check("空网络名只是警告，不是错误", ok7 == true and err7 == nil and warn7 ~= nil, tostring(warn7))
end

--==== 文本裁剪（界面控件保护）====--
do
    local clipped = Config.clip_text("短行\n" .. string.rep("x", 1000), 64 * 1024, 400)
    check("超长行被截断", #clipped < 1000 and clipped:find("…", 1, true) ~= nil, #clipped)

    local many = {}
    for i = 1, 5000 do many[i] = "line " .. i end
    local capped = Config.clip_text(table.concat(many, "\n"), 4096, 400)
    check("总体积受控", #capped < 6000, #capped)
    check("截断有提示", capped:find("已截断", 1, true) ~= nil)

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
            check("识别为静态链接", info:find("静态链接", 1, true) ~= nil, info)
        end
    else
        print("(未提供 easytier-core 路径，跳过 ELF 测试)")
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
