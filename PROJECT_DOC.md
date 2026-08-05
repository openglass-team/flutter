# OpenGlass AI 智能眼镜 — 项目完整文档

## 一、项目概述

基于 **XIAO ESP32S3 Sense** 的 AI 智能眼镜，具备实时照片传输、GPS 定位、AI 视觉问答、会议语音识别等功能。手机端使用 Flutter 开发，通过 BLE + WiFi TCP 与眼镜通信。

- **团队**: openglass-team
- **许可证**: MIT (基于 BasedHardware/OpenGlass)
- **固件版本**: v3.1
- **App 版本**: v1.0.25

---

## 二、硬件架构

| 组件 | 型号 | 接口 | 说明 |
|------|------|------|------|
| MCU | XIAO ESP32S3 Sense | - | 双核 240MHz, 8MB PSRAM |
| 麦克风 | MSM261 PDM | GPIO41(DATA), GPIO42(CLK) | 内置 PDM 数字麦 |
| 摄像头 | OV2640 | 8-bit DVP | SVGA 800x600, JPEG |
| GPS | GT-U8 | UART RX=1, TX=0 | 9600bps, NMEA |
| LED | GPIO21 | - | 会议录音指示灯 |

---

## 三、完整数据链路

### 3.1 照片传输链路
```
OV2640 → esp_camera (JPEG编码, SVGA) → TCP 8080 → [4字节长度+JPEG数据] → Flutter App → 实时显示
```
- 帧率: ~8-15 FPS (取决于 WiFi 质量)
- 格式: 4 字节小端长度前缀 + JPEG 二进制数据
- TCP 分包处理: Flutter 端使用缓冲区拼包 (`_buf` + `_len`)

### 3.2 GPS 定位链路
```
GT-U8 → Serial2(9600bps) → TinyGPS++ 解析 → BLE UUID 19B10003 → 22字节二进制包 → Flutter App → 高德地图显示
```
- GPS 数据包格式 (22 bytes):
  ```
  [0-1] uint16 frame_count
  [2]   uint8  fix (1=有效)
  [3]   uint8  satellites
  [4-7] float32 latitude (WGS-84)
  [8-11] float32 longitude (WGS-84)
  [12-15] float32 altitude
  [16-19] float32 speed (m/s)
  [20-21] reserved
  ```
- Flutter 端做 WGS-84 → GCJ-02 坐标转换
- 轨迹: 每 10 秒采样, 最多 200 点, 可导出 GPX

### 3.3 会议语音识别链路
```
PDM麦克风 → I2S PDM RX (16kHz, 16bit, MONO)
         → process_audio_realtime (高通滤波 α=0.995 + 6x增益)
         → WebSocket → 百度实时语音翻译 API (aip.baidubce.com:443)
         → JSON 返回文字
         → TCP 8081 → Flutter App 实时显示
```

### 3.4 会议控制链路
```
Flutter App → TCP 8081 连接 → ESP32 检测连接 → 自动开始录音
Flutter App → TCP 8081 断开 → ESP32 检测断开 → 自动停止录音
```
- 支持双模式: 手机 App TCP 控制 / 串口命令手动控制
- 文字通过 `add_record()` 同时推送 TCP 8081 和 WebSocket 81

### 3.5 BLE 通信链路
```
ESP32 BLE Server "OpenGlass" 广播
├── Service 19B10000
│   ├── 19B10003: GPS 数据 (Notify, 22 bytes)
│   └── 19B10004: WiFi IP 地址 (Read + Notify)
├── Service 0x180A: 设备信息 (厂商/型号/固件版本)
└── Service 0x180F: 电池电量
```
- IP 获取: BLE 连接成功后自动 notify IP 字符串
- GPS: 每 5 秒自动推送

### 3.6 AI 功能链路
```
Flutter App → 拍照 → Base64 编码
           → HTTPS POST → 智谱 GLM-4V API → 图片识别/问答
           → HTTPS POST → 通义千问 Chat API → 会议摘要生成
```

---

## 四、固件关键技术细节

### 4.1 I2S PDM 麦克风配置 (ESP-IDF v4.x API)

这是整个项目遇到最多问题的地方。**最终可用的配置**:

```c
i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
    .sample_rate = 16000,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,  // 关键!
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 512,
    .use_apll = false
};

i2s_pin_config_t pin_config = {
    .ws_io_num = 42,       // PDM CLK
    .data_in_num = 41,     // PDM DATA
    .bck_io_num = -1,      // 不使用
    .data_out_num = I2S_PIN_NO_CHANGE
};

i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
i2s_set_pin(I2S_NUM_0, &pin_config);
```

**关键点**: 
- 使用 ESP-IDF 原生 `driver/i2s.h` API，不能使用 Arduino `I2S.h` 库
- `I2S_CHANNEL_FMT_ONLY_LEFT` 而非默认的 `RIGHT_LEFT`
- ESP32-S3 上 PDM 数据从 DIN(GPIO41) 输入, CLK 从 GPIO42 输出

### 4.2 音频处理
```c
// 高通滤波器 (去除直流偏移) + 增益放大
const float alpha = 0.995f;  // 滤波系数
const float gain = 6.0f;      // 6倍增益
out = in - last_in + alpha * last_out;
```

### 4.3 百度实时语音翻译 API 协议
1. WebSocket 连接 `wss://aip.baidubce.com:443/ws/realtime_speech_trans`
2. 发送 START 帧 (JSON): app_id, app_key, format=pcm, sample_rate=16000, vad_head=3000, vad_tail=3000
3. 收到 `{"status":"STA"}` → 服务就绪
4. 持续发送 PCM 二进制帧 (1280 bytes = 40ms @ 16kHz)
5. 收到 `{"status":"TRN", "result":{"type":"MID", "asr":"..."}}` → 实时识别
6. 收到 `{"status":"TRN", "result":{"type":"FIN", "sentence":"..."}}` → 完整句子
7. 发送 FINISH 帧结束会话

### 4.4 相机配置
```c
camera_config_t config = {
    .xclk_freq_hz = 20000000,       // XCLK 20MHz
    .pixel_format = PIXFORMAT_JPEG,  // JPEG 硬件编码
    .frame_size = FRAMESIZE_SVGA,    // 800x600
    .jpeg_quality = 8,               // 质量 (0-63, 越低越快)
    .fb_count = 2,                   // 双缓冲
    .grab_mode = CAMERA_GRAB_LATEST, // 取最新帧
    .fb_location = CAMERA_FB_IN_PSRAM
};
```

### 4.5 WiFi 配置
- ESP32 连接手机热点 (sion/88888888)
- DHCP 获取 IP (非静态)
- 照片 TCP Server: 端口 8080
- 会议 TCP Server: 端口 8081

---

## 五、Flutter App 关键技术细节

### 5.1 TCP 照片接收
```dart
// 拼包机制: 4字节长度前缀 + JPEG数据
List<int> _buf = [];
int _len = -1;

void _onData(List<int> data) {
  _buf.addAll(data);
  while (_parse()) {}
}

bool _parse() {
  if (_len < 0) {
    if (_buf.length < 4) return false;
    _len = ByteData.sublistView(...).getUint32(0, Endian.little);
    _buf.removeRange(0, 4);
  }
  if (_buf.length < _len) return false;
  // 完整帧就绪
  onFrame(Uint8List.fromList(_buf.sublist(0, _len)));
  _buf.removeRange(0, _len);
  _len = -1;
  return true;
}
```

### 5.2 TCP 中文处理 (关键 Bug 修复)
```dart
// 问题: TCP 分包可能在 UTF-8 多字节字符中间切断
// 修复: 按 \n 行分隔, 逐行 utf8.decode
final List<int> _buf = [];
_buf.addAll(data);
while (true) {
  final nl = _buf.indexOf(0x0A);  // 找 \n
  if (nl == -1) break;
  final line = utf8.decode(_buf.sublist(0, nl), allowMalformed: true);
  _buf.removeRange(0, nl + 1);
  transcript += '$line\n';
}
```

### 5.3 GPS 坐标转换
```dart
// WGS-84 (原始GPS) → GCJ-02 (中国地图标准)
// 使用标准转换公式, 包含:
// - 经度偏移: _transformLng(x, y)
// - 纬度偏移: _transformLat(x, y)
// - 地球椭球参数: a=6378245.0, ee=0.006693421622965943
```

### 5.4 BLE 通信
```dart
// 扫描设备名 "OpenGlass"
// 连接 → 发现服务 → 订阅 GPS(19B10003) + IP(19B10004)
// GPS 数据 22 字节 → 解析 float32 坐标
// IP 数据 → 字符串 → 用于 TCP 连接
```

### 5.5 AI 集成
- **智谱 GLM-4V**: OpenAI 兼容接口, 图片 Base64 + JSON
- **通义千问 Chat**: 会议转写文本 → 结构化摘要 (主题+要点+行动项)
- **回退机制**: 智谱失败 → 尝试 Ollama 本地模型

---

## 六、遇到的所有问题及解决方案

### 问题 1: I2S PDM 麦克风无数据 ⭐ 核心问题
- **现象**: 串口无 `Sent 25 frames`, 百度 ASR 0 records
- **尝试1**: Arduino `I2S.h` 库, `setAllPins(-1,42,41,-1,-1)` → 引脚搞反, DIN 写成了 DOUT
- **尝试2**: `setAllPins(-1,42,-1,-1,41)` → 编译通过但无数据
- **尝试3**: 原生 `driver/i2s_pdm.h` (ESP-IDF v5.x API) → 编译报错, Arduino 2.0.17 不支持
- **尝试4**: `i2s_set_pdm_rx_down_sample(I2S_NUM_0, I2S_PDM_DSR_8S)` → 看门狗重启
- **根因**: Arduino I2S 库不支持 ESP32-S3 PDM RX 的正确配置
- **最终方案**: 使用 ESP-IDF v4.x 原生 `driver/i2s.h` API, `I2S_CHANNEL_FMT_ONLY_LEFT`

### 问题 2: 包含 `driver/i2s.h` 导致看门狗重启
- **现象**: 同时 `#include <I2S.h>` 和 `#include "driver/i2s.h"`, 系统 1 秒后 crash
- **原因**: 两个 I2S 驱动冲突, Arduino 库的命名空间包装与原生 API 冲突
- **解决**: 只使用原生 `driver/i2s.h`, 移除 Arduino I2S 库

### 问题 3: OneNET MQTT 疯狂重连
- **现象**: 串口每 3 秒刷 `[OneNET] Connection lost! Attempting reconnect...`
- **原因**: PubSubClient 库未安装, 但代码尝试连接 MQTT 服务器
- **解决**: 将 `onenet_handler.cpp` 替换为空壳函数

### 问题 4: TCP 启动会议后立即自动停止
- **现象**: `MTG TCP START` 和 `MTG TCP STOP` 同一毫秒出现
- **原因**: 串口打 `1` 设置 `recording=true`, TCP 检查 `!meetClient.connected()` 为真, 立即触发停止
- **解决**: 添加 `tcp_meeting` 标记, 仅当 TCP 启动的会议才响应 TCP 断开

### 问题 5: TCP 传输中文乱码
- **现象**: App 界面显示乱码
- **原因**: `String.fromCharCodes(data)` 在 TCP 分包时切断 UTF-8 多字节字符
- **解决**: 缓冲区按 `\n` 行分隔, 逐行 `utf8.decode()`

### 问题 6: 会议记录保存后文件为空
- **原因**: 正则 `r'\[.*?\].*\n'` 把带时间戳的 ASR 记录也删了 (如 `[00:01:23] 你好。`)
- **解决**: 保存时保留原始 transcript, 仅摘要生成时做清洗

### 问题 7: 代理导致 GitHub 推送失败
- **现象**: `SSL peer certificate not OK`, `Could not connect to server`
- **原因**: 代理端口变化 (7891→7890→未开), 国内网络限制
- **解决**: 切换代理端口或使用 SSH (`git@github.com:`)

### 问题 8: ESP32 WiFi 频繁断连
- **现象**: 串口反复出现 `WiFi:...` 和重启
- **原因**: 手机热点 5GHz 频段 / WPA3 不兼容
- **解决**: 手机热点设 2.4GHz + WPA2-PSK

### 问题 9: BLE 连接不稳定 (Android code 133)
- **现象**: 蓝牙连上即断
- **解决**: `BLEDevice::setEncryptionLevel(ESP_BLE_SEC_ENCRYPT)`, 降低加密级别

### 问题 10: 百度 ASR 不识别语音
- **现象**: ASR ready, 音频发送正常, 但 0 records
- **可能原因**: PDM 配置错误 (已解决), 音频增益不足, VAD 参数过严 (vad_head=3000)
- **调试手段**: 先串口打 `1` 测试 → 确认 ASR 正常 → 再测 TCP 方式

---

## 七、通讯协议总览

| 协议 | 方向 | 端口/UUID | 数据格式 |
|------|------|-----------|----------|
| BLE GPS | ESP32→手机 | 19B10003 | 22字节 Binary (float32) |
| BLE IP | ESP32→手机 | 19B10004 | UTF-8 字符串 |
| TCP 照片 | ESP32→手机 | 8080 | 4B长度 + JPEG |
| TCP 会议控制 | 手机→ESP32 | 8081 | 连接/断开即命令 |
| TCP 会议文字 | ESP32→手机 | 8081 | UTF-8 行 (`[时间戳] 文字\n`) |
| WebSocket 百度 | ESP32↔百度 | 443 | JSON + PCM Binary |
| HTTPS 智谱 | App↔云端 | 443 | JSON + Base64 JPEG |
| HTTPS 通义千问 | App↔云端 | 443 | JSON 文本 |

---

## 八、面试可能会被问到的问题

### Q1: 为什么选用 ESP32-S3 而不是其他 MCU？
- 内置 WiFi + BLE 双模 (无需额外模块)
- 8MB PSRAM (支持相机帧缓冲)
- 硬件 JPEG 编码器 (低延迟)
- I2S PDM 接口 (直连数字麦克风)
- Arduino/ESP-IDF 生态完善

### Q2: I2S PDM 麦克风的工作原理？
- PDM (Pulse Density Modulation): 1-bit 高频率采样 (通常 64× 采样率)
- 通过数字滤波器降采样到 PCM 16kHz 16-bit
- ESP32-S3 的 I2S 外设支持硬件 PDM→PCM 转换
- XIAO ESP32S3: CLK=GPIO42 (输出时钟), DATA=GPIO41 (输入数据)

### Q3: TCP 传输 JPEG 为什么用长度前缀？
- TCP 是流协议, 没有消息边界
- 4 字节长度前缀让接收端知道每帧的开始和结束
- 防止粘包/拆包导致 JPEG 损坏

### Q4: WGS-84 和 GCJ-02 有什么区别？为什么要转换？
- WGS-84: GPS 原始坐标系 (全球通用)
- GCJ-02: 中国国家测绘局加密坐标系 (火星坐标系)
- 中国地图服务 (高德/腾讯) 使用 GCJ-02
- 不转换的话 GPS 点在中国地图上会有 100-700 米偏移

### Q5: 音频处理中高通滤波的作用？
- PDM 麦克风输出包含直流偏移
- 高通滤波器 (α=0.995) 去除 DC 分量
- 6x 增益补偿 PDM 麦克风低灵敏度
- 输出限制在 int16 范围防止削波

### Q6: BLE 和 WiFi 如何协同工作？
- BLE: 低功耗、低带宽 (<1 Mbps)、适合小数据 (GPS、IP)
- WiFi: 高带宽、适合大数据 (照片、音频流)
- BLE 先建立连接, 传输 WiFi IP 地址
- App 获取 IP 后切换到 WiFi TCP 高速通道

### Q7: 为什么百度 ASR 的 VAD 参数很重要？
- vad_head: 前置静音检测时长 (3000ms = 3 秒)
- vad_tail: 尾随静音检测时长 (3000ms)
- 太短: 可能把噪音当语音
- 太长: 短句被忽略, 延迟大
- 3 秒是语音和延迟之间的平衡

### Q8: 项目中如何处理内存管理？
- PSRAM 存储相机帧缓冲 (fb_count=2, 双缓冲)
- I2S DMA 缓冲: 8 描述符 × 512 帧
- Stream Buffer: 640 字节 × 16 = 10KB
- 注意: ESP32-S3 内部 SRAM 有限, 大缓冲必须放 PSRAM

### Q9: 会议记录的数据流为什么设计成 ESP32 做 ASR 而不是手机？
- ESP32 直接处理音频, 减少 WiFi 传输带宽
- PCM 16kHz 原始数据 ~32KB/s, WiFi 可承受
- 百度 ASR 在云端, ESP32 仅做转发
- 手机端只接收识别后的文字 (~B/s 级别)

### Q10: 遇到的最难问题是什么？怎么解决的？
- I2S PDM 配置是最难的问题
- 经历了 Arduino 库→原生 API→错误配置→看门狗重启 多轮调试
- 最终参考队友的 ESP-IDF 示例代码, 使用原生 `driver/i2s.h` + `I2S_CHANNEL_FMT_ONLY_LEFT` 解决
- 经验: Arduino 库对 ESP32-S3 PDM 支持不完善, 复杂外设应直接用原生 API

### Q11: 如何保证实时性？
- 相机: CAMERA_GRAB_LATEST 跳过旧帧
- WiFi: TCP 直连, 无中间服务器
- ASR: WebSocket 长连接, 避免 TLS 握手开销
- Flutter: ListenableBuilder 局部刷新, 避免全树重建

### Q12: GPX 轨迹导出是什么格式？
- GPX (GPS Exchange Format) = XML 标准
- 包含经纬度、海拔、时间戳
- 可在 Google Earth、户外导航 App 中打开
- 10 秒采样间隔, 最多 200 点

---

## 九、项目文件结构

```
demo/
├── firmware/                    # ESP32 固件 (Arduino IDE)
│   ├── firmware.ino             # 主程序
│   ├── huiyi_handler.cpp/h     # 会议语音识别模块
│   ├── gps_handler.cpp/h       # GPS 解析 + BLE 推送
│   ├── onenet_handler.cpp/h    # OneNET 云平台 (已禁用)
│   ├── camera_pins.h           # 相机引脚定义
│   └── TinyGPSPlus/            # GPS 解析库
├── smartglass_native/          # Flutter App
│   └── lib/
│       ├── main.dart           # 主界面 (照片+地图+按钮)
│       ├── ai_config.dart      # AI API 配置
│       ├── meeting_service.dart # 会议 TCP 通信
│       ├── meeting_page.dart   # 会议界面
│       └── patch.dart          # 照片 TCP 接收器
└── mem_repo/                   # 队友的 ESP-IDF 参考实现
    └── main/
        ├── i2s_pdm_mic.c       # I2S PDM 驱动 (参考)
        ├── wss_streamer.c      # WebSocket 流媒体
        └── wifi_sta.c          # WiFi Station 模式
```

---

## 十、开发环境

| 工具 | 版本/说明 |
|------|-----------|
| Arduino IDE | ESP32 开发板包 2.0.17-cn |
| 依赖库 | WebSockets, ArduinoJson, TinyGPSPlus, PubSubClient |
| Flutter | SDK ^3.14.0, Dart |
| Flutter 依赖 | flutter_blue_plus, flutter_map, http, gal, path_provider, intl, latlong2 |
| ESP32 工具链 | xtensa-esp32s3-elf-gcc 8.4.0 |
| AI API | 智谱 GLM-4V, 通义千问, 百度实时语音翻译 |
