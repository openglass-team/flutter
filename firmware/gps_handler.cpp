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
}

void gps_send_if_due(unsigned long now, bool connected) {
  int count = 0;
  while (Serial2.available() && count < 50) {
    char c = Serial2.read();
    gps.encode(c);
    count++;
  }

  unsigned long sinceLast = now - lastGpsUpdate;
  if (sinceLast < 5000) return;
  if (!connected) { lastGpsUpdate = now; return; }

  uint8_t gpsBuffer[16];
  gpsBuffer[0] = gps_frame_count & 0xFF;
  gpsBuffer[1] = (gps_frame_count >> 8) & 0xFF;

  if (gps.location.isValid()) {
    gpsBuffer[2] = 1; gpsBuffer[3] = gps.satellites.value();
    double lat=gps.location.lat(), lng=gps.location.lng(), spd=gps.speed.mps();
    memcpy(&gpsBuffer[4],&lat,4); memcpy(&gpsBuffer[8],&lng,4); memcpy(&gpsBuffer[12],&spd,4);
  } else {
    gpsBuffer[2] = 0; memset(&gpsBuffer[3], 0, 13);
  }

  gpsDataCharacteristic->setValue(gpsBuffer, sizeof(gpsBuffer));
  gpsDataCharacteristic->notify();
  gps_frame_count++;
  lastGpsUpdate = now;
}
