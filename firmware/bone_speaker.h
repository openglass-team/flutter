#ifndef BONE_SPEAKER_H
#define BONE_SPEAKER_H

#include <driver/i2s.h>
#include <Arduino.h>

/**
 * BoneSpeaker — HC-13MM 骨传导喇叭驱动
 *
 * 通过 MAX98357A I2S 功放模块驱动 HC-13MM 骨传导喇叭 (8Ω, 200mW)。
 * 使用 ESP32-S3 的 I2S1 控制器（I2S0 已被板载 MEMS 麦克风占用）。
 *
 * 引脚分配：
 *   D3 (GPIO 4) — BCLK
 *   D5 (GPIO 6) — LRC (WS)
 *   D4 (GPIO 5) — DIN
 *
 * 音频格式：16kHz, 16bit, 单声道, I2S Philips 标准格式
 */
class BoneSpeaker {
public:
    struct Config {
        int bclk_pin       = 4;    // I2S 位时钟 (D3)
        int lrc_pin        = 6;    // I2S 左右声道时钟 (D5)
        int din_pin        = 5;    // I2S 数据输出 (D4)
        int sample_rate    = 16000;
        int bits_per_sample = 16;    // 16-bit 采样
        int buffer_count   = 4;    // DMA 缓冲区数量
        int buffer_samples = 256;  // 每个 DMA 缓冲区的采样数
    };

    BoneSpeaker()  = default;
    ~BoneSpeaker() { end(); }

    /// 初始化 I2S1 并启动功放
    bool begin(const Config& cfg);

    /// 释放 I2S 资源
    void end();

    /// 播放纯音测试（阻塞，duration_ms 毫秒）
    void tone(int freq_hz, int duration_ms);

    /// 写入原始 16-bit 单声道 PCM 数据
    void write(const int16_t* samples, size_t count);

    /// 静音（输出全零帧）
    void mute();

    /// 取消静音
    void unmute();

    /// 是否已初始化成功
    bool ready() const { return _ready; }

private:
    bool   _ready = false;
    bool   _muted = false;
    Config _cfg;

    static const int SINE_TABLE_SIZE = 256;
    int16_t _sine[SINE_TABLE_SIZE];

    void _genSine();
};

#endif // BONE_SPEAKER_H
