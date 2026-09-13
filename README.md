# SudoBox

**按需提权，即用即还** · Your Linux workspace, on demand.

面向（临时）root 设备的移动 GNU/Linux 工作台：**Termux 级终端体验 + Linux Deploy 级容器编排**，
引擎为 `unshare -m + chroot`（内核级），按需 `su`、不写 `/system`、卸载零残留。

- 设计基线：`SudoBox-开发思路.md` v2.3.2（终稿）、`SudoBox-设计方案.md` v1.1、`SudoBox-发行版支持设计.md` v1
- 许可：GPL-3.0（复用 termux / linuxdeploy 同许可代码，保留版权头）
- 当前阶段：**P0 双线基座**（R0 引擎闭环 + S0 App 骨架）
- 编译状态：App **已通过 Gradle 编译**并产出 APK（Android 12+ / minSdk 31）——见 §3.2

---

## 1. 仓库结构

```
SudoBox/
├── module/                     # KSU 模块源（打包为可刷 ZIP）
│   ├── module.prop             # id=chroot-mgr（磁盘 id，勿改）, name=SudoBox Service（对外名）
│   ├── customize.sh            # 安装：架构探测 + 创建数据目录（幂等，升级不动数据）
│   ├── service.sh              # late_start：仅在显式开启"开机恢复"时恢复容器（后台化不阻塞开机）
│   ├── action.sh               # KSU 管理器按钮：status/enable/enter/disable/diagnose
│   ├── uninstall.sh            # 卸载即全清：停容器 → umount → 删 /data/adb/chroot-mgr/
│   ├── sepolicy.rule           # 宽松（P0-P1），P2 按 avc 日志收窄
│   ├── bin/
│   │   ├── chroot-mgr          # 主控，11 子命令 + selftest
│   │   ├── chroot-enter.sh     # unshare -m 私有 ns 内的挂载 + exec chroot
│   │   └── net.sh              # DNS 兜底工具
│   ├── include/core/           # 组件系统（移植 linuxdeploy：deploy.conf + do_* 六函数）
│   │   ├── mnt/  net/  profile/
│   ├── include/hooks/          # post_unpack 适配钩子（seccomp-off-apt / dns / hosts / pacman-key / apk-repos）
│   └── distro/                 # 发行版描述符（新增发行版 = 新增一个目录）
│       ├── ubuntu/  alpine/  kali/  debian/  _template/
├── app/                        # Compose App（控制面）
│   ├── terminal-emulator/      # vendor 自 termux-app（PTY/JNI + VT 模拟，零重写）
│   ├── terminal-view/          # vendor 自 termux-app（渲染 + 手势 + 选区）
│   └── app/                    # SudoBox 主模块：4 Tab（仪表盘/终端/容器/设置）
└── tools/
    ├── build.sh / build_module.py   # 打包 KSU 模块 ZIP（保留权限位 + CRLF→LF）
    ├── build-app.sh                 # 构建 Compose App（自动规避中文路径的 NDK 问题）
    ├── test-logic.sh                # 本地逻辑回归测试（无需设备）
    ├── smoke-test.sh                # 设备端 P0 冒烟测试
    ├── device-verify.sh             # 设备端一键验收（装 APK + 推模块 + 自检 + 崩溃捕获）
    └── verify-clean.sh              # 无系统改动验收清单
```

**运行时路径**（D8/D9/D10）

| 用途 | 路径 | 生命周期 |
|---|---|---|
| 模块代码 | `/data/adb/modules/chroot-mgr/` | 升级被整体替换 |
| 数据（rootfs/状态/配置） | `/data/adb/chroot-mgr/data/` | 升级不动，`uninstall.sh` 全清 |
| 状态文件 | `/data/adb/chroot-mgr/data/.state` | 模块写、App 轮询读（免 IPC 常驻） |

---

## 2. 命令协议（§8.3 定稿）

```sh
su -c chroot-mgr <command>

  install <distro> [suite] [--name ID] [--mirror M]   部署（渠道 A: 官方 tarball）
  install --import <file.tar[.gz|.xz|.bz2]> [--name ID]  导入自定义 rootfs（渠道 C）
  install --list                                      列出可用描述符
  enable  <profile>                                   挂载并启用（幂等）
  disable [profile|--all]                             停组件 → 杀进程 → 校验清零 → 逆序 umount
  enter   [profile] [-- cmd]                          进入容器（自动启用）
  switch  <profile>                                   单实例仲裁切换（D22）
  exec    <profile> <cmd...>                          容器内执行一次性命令
  svc     list|start|stop <name> [profile]            服务管理（A/B 分级）
  export  <file.tar.gz|tar.xz|tar.bz2> [profile]      归档 rootfs
  import  <file.tar...> [--name ID]                   恢复归档为新 profile
  status  [--json|--field F|--mounts]                 状态（机器可读）
  diagnose                                            内核能力矩阵 + 工具链探测
  selftest                                            纯逻辑自检（不触碰容器）
```

**状态模型**（§8.2）：`state ∈ {disabled, enabled, running, starting, stopping, error}`；
`active` 为处于 running/starting 的 profile，**全局至多一个**（D21 单实例）。

**进入仲裁**（D22，`switch` 为原子入口）

```
选 B 时：B 已运行 → attach
        无冲突   → start → enter
        A 在运行  → 组件 stop → SIGTERM → 宽限 3s → SIGKILL
                  → 进程与挂载清零校验 → 才启动 B
        校验不过  → 整体回滚：B 保持 stopped，A 状态如实标记 error（不静默）
```

进程归属识别：会话台账（PID 文件）+ 兜底 `/proc/*/root` 指向 rootfs 扫描。

---

## 3. 打包与安装

```bash
# 打包（可选 --busybox <path> 内置静态 busybox）
./tools/build.sh

# 产物
out/SudoBox-chroot-mgr-v0.1.0.zip
```

安装：KernelSU App → 模块 → 从存储安装 → 重启。

### 3.2 构建 App（Compose 控制面）

要求：**Android 12+（minSdk 31）**、targetSdk/compileSdk 35、JDK 17+、NDK 29、Gradle 8.11.1。
仓库已内置 `gradlew` 与 `gradle-wrapper.jar`，Android Studio 可直接打开 `app/`。

命令行构建（产物回拷到 `out/`）：

```bash
bash tools/build-app.sh           # debug
bash tools/build-app.sh release   # release（自签名，见下）
bash tools/build-app.sh lint      # Android Lint 静态分析（解析报告后打印问题清单）
```

产物：

| 文件 | 大小 | 签名 |
|---|---|---|
| `out/app-debug.apk` | ~59 MB | Android Debug |
| `out/app-release.apk` | ~2.4 MB | 自签名 `CN=SudoBox`（`app/keystore.properties`，已 gitignore） |

> release 已开 **R8 混淆**（`minifyEnabled true`，2026-09-03）：
> dex 40.3 MB → 1.86 MB（-95%），APK 42.8 → 2.4 MB（-94%）。大头是此前未裁剪的
> `material-icons-extended`。裁剪安全依据：App 全量扫描零反射；唯一 JNI 面
> `com.termux.terminal.JNI`（纯 Java→native 单向）由默认 native keep 规则连带
> 保留类名与 native 方法名（mapping 实测 `JNI -> JNI` 恒等映射）。
> 混淆后崩溃日志需用 `app/build/outputs/mapping/release/mapping.txt` 反混淆。
> debug 未开 minify（保持可调试）。**R8 行为仍未实机验证**，随 device-verify 一起确认。

**静态分析**：Lint 8.7.3 报告 `out/lint-results-debug.xml`，当前 **0 个问题**。

> 注意：Lint 默认只报告不阻断，`BUILD SUCCESSFUL` **不等于**无问题。
> 首轮跑出 27 个告警（多为 `UnusedResources`），深挖后发现根因是 UI 里硬编码了中文文案、
> `strings.xml` 已定义的资源根本没接上——即 i18n 体系整体断裂。这类问题编译期完全无感，
> 只有 Lint 能发现。修完后 27 → 0。

**注意（中文路径的坑）**：本仓库位于含中文的目录下，AGP 侧靠 `android.overridePathCheck=true`
放行，但 **NDK 侧不行**——`ndk-build` 的 Install 步骤调用 cmd 内建命令 `copy /b/y`，中文路径下
会静默失败，导致 `lib/<abi>/libtermux.so` 不生成（编译与链接本身是成功的，失败的是拷贝那一步）。
因此在本仓库当前位置（中文路径）**不要直接用 Android Studio 构建**：AGP 侧能过，NDK 侧必失败，
且现象具有迷惑性——`ndk-build` 的 stdout 显示 `Compile` / `SharedLibrary` 均成功、stderr 为空，
实际失败的是后续的 `copy`（Install）步骤，最终报
`Expected output file … for target termux but there was none`。

应对（任选其一）：

1. 用 `tools/build-app.sh`——它检测到路径含非 ASCII 时，自动同步一份到 ASCII 工作副本
   （`~/.workbuddy/build/sudobox-app`）再编译，产物回拷 `out/`；
2. 把仓库移到纯 ASCII 路径，此时脚本原地编译，Android Studio 也能直接用。

### 3.3 UI 适配（全面屏 / 挖孔屏 / 宽屏）

适配由四处协同完成，缺一处就会出现遮挡或黑边：

| 位置 | 配置 | 作用 |
|---|---|---|
| `res/values/themes.xml` | `windowLayoutInDisplayCutoutMode=shortEdges` | 内容延伸到挖孔两侧；默认的 `default` 会在竖屏顶部留黑边、横屏直接切掉内容 |
| `AndroidManifest.xml` | `android:max_aspect=2.4` | 全面屏宽高比声明（兼容仍读该 meta-data 的国产 ROM） |
| `AndroidManifest.xml` | `configChanges=orientation｜screenSize｜screenLayout｜…` | 旋转/折叠/分屏时**不重建 Activity**，终端 PTY 会话不中断 |
| `SudoBoxApp.kt` | `Scaffold(contentWindowInsets = WindowInsets.safeDrawing)` | 让 Scaffold 自动避让状态栏 / 挖孔 / 导航栏 |

关键点与踩过的坑：

- **`enableEdgeToEdge()` 只负责把内容画到系统栏之后，避让必须靠 `WindowInsets`。**
  曾把 `contentWindowInsets` 写成 `WindowInsets(0,0,0,0)`——等于放弃所有避让，
  页面顶部标题直接被状态栏和挖孔压住。
- 用 `safeDrawing`（= `systemBars ∪ displayCutout`）而不是 M3 默认的 `systemBars`：
  后者不含 displayCutout，**横屏时侧边挖孔会切掉内容**。
- 终端页额外调用 `.imePadding()`：`safeDrawing` 不含 IME，
  否则软键盘弹出会盖住光标所在行（依赖 manifest 的 `windowSoftInputMode=adjustResize`）。
- 状态栏图标颜色跟随 **App 主题**而非系统（`MainActivity` 的 `DisposableEffect`）：
  透明状态栏下图标直接画在 App 背景上，若按系统深色模式取色，
  手动切浅色主题时会得到「浅底浅色图标」。

宽屏（≥840dp，横屏 / 折叠屏展开）：底部 `NavigationBar` 换成侧边 `NavigationRail`；
容器页列数 2 → 3 → 4；仪表盘与设置页内容限宽 720dp 居中，避免文字行过长。

**复查补充（2026-09-03 二次代码审核）**：`NavigationRail` 默认 `windowInsets = systemBars`，
而 rail 模式下 Scaffold 无 bottomBar，content padding 底部已含手势条（M3 源码：
`bottom = bottomBarHeight?.toDp() ?: insets.calculateBottomPadding()`）——
两层叠加会**双份避让**，rail 内容底部悬空。已在 `SudoBoxApp.kt` 给 Rail 显式
`windowInsets = WindowInsets(0, 0, 0, 0)`（避让职责统一交外层 Row）。

### 3.4 输入契约与注入防线

命令以**单个字符串**经 `su -c` 交给 shell，shell 会完整重新解析一遍。
因此 App 与模块两侧各有一道防线，任何一侧漏掉都是 root 级注入面：

| 层 | 机制 | 覆盖 |
|---|---|---|
| App（`ChrootBackend.q()`） | 单引号包裹 + `'` → `'\''` | `id` / `name` / `distro` / `suite` / `mirror` / `command` / `out` |
| 模块（`cm_sanitize_id()`） | 白名单 `[A-Za-z0-9._-]`，其余换 `_` | 容器 id（同时是目录名、profile.conf 字段、JSON 字段） |
| 模块（`cm_sanitize_line()`） | 控制字符压成空格 | 状态文件与 profile.conf 的 `KEY=VALUE` 值 |
| 模块（`cm_json_escape()`） | `\` → `\\`、`"` → `\"` | `status --json` 的全部字符串字段 |

三条各自对着一个具体失效场景，不是"为了安全而安全"：

- **没做 `cm_json_escape`** —— `S_ERROR` 里带引号的 shell 报错会让 App 侧 `JSONObject`
  直接抛异常、**状态页全白**。已用变异测试确认：把该函数退化成恒等函数后
  `json.load()` 报 `JSONDecodeError`。
- **没做 `cm_sanitize_line`** —— `error_msg` 恰好排在状态文件**最后一行**，
  值里插一个换行就能在下方伪造 `state=running`，把"已停止"伪造成"运行中"。
  变异测试同样复现（`state=running active=evil` 被成功注入）。
- **`echo` 而不是 `printf`** —— `echo` 多输出的换行会被 `tr` 换成 `_`，
  结果每个导入的容器名尾部都多一个下划线（`debian` → `debian_`）。

> 这些都属于**编译期与 Lint 都发现不了**的运行时缺陷，只能靠审查 + 测试覆盖。

### 3.5 运行时健壮性审查（2026-09-03 第二轮）

编译与 Lint 之外，对终端桥 / 命令通道 / 偏好存储做逐文件审查，修掉三类
静态检查看不到的问题：

| 缺陷 | 位置 | 后果 | 修法 |
|---|---|---|---|
| `readText()` 先于 `waitFor(timeout)` | `isRootAvailable()`、`dataDirSize()` | `readText` 无超时，su 挂起即**永久阻塞调用线程**（在 Main 上就是 ANR），`waitFor` 的超时形同虚设 | 复用 `execSu` 顺序：先 `waitFor(timeout)` → 超时 `destroyForcibly()` → 进程已死再读流 |
| 枚举下标越界 | `PreferencesRepository` | DataStore 文件若存了越界整数（损坏/跨版本），`ThemeMode.entries[idx]` 抛 `IndexOutOfBounds` 崩溃 | `Int?.enumOr(default)` 安全取值回退默认 |
| 终端会话无退出反馈 | `TerminalScreen` | 会话退出后 UI 无感知，停在最后画面 | 已核对接线点，留待实机确认交互形态（低优先） |

线程模型核对结论：`SudoBoxViewModel` 全部命令在 `Dispatchers.IO`、
UI 更新走 `withContext(Main)`；轮询只在有 UI 收集时运行；DataStore 异步主线程安全；
`TerminalSessionFactory` 的容器 id 经单引号包裹、`managerPath` 为内部常量——均无注入面。

---

## 4. 验证

### 4.0 设备端一键验收（推荐入口）

```bash
bash tools/device-verify.sh                  # 全流程：设备/root → 装 APK → 推模块 → 自检 → 冒烟 → 启动
bash tools/device-verify.sh --no-smoke       # 跳过冒烟（未刷模块时）
bash tools/device-verify.sh --local /sdcard/rootfs.tar.xz   # 冒烟用本地 rootfs，免下载
```

前置：手机开启 USB 调试并连接。脚本会依次检查设备与 root 通道、安装 App、推送模块 ZIP 与
工具脚本、跑 `chroot-mgr diagnose` / `selftest`、可选冒烟，最后启动 App 并捕获
`FATAL EXCEPTION` 崩溃日志。

> **2026-09-03 修复**：`su_()` 曾把命令裸拼进 `adb shell "su -c $1"`——adb 会把整条命令
> 交给设备端 shell 再解析一次，`su_ 'id -u'` 实际变成 `su -c id -u`（su 的 `-c` 只吃
> 一个词，`-u` 落到 su 自身选项 → 报 usage），root 探测在真机上必然失败。
> 已改为 `su -c '$1'`（单引号包裹，su 收到完整命令字符串）。步骤 6 同时新增
> 自动截图 `out/device-screen-dashboard.png`，用于远程目视核对 UI 适配三处
> （顶部标题 / 底部手势条 / 挖孔侵入）。

### 4.1 本地逻辑回归（无需设备）

```bash
bash tools/test-logic.sh
```

覆盖：压缩格式 magic bytes 识别、状态机读写往返、发行版探测、
profile 描述符读写、组件系统分派、描述符字段与钩子引用完整性，
以及 `status --json` 的 JSON 转义契约、容器 id 归一化、状态文件换行注入防线。

> 当前状态：**63 项全部通过**（含 20 项输入契约用例，见 §3.4）。

### 4.2 设备端冒烟（P0 验收）

```bash
adb push tools/smoke-test.sh /data/local/tmp/
adb push out/SudoBox-chroot-mgr-v0.1.0.zip /sdcard/
# 手机端安装模块并重启后：
adb shell su -c 'sh /data/local/tmp/smoke-test.sh'
# 或用本地 rootfs 归档（免下载）：
adb shell su -c 'sh /data/local/tmp/smoke-test.sh /sdcard/rootfs.tar.xz'
```

验收点：diagnose → selftest → install → enable → 容器内命令 → 包管理器 update
（验证 seccomp 豁免与 DNS）→ enter → disable → **进程与挂载零残留**。

### 4.3 无系统改动清单

```bash
adb shell su -c 'sh /data/local/tmp/verify-clean.sh'
```

---

## 5. 实现状态与诚实边界

| 项 | 状态 | 说明 |
|---|---|---|
| R0 引擎（mount/chroot/umount/enter） | ✅ 已实现 | 待 PD2338 实测 |
| 组件系统（mnt/net/profile） | ✅ 已实现 | 移植 linuxdeploy 的 deploy.conf + do_* 六函数 |
| 单实例约束 D21 / 进入仲裁 D22 | ✅ 已实现 | 台账 + /proc 扫描 + 清零校验 + 失败回滚 |
| 双视图 D23 | ✅ 已实现（App） | 方格/列表，偏好持久化 |
| App 4 Tab + 终端页 | ✅ 已实现并编译通过 | minSdk 31 / targetSdk 35；`out/app-{debug,release}.apk`；Lint 0 问题 |
| UI 全面屏 / 挖孔屏 / 宽屏适配 | ✅ 已实现 | 见 §3.3；**仅静态验证，未经实机目视确认** |
| App↔模块输入契约（注入 / 转义 / 行注入） | ✅ 已实现并测试 | 见 §3.4；4 道防线，20 项用例，已做变异测试确认用例有效 |
| App 实机运行 | ❌ 未验证 | 需连接设备后跑 `bash tools/device-verify.sh`（adb 37.0.1 已就绪，当前无设备连接） |
| 发行版 Wave1 | ⚠️ 部分 | ubuntu / alpine / kali 走渠道 A（官方 tarball 直下） |
| Debian | ⚠️ 未实现设备端部署 | 无官方 base tarball，官方渠道是 debootstrap 两阶段；资产未内置（P1）。当前请用 `install --import`（见 `distro/debian/distro.conf` 头部说明） |
| OCI 渠道（渠道 B） | ❌ 未实现 | P1 走 PC 侧 `skopeo` 预生成 + import；设备端拉取放 P3 |
| sepolicy 收窄（O3） | ⚠️ 宽松 | P2 按实测 avc 日志收窄 |
| 守护策略（P2：watchdog/前台服务/双进程） | ❌ 未实现 | P2 范围 |
| WebUI 兜底 | ❌ 未实现 | P3 范围 |

**已知限制（不隐藏）**

- 无 `PID_NS`：容器内 PID 不从 1 计数，**跑不了 systemd**；B 级发行版（Arch/Fedora/CentOS）服务只能裸进程/前台运行。
- `enter` 使用 `unshare -m` 私有 mount 命名空间：会话内挂载随 ns 销毁而消失（宿主零残留），
  但**在会话中启动的后台服务持有该 ns**，`disable` 时宿主编ns看不到这些挂载——
  服务应在 `enable` 后通过 `svc start`（宿主 ns）启动，而非在交互会话里拉起。
- CPU/内存 KPI 是**整机**口径，不是容器专属用量（无 PID_NS/cgroup 隔离）。
- 描述符实现为 POSIX sh 可 source 的 KV（等价于设计稿 YAML 的字段集），
  以适应设备端无 YAML 解析器的约束；新增发行版仍是"新增一个目录，引擎与 UI 零改动"。

---

## 6. 致谢

- [Linux Deploy](https://github.com/meefik/linuxdeploy)（Anton Skshidlevsky, GPLv3）——组件系统、`mnt`/`net`/`bootstrap` 逻辑
- [Termux](https://github.com/termux/termux-app)（GPLv3）——`terminal-emulator` / `terminal-view`
- [KernelSU](https://github.com/tiann/KernelSU)——模块生命周期与 root 通道
