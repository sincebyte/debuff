# debuff 宣传页资源

`../index.html` 是 debuff 的宣传落地页，图片资源都在本目录。

## 文件

| 文件 | 说明 |
|------|------|
| `appicon.png` | 应用图标（来自 `App/appicon.png`） |
| `show-real.png` | 「What is debuff」配图：实机截图（来自仓库根目录 `show.png`） |
| `shot-desktop.png` | 桌面场景：菜单栏 + 三枚 debuff 浮窗（首屏主图） |
| `shot-hud.png` | debuff 浮窗特写（微信 / 飞书 / 久坐） |
| `shot-waveform.png` | 语音输入波形指示条 + 缓冲文本 |
| `shot-waveform-loading.png` | 「转译中」进度条 |
| `DepartureMono-Regular.otf` | debuff 计时文字所用等宽字体 |

## 重新生成截图

界面截图不是从运行中的 App 抓的（本机截图权限受限），而是用 `_src/*.html`
按真实视图代码还原的 UI，再用 macOS 自带的 WebKit 渲染成 PNG：

```bash
cd promo
# 渲染（qlmanage 固定以 1024px 视口渲染，s=1024 时 1:1）
qlmanage -t -s 1024 -o /tmp/shots _src/shot-hud.html
# 裁掉多余留白（设计稿左上角对齐）
python3 - <<'PY'
from PIL import Image
Image.open('/tmp/shots/shot-hud.html.png').convert('RGBA').crop((0,0,560,300)).save('shot-hud.png')
PY
```

各截图的裁切尺寸见 `_src/*.html` 里的 `body` 宽高：

- `shot-hud` → 560 × 300
- `shot-desktop` → 1000 × 600
- `shot-waveform` → 1000 × 400
- `shot-waveform-loading` → 1000 × 400

（`_src/shot-menu.html` 为菜单栏设置菜单的备用源文件，页面上的设置区已移除。）

> 注意：`qlmanage` 不执行页面里的 JavaScript，所以波形等动态元素需要在
> HTML 里静态展开（`_src/shot-waveform.html` 已改为静态标签）。

## 在本地预览落地页

```bash
cd ..            # 仓库根目录
python3 -m http.server 8765
# 浏览器打开 http://127.0.0.1:8765/index.html
```
