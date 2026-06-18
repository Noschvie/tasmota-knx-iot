#!/usr/bin/env berry
#- ─────────────────────────────────────────────────────────────────────────────
   knx_subscribe.be
   load("knx_subscribe.be")

   Subscribes to KNX CoV notifications from semantic-knx-runtime.

   Flow:
     1. Fetch OAuth token (manage + read)
     2. Resolve GA → datapointUUID
     3. Register HTTP callback subscription (httpserver receives POSTs)
     4. Renew subscription periodically (at half lifetime)
     5. Print incoming CoV notifications
     6. Delete subscription on unload / restart

   Configuration: adjust the var lines below, or set Tasmota commands
   before loading:
     Var1  → API_URL           (default http://192.168.1.1:3000)
     Var2  → KNX_GROUP_ADDRESS (default 1/1/93)
     Var3  → CALLBACK_HOST     (Tasmota IP, must be reachable from KNX system)
   ─────────────────────────────────────────────────────────────────────────────
-#

import httpserver
import json
import string
