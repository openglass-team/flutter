// ============================================================
// OpenGlass - WiFi 照片 + BLE GPS + 会议语音识别 三模固件
// 照片: WiFi TCP port 8080 (5 FPS, SVGA 800x600)
// GPS:  BLE UUID 19B10003 + OneNET MQTT
// 会议: 百度实时语音识别 + WS Server:81 广播
// ============================================================
#define CAMERA_MODEL_XIAO_ESP32S3
#include <WiFi.h>
#include "esp_camera.h"
#include "camera_pins.h"
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include "gps_handler.h"
#include "onenet_handler.h"
#include "huiyi_handler.h"

// ====== WiFi 配置 (改成你的路由器) ======
const char* WIFI_SSID = "sion";
const char* WIFI_PASS = "88888888";
WiFiServer tcpServer(8080);
WiFiClient tcpClient;

// ====== BLE (仅 GPS) ======
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
  void onConnect(BLEServer *s)    { bleConnected = true; Serial.println("BLE OK");    if(WiFi.status()==WL_CONNECTED){String ip=WiFi.localIP().toString();ipCharacteristic->setValue(ip.c_str());ipCharacteristic->notify();}
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
  c3->setValue("1.0.1"); c4->setValue("XIAO ESP32S3 Sense");

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
  config.jpeg_quality = 8;               // 更低质量 = 更快编码
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
  Serial.println("\nOpenGlass WiFi+GPS starting...");

  configure_camera();

  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("WiFi connecting");
  for (int i = 0; i < 30 && WiFi.status() != WL_CONNECTED; i++) {
    delay(500); Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("\nWiFi OK: %s\n", WiFi.localIP().toString().c_str());
    tcpServer.begin();
    Serial.printf("TCP: %s:8080\n", WiFi.localIP().toString().c_str());
  } else {
    Serial.println("\nWiFi FAILED!");
  }

  gps_init();
  configure_ble();
  huiyi_init();

  Serial.println("Ready");
}

// ====== Loop ======
void loop() {
  unsigned long now = millis();

  gps_send_if_due(now, bleConnected);
  onenet_loop();
  huiyi_loop();
  send_photo_tcp();

  if (now - lastBatteryUpdate > 60000) {
    batteryLevelCharacteristic->setValue(&batteryLevel, 1);
    batteryLevelCharacteristic->notify();
    lastBatteryUpdate = now;
  }

  // 不 delay, 最大帧率 (~8-15 FPS SVGA)
}