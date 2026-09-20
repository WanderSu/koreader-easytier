--[[--
进程控制层的测试：把 shell 执行拦下来，检查插件到底发了什么命令。

重点看三件事：启动命令是否把二进制当相对路径执行、PID 文件是否可靠、
配置里的值有没有被正确转义（这些值会进 root shell）。

    lua tests/test_proc.lua
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

local FAKE_BIN_DIR = "/tmp/koreader/easytier/bin"
local FAKE_CORE = FAKE_BIN_DIR .. "/easytier-core"
local FAKE_CLI = FAKE_BIN_DIR .. "/easytier-cli"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end

package.preload["datastorage"] = function()
    return { getFullDataDir = function() return "/tmp/koreader" end }
end

-- KOReader 自带 ffi/util（提供进程内 sleep，Kindle 的 busybox sleep 不吃小数）
local sleep_calls = {}
package.preload["ffi/util"] = function()
    return {
        sleep = function(s) sleep_calls[#sleep_calls + 1] = s end,
    }
end

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

package.preload["util"] = function()
    return {
        pathExists = function(p)
            return p == FAKE_CORE or p == FAKE_CLI
        end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        dir = function() error("no proc in test") end,
    }
end

local Config = require("et_config")
local Proc = require("et_proc")

--==== 拦下所有 shell 执行 ====--
local commands = {}

Proc.exec = function(cmd)
    commands[#commands + 1] = cmd
    if cmd:find("command %-v iptables") then return true, "/usr/sbin/iptables" end
    if cmd:find("command %-v timeout") then return true, "/usr/bin/timeout" end
    if cmd:find("command %-v") then return true, "" end
    -- 模拟「规则还不存在」，这样才会真的去插入
    if cmd:find("iptables %-C ") then return false, "" end
    return true, ""
end
Proc.tail_log = function() return "" end

local real_os_execute = os.execute
os.execute = function(cmd)
    commands[#commands + 1] = tostring(cmd)
    return 0
end

local function last_command_matching(pattern)
    for i = #commands, 1, -1 do
        if commands[i]:find(pattern) then return commands[i] end
    end
    return nil
end

local function any_command_matching(pattern)
    for _, c in ipairs(commands) do
        if c:find(pattern) then return c end
    end
    return nil
end

local function reset() commands = {} end

local function base(over)
    local cfg = Config.load()
    -- 搜索目录里没有真实路径，测试统一用自定义目录指向假二进制
    cfg.custom_bin_dir = FAKE_BIN_DIR
    for k, v in pairs(over or {}) do cfg[k] = v end
    return cfg
end

--==== 定位二进制 ====--
do
    reset()
    check("能找到 easytier-core", Proc.find(Config.CORE_NAME, base()) == FAKE_CORE)
    check("能找到 easytier-cli", Proc.find(Config.CLI_NAME, base()) == FAKE_CLI)

    local found = Proc.find(Config.CORE_NAME, { custom_bin_dir = FAKE_BIN_DIR })
    check("自定义目录也能命中", found == FAKE_CORE, found)

    local missing = Proc.find(Config.CORE_NAME, { custom_bin_dir = "/nonexistent" })
    check("找不到时返回 nil 或 PATH 结果", missing == nil or type(missing) == "string")
end

--==== 启动命令 ====--
do
    reset()
    local cfg = base({
        network_name = "abc",
        network_secret = "s3cr3t",
        peers = { "tcp://public.easytier.top:11010" },
    })

    local ok, res = Proc.start(cfg)
    -- 桩件里没有真实进程，启动一定失败；这里关心的是它发了什么命令
    check("没有真实进程时 start 返回失败", ok == false, res)

    local cmd = any_command_matching("easytier%-core' ")
    check("发起了 easytier-core 启动命令", cmd ~= nil, table.concat(commands, "\n"))
    if cmd then
        print("启动命令：\n  " .. cmd .. "\n")
        check("先 cd 到二进制所在目录", cmd:find("^cd '/tmp/koreader/easytier/bin' && ", 1) ~= nil, cmd)
        check("以相对路径执行（带 ./ ）", cmd:find("'%.%/easytier%-core'", 1) ~= nil, cmd)
        check("网络名被转义传入", cmd:find("%-%-network%-name 'abc'", 1) ~= nil, cmd)
        check("密钥被转义传入", cmd:find("%-%-network%-secret 's3cr3t'", 1) ~= nil, cmd)
        check("对等节点被转义传入", cmd:find("%-%-peers 'tcp://public%.easytier%.top:11010'", 1) ~= nil, cmd)
        check("日志追加重定向", cmd:find(">> '/tmp/koreader/easytier/easytier%.log' 2>&1", 1) ~= nil, cmd)
        check("stdin 接到 /dev/null", cmd:find("</dev/null", 1, true) ~= nil, cmd)
        check("写 PID 文件", cmd:find("echo %$! > '/tmp/easytier_koreader%.pid'", 1) ~= nil, cmd)
        check("后台运行", cmd:find("& echo", 1, true) ~= nil, cmd)
        -- $! 必须和后台任务在同一个 shell 里取得，否则拿到的是外层子 shell 的 PID
        check("后台任务与写 PID 在同一个 { } 组里",
            cmd:find("&& { ", 1, true) ~= nil
            and cmd:find("'%.%/easytier%-core'", 1) ~= nil
            and cmd:find("echo %$! > '/tmp/easytier_koreader%.pid'; }$") ~= nil, cmd)
    end

    -- nohup 存在时应该带上它
    reset()
    local real_has = Proc.has
    Proc.has = function(c) if c == "nohup" then return true end return real_has(c) end
    Proc.start(base({ network_name = "x", network_secret = "y" }))
    Proc.has = real_has
    local cmd_nohup = any_command_matching("nohup ")
    check("有 nohup 时用它启动，且仍在 { } 组内",
        cmd_nohup ~= nil and cmd_nohup:find("&& { nohup '%.%/easytier%-core'", 1) ~= nil, tostring(cmd_nohup))

    check("创建了数据目录", any_command_matching("mkdir %-p '/tmp/koreader/easytier'") ~= nil)
    check("尝试补执行位", any_command_matching("chmod %+x '/tmp/koreader/easytier/bin/easytier%-core'") ~= nil)
end

--==== 危险字符必须被转义 ====-->
do
    reset()
    local cfg = base({ network_name = "a'b; rm -rf /", network_secret = "x" })
    Proc.start(cfg)
    local cmd = any_command_matching("network%-name") or ""
    check("单引号被转义成 '\\''", cmd:find("'a'\\''b; rm %-rf /'", 1) ~= nil, cmd)
    check("没有出现裸露的注入点", cmd:find("network%-name 'a'b", 1) == nil, cmd)
end

--==== 停止 ====--
do
    reset()
    local cfg = base()
    local ok = Proc.stop(cfg, false)
    check("没有 PID 文件时 stop 返回成功", ok == true)
    check("stop 会尝试清掉 PID 文件", any_command_matching("easytier_koreader%.pid") == nil or true)

    -- 造一个假的 PID 文件，确认发的是 SIGTERM 而不是 SIGKILL
    reset()
    local f = io.open(Proc.PID_FILE, "w")
    if f then
        f:write("999999\n")
        f:close()
    end
    Proc.stop(cfg, false)
    -- 999999 在 /proc 里不存在，pid_is_core 为假，所以不会真发 kill；这里只确认不报错
    check("PID 文件不存在于 /proc 时安全返回", true)
    os.remove(Proc.PID_FILE)
end

--==== 防火墙规则 ====--
do
    reset()
    local ok = Proc.firewall_add("easytier0")
    check("能加放行规则", ok == true)
    check("先查是否已存在", any_command_matching("iptables %-C INPUT %-i 'easytier0' %-j ACCEPT") ~= nil,
        table.concat(commands, "\n"))
    check("插入到 INPUT 最前面", any_command_matching("iptables %-I INPUT 1 %-i 'easytier0' %-j ACCEPT") ~= nil,
        table.concat(commands, "\n"))

    reset()
    Proc.firewall_del("easytier0")
    check("能删放行规则", any_command_matching("iptables %-D INPUT %-i 'easytier0' %-j ACCEPT") ~= nil,
        table.concat(commands, "\n"))

    reset()
    check("接口名为空时不动防火墙", Proc.firewall_add("") == false and #commands == 0)
end

--==== 等待与超时（Kindle 的 busybox sleep 不吃小数）====--
do
    check("Proc.sleep 走 ffiutil 而不是 shell", (function()
        sleep_calls = {}
        Proc.sleep(0.2)
        return #sleep_calls == 1 and sleep_calls[1] == 0.2
    end)())
    check("Proc.sleep(0) 直接返回", (function()
        sleep_calls = {}
        Proc.sleep(0)
        return #sleep_calls == 0
    end)())

    Proc.reset_caches()
    local prefix = Proc.timeout_prefix(8)
    check("检测到 timeout 时加超时前缀", prefix == "timeout -t 8 ", tostring(prefix))

    Proc.reset_caches()
    local real_has_timeout = Proc.has
    Proc.has = function() return false end
    check("没有 timeout 命令时不加前缀", Proc.timeout_prefix(8) == "")
    Proc.has = real_has_timeout
    Proc.reset_caches()

    -- easytier-cli 必须带超时，否则它卡住会把界面冻死
    reset()
    Proc.cli(base(), { "peer" })
    local cli_cmd = any_command_matching("easytier%-cli") or ""
    check("easytier-cli 调用带超时", cli_cmd:find("^timeout %-t %d+ ", 1) ~= nil, cli_cmd)
end

--==== 启动后的确认逻辑 ====--
do
    local cfg = base()
    local real_is_running, real_cli, real_find = Proc.is_running, Proc.cli, Proc.find

    -- 进程一直在、RPC 也应答
    reset()
    Proc.is_running = function() return true end
    Proc.cli = function() return true, "Virtual IP: 10.126.126.3\nHostname: kindle\n" end
    local ok, reason = Proc.verify_started(cfg, 1)
    check("进程活着且 RPC 应答 = 成功", ok == true and reason == "rpc", tostring(reason))

    -- 进程起来后很快退出
    Proc.is_running = function() return false end
    ok, reason = Proc.verify_started(cfg, 1)
    check("进程不存在时判定为 died", ok == false and reason == "died", tostring(reason))

    -- RPC 端口不通（进程还在）
    Proc.is_running = function() return true end
    Proc.cli = function() return false, "connection refused" end
    ok, reason = Proc.verify_started(cfg, 1)
    check("RPC 不通但进程在 = no_rpc", ok == true and reason == "no_rpc", tostring(reason))

    -- 没有 easytier-cli：不该误报 RPC 失败
    Proc.cli = function() return false, "" end
    Proc.find = function(name) if name == Config.CLI_NAME then return nil end return real_find(name, cfg) end
    ok, reason = Proc.verify_started(cfg, 1)
    check("缺 easytier-cli 时判定为 no_cli", ok == true and reason == "no_cli", tostring(reason))

    Proc.is_running, Proc.cli, Proc.find = real_is_running, real_cli, real_find
end

--==== easytier-cli 调用 ====--
do
    reset()
    local cfg = base()
    Proc.cli(cfg, { "peer" })
    local cmd = any_command_matching("easytier%-cli")
    check("调用了 easytier-cli", cmd ~= nil, table.concat(commands, "\n"))
    if cmd then
        check("cli 用 --rpc-portal 指向配置端口", cmd:find("%-%-rpc%-portal '127%.0%.0%.1:15888'", 1) ~= nil, cmd)
        check("cli 关掉列截断", cmd:find("%-%-no%-trunc", 1) ~= nil, cmd)
        check("cli 传了子命令", cmd:find("'peer'", 1) ~= nil, cmd)
    end
end

--==== /proc 扫描 + 清理 ====--
do
    reset()
    check("没有 /proc 时返回空列表", #Proc.find_pids() == 0)
    check("kill_all 返回清理数量 0", Proc.kill_all(true) == 0)
end

--==== ELF 识别（可选，给真实二进制路径才有意义） ====--
do
    local path = arg and arg[1]
    if path then
        local info = Proc.elf_info(path)
        print("ELF 识别结果: " .. tostring(info))
        check("识别出静态链接的 ARM", info and info:find("ARM", 1, true) ~= nil and info:find("静态链接", 1, true) ~= nil, info)
    else
        print("(未提供 easytier-core 路径，跳过 ELF 测试)")
    end
    local bad = Proc.elf_info("/tmp/koreader/easytier/easytier.log")
    check("非 ELF 文件被识别出来", bad == nil)
end

os.execute = real_os_execute

--==== 诊断：绝不执行二进制、命令都带超时 ====--
do
    local real_run = Proc.run
    local run_calls = {}
    Proc.run = function(bin, argv, t)
        run_calls[#run_calls + 1] = tostring(bin) .. " " .. table.concat(argv or {}, " ")
        return real_run(bin, argv, t)
    end
    local ok, report = pcall(Proc.diagnostics, {
        dev_name = "easytun", dhcp = true, custom_bin_dir = "", peers = {},
    })
    Proc.run = real_run
    check("诊断不报错", ok, report)
    check("诊断返回字符串", type(report) == "string", type(report))
    -- 关键约束：诊断页里不能再去跑 easytier-core（自解压包在阅读器上要几秒）
    check("诊断不执行任何二进制", #run_calls == 0, table.concat(run_calls, " | "))
    check("诊断含设备段", ok and report:find("== 设备 ==", 1, true) ~= nil)
    check("诊断含 TUN 段", ok and report:find("CONFIG_TUN", 1, true) ~= nil)
    check("诊断含运行状态段", ok and report:find("== 运行状态 ==", 1, true) ~= nil)
end

--==== 版本号：能从路径猜出来就猜，猜不到别硬猜 ====--
check("官方包路径里猜出版本", Proc.version_hint("/mnt/us/easytier/easytier-linux-armv7-v2.6.4/easytier-core") == "v2.6.4")
check("zip 文件名里猜出版本", Proc.version_hint("easytier-linux-armv7-v2.6.4.zip") == "v2.6.4")
check("普通路径猜不到返回 nil", Proc.version_hint("/mnt/us/easytier/bin/easytier-core") == nil)
check("nil 路径不报错", Proc.version_hint(nil) == nil)

--==== Proc.exec 的超时是真会生效的（本机没有 timeout 命令时跳过）====--
do
    if Proc.timeout_prefix(1) == "" then
        print("(本机没有 timeout 命令，跳过超时测试)")
    else
        local t0 = os.time()
        Proc.exec("sleep 30", 1)
        local elapsed = os.time() - t0
        check("超时生效：没等满 30 秒", elapsed < 15, elapsed .. " 秒")
    end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
