# Open Design Windows ARM64 绿色版便携重打包工具

这是一个为 Windows 11 ARM64 用户量身定制的、零 Node.js 依赖的自动化重打包工具。用户只需双击运行一个脚本，便能自动获取官方最新版的 x64 程序资源，并替换为原生 ARM64 运行时与依赖项，最终输出完全原生的 Windows ARM64 绿色免安装（便携式）压缩包。

## 🌟 核心特性

- **一键双击运行**：无需在本地配置 Node.js 运行时，也无需安装庞大的 Visual Studio C++ 编译工具链。
- **自动检测最新版本**：自动请求 GitHub API 侦测 Open Design 最新发布的 Tag 标签名。
- **动态依赖解析**：通过 CDN 动态抓取对应版本的 package.json 配置，自动匹配准确的 Electron 运行时版本、WiseLibs 预编译 `better-sqlite3` 版本以及 `node-pty` 版本。
- **自适应网络下载**：
  - 启动时支持交互式输入本地代理端口并检测可用性。
  - 若无本地代理（直接按回车跳过或连接失败），自动切换为国内分流反代加速源 `https://gh.llkk.cc/` 和淘宝 `npmmirror` 镜像源，确保国内网络环境跑满带宽。
- **PE 图标自动注入**：自动下载官方轻量的 `rcedit-x64.exe`，为主程序 `Open Design.exe` 注入官方的 `.ico` 图标。
- **超高速归档**：使用 Windows 系统自带的原生 `tar.exe` 进行解压与压缩，数秒内即可完成打包。

## 📋 运行要求

- **操作系统**：Windows 10 / 11 ARM64（利用系统内置的 x64 模拟机制执行轻量的图标注入工具）
- **内置工具**：系统自带的 `curl.exe` 和 `tar.exe`（通常默认已包含在 Windows 10/11 系统中）
- **网络连接**：正常连接互联网

## 🚀 使用方法

1. 下载本仓库的压缩包，并解压到您的本地磁盘（例如：`C:\tools\open-design-repack`）。
2. 双击运行根目录下的 **`repackage.bat`**。
3. 命令行窗口启动后，会提示输入代理配置：
   ```text
   请输入本地代理端口号 (如 7890，直接按回车跳过):
   ```
   - 如果您开启了本地代理（如 Clash/V2Ray 等），请输入其端口号（如 `7890`），脚本会自动进行测试和应用。
   - 如果您没有本地代理，**请直接按回车跳过**，脚本会自动应用在线加速镜像源进行极速下载。
4. 脚本将自动完成所有下载、解压、原生模块替换、图标注入和归档拼装工作。
5. **打包产物**：构建成功后，最终的原生 Windows ARM64 绿色版便携 ZIP 归档将保存在本地的如下目录中：
   ```text
   .tmp/repackage-ps1/open-design-<最新版本号>-win-arm64-portable.zip
   ```

## 🛠️ 文件结构说明

重打包工具仅包含以下轻量级文件，其余均为构建过程中的临时缓存，已被 `.gitignore` 自动忽略，不影响 Git 提交：
- `repackage.bat`：一键批处理启动入口
- `scripts/repackage.ps1`：核心 PowerShell 自动化重组脚本
- `.gitignore`：Git 忽略配置（忽略 `.tmp/` 缓存）
- `README.md`：本使用指南

## ⚖️ 许可证 & 免责声明

本工具仅用作将 [nexu-io/open-design](https://github.com/nexu-io/open-design) 的官方发布版在本地重构组装为 Windows ARM64 架构，其包含的核心软件、运行时与二进制库（如 Electron, WiseLibs better-sqlite3, node-pty）的版权及许可证均归其原作者和官方所有。
