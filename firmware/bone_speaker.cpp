#include "bone_speaker.h"

// ---------------------------------------------------------------------------
// 工具函数：生成 256 点正弦波表
// ---------------------------------------------------------------------------
void BoneSpeaker::_genSine() {
    for (int i = 0; i < SINE_TABLE_SIZE; i++) {
        float angle = 2.0f * M_PI * (float)i / (float)SINE_TABLE_SIZE;
        _sine[i] = (int16_t)(sin(angle) * 30000.0f);  // 幅值 0.92，留余量防止削波
    }
}

// ---------------------------------------------------------------------------
// begin — 初始化 I2S1 (MAX98357A)
// ---------------------------------------------------------------------------
bool BoneSpeaker::begin(const Config& cfg) {
    _cfg = cfg;

    // 生成一次正弦波表
    _genSine();

    // --- I2S1 配置 ---
    i2s_config_t i2s_cfg = {};

    i2s_cfg.mode                 = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
    i2s_cfg.sample_rate          = _cfg.sample_rate;
    i2s_cfg.bits_per_sample      = (i2s_bits_per_sample_t)_cfg.bits_per_sample;
    i2s_cfg.channel_format       = I2S_CHANNEL_FMT_RIGHT_LEFT;  // 立体声
    i2s_cfg.communication_format = I2S_COMM_FORMAT_STAND_MSB;     // Left-Justified（MAX98357A 兼容）
    i2s_cfg.intr_alloc_flags     = ESP_INTR_FLAG_LEVEL1;
    i2s_cfg.dma_buf_count        = _cfg.buffer_count;
    i2s_cfg.dma_buf_len          = _cfg.buffer_samples;
    i2s_cfg.use_apll             = false;                       // 不锁相
    i2s_cfg.tx_desc_auto_clear   = true;
    i2s_cfg.fixed_mclk           = 0;                           // MAX98357A 不需要 MCLK

    // 安装 I2S 驱动
    esp_err_t err = i2s_driver_install(I2S_NUM_1, &i2s_cfg, 0, nullptr);
    if (err != ESP_OK) {
        Serial.printf("BoneSpeaker: i2s_driver_install(I2S_NUM_1) failed: %d\n", err);
        return false;
    }

    // 设置 I2S 引脚
    i2s_pin_config_t pin_cfg = {};
    pin_cfg.bck_io_num   = _cfg.bclk_pin;
    pin_cfg.ws_io_num    = _cfg.lrc_pin;
    pin_cfg.data_out_num = _cfg.din_pin;
    pin_cfg.data_in_num  = I2S_PIN_NO_CHANGE;

    err = i2s_set_pin(I2S_NUM_1, &pin_cfg);
    if (err != ESP_OK) {
        Serial.printf("BoneSpeaker: i2s_set_pin() failed: %d\n", err);
        i2s_driver_uninstall(I2S_NUM_1);
        return false;
    }

    // 启动前先静音（填充零数据帧）
    i2s_zero_dma_buffer(I2S_NUM_1);
    mute();

    _ready = true;
    Serial.println("BoneSpeaker: I2S1 初始化成功");
    return true;
}

// ---------------------------------------------------------------------------
// end — 释放资源
// ---------------------------------------------------------------------------
void BoneSpeaker::end() {
    if (_ready) {
        i2s_driver_uninstall(I2S_NUM_1);
        _ready = false;
    }
}

// ---------------------------------------------------------------------------
// tone — 播放纯音（阻塞）
// ---------------------------------------------------------------------------
void BoneSpeaker::tone(int freq_hz, int duration_ms) {
    if (!_ready) return;

    const int sample_rate = _cfg.sample_rate;
    const int total_samples = sample_rate * duration_ms / 1000;
    const int chunk = 128;   // 每次写入 128 个采样对（L+R）
    int remaining = total_samples;

    // 每个采样点的相位增量
    float phase = 0.0f;
    float phase_inc = (float)freq_hz * (float)SINE_TABLE_SIZE / (float)sample_rate;

    int16_t buf[chunk * 2];  // 双声道：L R L R L R ...
    size_t written = 0;

    while (remaining > 0) {
        int n = (remaining < chunk) ? remaining : chunk;
        for (int i = 0; i < n; i++) {
            int idx = (int)phase % SINE_TABLE_SIZE;
            int16_t s = _muted ? 0 : _sine[idx];
            buf[i * 2]     = s;  // 左声道
            buf[i * 2 + 1] = s;  // 右声道 — 必须同时发送
            phase += phase_inc;
        }
        i2s_write(I2S_NUM_1, buf, n * 2 * sizeof(int16_t), &written, portMAX_DELAY);
        remaining -= n;
    }

    // 播放完毕后静音
    i2s_zero_dma_buffer(I2S_NUM_1);
}

// ---------------------------------------------------------------------------
// write — 写入原始 PCM（16-bit 单声道，自动扩展为立体声适配 MAX98357A）
// ---------------------------------------------------------------------------
void BoneSpeaker::write(const int16_t* samples, size_t count) {
    if (!_ready) return;
    if (count == 0) return;

    if (_muted) {
        i2s_zero_dma_buffer(I2S_NUM_1);
        return;
    }

    // MAX98357A 需要立体声数据 (L+R)，将单声道复制到左右声道
    const size_t chunk = 128;
    int16_t stereo[chunk * 2];
    size_t remaining = count;

    while (remaining > 0) {
        size_t n = (remaining < chunk) ? remaining : chunk;
        for (size_t i = 0; i < n; i++) {
            stereo[i * 2]     = samples[count - remaining + i];  // L
            stereo[i * 2 + 1] = stereo[i * 2];                    // R = L
        }
        size_t written = 0;
        i2s_write(I2S_NUM_1, stereo, n * 2 * sizeof(int16_t), &written, portMAX_DELAY);
        remaining -= n;
    }
}

// ---------------------------------------------------------------------------
// mute / unmute
// ---------------------------------------------------------------------------
void BoneSpeaker::mute() {
    _muted = true;
    if (_ready) {
        i2s_zero_dma_buffer(I2S_NUM_1);
    }
}

void BoneSpeaker::unmute() {
    _muted = false;
}
