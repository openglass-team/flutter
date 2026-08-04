#include "gps_handler.h"
#include <TinyGPS++.h>
#include <BLEDevice.h>

#define GPS_RX 1
#define GPS_TX 0
#define GPS_BAUD_RATE 9600

extern BLECharacteristic *gpsDataCharacteristic;

static TinyGPSPlus gps;
static uint16_t gps_frame_count = 0;
static unsigned long lastGpsUpdate = 0;

void gps_init() {
  Serial2.begin(GPS_BAUD_RATE, SERIAL_8N1, GPS_RX, GPS_TX);
  pinMode(GPS_RX, INPUT);
  digitalWrite(GPS_RX, LOW);
  pinMode(GPS_TX, OUTPUT);
  Serial.printf("[GPS] RX=%d TX=%d baud=%d\n", GPS_RX, GPS_TX, GPS_BAUD_RATE);
}

void gps_send_if_due(unsigned long now, bool connected) {
  int count = 0;
  while (Serial2.available() && count < 50) {
    char c = Serial2.read();
    //Serial.write(c); GPS echo off
    gps.encode(c);
    count++;
  }

  if (now - lastGpsUpdate < 1000) return;

  if (gps.location.isValid()) {
    Serial.printf("[GPS] fix=1 sats=%d lat=%.6f lng=%.6f\n",
      gps.satellites.value(), gps.location.lat(), gps.location.lng());
  }

  if (!connected) { lastGpsUpdate = now; return; }

  uint8_t buf[22] = {0};
  buf[0] = gps_frame_count & 0xFF;
  buf[1] = (gps_frame_count >> 8) & 0xFF;

  if (gps.location.isValid()) {
    buf[2] = 1;
    buf[3] = gps.satellites.value();
    float lat = gps.location.lat();
    float lng = gps.location.lng();
    float alt = gps.altitude.meters();
    float spd = gps.speed.mps();
    uint16_t course = (uint16_t)(gps.course.deg() * 100);
    memcpy(&buf[4], &lat, 4);
    memcpy(&buf[8], &lng, 4);
    memcpy(&buf[12], &alt, 4);
    memcpy(&buf[16], &spd, 4);
    buf[20] = course & 0xFF;
    buf[21] = (course >> 8) & 0xFF;
  }

  gpsDataCharacteristic->setValue(buf, sizeof(buf));
  gpsDataCharacteristic->notify();
  gps_frame_count++;
  lastGpsUpdate = now;
}
