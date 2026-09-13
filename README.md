<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Formora 图标">
</p>

<h1 align="center">Formora</h1>

<p align="center">给独立开发者的 macOS 多 Agent 工作台</p>

每个 Agent 对应一个真实岗位——产品设计、研发、测试、数据分析、运营——一个需求在这些岗位之间流转。你是老板，Agent 是替你干活的同事：它们在你的项目文件夹里读写文件、跑命令、上网查资料，每一步都摆在你眼前，要紧的步骤等你点头。

Formora 是原生的 macOS 应用（SwiftUI），不需要自己的服务器：模型用你自己的 API Key 直接调用，对话、文件和记忆都留在你的电脑上。

## 下载安装

1. 到 [Releases](https://github.com/Eugeneheng1020/Formora-App/releases) 下载最新的 `Formora-<版本>.dmg`。
2. 打开 dmg，把 Formora 拖进「应用程序」。
3. 第一次打开时，macOS 会提示无法验证开发者：这个版本还没有经过苹果公证。到「系统设置 → 隐私与安全性」，在页面下方找到 Formora，点「仍要打开」；或者在「应用程序」里按住 Control 键点 Formora，选「打开」。之后就能正常打开了。

需要 macOS 14 或更新。用之前准备一个模型服务商的 API Key：OpenAI、Anthropic、Google Gemini、DeepSeek、通义千问等，或者任何兼容 OpenAI 接口的服务。Key 存在 macOS 钥匙串里。

## 它能做什么

- **项目**：一个项目就是你电脑上的一个文件夹。对话和 Agent 写的文件都跟着项目走，Agent 只能进你授权给它的项目。
- **消息**：单聊找一个 Agent；群聊里 @ 谁就交给谁，不 @ 就按任务性质自动分配。几个人同时开工时，每人在自己的项目副本里干活，做完再合回来，不会互相覆盖。
- **看得见、管得住**：Agent 的每一步都是对话里的一张卡片。改文件前能先看改动，改完能一键撤销；要你批准的步骤停在卡片上等你点「允许」，也可以让它在这个对话里、或在这个项目里以后都不再问。
- **看板**：对话的另一种看法。一次派活是一张卡片，谁交给了谁用线连着，能直接在画布上补充要求、把活接着派下去。
- **文件**：当前项目的文件树和预览，Agent 写的文件都在这里。
- **旁审**：另一个模型在旁边看 Agent 干活，有问题就提醒它；`/review` 让它把最近一轮完整审一遍，按 P0–P3 列出问题。
- **更多**：
  - 回到之前的某条消息改了重发；
  - `/side` 岔开问一句，不打扰主对话；
  - 长时间的命令放到后台跑；
  - 读项目里现成的 `AGENTS.md`、`CLAUDE.md`；
  - 只在 Agent 违反时才出现的规则；
  - 按项目记住偏好和约定，很久没用到的记忆不再给它看；
  - Skills、MCP 服务、Hooks；
  - 让 Agent 看屏幕、点按、打字，替你操作电脑（要先在系统设置里授权）。
- **Bob**：设置里的助手，回答关于 Formora 的问题，替你接入 MCP、创建 Skill；群聊里还负责安排谁先做、谁同时做。
- **密钥保护**：你在对话里贴的 Key 不会原样发给模型，也不会被记进记忆。

## 从源代码编译

需要 macOS 14 或更新、Xcode 26，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
git clone https://github.com/Eugeneheng1020/Formora-App.git
cd Formora-App
xcodegen generate
open Formora.xcodeproj
```

在 Xcode 里选 Formora 方案运行。

**签名**：工程默认用本地签名（ad-hoc），不需要开发者账号就能编译运行。想用自己的开发团队签名，在 `project.yml` 里设置 `DEVELOPMENT_TEAM`，把 `CODE_SIGN_STYLE` 改回 `Automatic`，并删掉 `CODE_SIGN_IDENTITY`。

**两种版本**（`project.yml` 里的配置）：

| 配置 | 用途 |
|---|---|
| Debug | 开发时用，就是官网版：不带沙盒，支持操作电脑、在本机启动 MCP 服务 |
| ReleaseDeveloperID | 官网版的正式构建，安装包用它 |
| Release | App Store 版，带沙盒 |

## 打安装包

```sh
bash package.sh            # 默认输出到桌面
bash package.sh <输出目录>
```

脚本会生成工程、归档 ReleaseDeveloperID 配置，然后做一个拖进「应用程序」安装的 `Formora-<版本>.dmg`。签名照 `project.yml` 的设置。要让别人下载后不经提示就能打开，需要用 Developer ID 证书签名并经过苹果公证（要加入 Apple Developer Program）。

## 项目结构

```
App/            源代码（SwiftUI），含图标（AppIcon.icon 给 macOS 26，Assets.xcassets 给更早的系统）和权限配置
Resources/
  Fonts/          Sora、JetBrains Mono
  Preview/        文件预览用的 marked、highlight.js
  ProviderLogos/  模型服务商的标志
  Knowledge/      Bob 的说明文档
  Skills/         内置的 Skills
project.yml     XcodeGen 的工程描述
package.sh      打安装包的脚本
```

## 许可

[PolyForm Noncommercial 1.0.0](LICENSE)：源代码公开，可以免费用于非商业用途，比如个人使用、学习、研究、非营利组织；商业用途需要另外取得作者授权。

Required Notice: Copyright (c) 2026 Eugene Cheng (https://github.com/Eugeneheng1020)

用到的第三方字体和脚本各有自己的许可，见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
