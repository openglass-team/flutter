#pragma once
#include <Arduino.h>

void gps_init();
void gps_send_if_due(unsigned long now, bool connected);
