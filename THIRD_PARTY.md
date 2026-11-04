# 第三方代码及IP说明

| 内容 | 来源与说明 |
|---|---|
| Baseline JPEG Decoder | Ultra-Embedded.com，Apache License 2.0；见 `fpga/src/user_source/hdl_source/jpeg/LICENSE` 和各源文件头 |
| HDMI 1.4b transmitter | 安路参考工程/IP，保留原文件和声明 |
| SDRAM、PLL、FIFO及底层原语包装 | 安路工具生成文件或参考工程，保留原版权声明；依赖安路TD工具和器件库 |
| 板卡接口与基础模块 | AC601/AC201相关例程，保留随原文件提供的注释和声明 |

本项目实现的媒体文件访问、播放器集成、帧缓存协调、模式交互、OSD及频谱等代码与上述模块共同构成工程。各第三方文件继续适用其原有条款。本次整理未将厂商IP转换为其他许可证，也未包含厂商工具许可证文件。

GitHub仓库不包含博物馆图片、官方宣传片或《烟花易冷》音频文件；演示媒体的来源与使用依据在本地参赛材料中分别维护。
