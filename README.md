# BlockAd — 免VPN的DNS去广告插件

替代「Loon 类网络工具常开 VPN 去广告」方案的越狱插件：**不依赖 VPN / 代理 / 常驻后台**，
只在被注入的 App 进程里拦截广告域名解析。耗电与 Loon 常开完全不在一个量级。

适用环境：**Relaxin（roothide / 隐根）** 越狱，如 iPhone 15 Pro Max + iOS 17.3.1（A17 Pro）。
包架构为有根式 `iphoneos-arm`。

---

## 它做了什么

1. 把开源广告域名列表（[VeleSila/yhosts](https://github.com/VeleSila/yhosts) 国内广告/统计 +
   [OISD small](https://oisd.nl) 全球追踪/广告）在**每次构建时**打包进 `/Library/BlockAd/blocklist.txt`；
2. 注入 App 进程，hook 系统 DNS 解析入口 `getaddrinfo()`；
3. 命中广告域名的解析直接返回「域名不存在」→ App 的广告 SDK 请求发不出去，广告自然加载失败。

对 App 其他行为零侵入：它不是隐藏广告视图，也不是改请求，失败方式与网络断开域名解析失败一致，
App 会优雅降级（跳过开屏广告、正文下方广告不加载等）。

## 特性

- ✅ 免 VPN，无后台常驻，耗电极低（仅进程内一次列表加载 + 每查询一次二分）
- ✅ 原生设置界面（`设置 → BlockAd`）：总开关、生效范围、指定 App 列表
- ✅ 拦截表每次 CI 自动从开源列表现场生成，更新列表 = 重新点一次工作流
- ✅ 核心逻辑带单元测试，构建时自动断言（macOS 上直接编译运行，无需 iOS 设备）
- ✅ GitHub Actions 云编译，`.deb` 一键下载，无需在 Windows/mac 上配本地编译环境

---

## 一、云编译拿 .deb（推荐，无需本地环境）

1. 去 [GitHub](https://github.com/new) 建一个**空仓库**（比如 `BlockAd`，可以设为 Private）；
2. 把本目录的内容全部推上去：
   ```bash
   git init && git add . && git commit -m "init" 
   git remote add origin https://github.com/<你的用户名>/BlockAd.git
   git push -u origin main
   ```
   （Windows 上建议用 [GitHub Desktop](https://desktop.github.com) 或 `git-bash`。）
3. 进仓库页面 → **Actions** → 左侧 **Build BlockAd** → **Run workflow**；
4. 跑完后点进这次构建 → 底部 **Artifacts** → 下载 `BlockAd-deb` 压缩包，
   里面有 `com.blockad.tweak_1.0.0_iphoneos-arm.deb`。

> ⚠️ 构建会在 macOS 云机器上自动拉取 Theos（roothide 分支）、生成拦截表、跑单元测试、出包。
> 工作流默认每周一凌晨自动重新出一次新列表的包，也可以随时手动 Run workflow。

## 二、安装到手机

1. 把 `.deb` 传到手机（AirDrop / 网盘 / `sftp`）；
2. 用 **Filza** 打开 `.deb` → 用 Sileo 安装（Filza 里直接点 deb 选 Sileo 即可）；
3. 安装时 Sileo 会自动把依赖（`mobilesubstrate`、`preferenceloader`）一并装上，如提示缺少源请先添加对应的软件源（如 Havoc / Chariz / Procursus）；
4. 安装完成后 **注销（Respring）**；
5. 打开 **设置 → BlockAd** 即可看到设置页。

## 三、验证是否生效

- 用 Filza / 终端（`NewTerm`）执行：
  ```bash
  ping -c1 doubleclick.net
  ```
  应提示 `Cannot resolve` / 解析失败。
- 打开任意一个被启用的 App，观察开屏广告/广告位消失。

## 四、设置页（iOS 设置 → BlockAd）

安装后默认**对所有 App 生效**，无需配置。设置页包含：

| 设置项 | 说明 |
|---|---|
| **启用去广告** | 总开关（默认开） |
| **生效 App** | `全部 App` / `仅指定 App` |
| **指定 App 的 Bundle ID** | 逗号分隔，如 `com.tencent.xin, com.sina.weibo` |

修改后**注销（Respring）**完全生效；即使不注销，设置变更也会通过系统通知实时刷新已运行 App 的开关状态。

> 怎么查某个 App 的 Bundle ID：Filza 点 App 的信息；或 Sileo → 已安装列表。
> 提示：未启用的 App 进程里完全不会安装 hook，零开销。

## 给更多 App 生效

ellekit 按 `BlockAd.plist` 里的 **Bundles 清单**决定注入哪些 App（清单外的不注入）。
加 App：用 Filza 编辑 `/Library/MobileSubstrate/DynamicLibraries/BlockAd.plist`，
在 `Bundles` 数组里加一行该 App 的 Bundle ID → 保存 → Respring。

## 五、更新拦截规则（自动）

- **自动更新**：插件每个被注入的 App 启动时后台检查一次，**24 小时自动拉最新规则**（从本仓库 GitHub Release 下载），拉到即**热替换**，无需重装、无需 Respring。
- **手动刷新（升级内置基线）**：仓库 Actions → Run workflow 重新出包 → 安装新 deb。CI 每次构建会：拉最新开源规则 → 生成列表 → 发布到 GitHub Release → 出包。
- 自动更新失败完全不影响使用：内置 29.5 万条基线兜底，**永远不会失效/变空**。
- 自动更新下载地址（固定）：`https://github.com/zhangtao838/BlockAd/releases/latest/download/blocklist.txt`
  > 若换了仓库地址，改 `Tweak.xm` 里的 `BA_RULES_URL` 重新构建即可。

---

## 本地/自编译（可选，需要 Linux/macOS + Theos）

```bash
# 1. 装 Theos（roothide 官方分支，--recursive 需拉取 libsubstrate 等子模块）
git clone --recursive https://github.com/roothide/theos $HOME/theos
export THEOS=$HOME/theos
# 补充头文件：只拷设置页需要的 Preferences（避免遮蔽 SDK 头文件）
git clone --depth 1 https://github.com/theos/headers /tmp/theos-headers
mkdir -p "$THEOS/include"
cp -R /tmp/theos-headers/Preferences "$THEOS/include/"
cp -R /tmp/theos-headers/SpringBoardServices "$THEOS/include/" 2>/dev/null || true

# 2. 生成拦截表（yhosts + OISD）
python3 scripts/make-blocklist.py

# 3. 单元测试（核心逻辑，无需设备）
make -C test && ./test/t_blocklist

# 4. 出包（tweak + 设置页两个子工程一并打进 .deb，roothide 打包方案）
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

## 目录结构

```
BlockAd/
├── Tweak.xm                # tweak 主体：getaddrinfo hook + 多路径加载拦截表 + 设置读取
├── blocklist.c/.h          # 拦截表核心：加载 / 反转域名 / 二分查找（纯C，可单测）
├── Prefs/                  # 设置页子工程（PreferenceBundle）
│   ├── BlockAdController.mm   # 设置项程序化构造（开关/生效范围/指定App/注销按钮）
│   └── Resources/
│       ├── Info.plist          # bundle 元信息（BNDL / NSPrincipalClass）
│       └── BlockAdIcon*.png    # 设置入口图标
├── scripts/
│   ├── make-blocklist.py   # 拉取开源列表生成 blocklist.txt
│   └── make-icons.py       # 生成设置图标（纯 Python）
├── layout/
│   ├── Library/BlockAd/blocklist.txt                  # 拦截表
│   └── Library/PreferenceLoader/Preferences/BlockAdPrefs.plist  # 设置入口
├── test/                   # 核心逻辑单元测试（CI 自动跑）
└── .github/workflows/build.yml  # 云编译工作流
```

## 已知边界（正常现象）

| 场景 | 说明 |
|---|---|
| App 走自己的 DoH/硬编码 IP | DNS 层拦不到；此类极少见于广告场景 |
| 广告与内容同域（如 `api.weibo.com/ads`） | 域名级无能为力，属 Loon 免费规则同样限制 |
| 装包后立刻没效果 | 需要 Respring；确认 `/Library/BlockAd/blocklist.txt` 存在 |
| 想彻底不拦截某个 App | 改 conf 去掉该 App，Respring |

## 免责声明

仅供学习研究、在自有设备上使用。拦截广告/统计可能违反部分 App 的用户协议，后果自负。
不同 App 广告实现差异大，个别 App 可能需要针对性处理，本项目不保证覆盖所有情况。