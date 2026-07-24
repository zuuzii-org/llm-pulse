# LLM Pulse 发布流程

本文档用于发布 LLM Pulse macOS 应用和配套插件。当前公开基准版本为 `2.2.0`，下一功能版本为 `2.3.0`，品牌署名统一使用 **Zuuzii**。

## 发布原则

- 发布源码必须来自 `main` 的干净、已推送 commit。
- App、插件 manifest、tag、DMG、appcast 和 Release Notes 必须使用同一版本号。
- 产物必须为 `arm64 + x86_64` Universal App，最低支持 macOS 14。
- App 和 DMG 都必须通过签名、Apple 公证、staple 与 Gatekeeper 验证。
- Release 先作为 Draft 上传，从 GitHub 重新下载验证后才公开。
- 绝不移动、复用或覆盖已公开的 tag 和版本产物。

## 前置条件

发布机需要：

- macOS 与 Xcode 16+，已接受 Xcode License。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)。
- `gh` CLI，已登录且可向 `zuuzii-org/llm-pulse` 推送 tag 和创建 Release。
- 登录 Keychain 中可用的 Developer ID Application 证书。
- Keychain 中名为 `LLMPulseNotary` 的 `notarytool` 凭据 profile。
- 仓库外的 Sparkle EdDSA private-key 文件，默认路径为 `~/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key`。仓库只保存匹配的 public key。

检查工具、身份与公证 profile：

```bash
xcodebuild -version
xcodegen --version
gh auth status
security find-identity -v -p codesigning | grep -q "Developer ID Application"
xcrun notarytool history --keychain-profile "LLMPulseNotary" >/dev/null
scripts/sparkle_key_tool.swift public-key \
  "$HOME/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key"
```

### 当前发布身份

LLM Pulse 当前发布、构建和本地写入统一使用以下技术身份：

- Bundle ID：`com.zuuzii.LLMPulse`
- Xcode project、target、scheme 与 module：`LLMPulse`
- `notarytool` profile：`LLMPulseNotary`
- Application Support：`~/Library/Application Support/LLM Pulse/`
- Sparkle private-key 文件：`~/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key`
- Codex plugin 与 marketplace ID：`llm-pulse`

升级所需旧常量只能从 basename 为 `LegacyCompatibility.*` 的集中定义读取。发布源码、生成工程、DMG、插件 manifest、当前文档和 appcast 都不得继续写入旧身份。Sparkle public key 保持不变，以维持既有更新信任链。

### 凭据安全

`LLMPulseNotary` 只是 Keychain lookup 名，可以出现在命令或脚本中；实际公证凭据仍由 Keychain 保管。Sparkle 私钥采用仓库外的文件模式，发布脚本默认 `SPARKLE_KEY_SOURCE=file`。

- 不要把 Apple ID app-specific password、App Store Connect API `.p8` key、`.p12` 证书、Keychain 导出文件或公证请求 JSON 写入仓库。
- 不要在命令行中传递 `--password`，不要把凭据保存到 `.env`、shell history、CI log 或 Release 附件。
- 发布时不要开启 `set -x`；如 shell 已开启 trace，先执行 `set +x`。
- 需要重建 profile 时，使用 `xcrun notarytool store-credentials` 的交互式提示，不把密码写进命令。
- Sparkle key 文件必须由当前用户拥有、mode `0600`、hard-link count 为 1，父目录必须为 mode `0700`。不要把它放入仓库、`.build`、`dist`、`/tmp`、`/var/folders`、CloudStorage 或 Mobile Documents。
- 不要把私钥内容放进 argv、环境变量、stdin、shell command substitution 或日志。`SPARKLE_PRIVATE_KEY_FILE` 只能保存路径。
- 首次生成使用 `scripts/sparkle_key_tool.swift generate <absolute-path>`；该工具以 32-byte Ed25519 seed 新格式写入文件，拒绝覆盖、符号链接和弱权限。
- Keychain 兼容模式必须显式设置 `SPARKLE_KEY_SOURCE=keychain`；文件模式发生任何错误都会立即停止，不会回退到 Keychain。
### 三项不可再生的凭据

发布依赖三样只存在于发布机的东西。它们没有一样可以由他人重建，其中第一样丢失的后果是**不可挽回的**。

| 凭据 | 位置 | 丢失后果 |
| --- | --- | --- |
| Sparkle Ed25519 私钥 | `~/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key` | **所有已安装版本的应用内更新永久失效。** `SUPublicEDKey` 已烧进每个发出的二进制，无法补发；用户只能手动重新下载 |
| Developer ID Application 证书与私钥 | 登录 Keychain | 无法签名，需向 Apple 重新申请并作废旧证书 |
| 公证 Keychain profile `LLMPulseNotary` | 登录 Keychain | 可用 Apple ID 重建，是三者中唯一可恢复的 |

**Sparkle 私钥必须有一份离机备份，且必须验证过能恢复。** 这不是发布前的一次性任务，而是每次更换发布机、重装系统或轮换密钥后都要重做的前置条件。

加密备份（口令交互输入，不进 shell history）：

```bash
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$HOME/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key" -out "$HOME/Desktop/llm-pulse-sparkle-key.enc"
```

或直接存入密码管理器（走剪贴板，不经终端回显与滚动缓冲）：

```bash
pbcopy < "$HOME/Library/Application Support/Zuuzii/Release Keys/LLM Pulse Sparkle Ed25519.key"
```

**备份必须做恢复演练才算数。** 解密后确认导出的公钥与 `Info.plist` 中的 `SUPublicEDKey` 逐字符相同，然后删除还原副本。

还原目标**不能放在 `/tmp`**：`/tmp` 是指向 `private/tmp` 的符号链接，而 `sparkle_key_tool` 拒绝路径链上的任何符号链接；`/private/tmp` 本身又是 `1777` 全局可写，同样不满足父目录 `0700` 的要求。用一个自建的 `0700` 目录。

还原副本是一份**明文私钥**。清理必须由 `trap` 保证，而不是靠命令末尾那一行——中途任何一步失败、粘贴被终端截断、或按下 Ctrl-C，末尾的清理都不会执行，明文就留在盘上了：

```bash
bash -c '
set -uo pipefail
D="$HOME/.llm-pulse-restore-check"
trap "find \"$D\" -type f -exec rm -P -f {} \; 2>/dev/null; rm -rf \"$D\"" EXIT
mkdir -p "$D" && chmod 700 "$D"
openssl enc -d -aes-256-cbc -pbkdf2 \
  -in "$HOME/Desktop/llm-pulse-sparkle-key.enc" -out "$D/restored.key" || exit 1
chmod 600 "$D/restored.key"
swift scripts/sparkle_key_tool.swift public-key "$D/restored.key"
/usr/bin/plutil -extract SUPublicEDKey raw -o - LLMPulse/Resources/Info.plist
'
```

两行输出一致即通过。演练结束后确认 `~/.llm-pulse-restore-check` 已不存在。

加密备份完成后把 `.enc` 移到离线介质或密码管理器附件，不要留在 Desktop、云同步目录或仓库内。

## 1. 锁定版本与源码

```bash
export VERSION="2.2.0"
export TAG="v${VERSION}"
export NOTARY_PROFILE="LLMPulseNotary"

git fetch origin --tags
test "$(git branch --show-current)" = "main"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
test -z "$(git tag -l "$TAG")"
test -z "$(git ls-remote --tags origin "refs/tags/$TAG")"

test "$(plutil -extract CFBundleShortVersionString raw LLMPulse/Resources/Info.plist)" = "$VERSION"
test "$(python3 -c 'import json; print(json.load(open("Plugin/.codex-plugin/plugin.json"))["version"])')" = "$VERSION"
test -s "docs/release-notes-v${VERSION}.md"
```

然后执行完整回归：

```bash
make check
```

任何测试、构建或版本校验失败时都应停止发布。

## 2. 构建、签名、公证与生成 DMG

在仓库根目录执行：

```bash
umask 077
./scripts/release.sh \
  --version "$VERSION" \
  --notary-profile "$NOTARY_PROFILE"
```

`scripts/release.sh` 应一次完成以下阶段，任一阶段失败即退出：

脚本会在任何签名或公证开始前检查 Release Notes 是否存在，并验证 Codex plugin manifest 与 App 版本一致，避免到 appcast 阶段才发现发布源不完整。

1. 从当前 commit 生成 Xcode 工程并构建 Release Universal App。
2. 签名 App 及其嵌套可执行文件，开启 Hardened Runtime。
3. 将 App 提交 Apple 公证，等待 `Accepted`，然后对 App staple。
4. 生成只包含 `LLM Pulse.app → Applications` 的拖拽安装 DMG；若检测到另一个旧或当前 wrapper，启动期迁移器会在移动数据前停止，要求用户先退出并只保留一个副本。
5. 签名 DMG，提交公证，等待 `Accepted`，然后对 DMG staple。
6. 输出 SHA-256 校验文件。
7. 从最终 staple 后的 DMG 生成两跳 `appcast.xml`：v2 item 要求 host build 6，同时保留固定校验的 v1.4 bridge item，让 build 1–5 先升级到 build 6。脚本会验证两项的版本、URL、长度与签名。

预期产物：

```text
dist/LLM-Pulse-2.2.0.dmg
dist/LLM-Pulse-2.2.0.dmg.sha256
dist/appcast.xml
```

脚本只生成本地产物，不应自动创建 tag、推送 Git 或公开 GitHub Release。

### 公证失败时

保留 `notarytool` 输出的 submission ID，读取 Apple 的详细日志：

```bash
xcrun notarytool log "<submission-id>" \
  --keychain-profile "$NOTARY_PROFILE"
```

检查未签名的嵌套代码、Hardened Runtime、bundle 结构、最低系统版本和架构。修复后从干净构建重新开始；不要修改已签名或已公证的 bundle。对外分享公证日志前，先检查其中的本地路径和账户元数据。

## 3. 验证本地产物

先验证校验和 DMG 本体：

```bash
DMG="dist/LLM-Pulse-${VERSION}.dmg"
CHECKSUM="${DMG}.sha256"
APPCAST="dist/appcast.xml"

test -f "$DMG"
test -f "$CHECKSUM"
test -f "$APPCAST"
(cd dist && shasum -a 256 -c "LLM-Pulse-${VERSION}.dmg.sha256")

codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
xmllint --noout "$APPCAST"
```

以只读方式挂载 DMG，再验证内部 App：

```bash
MOUNT_POINT="$(mktemp -d)"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG"
APP="$MOUNT_POINT/LLM Pulse.app"

codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"
test "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION"
test "$(lipo -archs "$APP/Contents/MacOS/LLM Pulse")" = "x86_64 arm64" || \
  test "$(lipo -archs "$APP/Contents/MacOS/LLM Pulse")" = "arm64 x86_64"

hdiutil detach "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
```

如中途失败，先执行 `hdiutil detach "$MOUNT_POINT"` 再清理临时目录。

最后做一次手动验收：

- 如修改过安装视觉，先运行 `swift scripts/render_dmg_background.swift --preview .build/release/dmg-background-preview.png`，确认 1x/2x 背景可重复生成。
- 打开 DMG，检查图标、背景、中央拖拽箭头、窗口尺寸和 `Applications` 快捷方式是否正确；两个未选中标签都应在浅色底板上清晰可读。
- 将 App 拖入 `/Applications`，从该路径首次启动，确认 Gatekeeper 不报错。
- 确认菜单栏计数、触边侧边栏、设置、通知与 Codex 任务跳转。
- 用测试 feed 分别演练 v1.3→v1.4→v2 与 v1.4→v2；确认第一条路径必须经过 build 6，且最终只存在一个 App 与菜单栏进程。
- 在 `enabled`、`requiresApproval` 与 `notRegistered` 三种状态下记录“登录时启动”结果；新 Bundle ID 下重新验证通知授权请求，不得宣称旧授权或 pending notifications 被迁移。
- 确认 App 仍只读 Codex 数据，未安装插件时 SQLite/JSONL 降级路径可用。
- 手动升级时先退出并移除旧 wrapper，再复制 `LLM Pulse.app`；验证重复 App 会在任何数据迁移前阻断启动。

## 4. 创建 tag 与 Draft GitHub Release

只有本地验收全部通过后才能创建 tag：

```bash
git status --short
git push origin main
git tag -a "$TAG" -m "LLM Pulse ${TAG}"
git push origin "$TAG"

gh release create "$TAG" \
  "dist/LLM-Pulse-${VERSION}.dmg" \
  "dist/LLM-Pulse-${VERSION}.dmg.sha256" \
  "dist/appcast.xml" \
  --repo zuuzii-org/llm-pulse \
  --title "LLM Pulse ${TAG}" \
  --notes-file "docs/release-notes-v${VERSION}.md" \
  --verify-tag \
  --draft
```

上传后检查 Draft 元数据和附件：

```bash
gh release view "$TAG" \
  --repo zuuzii-org/llm-pulse \
  --json isDraft,tagName,targetCommitish,url,assets
```

## 5. 从 GitHub 回下下载并公开

不要直接信任本地 `dist/`。从 Draft Release 下载一份全新副本，再次校验：

```bash
VERIFY_DIR="$(mktemp -d)"
gh release download "$TAG" \
  --repo zuuzii-org/llm-pulse \
  --dir "$VERIFY_DIR"

(cd "$VERIFY_DIR" && shasum -a 256 -c "LLM-Pulse-${VERSION}.dmg.sha256")
xmllint --noout "$VERIFY_DIR/appcast.xml"
xcrun stapler validate "$VERIFY_DIR/LLM-Pulse-${VERSION}.dmg"
spctl --assess --type open --context context:primary-signature -vv \
  "$VERIFY_DIR/LLM-Pulse-${VERSION}.dmg"
```

验证 Release Notes 的中英文内容、版本号、兼容性、已知限制和 SHA-256 附件都正确后，再公开：

```bash
gh release edit "$TAG" \
  --repo zuuzii-org/llm-pulse \
  --draft=false \
  --latest
```

公开后确认固定 feed 已切换到新版本，再从 Release 页下载一次 DMG，执行安装与首次启动烟雾测试：

```bash
curl -fL "https://github.com/zuuzii-org/llm-pulse/releases/latest/download/appcast.xml" \
  -o "$VERIFY_DIR/latest-appcast.xml"
cmp "$VERIFY_DIR/appcast.xml" "$VERIFY_DIR/latest-appcast.xml"
```

记录 Release URL 和最终 SHA-256，但不记录签名或公证凭据。

## 回滚与故障处理

### tag 尚未推送

删除本地产物，修复后重新构建。如已创建本地 tag：

```bash
git tag -d "$TAG"
```

### tag 已推送，但 Release 仍为 Draft

只在确认从未对外公开、无人依赖该 tag 时，才可删除 Draft 和 tag：

```bash
gh release delete "$TAG" --repo zuuzii-org/llm-pulse --yes
git push origin --delete "$TAG"
git tag -d "$TAG"
```

修复后从新的干净 commit 重新执行整个流程。

### Release 已公开

不要移动或重建同名 tag，也不要用不同内容覆盖原有附件。

1. 立即编辑 Release Notes 说明影响和建议。
2. 严重问题可删除 GitHub Release 以停止分发，但保留 Git tag 作为已发生的历史：

   ```bash
   gh release delete "$TAG" --repo zuuzii-org/llm-pulse --yes
   ```

3. 修复后以更高的 patch 版本（例如 `v0.1.1`）重新签名、公证和发布。

已签发的公证 ticket 不能作为常规回滚机制。如怀疑证书或公证凭据泄漏，立即停止发布、在 Apple Developer 后台轮换或撤销相关凭据，并对 GitHub 凭据同步轮换；不要仅删除 DMG 就视为完成处理。
