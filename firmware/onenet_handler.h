#pragma once
#include <Arduino.h>

void onenet_init();
void onenet_upload_gps(double lat, double lng, double speed);
bool onenet_is_connected();
void onenet_loop();