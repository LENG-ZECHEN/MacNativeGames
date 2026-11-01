# 第三方说明

本仓库没有复制其他项目的源代码。下面这些资料提供了协议知识（事实和数据格式），
实现都是本仓库自己写的。

| 资料 | 许可证 | 用到了什么 |
| --- | --- | --- |
| [ndeadly/switch2_controller_research](https://github.com/ndeadly/switch2_controller_research) | 无许可证 | 协议文档（GATT 特征、报告格式、命令、闪存布局）。它的蓝牙抓包**没有放进本仓库**：单元测试运行时由 `tests/fetch_captures.sh` 下载到被 git 忽略的 `tests/captures/`，再解成文本。 |
| [SDL](https://github.com/libsdl-org/SDL) `src/joystick/hidapi/SDL_hidapi_switch2.c` | zlib | 摇杆校准格式、陀螺仪零偏的位置、体感原始轴的方向、"时间戳不是微秒"的现象、HD 震动帧的位布局和默认频率。`tests/test_core.c` 里有一个按 SDL 写法独立实现的对照函数，只用来核对我们的编码结果。 |
| Linux 内核 `drivers/hid/hid-nintendo.c` | GPL-2.0+ | 只参考事实：用户摇杆校准地址和标记、HD 震动的 10 位字段定义、振幅安全上限、命令 0x11 的作用、一代 Pro 手柄的体感轴定义。没有复制代码。 |
| [caqlayan/procon2-mac](https://github.com/caqlayan/procon2-mac) | MIT | 核对过 GATT UUID 和蓝牙下的按键位排列。没有复制代码。 |
| [joaorb64/joycond-cemuhook](https://github.com/joaorb64/joycond-cemuhook) | MIT | DSU 体感的坐标约定。没有复制代码。 |
| [cemuhook-protocol](https://v1993.github.io/cemuhook-protocol/) | — | DSU 协议格式。 |
| [vialoh/switch2mac](https://github.com/vialoh/switch2mac) | 无许可证 | 没有参考它的代码。 |

caqlayan/procon2-mac 的版权声明（MIT，按许可证要求附上，以备将来借用其代码时使用）：

```
Copyright (c) 2026 Arda Caglayan Ercan
```
