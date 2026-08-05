#include "huiyi_handler.h"
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <WebSocketsServer.h>
#include <ArduinoJson.h>
#include "driver/i2s.h"

const int ledPin = 21;
const char* baidu_app_id = "124044995";
const char* baidu_app_key = "H2hQT1BVZGewVCLUHTS4I1Rb";
const char* trans_from = "zh";
const char* trans_to = "zh";

#define SAMPLE_RATE   16000
#define I2S_PORT      I2S_NUM_0
#define SUB_FRAME_SIZE 640
#define CHUNK_SIZE     1280
#define WS_SERVER_PORT 81
#define MAX_RECORDS 50

WebSocketsServer wsServer(WS_SERVER_PORT);
WebSocketsClient webSocket;
WiFiServer meetServer(8081);
WiFiClient meetClient;
extern WiFiClient tcpMicClient;

bool ws_connected = false;
bool tcp_meeting = false;
bool recording = false;
bool start_sent = false;
int frames_sent = 0;

String meeting_records[MAX_RECORDS];
int record_count = 0;
unsigned long meeting_start_time = 0;

uint8_t send_buffer[CHUNK_SIZE];
int send_buf_ptr = 0;
int16_t sub_frame[SUB_FRAME_SIZE / 2];
float last_in = 0.0f;
float last_out = 0.0f;

String get_timestamp() {
  unsigned long elapsed = (millis() - meeting_start_time) / 1000;
  int hours = elapsed / 3600;
  int minutes = (elapsed % 3600) / 60;
  int seconds = elapsed % 60;
  char buf[12];
  sprintf(buf, "%02d:%02d:%02d", hours, minutes, seconds);
  return String(buf);
}

void wsServerEvent(uint8_t num, WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_CONNECTED:
      Serial.printf("[WS Server] client #%u connected\n", num);
      break;
    case WStype_DISCONNECTED:
      Serial.printf("[WS Server] client #%u disconnected\n", num);
      break;
    default:
      break;
  }
}

void add_record(const char* text) {
  if (record_count >= MAX_RECORDS) {
    for (int i = 0; i < MAX_RECORDS - 1; i++) {
      meeting_records[i] = meeting_records[i + 1];
    }
    record_count = MAX_RECORDS - 1;
  }
  String record = "[" + get_timestamp() + "] " + String(text);
  meeting_records[record_count] = record;
  record_count++;
  wsServer.broadcastTXT(record);
    if(meetClient&&meetClient.connected()){meetClient.print(record);meetClient.print("\n");meetClient.flush();}

}

void print_meeting_records() {
  Serial.println("\n========== Meeting Records ==========");
  Serial.printf("Start time: %s\n", get_timestamp());
  Serial.printf("Records: %d\n", record_count);
  Serial.println("-------------------------------------");
  for (int i = 0; i < record_count; i++) {
    Serial.println(meeting_records[i]);
  }
  Serial.println("========== Meeting End ==========\n");
}

void clear_meeting_records() {
  for (int i = 0; i < MAX_RECORDS; i++) {
    meeting_records[i] = "";
  }
  record_count = 0;
  Serial.println("Meeting records cleared");
}

void process_audio_realtime(int16_t* samples, int length) {
  const float alpha = 0.995f;
  const float gain = 6.0f;

  for (int i = 0; i < length; i++) {
    float in = samples[i];
    float out = in - last_in + alpha * last_out;
    last_in = in;
    last_out = out;

    int32_t val = (int32_t)(out * gain);
    if (val > 32767) val = 32767;
    else if (val < -32768) val = -32768;
    samples[i] = (int16_t)val;
  }
}

void send_start_frame() {
  StaticJsonDocument<512> doc;
  doc["type"] = "START";
  doc["from"] = trans_from;
  doc["to"] = trans_to;
  doc["app_id"] = baidu_app_id;
  doc["app_key"] = baidu_app_key;
  doc["format"] = "pcm";
  doc["sampling_rate"] = SAMPLE_RATE;
  doc["vad_head"] = 3000;
  doc["vad_tail"] = 3000;

  String json;
  serializeJson(doc, json);
  Serial.printf("Sending START frame: %s\n", json.c_str());
  webSocket.sendTXT(json);
}

void send_end_frame() {
  webSocket.sendTXT("{\"type\":\"FINISH\"}");
  Serial.println("End frame sent");
}

void init_i2s() {
  i2s_config_t i2s_config = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
    .sample_rate = SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count = 8,
    .dma_buf_len = 512,
    .use_apll = false
  };

  i2s_pin_config_t pin_config = {
    .mck_io_num = I2S_PIN_NO_CHANGE,
    .bck_io_num = -1,
    .ws_io_num = 42,
    .data_out_num = I2S_PIN_NO_CHANGE,
    .data_in_num = 41
  };

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      ws_connected = false;
      Serial.printf("WebSocket disconnected. Payload: %s\n", payload ? (char*)payload : "none");
      break;

    case WStype_CONNECTED:
      ws_connected = true;
      start_sent = false;
      Serial.println("WebSocket connected to Baidu Translation Server.");
      if (recording) {
        send_start_frame();
        start_sent = true;
        Serial.println("Re-sent START frame after reconnect");
      }
      break;

    case WStype_TEXT: {
      String text = (char*)payload;
      StaticJsonDocument<1024> doc;
      if (deserializeJson(doc, text) == DeserializationError::Ok) {
        int code = doc["code"];
        const char* msg = doc["msg"];

        if (code != 0) {
          Serial.printf("\n>>> Speech recognition error: %d - %s\n", code, msg ? msg : "unknown");
          break;
        }

        JsonObject data = doc["data"];
        if (data.isNull()) break;

        const char* status = data["status"];
        if (!status) break;

        if (strcmp(status, "STA") == 0) {
          Serial.println(">>> Speech recognition service ready, start speaking...");
        } else if (strcmp(status, "TRN") == 0) {
          JsonObject result = data["result"];
          if (result.isNull()) break;

          const char* res_type = result["type"];
          const char* asr = result["asr"];
          const char* sentence = result["sentence"];

          if (res_type && strcmp(res_type, "MID") == 0) {
            if (asr && strlen(asr) > 0)
              Serial.printf("\r[Recognizing] %s", asr);
          } else if (res_type && strcmp(res_type, "FIN") == 0) {
            if (sentence && strlen(sentence) > 0) {
              Serial.printf("\n[Result] %s\n", sentence);
              add_record(sentence);
            }
          }
        } else if (strcmp(status, "END") == 0) {
          Serial.println(">>> Speech recognition session ended");
        }
      }
      break;
    }

    case WStype_BIN:
      break;

    case WStype_ERROR:
      Serial.println("WebSocket error occurred");
      ws_connected = false;
      break;
    default:
      break;
  }
}

void huiyi_init() {
  pinMode(ledPin, OUTPUT);
  digitalWrite(ledPin, LOW);

  init_i2s();

  wsServer.begin();
  wsServer.onEvent(wsServerEvent);
  meetServer.begin();
  Serial.printf("WS Server started, port: %d\n", WS_SERVER_PORT);
  Serial.printf("Mobile connect: ws://%s:%d\n", WiFi.localIP().toString().c_str(), WS_SERVER_PORT);

  webSocket.beginSSL("aip.baidubce.com", 443, "/ws/realtime_speech_trans");
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(3000);

  Serial.printf("Speech recognition language: %s\n", trans_from);
  Serial.println("=== Meeting Record Mode ===");
  Serial.println("Commands:");
  Serial.println("  1 - Start recording");
  Serial.println("  0 - Stop recording");
  Serial.println("  p - View records");
  Serial.println("  c - Clear records");
  Serial.println("===========================");
}

void huiyi_loop() {
  // TCP 8081: 手机App连上→开始
  if(!meetClient||!meetClient.connected()){
    WiFiClient c=meetServer.available();
    if(c){meetClient=c;if(!recording){recording=true;frames_sent=0;send_buf_ptr=0;last_in=0;last_out=0;meeting_start_time=millis();digitalWrite(ledPin,HIGH);webSocket.sendTXT("{\"type\":\"FINISH\"}");delay(50);send_start_frame();start_sent=true;tcp_meeting=true;Serial.println("MTG TCP START");}}
  }
  // TCP断开→停止(仅当TCP启动的会议)
  if(tcp_meeting&&recording&&(!meetClient||!meetClient.connected())){
    recording=false;tcp_meeting=false;digitalWrite(ledPin,LOW);send_end_frame();Serial.println("MTG TCP STOP");
  }

  webSocket.loop();
  wsServer.loop();

  if (Serial.available()) {
    char cmd = Serial.read();
    if (cmd == '1' && !recording) {
      recording = true;
      frames_sent = 0;
      send_buf_ptr = 0;
      last_in = 0;
      last_out = 0;
      meeting_start_time = millis();
      digitalWrite(ledPin, HIGH);
      Serial.println("\n=== Meeting recording started ===");
      send_start_frame();
      start_sent = true;
    } else if (cmd == '0' && recording) {
      recording = false; tcp_meeting = false;
      digitalWrite(ledPin, LOW);
      send_end_frame();
      Serial.printf("\n=== Meeting recording stopped (%d records, ~%.2f sec) ===\n",
        record_count, (float)(frames_sent * 40) / 1000);
    } else if (cmd == 'p' || cmd == 'P') {
      print_meeting_records();
    } else if (cmd == 'c' || cmd == 'C') {
      clear_meeting_records();
    }
  }

  // 按需读 I2S: 会议录音 或 语音对话TCP连接时
  bool needMic = (recording && ws_connected && start_sent)
              || (tcpMicClient && tcpMicClient.connected());
  if (needMic) {
    size_t bytes_read = 0;
    esp_err_t err = i2s_read(I2S_PORT, (void*)sub_frame, SUB_FRAME_SIZE, &bytes_read, portMAX_DELAY);

    if (err == ESP_OK && bytes_read > 0) {
      if(tcpMicClient&&tcpMicClient.connected()){
        tcpMicClient.write((uint8_t*)sub_frame,bytes_read);
      }
      if (recording && ws_connected && start_sent) {
        int sample_count = bytes_read / sizeof(int16_t);
        process_audio_realtime(sub_frame, sample_count);
        memcpy(send_buffer + send_buf_ptr, sub_frame, bytes_read);
        send_buf_ptr += bytes_read;
        if (send_buf_ptr >= CHUNK_SIZE) {
          webSocket.sendBIN(send_buffer, CHUNK_SIZE);
          frames_sent++;
          send_buf_ptr = 0;
        }
      }
    }
  }
}