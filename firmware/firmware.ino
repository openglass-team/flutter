// ============================================================
// OpenGlass - WiFi 照片 + BLE GPS + 会议语音 + 骨传导音频 四合一固件
// 照片: WiFi TCP port 8080 (5 FPS, SVGA 800x600)
// GPS:  BLE UUID 19B10003 + OneNET MQTT
// 会议: 百度实时语音识别 + WS Server:81 广播 + TCP :8081 转写
// 音频: TCP :8083 → 骨传导喇叭 + HTTP :82 PC bridge 兼容
// ============================================================
#define CAMERA_MODEL_XIAO_ESP32S3
#include <WiFi.h>
#include <WebServer.h>
#include <I2S.h>
#include "esp_camera.h"
#include "camera_pins.h"
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include "gps_handler.h"
#include "onenet_handler.h"
#include "huiyi_handler.h"
#include "bone_speaker.h"

// ====== 音频参数 ======
#define SAMPLE_RATE   16000
#define SAMPLE_BITS   16

// 环形缓冲区 (单读者单写者, 无锁)
// 注意: 用 PSRAM 分配, 不占 DRAM — 相机帧缓存也需要 PSRAM, 两者共用 8MB
#define BUF_SZ 16384  // 16K 采样 = 32KB = ~1 秒缓冲, 足够抖动缓冲用

// ====== WiFi 配置 ======
const char* WIFI_SSID = "sion";
const char* WIFI_PASS = "88888888";
WiFiServer tcpServer(8080);
WiFiClient tcpClient;

// ---- TCP 音频服务器 ----
WiFiServer tcpAinServer(8083);   // 音频输入: 手机 → ESP32 → 骨传导喇叭
WiFiClient  tcpAinClient;
WiFiServer tcpMicServer(8082);   // 麦克风输出: ESP32 I2S0 → 手机
WiFiClient  tcpMicClient;

// ---- HTTP 服务器 (PC bridge 兼容, 端口 82 避免与 WS :81 冲突) ----
WebServer server(82);

// ---- 环形缓冲区 (PSRAM 分配, 不占 DRAM) ----
static int16_t *s_buf = nullptr;
static volatile size_t s_w = 0;
static volatile size_t s_r = 0;

// ---- 骨传导喇叭 ----
BoneSpeaker speaker;

// ---- beep ----
static int16_t *s_beep = nullptr;
static volatile size_t s_beep_total = 0, s_beep_pos = 0;
static volatile size_t s_pcm_bytes = 0;

// ---- 统计 ----
static volatile size_t s_underrun_count = 0;
static volatile size_t s_overflow_count = 0;
static volatile float  s_buf_watermark = 0;

// ---- 环形缓冲区操作 ----
size_t buf_avail_read() {
  if (s_w >= s_r) return s_w - s_r;
  return BUF_SZ - s_r + s_w;
}

size_t buf_avail_write() {
  return BUF_SZ - 1 - buf_avail_read();
}

void audio_push(const uint8_t *data, size_t len) {
  size_t samples = len / 2;
  const int16_t *in = (const int16_t *)data;
  for (size_t i = 0; i < samples; i++) {
    size_t next = (s_w + 1) % BUF_SZ;
    if (next == s_r) { s_overflow_count++; break; }
    s_buf[s_w] = in[i];
    s_w = next;
  }
}

size_t audio_pop(int16_t *out, size_t max_count) {
  size_t n = 0;
  while (n < max_count && s_r != s_w) {
    out[n++] = s_buf[s_r];
    s_r = (s_r + 1) % BUF_SZ;
  }
  if (n == 0) s_underrun_count++;
  return n;
}

// ---- AudioTask handle (Core 0) ----
TaskHandle_t s_audio_task_handle = nullptr;

// ================================================================
// HTTP 路由 (端口 82, 兼容 PC bridge)
// ================================================================

void handleBeep() {
  int freq = server.hasArg("freq") ? server.arg("freq").toInt() : 1000;
  int dur  = server.hasArg("ms")   ? server.arg("ms").toInt()   : 300;
  if (freq < 50) freq = 50;   if (freq > 8000)  freq = 8000;
  if (dur  < 10) dur  = 10;   if (dur  > 3000)  dur  = 3000;
  int total = SAMPLE_RATE * dur / 1000;
  if (s_beep) free(s_beep);
  s_beep = (int16_t *)malloc(total * sizeof(int16_t));
  if (!s_beep) { server.send(500); return; }
  s_beep_total = total; s_beep_pos = 0;
  for (int i = 0; i < total; i++)
    s_beep[i] = (int16_t)(sin(2.0f * M_PI * freq * i / SAMPLE_RATE) * 28000.0f);
  server.send(200, "text/plain", "ok");
}

void handlePcmUpload() {
  HTTPUpload &u = server.upload();
  if (u.status == UPLOAD_FILE_START) { s_pcm_bytes = 0; }
  else if (u.status == UPLOAD_FILE_WRITE) {
    audio_push(u.buf, u.currentSize);
    s_pcm_bytes += u.currentSize;
  }
  else if (u.status == UPLOAD_FILE_END) {
    Serial.printf("PCM HTTP: %d B, buf_avail=%d\n", (int)s_pcm_bytes, (int)buf_avail_read());
  }
}

void handlePcmDone() { server.send(200, "text/plain", String(s_pcm_bytes)); }

void handleStatus() {
  char js[256];
  snprintf(js, sizeof(js),
    "{\"buf_avail\":%d,\"buf_cap\":%d,\"watermark\":%.2f,\"underrun\":%d,\"overflow\":%d}",
    (int)buf_avail_read(), BUF_SZ,
    (float)buf_avail_read() / (float)BUF_SZ,
    (int)s_underrun_count, (int)s_overflow_count);
  server.send(200, "application/json", js);
}

void handleRoot() {
  server.send(200, "text/html", "<!DOCTYPE html><html><head><meta charset=UTF-8>"
  "<meta name=viewport content='width=device-width,initial-scale=1'>"
  "<title>OpenGlass Audio</title></head>"
  "<body style='font-family:system-ui;background:#111;color:#eee;padding:24px;text-align:center'>"
  "<h1>OpenGlass Audio</h1><p>HTTP :82 | TCP :8083 (speaker)</p></body></html>");
}

// ================================================================
// 音频播放任务 (Core 0, 最高优先级)
// ================================================================
void audioTask(void *pvParameters) {
  const int chunk_samples = 512;
  int16_t *chunk = (int16_t *)malloc(chunk_samples * sizeof(int16_t));
  if (!chunk) { vTaskDelete(nullptr); return; }

  for (;;) {
    size_t n = audio_pop(chunk, chunk_samples);
    if (n < (size_t)chunk_samples) {
      memset(chunk + n, 0, (chunk_samples - n) * sizeof(int16_t));
    }
    speaker.write(chunk, chunk_samples);

    static int tick_count = 0;
    if (++tick_count >= 31) {
      tick_count = 0;
      s_buf_watermark = (float)buf_avail_read() / (float)BUF_SZ;
    }
  }
}

// ====== BLE ======
#define DEVICE_INFORMATION_SERVICE_UUID (uint16_t)0x180A
#define MANUFACTURER_NAME_STRING_CHAR_UUID (uint16_t)0x2A29
#define MODEL_NUMBER_STRING_CHAR_UUID (uint16_t)0x2A24
#define FIRMWARE_REVISION_STRING_CHAR_UUID (uint16_t)0x2A26
#define HARDWARE_REVISION_STRING_CHAR_UUID (uint16_t)0x2A27
#define BATTERY_SERVICE_UUID (uint16_t)0x180F
#define BATTERY_LEVEL_CHAR_UUID (uint16_t)0x2A19

static BLEUUID serviceUUID("19B10000-E8F2-537E-4F6C-D104768A1214");
static BLEUUID gpsDataUUID("19B10003-E8F2-537E-4F6C-D104768A1214");
static BLEUUID ipUUID("19B10004-E8F2-537E-4F6C-D104768A1214");
BLECharacteristic *ipCharacteristic;
BLECharacteristic *gpsDataCharacteristic;
BLECharacteristic *batteryLevelCharacteristic;
bool bleConnected = false;
uint8_t batteryLevel = 100;
unsigned long lastBatteryUpdate = 0;

// ====== BLE Callbacks ======
class ServerHandler : public BLEServerCallbacks {
  void onConnect(BLEServer *s) {
    bleConnected = true; Serial.println("BLE OK");
    if (WiFi.status() == WL_CONNECTED) {
      String ip = WiFi.localIP().toString();
      ipCharacteristic->setValue(ip.c_str());
      ipCharacteristic->notify();
    }
  }
  void onDisconnect(BLEServer *s) { bleConnected = false; BLEDevice::startAdvertising(); }
};

// ====== BLE 初始化 ======
void configure_ble() {
  BLEDevice::init("OpenGlass");
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerHandler());
  BLEService *service = server->createService(serviceUUID);

  gpsDataCharacteristic = service->createCharacteristic(
    gpsDataUUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  BLE2902 *ccc = new BLE2902();
  ccc->setNotifications(true);
  gpsDataCharacteristic->addDescriptor(ccc);

  ipCharacteristic = service->createCharacteristic(
    ipUUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  { BLE2902 *c = new BLE2902(); c->setNotifications(true); ipCharacteristic->addDescriptor(c); }

  BLEService *deviceInfoService = server->createService(DEVICE_INFORMATION_SERVICE_UUID);
  BLECharacteristic *c1 = deviceInfoService->createCharacteristic(MANUFACTURER_NAME_STRING_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
  BLECharacteristic *c2 = deviceInfoService->createCharacteristic(MODEL_NUMBER_STRING_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
  BLECharacteristic *c3 = deviceInfoService->createCharacteristic(FIRMWARE_REVISION_STRING_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
  BLECharacteristic *c4 = deviceInfoService->createCharacteristic(HARDWARE_REVISION_STRING_CHAR_UUID, BLECharacteristic::PROPERTY_READ);
  c1->setValue("Based Hardware"); c2->setValue("OpenGlass");
  c3->setValue("1.0.2"); c4->setValue("XIAO ESP32S3 Sense");

  BLEService *batteryService = server->createService(BATTERY_SERVICE_UUID);
  batteryLevelCharacteristic = batteryService->createCharacteristic(
    BATTERY_LEVEL_CHAR_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  ccc = new BLE2902(); ccc->setNotifications(true);
  batteryLevelCharacteristic->addDescriptor(ccc);
  batteryLevelCharacteristic->setValue(&batteryLevel, 1);

  service->start(); deviceInfoService->start(); batteryService->start();
  BLEDevice::startAdvertising();
  Serial.println("BLE OK");
}

// ====== 相机 ======
void configure_camera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_SVGA;   // 800x600
  config.jpeg_quality = 8;
  config.fb_count = 2;
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.fb_location = CAMERA_FB_IN_PSRAM;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera fail: 0x%x\n", err);
    Serial.printf("  SIOD=%d SIOC=%d PWDN=%d RESET=%d XCLK=%d\n",
      config.pin_sccb_sda, config.pin_sccb_scl, config.pin_pwdn, config.pin_reset, config.pin_xclk);
    Serial.println("  Check: 1)ribbon cable  2)board model  3)PSRAM enabled");
    while(1) delay(1000);
  }
  Serial.println("Camera OK");
}

// ====== WiFi TCP 照片发送 ======
camera_fb_t *fb = nullptr;
void send_photo_tcp() {
  if (!tcpClient || !tcpClient.connected()) {
    tcpClient = tcpServer.available();
    return;
  }
  if (fb) { esp_camera_fb_return(fb); fb = nullptr; }
  fb = esp_camera_fb_get();
  if (!fb) return;

  uint32_t len = fb->len;
  tcpClient.write((uint8_t*)&len, 4);
  tcpClient.write(fb->buf, fb->len);
  tcpClient.flush();
}

// ====== Setup ======
void setup() {
  Serial.begin(115200);
  Serial.println("\n=== OpenGlass 四合一固件 (相机+GPS+会议+骨传导) ===");
  Serial.printf("Free heap: %d\n", ESP.getFreeHeap());

  // 0. 环形缓冲区 — PSRAM 分配 (32KB, 不占 DRAM)
  s_buf = (int16_t *)ps_malloc(BUF_SZ * sizeof(int16_t));
  if (s_buf) {
    memset(s_buf, 0, BUF_SZ * sizeof(int16_t));
    Serial.printf("Audio buf OK (%dKB PSRAM)\n", (int)(BUF_SZ * sizeof(int16_t) / 1024));
  } else {
    Serial.println("Audio buf FAIL — no PSRAM?");
  }

  // 1. 相机
  configure_camera();

  // 2. WiFi
  WiFi.mode(WIFI_AP_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("WiFi connecting");
  for (int i = 0; i < 30 && WiFi.status() != WL_CONNECTED; i++) {
    delay(500); Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\nSTA OK: %s\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("\nSTA failed, AP only");
  }
  WiFi.softAP("OpenGlass", "12345678");
  Serial.printf("AP: %s\n", WiFi.softAPIP().toString().c_str());
  tcpServer.begin();
  Serial.printf("TCP photo: %s:8080\n", WiFi.localIP().toString().c_str());

  // 3. GPS
  gps_init();

  // 4. BLE (GPS + IP)
  configure_ble();

  // 5. 会议语音识别 (百度 ASR, I2S0 mic)
  huiyi_init();

  // 6. 骨传导喇叭 (I2S1, GPIO 4/5/6)
  BoneSpeaker::Config spk_cfg;
  spk_cfg.buffer_count  = 8;
  spk_cfg.buffer_samples = 512;
  if (speaker.begin(spk_cfg)) {
    Serial.println("Speaker OK (I2S1, DMA: 8x512=256ms)");
    speaker.unmute();
    speaker.tone(1000, 150);
  } else {
    Serial.println("Speaker FAIL");
  }

  // 7. HTTP 服务器 (端口 82, PC bridge 兼容)
  server.on("/",          HTTP_GET,              handleRoot);
  server.on("/beep",      HTTP_GET,              handleBeep);
  server.on("/status",    HTTP_GET,              handleStatus);
  server.on("/pcm",       HTTP_POST, handlePcmDone, handlePcmUpload);
  server.begin();

  // 8. TCP 音频服务器
  tcpAinServer.begin();
  tcpMicServer.begin();
  Serial.println("HTTP audio :82 | TCP ain :8083 | TCP mic :8082 | WS meeting :81 | TCP meeting :8081");

  Serial.printf("Free heap: %d\n\n", ESP.getFreeHeap());

  // 9. 音频播放任务 (Core 0, 最高优先级)
  xTaskCreatePinnedToCore(
    audioTask, "AudioOut", 4096, nullptr,
    configMAX_PRIORITIES - 1, &s_audio_task_handle, 0
  );

  Serial.println("Ready");
}

// ====== Loop ======
void loop() {
  unsigned long now = millis();

  // ---- 1. HTTP 请求 (:82) ----
  server.handleClient();

  // ---- 2. TCP 音频输入 (8083): 手机 App → raw PCM → 环形缓冲区 → 骨传导喇叭 ----
  if (tcpAinServer.hasClient()) {
    if (!tcpAinClient) {
      tcpAinClient = tcpAinServer.available();
      Serial.println("TCP ain connected");
    } else {
      WiFiClient reject = tcpAinServer.available();
      reject.stop();
    }
  }
  if (tcpAinClient && tcpAinClient.connected()) {
    while (tcpAinClient.available() >= 2) {
      uint8_t pair[2];
      tcpAinClient.read(pair, 2);
      audio_push(pair, 2);
    }
  }

  // ---- 3. TCP 麦克风输出 (8082): ESP32 I2S0 → raw PCM → 手机 App ----
  if (tcpMicServer.hasClient()) {
    if (!tcpMicClient || !tcpMicClient.connected()) {
      tcpMicClient = tcpMicServer.available();
      Serial.println("TCP mic connected");
    } else {
      WiFiClient reject = tcpMicServer.available();
      reject.stop();
    }
  }
  if (tcpMicClient && !tcpMicClient.connected()) {
    tcpMicClient.stop();
  }

  // ---- 4. 非阻塞 beep ----
  if (s_beep && s_beep_pos < s_beep_total) {
    int n = 128;
    if (s_beep_pos + n > s_beep_total) n = s_beep_total - s_beep_pos;
    audio_push((uint8_t *)(s_beep + s_beep_pos), n * 2);
    s_beep_pos += n;
    if (s_beep_pos >= s_beep_total) { free(s_beep); s_beep = nullptr; }
  }

  // ---- 5. GPS BLE 推送 ----
  gps_send_if_due(now, bleConnected);

  // ---- 6. OneNET MQTT ----
  onenet_loop();

  // ---- 7. 会议语音识别 ----
  huiyi_loop();

  // ---- 8. 照片 TCP 推送 (:8080) ----
  send_photo_tcp();

  // ---- 9. 电池更新 ----
  if (now - lastBatteryUpdate > 60000) {
    batteryLevelCharacteristic->setValue(&batteryLevel, 1);
    batteryLevelCharacteristic->notify();
    lastBatteryUpdate = now;
  }

  delay(1);
}