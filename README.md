# Meeting Assistant

原生 macOS 会议助手：全系统声音 + 麦克风、双语字幕、直接基于实时原文的文字总结与引用。每人使用自己的 OpenAI API Key。

当前源码版本为 **0.1.12 (14)**。设置中的 API Key 保存至 macOS 钥匙串；图标采用记录页、单色声波与笔。按下方步骤可在本地构建应用。

开启同传会自动切换系统麦克风，停止后恢复。自动路由与播放器离线回归已通过；全新 Mac 安装和真实会议对端听音仍待验收，详见 [验证与验收](docs/验证记录.md)。

0.1.9 起移除会后录音重转写、翻译和说话人识别，结束会议后直接使用实时原文，由 `gpt-5.6-luna` 生成文字总结。已有历史转写和引用保留，生成失败保留原文及旧总结。图标源文件见 [图标设计](docs/图标设计.md)。

0.1.7 在译音引擎重配置后重新确认原虚拟设备、更新播放格式并恢复，恢复期间暂存新译音，不重播被中断的旧队列。已通过离线回归及 BlackHole 静音播放恢复检查；会议对端实际听音仍待验收。

字幕单列显示，突出对方译文，原文紧接下方；新内容自动跟随，手动上翻时暂停跟随。0.1.3 及更早分发包不包含这些修复。

## 运行

要求 macOS 14.2+、Swift 5.10+，使用配套的 macOS SDK，不依赖 npm、Python 服务或第三方 Swift 包。

```sh
swift run --disable-sandbox MeetingCoreChecks
swift run --disable-sandbox AudioSafetyChecks
bash scripts/check-voice-output.sh
bash scripts/build-app.sh
open dist/MeetingAssistant.app
```

`--disable-sandbox` 仅关闭 SwiftPM 的构建插件子沙盒，用于受限开发环境；不修改系统安全设置。

离线测试使用独立 Swift 可执行程序，兼容仅安装 Command Line Tools、没有 XCTest/Swift Testing 框架的 Mac。`MeetingDiagnostics` 是开发专用的短音频在线测试工具，只从进程环境读取 `OPENAI_API_KEY`，不存储凭据，不采集真实麦克风。

1. 打开设置，粘贴自己的 OpenAI API Key，点击“保存”，再验证连接。
2. 选择真实麦克风、字幕/总结语言与对外语言。
3. 点击开始新会议，允许麦克风和系统音频权限。
4. 在 Meet、Zoom、Teams 中正常开会，建议使用耳机。
5. 结束后保存实时原文与本地录音，再用已有实时原文自动生成文字总结；失败可点击“生成总结 / 更新总结”重试。
6. 0.1.4 起，选中会议后点击右上角“删除”，或右键会议记录选择“删除会议…”。确认后永久删除该会议的本地录音、全文、译文、总结和说话人参考；已导出的文件不受影响。准备、录制或总结期间不可删除。

全文始终默认显示实时原文，总结也仅使用它；没有有效实时原文时明确提示，不上传录音补跑，也不使用旧版转写替代。旧版转写可以通过“历史转写”单独查看，历史总结的引用仍跳到实际来源。更新总结后引用实时原文，失败保留旧总结。

## 向会议发送译音

0.1.11 起，首次打开应用先检测本机音频设备：已有可用 [BlackHole 2ch](https://existential.audio/blackhole/) 时自动保存译音输出配置并跳过安装；已有其他可用虚拟输出选择时保留原选择。检测不会切换系统麦克风。未配置时显示“准备同传音频”，用户点击后从 BlackHole 官方服务器下载固定版本安装包，经过 SHA-256、发布者签名与 Gatekeeper 检查才打开 macOS 安装器；不会附带安装包或要求安装 Homebrew。系统安装器负责管理员授权，可能要求重启。安装后返回应用会重新检测；只有实际枚举到可用设备才显示已配置。仅发现驱动文件时提示完成重启，不重复安装。可以暂时跳过，之后在设置的“设置同传音频…”中继续；录音和字幕不要求先安装该组件。

点击“发送我的译音”会自动把系统默认麦克风切到该虚拟设备，并回读确认；停止发送、暂停、结束或正常退出时恢复原设备，异常退出后下次启动恢复。会议软件使用系统默认麦克风即可跟随，无需每次手动切换。固定选择某个设备的软件不会跟随系统，各会议软件仍需分别验收。助手的采集始终绑定所选真实麦克风，系统扬声器及提示音输出保持不变。

BlackHole 由 Existential Audio Inc. 提供，保留其版权与品牌归属。安装源和校验值记录于 `Sources/MeetingAssistant/BlackHolePackage.swift`（当前 0.7.1，依据 [Homebrew 官方 cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/b/blackhole-2ch.rb) 核对，并实测官方下载包）。更新版本时须同时复核下载地址、SHA-256、开发者签名与公证结果。

安装引导回归：`bash scripts/check-blackhole-setup.sh`，不联网、不打开安装器、不修改系统设备。可附加 `--devices` 只读验证当前设备，或 `--download` 实际下载并校验官方包；两者都不会安装。原生界面可用 `bash scripts/build-ui-regression.sh` 构建后，以 `--preview-blackhole` 启动离线预览。

如果用户在同传期间改选系统麦克风，助手停止发送并提示，保留用户的新选择。原设备断开或恢复失败会明确报错并保留恢复记录，不猜测改用其他麦克风。路由恢复记录只包含设备 UID，不包含音频或凭据。

0.1.5 点击“发送我的译音”后，使用独立的 `gpt-realtime-translate` 会话将随后的麦克风音频实时译成设置的对外语言，再播放到虚拟设备。停止发送、暂停或结束会断开该会话并清空译音队列。对方听到 AI 合成语音，请向参会者说明。模型对已是目标语言的语音可能不输出，因此不保证目标语言原声透传；虚拟设备的真实会议播放尚待验收。

本机译音输出回归可运行 `bash scripts/check-voice-output.sh --hardware`：需要已安装 BlackHole 2ch，仅播放静音 PCM，通过实际通知入口模拟重配置并验证恢复；不采集麦克风、不调用 API、不改系统默认设备。此检查不等同于会议对端听音验收。

自动麦克风路由回归为 `bash scripts/check-voice-output.sh --hardware-route`：临时切换系统输入到 BlackHole，两秒后恢复，并核对扬声器未改变。不采集音频、不调用 API；请在没有通话时运行。诊断文件增加最近一次对外翻译连接计数、译音收到/排队/播放完成字节数及路由接管状态；这些计数不能证明会议对端收到了声音。

实时字幕使用同一翻译会话中的 `gpt-live-transcribe` 原文与译文增量，按音频帧时钟归入同一发言段。会议总结使用 `gpt-5.6-luna`，包括长会议分段总结、最终汇总和引用校验重试。总结模型不参与实时字幕。同传按停顿分段，不承诺逐句严格对齐。

## 数据与凭据

- 设置只提供“保存”，Key 安全保存在这台 Mac，下次启动可继续使用。保存失败保留输入，不将未保存的 Key 用于 API 请求。
- 底层使用 Keychain service `com.meetingassistant.openai`、account `api-key-v2`；写入后读回验证成功才显示已保存。Key 不包含在程序、UserDefaults、会议文件中。
- 从旧临时签名原型首次升级到正式签名版本需要重新填写一次 Key；0.1.1 → 0.1.2 → 0.1.3 不需要。旧临时签名版本的钥匙串条目保留，不尝试绕过其访问授权。
- 本地文件：`~/Library/Application Support/MeetingAssistant/Meetings/<UUID>/`。
- 每个会议：`meeting.json`、两路分段 WAV；旧版留下的 `speakers.json` 等历史文件仍保留，新版不生成说话人身份或参考音频。
- 录制时每五秒保存 `audio-diagnostics.json`，只记录两路采集、接收、发送、丢弃字节数和协议事件计数，不包含音频、转写文本或 Key。
- 录音本地保存；会中音频发送至 OpenAI 生成实时字幕与译文，会后仅发送已有实时原文生成总结。费用由当前用户的 API 账户支付。
- Markdown 导出只有文字与时间引用，不携带凭据或录音。
- 直接连接官方 API，不存在共享账户、代理服务器或遥测。

## 当前边界

这是首个原型。全系统采集排除自身输出；尚未实现外放条件下的专用声学回声消除，建议耳机。只区分“我 / 系统声音”两个音频来源，不识别远端个人身份。断网期间持续保存本地音频，字幕重连后继续；缺失字幕不会在会后自动从录音补全。总结质量取决于已经收到的实时原文。

本地构建使用项目专用自签名开发身份，签名材料位于 `~/Library/Application Support/MeetingAssistant/DevelopmentSigning/`，不进入应用包或仓库，不修改证书信任或默认钥匙串。它提供固定的签名身份，但实测本地自签名版本在二进制改变后仍可能需要钥匙串重新授权；此时需要完成系统授权，或在设置中重新填写并保存 Key。

`bash scripts/check-credentials.sh` 使用独立假 Key 验证保存、重启读取、替换、删除，同时明确报告跨版本授权限制。它不读取用户 Key。给其他人正式分发前，应设置 `MEETING_SIGNING_IDENTITY` 使用 Developer ID 签名并完成 Apple 公证，再验收跨升级凭据访问、安装、权限、虚拟设备及三平台兼容性。构建成功与真实模型、录音权限、远端播放验证是不同证据。

完整设计见 [方案](docs/方案.md)。检查命令和待验收范围见 [验证与验收](docs/验证记录.md)。

## Apple 签名与公证

`Resources/MeetingAssistant.entitlements` 包含 Hardened Runtime 下的麦克风权限。指定 `MEETING_SIGNING_IDENTITY` 构建时启用 Hardened Runtime 和安全时间戳。

已有本地 Developer ID Application 身份时，先用它运行 `scripts/check-credentials.sh` 和 `scripts/build-app.sh`，再执行：

```sh
swift scripts/create-archive.swift dist/MeetingAssistant.app dist/MeetingAssistant.xcarchive
```

使用 Xcode 云端 Developer ID 签名时，先以 Apple Development 身份构建应用，再执行：

```sh
swift scripts/create-archive.swift --for-cloud-signing PATH_TO_DEVELOPMENT_APP.app dist/MeetingAssistant-for-signing.xcarchive
```

归档脚本检查证书类型、Hardened Runtime、时间戳、麦克风权限及调试权限。云端签名前归档不是最终分发包；在 Xcode Organizer 中选 Direct Distribution，由具备独立云端 Developer ID 权限的账号完成签名和公证。公证通过后导出、验证票据与 Gatekeeper，再压缩最终应用。每个分发包都需要独立完成这些检查。

没有本地 Developer ID 私钥时，可以通过云端签名完成跨版本凭据验收：

```sh
bash scripts/check-cloud-credentials.sh APPLE_DEVELOPMENT_IDENTITY TEAM_ID
```

此脚本要求 Xcode 已登录并获得云端 Developer ID 权限，分别导出两个签名不同的测试版本，在同一路径测试假 Key 的保存、重启、升级、回退和删除。测试程序包含真实凭据存储实现，但不使用产品的钥匙串条目，也不读取用户 Key；完成后清理测试条目及文件。
