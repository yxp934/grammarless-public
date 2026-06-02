# Grammarless

Grammarless是Grammarly、秘塔写作猫这类写作辅助工具的开源平替。在任意输入场景都能纠错语法、拼写帮忙改写问题，支持双语。

现只有Mac版因为我没windows电脑。

项目起因：经常需要英文、中文写作，我不喜欢直接让AI帮我写完放进去，而是Grammarly这种无感的提示，但是Grammarly月费30刀而且对话功能一坨屎，还不支持中文，秘塔写作猫几年没更新了，就自己做了。

项目定位：**开源、本地优先、BYOK（Bring Your Own Key，自带模型与密钥）**。仓库不内置 API Key，也不绑定特定模型厂商；你可以接入任意兼容 OpenAI `/v1/chat/completions` 的服务。

> 当前版本是 `0.0.1` 尚未 notarize。首次运行需要在 macOS 系统设置中授予 Accessibility 权限。
>
> “Grammarly / 秘塔写作猫”仅用于说明产品定位；Grammarless 与上述产品或公司没有从属、合作或背书关系。

## 核心功能

- **英文直接语法报错**：本地检查英文拼写、混淆词和常见语法模式，并在文本旁显示错误提示与替换建议。
- **中文写作处理**：中文内置轻量离线规则用于基础错别字、标点和模式提示；更自然的中文润色、改写、语气调整和篇章分析建议接入 LLM 处理。
- **一键唤出对话修改**：在任意可访问文本框中呼出 Grammarless，对选中文本或当前上下文发起对话式改写。
- **详细分析文章**：支持长文侧边栏，对文章结构、表达、逻辑、风格和可读性做更细的分析与修改建议。
- **结构化补丁预览**：AI 修改会以 patch 形式展示，方便预览、应用和回滚。
- **原生 macOS 体验**：使用 AppKit / SwiftUI 构建悬浮层、建议卡片、设置页和替换流程。

## 模型与 BYOK

Grammarless 不提供托管模型，也不上传密钥。你需要在设置中配置自己的模型服务：

- Base URL：任意 OpenAI-compatible endpoint，默认 `http://127.0.0.1:8317/v1`
- API Key：你自己的密钥，默认通过 Keychain 保存
- Model：你的服务支持的模型名

建议使用快模型，因为写作助手需要频繁、低延迟地处理选中文本和短上下文。长文分析可以切换到更强模型。

默认开发配置为：

```text
Base URL: http://127.0.0.1:8317/v1
Model: gpt-5.4-mini
API Key: sk-xxx
```

## 语言处理策略

Grammarless 坚持本地优先：

- 英文：拼写、常见混淆词、基础语法模式可直接在本地提示错误。
- 中文：基础错别字、标点、日期金额、序列和专名等规则可离线提示；高质量中文语义润色、重写和文章分析建议使用用户配置的 LLM。
- 自动 CJK 基础校对不会捆绑第三方大模型权重或外部中文模型。
- LLM 功能只会请求你在设置中配置的 endpoint。

## 下载预编译版本

前往 [Releases](https://github.com/yxp934/grammarless-public/releases) 下载 `Grammarless-0.0.1-macOS.zip`，解压后运行 `Grammarless.app`。

由于当前发布包是 ad-hoc signed 且尚未 notarize，macOS 首次打开时可能需要在 Finder 中右键应用选择“打开”，并在系统设置中授予 Accessibility 权限。

## 快速开始

```bash
git clone https://github.com/yxp934/grammarless-public.git
cd grammarless-public

xcodebuild build \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData

open .build/DerivedData/Build/Products/Release/Grammarless.app
```

首次启动后，请在 macOS System Settings 中授予 Grammarless Accessibility 权限，否则应用无法读取或替换当前输入框中的文本。

## 开发与测试

重新生成 Xcode 工程（源文件结构变更时）：

```bash
ruby scripts/generate_xcodeproj.rb
```

运行测试：

```bash
xcodebuild test \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData
```

构建 Debug 版本：

```bash
xcodebuild build \
  -project Grammarless.xcodeproj \
  -scheme Grammarless \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData
```

## 项目结构

```text
Grammarless.xcodeproj/       Xcode project
GrammarlessApp/              macOS app、Accessibility 集成、悬浮 UI、设置、文本替换流程
GrammarlessCore/             模型配置、本地校对、LLM client、agent、memory、patch 解析
GrammarlessCoreTests/        Core 单元测试
scripts/                     工程生成和临时签名辅助脚本
```

## 隐私与安全

- 仓库不包含 API Key。
- 用户 API Key 默认通过 Keychain 保存。
- 本地校对使用 Swift 原生规则与词典资源。
- LLM 功能只把选中文本或必要上下文发送到用户配置的 endpoint。
- 当前版本是开发者预览版，发布包为 ad-hoc signed，尚未 notarize。

## 已知限制

- 当前版本为 `0.0.1` 早期预览，功能和交互仍在快速变化。
- macOS Accessibility 在不同宿主应用中的表现可能不一致。
- Microsoft Word 等富文本编辑器仍需要更多生产级验证。
- 离线校对偏保守，中文高质量润色和长文分析建议使用 LLM。

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
