# SedentaryDebuff（久坐 Debuff）

macOS 原生小工具：启动后出现**设置窗口**，可在其中调节久坐阈值与 debuff 图标。计时从启动或清除 debuff 后开始；超过阈值后出现仿魔兽风格的 **debuff 浮窗**：外框使用资源 **`border.png`**，技能图默认使用 **`sentinel-juggernautstance-128.png`**（可被用户自选图片覆盖）。图标下方为计时（分钟，一位小数 + `m`）。**双击** debuff 浮窗可清除状态并重新计时。

配置项：

- **久坐多久后出现 debuff**：滑块调节（约 0.1～240 分钟，默认 45 分钟）。
- **自定义 debuff 图标**：选择本地图片；「恢复默认」即重新使用包内 `sentinel-juggernautstance-128.png`。

## 资源文件

外框与默认图标位于 `Sources/SedentaryDebuff/Resources/`：

| 文件 | 用途 |
|------|------|
| `border.png` | debuff 浮窗外框（叠放图标与计时文字） |
| `sentinel-juggernautstance-128.png` | 默认 debuff 图标 |

可自行替换同名文件后重新编译；请保持文件名不变。

## 环境要求

- macOS 13 或更高版本  
- [Swift](https://www.swift.org/) 5.9+（随 Xcode 或 Command Line Tools 安装）

## 使用命令行编译与运行

在项目根目录（含 `Package.swift` 的目录）执行：

```bash
cd /path/to/debuff
swift build -c release
```

运行 Release 构建产物：

```bash
./.build/release/SedentaryDebuff
```

调试构建可直接：

```bash
swift run SedentaryDebuff
```

首次运行若出现来自未签名本机工具的 Gatekeeper 提示，可在「系统设置 → 隐私与安全性」中按需允许，或在右键菜单中选择打开。

## 使用 Xcode 编译与运行

1. 打开 Xcode，选择 **File → Open…**，选中本仓库中的 **`Package.swift`**（不要只选文件夹）。
2. 等待依赖解析完成后，在顶部 Scheme 中选择 **`SedentaryDebuff`**，运行目标为 **My Mac**。
3. 使用 **⌘R**（Product → Run）启动应用，在**设置窗口**中调节参数。

## 行为说明

- **计时起点**：应用启动时，或你 **双击 debuff 浮窗** 清除后。
- **浮窗计时**：从「久坐时间首次达到阈值」的时刻起算，展示为 `XX.Xm`（一位小数）。
- **配置持久化**：阈值与自定义图标路径保存在本机 `UserDefaults` 中。

## 许可证

按你的需要自行补充（例如 MIT 或专有许可）。
