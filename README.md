# koreader-easytier

把 [EasyTier](https://github.com/EasyTier/EasyTier)（去中心化异地组网）搬到 Kindle 等阅读器上的 KOReader 插件。

设计上**不内嵌 EasyTier**：插件只负责拉起/停掉独立运行的 `easytier-core` 进程、生成命令行配置、显示节点与路由状态。TUN、权限、架构、功耗这些麻烦事留在 core 侧，插件本体是个「遥控器」——这也是同类插件（KOReader 的 SSH 插件、社区 WireGuard / Tailscale 插件）验证过的做法。

```
koreader-easytier/
├── easytier.koplugin/          # 插件本体（拷到设备上就这个目录）
│   ├── main.lua                # 菜单、事件、启停流程
│   ├── et_config.lua           # 配置模型：默认值 / 校验 / 参数生成
│   ├── et_proc.lua             # 找二进制、启停进程、easytier-cli、诊断
│   └── et_ui.lua               # 对话框与状态页封装
├── tests/                      # 单元测试（不需要 KOReader，可直接跑）
│   ├── run-all.sh
│   ├── test_config.lua         # 配置 / 参数生成 / 校验 / 文本裁剪
│   ├── test_proc.lua           # 进程与 shell 命令拼装
│   └── test_menu.lua           # 用桩件加载 main.lua，遍历菜单树
├── tools/prepare-device.sh     # 电脑上准备二进制 + 插件目录
├── LICENSE                     # AGPL-3.0
└── out/                        # 上面脚本的产物（不入库）
```

## 功能

* 菜单里一键**启动 / 停止**组网，带勾选状态
* **配置工具**：网络名称、网络密钥、节点 IP 或 DHCP、初始节点（服务器）、共享子网、监听地址、端口转发、RPC 端口、主机名、实例名、TUN 接口名、MTU、默认协议、日志级别、额外参数、程序目录
* **连接状态页**：本机配置摘要 + 进程 PID + `easytier-cli node info / peer / route` 的实时输出
* **日志页**：`easytier-core` 的输出，可清空
* **诊断页**：CPU 架构、系统 libc、`/proc/config.gz` 里的 `CONFIG_TUN`、`/dev/net/tun`、二进制架构与静态链接情况、防火墙规则、搜索过的目录
* **自动化**：随 KOReader 启动、连上 Wi-Fi 后启动、被系统或掉线打断后自动拉起（看门狗）
* **Kindle 适配**：启动时自动加一条 iptables 放行规则（Kindle 防火墙会拦进入虚拟网卡的包），停止时撤掉
* **手势/配置文件**：注册了 4 个 Dispatcher 动作（开关 / 启动 / 停止 / 状态），可在手势管理器或 Profiles 里绑定

## 安装

### 0. 前提

* Kindle 已越狱，装了 KOReader（KOReader 在 Kindle 上以 root 运行，这是建 TUN、改路由、动 iptables 的必要条件）
* 插件目录名**必须以 `.koplugin` 结尾**，当前 KOReader 只认这个后缀（老文档里的 `.koreader` 已失效）

### 1. 准备插件与 EasyTier 二进制

先取插件本体，二选一：

* 下载本仓库 Release 里的 **`easytier.koplugin.zip`**，解压得到 `easytier.koplugin/` 目录；或
* 直接把仓库里的 `easytier.koplugin/` 目录拷出来。

EasyTier 的二进制不随插件分发（体积 8MB+，且会随上游更新），用脚本一键准备（依赖 `unzip`、`curl`）：

```bash
tools/prepare-device.sh                                    # 自动下载 v2.6.4 的 armv7 静态包
tools/prepare-device.sh ~/Downloads/easytier-linux-armv7-v2.6.4.zip v2.6.4   # 或用手上已有的 zip
```

会产出两个目录：

```
out/easytier/                 -> 拷到 /mnt/us/easytier
out/koreader/plugins/         -> 拷到 /mnt/us/koreader/plugins
```

### 2. 拷进设备

数据线连接即可，最终设备上的结构：

```
/mnt/us/easytier/bin/easytier-core
/mnt/us/easytier/bin/easytier-cli
/mnt/us/koreader/plugins/easytier.koplugin/{main.lua,_meta.lua,et_config.lua,et_proc.lua,et_ui.lua}
```

插件也会识别 `/mnt/us/easytier/` 下的一级子目录（官方 zip 解压后原样拷进去也行），以及 `/usr/local/bin`、`/usr/bin`。

### 3. 用起来

重启 KOReader → 菜单 **网络 → EasyTier 异地组网**：

1. 先到 **配置** 里填「网络名称」和「网络密钥」（同一网络的所有节点必须一致），
2. 决定节点 IP：留着「DHCP 自动分配」最省事，或者关掉它自己填一个 `10.144.144.x`，
3. 「初始节点」填启动时要主动去连的地址，多个用逗号分隔。可以填**自己的节点**（家里/服务器上跑一份同网络名、同密钥的 core），也可以填**别人分享的公共共享节点**，例如 `tcp://public.easytier.top:11010`——官方 GUI 的说明就是「EasyTier 不分服务端/客户端，填初始节点 = 直接加入已有网络，初始节点可以用自己的，也可以用别人分享的」。
4. 回到菜单点 **启动 EasyTier**，然后到 **连接状态** 看 `peer` 表里有没有出现其他节点。

> 关于「对等节点」和「公共共享节点」：在 EasyTier 里这两个**不是两种东西**。`--external-node`(-e) 在 core 里走的是和 `--peers`(-p) 完全相同的代码（同样构造 `PeerConfig`、塞进同一个 peers 列表），唯一区别是它只能填一个值。真正决定行为的是**对端那台机器的角色**：同网络的普通节点 → 你直接通过它入网；别人网络的公共共享节点 → 它允许你的网络借它握手/中转，用来发现你网络里的其他节点，P2P 失败时流量也经它中转（它自己不建 TUN、也不会共享它的内网）。所以插件只保留一个「初始节点」字段（输出 `--peers`），旧设置里填过的 `-e` 值会自动并入其中。

## 两种运行模式

| 模式 | 参数 | 适用 | 代价 |
| --- | --- | --- | --- |
| **TUN（默认）** | `--dev-name` + `--dhcp`/`--ipv4` | 设备有 `/dev/net/tun`：整个系统按虚拟网 IP 走路由，KOReader 的 OPDS、Calibre、同步、SSH 全都能直接用 | 需要 TUN 驱动；接口 DOWN 前流量会被黑洞 |
| **代理（无 TUN）** | `--no-tun --socks5 <端口>` | 内核没有 TUN 的机型；只让个别程序走虚拟网络 | 只有把 SOCKS5 指向 `127.0.0.1:<端口>` 的程序能用 |

插件启动时会检查 `/dev/net/tun`，缺失就先尝试 `mknod /dev/net/tun c 10 200`，仍然没有就提示切到代理模式。

另外「端口转发」（`--port-forward tcp://127.0.0.1:8080/10.126.126.1:80`）**两种模式都能用**，而且不需要任何代理支持——让 KOReader 直接访问 `http://127.0.0.1:8080` 就能打到虚拟网络里的服务，这在 Kindle 上是最省事的接法（KOReader 自己的代理设置只支持 `http://` 形式的 HTTP 代理，不支持 SOCKS5）。

## Kindle / Paperwhite 6 相关的实测信息

* **架构**：PW6（Paperwhite 12 代）是 32 位 `armv7l`。EasyTier 官方 `easytier-linux-armv7-*.zip` 里的 `easytier-core` / `easytier-cli` 是**静态链接的 32 位 ARM（软浮点 ABI）**，没有 glibc 版本要求，不依赖 libgcc/libssl，直接扔到设备上就能跑。
* **UPX**：官方发布的这些二进制用 UPX 打包过（文件头就是 UPX 的壳）。正常运行没问题；万一设备上报奇怪的加载错误，可以在电脑上用 `upx -d easytier-core` 解开再拷。
* **TUN**：网上有 PW6（5.19.x 固件）的 TUN 可用报告（社区 Tailscale 和 OpenVPN 的帖子都提到 PW6 有 `/dev/net/tun`）。但**以设备实测为准**——用插件里的「运行诊断」看一眼 `CONFIG_TUN` 和 `/dev/net/tun` 最快。
* **防火墙**：Kindle 系统防火墙会拦进入虚拟网卡的包，症状是「能连上、peer 表是绿的，但访问不通」。插件启动时会执行
  `iptables -I INPUT 1 -i <接口名> -j ACCEPT`，停止时删除。重启设备后规则消失，下次启动插件会重新加。
* **功耗**：core 常驻会持续占用 Wi-Fi 和 CPU。阅读器上建议在「自动化」里只开需要的项，不用时手动停掉。

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 菜单里没有「EasyTier 异地组网」 | 确认插件目录名以 `.koplugin` 结尾、`main.lua` 在目录根下、KOReader 已重启。也可以看 `crash.log` |
| 提示「找不到 easytier-core」 | 菜单 → 工具 → **安装说明**，里面列了插件搜索过的全部目录；或到「进阶 → 程序目录」手填 |
| 提示「已启动」但菜单项没有打钩 | 勾选框只看**进程此刻是否真的活着**。旧版本只要启动命令发出就报成功，所以进程起来后立刻退出时会误导人。现在的行为是：启动后连续确认约 8 秒（进程仍在 + RPC 应答），进程若已退出会直接报错并把日志末尾贴在提示框里，同时菜单文字会显示 `停止 EasyTier（PID 1234）` |
| 点「连接状态 / 运行诊断」后白屏并退出 KOReader | 这类长文本页旧版是「先算内容、再交给 `TextViewer`」，任何一步抛错都会变成未捕获错误把 KOReader 带崩（白屏就是 KOReader 的错误页）。现在整页走 `pcall`：内容生成失败、控件创建失败、显示失败都会**降级成一个提示框**把错误原文显示出来，并写进 `crash.log`；文本先裁剪体积（超长行截断、总量上限 64KB），且只用 `TextViewer` 的标准最小用法 |
| 日志里刷出 `sleep: invalid number '0.2'` | 旧版用 `os.execute("sleep 0.2")` 做等待，而 **Kindle 的 busybox `sleep` 只认整数**，等于一次都没等。现在等待统一走 KOReader 自带的 `ffiutil.sleep`（进程内 nanosleep，不经 shell），shell 兜底只用整秒 |
| 界面卡死在状态页 | 旧版同步调用 `easytier-cli`，它连不上 RPC 时可能一直等，会把界面线程冻住。现在所有 `easytier-cli` 调用都套了 6 秒 `timeout`（自动适配 busybox `timeout -t` 与 coreutils 语法），超时后显示「(读取失败)」而不是卡住 |
| 想知道插件到底报了什么错 | 菜单 → 工具 → **查看 KOReader 崩溃日志**（读数据目录下 `crash.log` 的末尾 120 行）；USB 连电脑直接打开 `koreader\crash.log` 也一样 |
| 启动失败 | 菜单 → 工具 → **查看日志**，末尾几行一般是原因（密钥错、对等节点写错、端口占用）；「运行诊断」能一次性把环境信息摊开 |
| 起来了但访问不通 | ① 看「连接状态」里 `peer` / `route` 是否有对端；② 检查防火墙放行项；③ 子网访问还需要对端开了 `--proxy-networks` 并同步到路由表 |
| `/dev/net/tun` 不存在 | 先试「改用代理模式」，或用「端口转发」把需要的服务映射出来 |
| 进程杀不掉 | 工具 → **清理残留 easytier-core 进程**（会 SIGKILL 设备上所有 easytier-core） |
| 设置乱了 | 工具 → **恢复默认设置** |

日志与 PID：日志在 `<KOReader 数据目录>/easytier/easytier.log`（Kindle 上是 `/mnt/us/koreader/easytier/easytier.log`），PID 文件在 `/tmp/easytier_koreader.pid`。

## 自动化行为（谁在什么时候启动它）

* **「随 KOReader 启动时自动组网」是唯一决定「KOReader 一启动就跑起来」的开关**。关着就是关着：即使上次在运行、即使看门狗开着，本次启动也不会把 core 拉起来。
* 「掉线/被系统中断后自动拉起」（看门狗）只管**本次会话内**：KOReader 恢复前台、或 Wi-Fi 重连时，发现进程不在了才补一次。
* 手动点「停止」→ 记录为「不想要它运行」，本会话内看门狗也不会再拉。
* **core 是独立进程，KOReader 退出不会杀掉它**：`stopPlugin` 只在插件管理界面里「禁用插件」时才被 KOReader 调用（KOReader 退出时不会调）。所以退出 KOReader 后它还活着是正常的——菜单第一行会显示 `停止 EasyTier（PID xxx）`。想让它别跑，就点它停止。
* 插件被禁用或删除时，`stopPlugin` 会停掉 core 并撤掉防火墙规则。

### 两个容易混的名字

| 字段 | 参数 | 作用 |
| --- | --- | --- |
| **主机名** | `--hostname` | **对端节点列表里显示的就是这个名字**（也用作魔法 DNS 的 `<主机名>.et.net`）。留空则用系统主机名，Kindle 上通常是 `kindle` |
| 实例名 | `--instance-name` | 只在**同一台机器上**区分多个 core 实例用，对端看不到 |

所以改了「实例名」而 Windows 端的 peer 列表还是 `kindle`——那是主机名在起作用，改「主机名」即可（别用空格，写成 `kindle-kpw6`；插件会拦带空格的输入）。

## 开发与验证

```bash
tests/run-all.sh [easytier-core 的路径]      # 三个测试文件：55 + 35 + 239 项断言
```

* `tests/test_config.lua`（55 项）：默认值、参数生成、校验、引号转义、列表解析、ELF 识别。
  其中一项结构自检会遍历生成的参数，确认**每个需要值的开关后面确实跟着值**——
  这个检查真的抓到过一个 bug：值为空时 `--hostname` 会变成光杆参数，把后面的 `--rpc-portal`
  当成自己的值吞掉，导致 core 启动参数错位。
* `tests/test_proc.lua`（35 项）：把 shell 执行拦下来，检查启动命令拼得对不对
  （相对路径执行、日志重定向、PID 文件、iptables 规则形状、配置值里的单引号是否被正确转义）。
* `tests/test_menu.lua`（239 项）：用桩件顶掉 KOReader 运行时，真正加载 `main.lua`，
  走完 init、遍历整棵菜单树把每个 `text_func` / `checked_func` / `enabled_func` 执行一遍，
  并检查事件处理（Wi-Fi 重连、看门狗）是否正确安排任务。

已经验证到的程度：

* **启动判定**：`Proc.verify_started` 在启动命令发出后连续确认约 8 秒——进程必须一直活着，
  并且（装了 `easytier-cli` 时）RPC 必须应答，才认为成功；进程中途消失会报失败并附上日志尾部。
  缺 `easytier-cli` 时会明确说「读不到状态」，而不是误报 RPC 失败。
* **PID 归属**：启动命令用 `{ ... & echo $! > pidfile; }` 把后台任务与写 PID 放在同一个 shell 里，
  否则 `$!` 拿到的是外层子 shell 的 PID（会连带出现「提示成功但进程已退出」和「杀不干净」两个毛病）。
* 生成的全部命令行**长参数**逐个对照 EasyTier **v2.6.4 标签**的 `easytier/locales/app.yml` 与
  `easytier-cli.rs` 核对（不看主分支，避免版本漂移）；因此插件只发长参数，不发单字母短选项。
* ELF 识别拿官方 `easytier-linux-armv7-v2.6.4.zip` 里的真实 `easytier-core` 跑过，
  输出「32 位 / ARM / 软浮点 ABI / 静态链接」。
* `tools/prepare-device.sh` 在本机跑通，产物结构与文档一致。

还没验证的部分（需要真机）：插件在 KOReader 里加载后的实际界面交互、`easytier-core` 在 PW6 上真的建成 TUN、
与对端打洞成功。真机跑过之后麻烦把「运行诊断」页的输出贴回来，有问题据此修。

## 许可与致谢

* 本插件以 **AGPL-3.0** 发布（与它运行所在的 KOReader 生态保持一致），见 `LICENSE`。
* EasyTier 本身是独立的 LGPL-3.0 项目，由 KKRainbow 等人开发；本插件不包含也不修改其代码，只是调用你自行准备的 `easytier-core` / `easytier-cli` 可执行文件。
* 插件接口与若干写法参考了 KOReader 自带的 SSH / KeepAlive 插件，以及社区的 `wtb04/wireguard.koplugin`。
