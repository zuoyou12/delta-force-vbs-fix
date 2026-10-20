<p align="center"><img src="docs/assets/banner.svg" alt="Delta Force VBS Fix Toolkit" width="100%"></p>

# 三角洲行动 CPU 虚拟化工具包 2.0

辅助排查国服“未开启或有其他软件占用 CPU 虚拟化功能”提示。提供只读诊断、按项修复、修改前备份与原配置恢复。参考[腾讯游戏安全指引](https://gamesafe.qq.com/article/1181.shtml)，本项目为第三方工具。

**适用环境：Windows 10 / 11 x64，内置 Windows PowerShell 5.1。** 无需安装 Python、Node.js 或 MCP。

## 下载与开始使用

下载 [2.0 完整工具包](docs/downloads/delta-force-vbs-fix-2.0.0.zip)，并核对 [SHA-256](docs/downloads/delta-force-vbs-fix-2.0.0.sha256)。也可以下载整个源码目录。

1. 如果 ZIP 属性中有“解除锁定”，先解除，再完整解压。保留 `scripts` 文件夹，与三个 BAT 放在一起。**不要单独下载一个 BAT。**
2. 运行 `diagnose-vbs.bat` 查看本机状态。普通权限可运行；需要权限或查询失败的检查显示“未知”，建议管理员运行获得更完整结果。
3. 保存工作。确有需要时，右键 `fix-vbs.bat` → **以管理员身份运行**，按诊断与实际游戏弹框选择菜单。每次修改需要在工具中输入 `APPLY`。
4. 重启后再次运行诊断，核对实际状态，再进游戏验证。
5. 需要恢复时，管理员运行 `restore-vbs.bat`，输入 `RESTORE`。它只恢复本机 2.0 活动备份中的原配置。若 Windows 功能处于待重启状态，重启后再次运行恢复完成校验。

诊断页位于 `docs/index.html`，可直接用浏览器打开。页面只能根据问答给出建议，无法读取电脑状态。部署 GitHub Pages 时请一并发布 `docs/downloads`。

## 这一版改了什么

- 修复旧 BAT 菜单中无条件跳转、输入复用与错误处理问题。BAT 变为 ASCII 启动入口，中文 PowerShell 源码为 UTF-8 BOM，兼容 Windows PowerShell 5.1。
- 每项修改前持久保存原值，再执行并校验。重复修复保留第一次基线；失败保留备份，不输出笼统的“全部成功”。
- 恢复精确到配置值：原本不存在的值删除，原本禁用的功能维持禁用。原启动项未显式配置 hypervisorlaunchtype 时，恢复为未显式配置。
- 修复 `LsaCfgFlags` 路径，使用 `SYSTEM\CurrentControlSet\Control\Lsa`。不再写入旧版误用的 DeviceGuard 同名项。
- 菜单 5 收窄为基础修复，不再批量关闭 Hello、HVCI、Windows 功能或 Credential Guard。
- Windows Hello 改为手动指引，不再声称修改某个注册表值可以代替关闭指纹、面部识别或 PIN。
- 诊断失败显示未知，区分安装配置与实际运行状态，导出 JSON 报告。网页下载改为完整 ZIP，修复复选框重复切换与损坏本地设置导致页面中断的问题。

详见 [CHANGELOG.md](CHANGELOG.md)。

## 修复菜单

| 菜单 | 操作 | 影响与范围 |
| --- | --- | --- |
| 0 | 退出 | 不修改配置 |
| 1 | 当前启动项 `hypervisorlaunchtype=Off` | 禁止 Windows hypervisor 随启动加载，重启生效；影响依赖它的 WSL2、Docker、虚拟机等 |
| 2 | Windows Hello 指引 | 可打开“账户 → 登录选项”；不会改动 PIN、指纹、面部数据 |
| 3 | HVCI `Enabled=0` | 关闭内存完整性配置，降低内核保护；写入前备份原值或不存在状态 |
| 4 | 禁用三个目标虚拟化功能 | 对已启用的 `Microsoft-Hyper-V-Hypervisor`、`VirtualMachinePlatform`、`HypervisorPlatform` 操作；备份相关功能状态以覆盖依赖变化 |
| 5 | 按诊断执行基础修复 | 检测到 VBS 已配置或 hypervisor 运行时执行菜单 1；诊断失败则停止 |
| 6 | 高级本地配置处理 | 只将已存在的 VBS、HVCI、LSA Credential Guard 配置归零；不创建缺失配置，不改组策略 |
| 7 | 重启 | 输入 `REBOOT` 后安排 30 秒后重启；可用 `shutdown /a` 取消 |
| 8 | 只读诊断 | 与诊断 BAT 相同 |

**菜单 1 / 5 即使没有卸载 Hyper-V，也会影响依赖 hypervisor 的软件。** 它们不是保留 WSL2 / Docker 正常运行的绕过方案。

工具检测到列出的 Device Guard 策略或 UEFI 锁时会停止修复。域策略、MDM、固件锁和系统默认启用机制可能需要管理员进一步检查，脚本不保证枚举所有管理来源。

## 诊断如何理解

检查 CPU 虚拟化属性、HypervisorPresent、BCD 启动配置、Win32_DeviceGuard、相关 Windows 功能、指定注册表值、策略与锁、杀毒软件列表。

- `VirtualizationBasedSecurityStatus`：0 未启用，1 已启用但未运行，2 正在运行。读取失败显示未知。
- `SecurityServicesRunning` 中 1 代表 Credential Guard，2 代表内存完整性。配置值和实际运行状态可能不同。
- hypervisor 运行时 CPU 的部分属性可能被屏蔽，不应仅凭 `VirtualizationFirmwareEnabled=False` 就判定 BIOS 没开。
- CPU 查询不能证明 VT-d / IOMMU 已开启。按主板或整机厂商文档核对 BIOS，通常是 VT-x / SVM 与 VT-d / IOMMU；具体名称和进入按键因机型而异。
- Windows 功能 `Enabled` 代表功能已启用，不证明它当前运行；第三方杀软或 Windows Hello 的存在也不能证明它是弹框原因。
- 工具不修改 BIOS，不自动关闭或卸载杀软。登录选项需要用户按官方指引手动核对，先确认账户密码。

## 备份、日志与恢复

| 内容 | 位置 |
| --- | --- |
| 活动备份 | `%ProgramData%\DeltaForceVbsFix\active.json` |
| 操作日志 | `%ProgramData%\DeltaForceVbsFix\operations.log` |
| 已完成恢复的历史备份 | 同目录 `restored-*.json` |
| 诊断报告 | `%LOCALAPPDATA%\DeltaForceVbsFix\Reports\diagnostic-*.json` |

修复与恢复使用管理员受限目录保存状态，同一时间仅允许一个修改会话。备份写入失败即停止对应修改；恢复前校验本机标识、启动项与操作白名单。正在恢复的基线不能被新修复覆盖。

恢复中断或失败后，保留 `active.json`，排除错误后重新运行恢复。Windows 功能的启用/禁用可能需要重启后才能最终核对；此时备份继续保留。重启后运行恢复完成校验，成功才归档活动备份。

备份记录配置原值，不是完整系统镜像。不要手动编辑或删除活动备份，也不要在尚未恢复时另行更改相同配置，否则恢复会以备份中的原值为准。功能列表、Windows 版本或启动项发生变化时可能需要手动处理。手动 BIOS、登录凭据与其他软件的修改不在备份范围内。

**升级前已用旧版修改过系统的用户：2.0 无法推断旧版修改前的设置。** 没有本机 2.0 活动备份时，恢复脚本会退出，不会把所有安全特性一律打开。请结合个人原配置与[腾讯恢复指引](https://gamesafe.qq.com/article/1182.shtml)处理；新备份以第一次运行 2.0 修复时的状态为基线。

## 开发与验证

```powershell
# 无需管理员：模拟系统状态与写入适配器，不修改真实注册表、BCD 或 Windows 功能
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/mock-tests.ps1

# 创建固定版本的分发包与 SHA-256，写入 docs/downloads
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build-release.ps1
```

测试覆盖原值/不存在状态恢复、重复修复、备份失败、写入失败、诊断未知、策略/锁阻断、待重启、恢复重试与并发锁。测试不能替代不同 Windows 版本、硬件与重启后的系统验收。当前版本未在本机实际执行关闭安全特性的操作。

```text
.
├── diagnose-vbs.bat
├── fix-vbs.bat
├── restore-vbs.bat
├── scripts/
│   ├── vbs-toolkit.ps1       # 菜单与运行入口
│   ├── VbsToolkit.psm1       # 诊断、持久备份与恢复核心
│   └── build-release.ps1
├── tests/mock-tests.ps1
├── docs/index.html
├── docs/downloads/          # 完整 ZIP 与校验值
├── README.md
└── CHANGELOG.md
```

## 参考与许可

- [腾讯游戏安全：CPU 虚拟化排查](https://gamesafe.qq.com/article/1181.shtml)
- [腾讯游戏安全：恢复指引](https://gamesafe.qq.com/article/1182.shtml)
- [微软：虚拟化软件与 Hyper-V 及依赖功能](https://learn.microsoft.com/en-us/troubleshoot/windows-client/application-management/virtualization-apps-not-work-with-hyper-v)
- [微软：内存完整性与 Win32_DeviceGuard](https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity)
- [微软：配置 Credential Guard 与 UEFI 锁](https://learn.microsoft.com/en-us/windows/security/identity-protection/credential-guard/configure)

本工具按 MIT 许可提供，见 [LICENSE](LICENSE)。修改系统安全配置有实际影响，请先保存工作，按需创建系统还原点。工具无法保证解决所有游戏弹框或账号处理结果。
