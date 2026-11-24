# 基于FPGA的博物馆多媒体展示终端

基于安路 EG4S20BG256、AC601 核心板和 AC201 底板的离线多媒体展示终端。本仓库保存最终选用的 **C14116 seed2** 位流及对应工程代码，以湖北省博物馆为应用场景。

## 最终位流

- 文件：[bitstream/c14116_seed2.bit](bitstream/c14116_seed2.bit)
- 板端版本：`00C14116`；placement seed：`2`
- 大小：634,280 字节
- SHA256：`c495c39ef41427330c391c106ded7192ab6bc0b5b0ed879b5f91e58783af212a`
- TD：6.2.1_SP1 / 6.2.178.840
- 原始构建日期：2026-11-03

使用者于2026-11-04确认采用seed2并反馈运行稳定。归档构建元数据中的 `BOARD_PENDING` 保留生成时状态；该反馈为后续实物使用观察，未附长时计时或循环次数量测。

## 功能

- FAT32 TF卡读取BMP、WAV和MJP1媒体文件。
- BMP24解析、RGB888图片缓存、最近邻等比缩放与居中、手动切图、自动轮播、上下擦除转场。
- JPEG视频帧解码、RGB565视频缓存、视频暂停/继续/重播。
- HDMI画面与48kHz PCM音频输出；图片背景音乐与视频解说按模式选择。
- 1024点FFT、24频带频谱、冻结/恢复；图片模式显示频谱。
- 亮度与对比度调节、参数OSD、图片状态、运行计时、滚动字幕和视频FPS统计。

当前演示画布为640×480，省博视频素材为31秒/465帧/15fps目标；实际更新帧率由板端FPS计数显示。当前四张海报实际尺寸均为640×480。

## 按键

板上功能键按实物命名为KEY0、KEY1；RTL顶层端口 `key1`、`key2` 分别连接这两个键。

| 操作 | 功能 |
|---|---|
| KEY0短按 | 图片下一张；视频从头重播 |
| KEY1短按 | 图片自动轮播开关；视频暂停/继续 |
| KEY0长按约1.5秒 | 普通播放→亮度→对比度→普通播放 |
| 调节模式下KEY0 / KEY1短按 | 减小 / 增大参数 |
| 双键短按并松开 | 图片频谱冻结 / 恢复 |
| 双键长按并全部松开 | 图片 / 视频模式切换 |

## 目录

- `fpga/src/`：与原seed2综合输入对应的RTL、IP、约束、ROM及TD工程。
- `fpga/scripts/`：分阶段综合、布局布线、hold修复、位流生成及证据校验。
- `tools/`：工具定位和发布文件校验。
- `bitstream/`：已生成的最终seed2位流。
- `evidence/`：seed2最终时序、资源、实际place/route参数及输入校验信息。
- [THIRD_PARTY.md](THIRD_PARTY.md)：第三方代码和IP说明。

原seed2与seed1使用同一综合gate，实际placement参数为2。发布整理只调整路径、注释中的本机位置及构建入口，剔除一个未使用的调试备份；RTL运算和控制逻辑保持。详细逐文件原始/发布哈希见 `evidence/source_integrity.json`。预编译位流原字节保留。

## 构建

环境：Windows、PowerShell 7、有效许可的安路TD及EG4S20设备支持。先把TD的bin目录加入PATH，或将 `ANLU_TD_BIN` 设置为本机安装目录的绝对路径。

从仓库根目录执行：

```powershell
python tools/verify_release.py
pwsh -NoProfile -File fpga/scripts/build_candidate.ps1 -Stage synthesis
pwsh -NoProfile -File fpga/scripts/build_candidate.ps1 -Stage physical
pwsh -NoProfile -File fpga/scripts/build_candidate.ps1 -Stage hold
pwsh -NoProfile -File fpga/scripts/build_candidate.ps1 -Stage bitstream
```

脚本自动定位当前TD工程路径，physical阶段固定seed2。首次综合应从源码开始；本仓库不包含旧gate数据库。新构建输出在 `fpga/build/manual/`，位流文件名为 `AC201_player_c41_museum_osd.bit`。脚本保留输入/阶段一致性及最终时序门槛。

发布整理后完成了文件、源范围、项目引用和脚本语法核查；本轮未重新编译。重新构建的结果应以本次TD输出和时序报告为准，预编译位流身份由上方SHA256确定。

## Seed2实现结果

| 项目 | 结果 |
|---|---:|
| LUT | 17,561 / 19,600 |
| 寄存器 | 8,864 / 19,600 |
| BRAM | 62 / 64 |
| DSP | 26 / 29 |
| Setup WNS / TNS | +0.804 ns / 0 |
| Hold WNS / TNS | +0.027 ns / 0 |

数据来自本仓库 `evidence/final.area`、`final.ts`，实际seed参数保存在 `actual_params.place.log`。

## TF卡文件

配套FAT32卡根目录使用 `01.BMP`–`04.BMP`、`BGM.WAV`、`TEST.WAV`、`VIDEO.MJP`。本次GitHub发布范围为位流与代码；省博参考图片、宣传片节选、伴奏等第三方演示媒体留在本地交付包，使用时请自备适用素材或取得相应使用依据。

## 代码与IP

JPEG解码基于Ultra-Embedded Baseline JPEG Decoder，Apache-2.0许可证保留在源码目录。HDMI发送、SDRAM及其他厂商模块保留其原始版权声明。本仓库包含不同来源的工程文件，各文件按其上游条款使用；未对混合工程额外指定统一开源许可证。工具安装包、许可证密钥与个人缓存均未纳入发布。

## 工程与文档双仓架构

本项目在长周期硬件开发与板端联调过程中，采用**交付展示仓 + 工程代码仓 + 硬件资料仓**分离的组织方式，配合薄 `AGENTS.md` 与任务按需读取路由，避免长会话上下文膨胀并保障跨会话稳定接续：

| 仓库 | 角色定位 | 核心内容 |
| --- | --- | --- |
| **[FPGA-multimedia-player](https://github.com/XiAzir/FPGA-multimedia-player)**（本仓） | 最终交付与复现展示仓 | 面向评审与复现的完整说明、最终位流 `c14116_seed2.bit` 及资源/时序收敛结果（LUT 17,561/19,600、BRAM 62/64、DSP 26/29、Setup `+0.804 ns` / Hold `+0.027 ns`、`TNS = 0`） |
| **[FPGA-ANLU](https://github.com/XiAzir/FPGA-ANLU)** | 主工程源码与构建仓 | 薄 `AGENTS.md` + 任务按需读取路由表，以及 `bringup/`、`build/`、`deliverables/`、`development/`、`planning/`、`scripts/` 全周期工程目录 |
| **[FPGA-ANLU-docs](https://github.com/XiAzir/FPGA-ANLU-docs)** | 独立硬件资料与留档仓 | 板卡引脚约束、开发约定、阶段开发排障记录与跨会话接续入口 `当前状态.md` |
