# PokeBonk (iPad) — 离线 WKWebView 外壳 + 未签名 IPA 构建

把 `pokebonk.com` 的完整静态镜像放进一个 iPad-only 的 WKWebView 外壳里离线运行，
构建产物是 **未签名 `PokeBonk-unsigned.ipa`**，可自行重签或经 AltStore / SideStore 侧载。

```
PokeBonk/
├── project.yml                     # XcodeGen 工程描述（唯一真源，不用手写 pbxproj）
├── make_ipa.sh                     # macOS/CI：xcodegen + xcodebuild + Payload zip（未签名 ipa）
├── make_site_zip.sh                # Linux/macOS：镜像目录 -> site.zip（剥掉 Android 的 __bridge.js）
├── Sources/
│   ├── AppDelegate.swift           # @main，注册 SceneDelegate，无 Storyboard
│   ├── SceneDelegate.swift         # UIWindow + GameWebViewController
│   ├── GameWebViewController.swift # WKWebView 配置、全屏沉浸、键盘中继、持久化钩子
│   ├── AssetSchemeHandler.swift    # WKURLSchemeHandler：appassets:// -> Bundle/site
│   ├── WebScripts.swift            # bridge.js（.atDocumentStart）+ 平台胶水 + CSS 覆盖
│   └── AppScheme.swift             # scheme / host / site 目录常量
├── Resources/
│   ├── Info.plist                  # iPad only, iOS 15.0, 横屏, UIRequiresFullScreen
│   ├── Assets.xcassets/            # AppIcon + 启动色 LaunchBackground
│   └── site/                       # ← 不进仓库；CI 从 Release 资产 site.zip 解压到这里
├── Config/
│   ├── PokeBonk.entitlements       # 仅供重签使用（最低权限：get-task-allow=false）
│   ├── Shared.xcconfig             # 本地 Xcode 直接打开工程时的默认设置
│   └── Shared.Release.xcconfig     # Release 覆盖
├── .github/workflows/ios.yml       # macos-14：下载 site.zip → xcodegen → xcodebuild → ipa
└── .gitignore
```

---

## 1. 结构设计要点

| 需求（Android 参考实现） | iOS 实现 |
|---|---|
| `WebViewAssetLoader` 把 `appassets.androidplatform.net` 映射到 `assets/` | `WKURLSchemeHandler` 把 `appassets://appassets.local/*` 映射到 `Bundle.main/site/*` |
| `assets/bridge.js` 经拦截 `/__bridge.js` 加载 | `WKUserScript(source: bridge.js, injectionTime: .atDocumentStart)`，原样注入 |
| `setDomStorageEnabled(true)` | `WKWebsiteDataStore.default()`（持久化 localStorage + IndexedDB） |
| `setMediaPlaybackRequiresUserGesture(false)` | `mediaTypesRequiringUserActionForPlayback = []` |
| 全屏横屏 | `Info.plist` 只声明 landscape + `UIRequiresFullScreen` |

`bridge.js` 一个字节都没改：`make_site_zip.sh` 只是把 `index.html` 里的
`<script src="/__bridge.js"></script>` 那一个标签删掉，其余文件逐字节拷贝。
注入时机 `.atDocumentStart` 早于 index.html 被解析，因此早于
`<script type="module" src="./assets/main-*.js">`——和 Android 版本里
`__bridge.js` 位于 `<head>` 中的执行顺序等价。

---

## 2. 生成 `site.zip`（只有一次，需要完整镜像）

```bash
# 需要有完整镜像 /tmp/pb_mirror（约 70–80 MB，5000+ 文件）
cd PokeBonk
./make_site_zip.sh /tmp/pb_mirror
#   -> dist/site.zip

# 镜像里没有 bridge.js 时，从 Android APK 里取：
unzip -p PokeBonk-3D光哥离线版10-19_sign.apk assets/bridge.js > /tmp/pb_mirror/bridge.js
./make_site_zip.sh /tmp/pb_mirror
# 或者一步到位：
BRIDGE_SRC=/var/minis/shared/PokeBonk-3D光哥离线版10-19_sign.apk ./make_site_zip.sh /tmp/pb_mirror
```

脚本做的事：

1. 拷贝镜像（排除 `_log/`、`*.warc`、`.DS_Store`）；
2. 确认 `bridge.js` 存在且 > 10 KB；
3. 删掉 `index.html` 里的 `/__bridge.js` 标签，并断言不再引用它；
4. 检查 index.html 里所有本地 `src`/`href` 引用在磁盘上存在；
5. 解出 `assets/main-*.js` 的动态 import，报告缺失的 hashed 分块（只告警）；
6. 打包成 `dist/site.zip`（`index.html` 在 zip 根目录）。

把 `dist/site.zip` 作为 **Release 资产** 上传：

```bash
gh release create v1.0.0 dist/site.zip --title "PokeBonk site v1.0.0"
```

---

## 3. GitHub Actions 构建（无需 Mac）

`.github/workflows/ios.yml`，`runs-on: macos-14`：

```
checkout → 选 Xcode → brew install xcodegen
→ 解析 site.zip（workflow_dispatch 的 site_zip_url / site_release_tag → tag 对应 Release 的
   site.zip → latest Release 的 site.zip → 仓库根目录的 site.zip）
→ 解压到 Resources/site/（校验 index.html / bridge.js / 无 __bridge.js 引用）
→ xcodegen generate
→ ./make_ipa.sh（xcodebuild Release, CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO）
→ 冒烟检查（bundle id / UIDeviceFamily / lipo arm64 / 必须无签名 / 资源逐文件对比）
→ 归档为 build/PokeBonk-unsigned.ipa 并 actions/upload-artifact
```

触发方式：

```bash
# 手动指定 release tag
gh workflow run ios.yml -f site_release_tag=v1.0.0

# 打 tag 自动构建（会用同名 tag 的 release 里的 site.zip）
git tag v1.0.0 && git push origin v1.0.0
```

产物：Actions run → Artifacts → `PokeBonk-unsigned-ipa`
（含 `PokeBonk-unsigned.ipa` 与 `.sha256`）。

本地 macOS 上等价命令：

```bash
cd PokeBonk
unzip ~/Downloads/site.zip -d Resources/site     # index.html 在根
xcodegen generate
./make_ipa.sh                                    # -> build/PokeBonk-unsigned.ipa
```

---

## 4. 重签未签名 IPA

未签名 ipa 可以直接被 **AltStore / SideStore / Sideloadly** 重签；也可以手动来。

### 4.1 macOS：`codesign` + `xcodebuild`

```bash
IPA=PokeBonk-unsigned.ipa
WORK=$(mktemp -d); cd "$WORK"
unzip -q "/path/to/$IPA"

# a) 最小 entitlements（免费开发者账号不要带 application-identifier / keychain groups）
cat > entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>get-task-allow</key><false/>
</dict></plist>
PLIST

# b) 用 Xcode 的自动签名身份（Apple Development: Name (TEAMID) 或 Apple Distribution）
#    没有证书时：Xcode ▸ Settings ▸ Accounts ▸ 登录 Apple ID ▸ Manage Certificates ▸ + ▸ Apple Development
security find-identity -v -p codesigning          # 取 identity 名称 / 40 位 SHA-1
IDENTITY="Apple Development: You (ABCDE12345)"

# c) 重签：先 frameworks，再主程序；最后整个 .app
APP="Payload/PokeBonk.app"
find "$APP/Frameworks" -name '*.dylib' -o -name '*.framework' 2>/dev/null | while read -r f; do
  codesign -f -s "$IDENTITY" --timestamp=none "$f"
done
codesign -f -s "$IDENTITY" \
         --entitlements entitlements.plist \
         --generate-entitlement-der \
         "$APP"

codesign -dv --verbose=4 "$APP"        # 确认 Authority / Identifier
codesign --verify --deep --strict --verbose=2 "$APP"

# d) 重新打包
zip -qry "PokeBonk-signed.ipa" Payload
```

> 若用 **付费** 开发者账号 / 描述文件（而非 AltStore 的自动签名），把
> `Config/PokeBonk.entitlements` 换成含 `application-identifier`、`get-task-allow=true`
> 的版本，并把 `embedded.mobileprovision` 放进 `Payload/PokeBonk.app/` 再签。

### 4.2 `xcodebuild` 方式（有工程时）

```bash
xcodegen generate
xcodebuild -project PokeBonk.xcodeproj -scheme PokeBonk \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/PokeBonk.xcarchive \
  DEVELOPMENT_TEAM=ABCDE12345 CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/PokeBonk.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist          # method=development|ad-hoc|app-store
```

`ExportOptions.plist` 最小内容（ad-hoc，付费账号）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>ad-hoc</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>ABCDE12345</string>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
```

### 4.3 Linux / Windows / 无 Mac：`zsign`

```bash
# 输入：p12（含私钥 + 证书）、password、mobileprovision（免费账号用 Xcode 导出的 development profile）
zsign -k signing.p12 -p 'P12_PASSWORD' \
      -m signing.mobileprovision \
      -b com.pokebonk.offline \
      -z 6 \
      -o PokeBonk-signed.ipa \
      PokeBonk-unsigned.ipa
```

`ldid` 只能做伪签名（供 jailbreak / TrollStore 用），**不能**用于正常侧载：

```bash
unzip -q PokeBonk-unsigned.ipa -d out && cd out
ldid -S entitlements.plist Payload/PokeBonk.app/PokeBonk
zip -qry ../PokeBonk-ldid.ipa Payload
```

### 4.4 免费 Apple ID 的注意事项

- 免费账号签名有效期 **7 天**，AltStore / SideStore 需要在到期前刷新（后台刷新需连接同一 Wi-Fi 或 VPN 回本机/服务器）；
- 免费账号只能签 **3 个 App**（含 SideStore 自身）；
- 免费账号拿不到 `application-identifier` / `keychain-access-groups` 等 entitlement，
  因此本工程不请求任何特殊能力（无推送、无钥匙串共享、无 App Group）——这正好满足要求；
- `get-task-allow=true` 是调试签名必须的，AltStore 会自动处理；手动签时按 4.1 的模板把
  `false` 改成 `true`。

---

## 5. AltStore / SideStore 侧载

1. 在 iPad 上装好 **AltStore**（需先在一台电脑上用 AltServer 安装）或 **SideStore**（用
   WireGuard + SideServer 配对，完全不需要电脑常开）。
2. 把 `PokeBonk-unsigned.ipa` 传到 iPad（AirDrop / 文件 App / iCloud）。
3. AltStore：`My Apps` ▸ `+` ▸ 选择 ipa ▸ 输入 Apple ID 与密码（应用专用密码）▸ 等待重签安装。
   SideStore：`Sources`（添加任意源）或用 `+` 选本地 ipa，流程相同。
4. 首次启动后去 `设置 ▸ 通用 ▸ VPN 与设备管理` 信任开发者证书。
5. **刷新**：AltStore 打开时后台刷新；SideStore 需开启其 VPN（本地回环）。7 天到期前刷新即可，
   存档不会丢——存档在 `WKWebsiteDataStore.default()` 的 app 容器里，重签覆盖安装会保留
   （Bundle ID 不变的前提下）。

其他选择：Sideloadly（Win/Mac，需要电脑插线）、TrollStore（仅支持特定 iOS 版本，永久签名）。

---

## 6. 已知 / 可能出问题的地方

### 6.1 `WKURLSchemeHandler` 不支持 Range 请求

`WKURLSchemeRequest` 没有 API 回 `206 Partial Content`。本实现：

- 只回 **200 + 完整 body**，并显式带 `Accept-Ranges: none`；
- WebKit 自己会对自定义 scheme 的媒体做缓冲/切片，`<audio>`（`music/*.ogg`、`cries/*.ogg`）
  会退回整文件下载；ogg 本来就是软件解码，整文件进内存没有额外风险；
- 如果将来换成 `<video>` 或大 mp4 需要 seek：要么给每种媒体开一个**单独 scheme**
  （每个 `WKURLSchemeHandler` 实例只处理一个请求），要么直接用 `AVAudioPlayer` 播本地文件。
  另注意：同一个 `WKURLSchemeTask` 在 `didReceive(response)` 里给的 status code 就决定了
  整个响应，**不能**先发 200 再补 206。

### 6.2 localStorage 持久化

- 必须 `websiteDataStore = .default()`；`.nonPersistent()` 会让存档随 WebProcess 一起消失。
- 数据落在 app 容器的 `Library/WebKit/WebsiteData/` + `Library/Caches/` 里，**重签覆盖安装保留**，
  但 **删除 App 会清空**。卸载前先备份：`设置 ▸ 通用 ▸ iPad 储存空间 ▸ PokeBonk` 没有导出功能，
  只能走 iTunes/Finder 的「文件共享」——本工程 `UIFileSharingEnabled=false`（存档在 WebKit 容器里，
  开了也看不到），真正的备份手段是 iCloud/iTunes 整机备份或越狱环境下的容器导出。
- `bridge.js` 用 `localStorage['pb.local.state.v2']` 存整个账号/战队树；数据量随对局增长，
  超过 ~5 MB 时 WebKit 抛 `QuotaExceededError`（bridge 里 `save()` 是 try/catch 吞掉的），
  表现为「新的对局成绩没保存」。如果出现，需要改 bridge 的存储层（本工程按要求不改）。

### 6.3 资源路径大小写

- CI runner 的 APFS 默认 **大小写不敏感**，iPad 的 APFS 是 **大小写敏感**。
  本工程的处理：
  - `AssetSchemeHandler` **不做**大小写回退匹配，找不到就 404；
  - `make_site_zip.sh` 在打包前逐条校验 index.html 的本地引用；
  - workflow 在打包后把 `Resources/site` 与 `PokeBonk.app/site` 的文件列表逐项比对。
- 仍可能出现的是 **代码里拼出来的路径**（`${biome}/atlas.json` 之类）大小写不一致，
  这种静态检查看不出来，只能在真机上跑一遍所有场景。

### 6.4 ES module / MIME

`<script type="module">` 严格要求 JS 的 MIME 是 `text/javascript`。`AssetSchemeHandler`
对 `.js/.mjs/.json/.css/.woff2/.ogg/.glb` 等做了显式映射，避免 `octet-stream` 导致整页白屏。

### 6.5 键盘

`preferences.isTextInteractionEnabled = false` 会同时禁掉系统键盘弹起，所以加了一个
1×1 的隐藏 `UITextField` 做中继：页面 `<input>` 获得焦点 → `pbKeyboard` 消息 → 原生弹键盘 →
每次 `editingChanged` 回写 `el.value` 并派发 `input` 事件。`bridge.js` / 游戏 UI 只看 `value`，
因此不影响原有逻辑。若某些输入法（中文拼音）组合态有问题，可在 `keyboardChanged` 里改用
`insertText:` 或临时把 `isTextInteractionEnabled` 设回 `true`。

### 6.6 其他

- **WebGL**：iOS 15+ 一律 Metal ANGLE，无需开关；GPU 进程被内存压力杀掉时
  `getContext` 返回 `null`，外壳检测到 `WKWebViewWebProcessDidCrash` 后自动重载。
- **横屏**：`Info.plist` 只声明 landscape + `UIRequiresFullScreen`。iPadOS 16 Stage Manager
  下仍可能被系统以窗口形式显示，`UIRequiresFullScreen` 是 Apple 唯一公开手段。
- **状态栏 / home indicator**：`prefersStatusBarHidden=true`、`prefersHomeIndicatorAutoHidden=true`，
  并对底边做 `preferredScreenEdgesDeferringSystemGestures`，避免游戏摇杆误触回桌面。
- **`project.yml` 的 `Resources/site`** 标记为 `optional`，所以没有 site 时 `xcodegen`
  也能生成工程（只是 App 启动会显示「site/ 缺失」）。CI 一定在 `xcodegen` **之前**解压 site.zip。
- **`site.zip` 体积**：完整站约 73 MB（其中音频 16 MB、PNG 37 MB）。ipa 会接近这个大小；
  App Store 上限不影响侧载，但 AltStore 上传到设备会走本地网络，首次安装会花几分钟。
- **ATS**：只加载自定义 scheme，不发任何网络请求，`NSAppTransportSecurity` 不需要配置。
- **签名检查**：workflow 里若发现 bundle 有签名会直接 fail，确保产物确实是 unsigned。
