# Portly 宣传网站

公开地址：<https://icebigpig.github.io/portly/>。

纯 HTML、CSS、JavaScript，无框架、运行时 CDN 或第三方追踪。网站源文件独立存放于 `website/`，Flutter 应用原有 `web/` 目录继续用于应用构建。

## 本地预览

在仓库根目录运行：

```sh
node --test website/tool-core.test.mjs
python3 website/build.py
python3 -m http.server 4173 --directory dist/website
```

打开 <http://localhost:4173/>。中文是默认语言；`?lang=en` / `?lang=zh` 可分享指定语言，语言选择会保存在浏览器本地。

## 内容与交互

- `index.html`：中文默认文案、结构、SEO 与静态下载回退链接。
- `app.js`：英文文案、双语切换、演示工作台、命令参数、工具箱、下载选择与预览弹窗。
- `styles.css`：桌面、手机与横屏适配，包含减少动态效果设置。
- `tool-core.mjs`：CRC16 / Modbus、64 位整数进制转换、字节顺序、NMEA XOR 校验的纯函数。
- `release.json`：经核实的公开版本和实际附件地址，用于离线构建及网络失败时回退。
- `assets/`：沿用应用图标和 JetBrains Mono（OFL-1.1）字体；社交分享图为网站原创排版。

工作台使用明确标注的演示报文，不连接真实设备。工具箱计算在浏览器本地完成。

## GitHub Pages 发布

仓库 Settings → Pages → Build and deployment → Source 选择 **GitHub Actions**。

`.github/workflows/pages.yml` 会在以下情况构建并部署：

1. `main` 的网站文件或 Pages 工作流发生变化。
2. 一个新版本的 GitHub Release 正式公开（草稿不触发）。
3. 在 Actions 手动运行 Deploy Portly website。

部署时通过 GitHub 公共 API 解析最新稳定版并核实 macOS、Windows x64 / ARM64 安装器与便携包。生成静态 `release.json`，同时更新 HTML 默认版本和下载地址；浏览器无须请求 GitHub API。

本地同步最新公开版本：

```sh
python3 website/build.py --refresh-release
```

仅修改网站不会触发桌面发布流水线。现有二进制包与版本标签保持独立。
