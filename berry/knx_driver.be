#!/usr/bin/env berry
# KNX ESP32 driver (UUID-only runtime, no callback/subscription)
# load("knx_driver.be")

import json
import string
import persist

# ---- Configuration -----------------------------------------------------------
var CFG_API_URL       = "http://knx-runtime-engine.example.org"
var CFG_API_BASE      = "/api/v2"
var CFG_OAUTH_ID      = "knx-default-client"
var CFG_OAUTH_SECRET  = "change-me-in-production"
var CFG_CACHE_VERSION = 1

# Provided datapoints (boot-time GA->UUID resolution only)
var CFG_POINTS = [
    {"ga":"3/1/21", "dpt":"9.001", "tele_key":"Temperature",     "critical":true},
    {"ga":"3/1/22", "dpt":"9.007", "tele_key":"Humidity",        "critical":true},
    {"ga":"3/1/23", "dpt":"9.008", "tele_key":"CarbonDioxide",   "critical":true},
    {"ga":"3/1/24", "dpt":"9.001", "tele_key":"DewPoint",        "critical":false},
]

class KNXDriver
    # State names are plain strings for easy logging.
    static var ST_INIT           = "INIT"
    static var ST_NETWORK_WAIT   = "NETWORK_WAIT"
    static var ST_API_CHECK      = "API_CHECK"
    static var ST_AUTH_INIT      = "AUTH_INIT"
    static var ST_CACHE_LOAD     = "CACHE_LOAD"
    static var ST_CACHE_VALIDATE = "CACHE_VALIDATE"
    static var ST_GA_RESOLVE     = "GA_RESOLVE"
    static var ST_READY          = "READY"
    static var ST_RUN            = "RUN"
    static var ST_DEGRADED       = "DEGRADED"

    var _state
    var _read_token
    var _write_token
    var _runtime_map
    var _last_value_dump
    var _tele_rule_registered

    def init()
        self._state = self.ST_INIT
        self._read_token = nil
        self._write_token = nil
        self._runtime_map = {}
        self._last_value_dump = {}
        self._tele_rule_registered = false
    end

    # ---- Public API ---------------------------------------------------------
    def start()
        self._transition(self.ST_INIT)

        self._transition(self.ST_NETWORK_WAIT)
        if !self._wait_network()
            return self._degrade("wifi not ready")
        end

        self._transition(self.ST_API_CHECK)
        if !self._api_check()
            return self._degrade("api check failed")
        end

        self._transition(self.ST_AUTH_INIT)
        self._read_token = self._get_token("read")
        if self._read_token == nil
            return self._degrade("read token missing")
        end

        self._transition(self.ST_CACHE_LOAD)
        var cache = self._load_cache()

        self._transition(self.ST_CACHE_VALIDATE)
        if self._cache_valid(cache)
            self._runtime_map = cache["map"]
        else
            self._transition(self.ST_GA_RESOLVE)
            var resolved = self._resolve_all_ga()
            if resolved == nil
                return self._degrade("ga resolve failed")
            end
            self._runtime_map = resolved
            self._save_cache({"version": CFG_CACHE_VERSION, "map": self._runtime_map})
        end

        self._transition(self.ST_READY)
        self._transition(self.ST_RUN)
        print(f"[{self._ts()}] KNX driver ready ({self._runtime_map.size()} mappings)")

        self._register_scd41_rule()

        return true
    end

    def stop()
        # No callback/subscription teardown needed in this mode.
        print(f"[{self._ts()}] KNX driver stopped")
    end

    def on_scd41_update(value, trigger, msg)
        if value == nil
            print(f"[{self._ts()}] SCD41 update ignored: nil value")
            return false
        end

        # Optional diagnostic field, not mapped to KNX in this driver.
        if value.find("eCO2") != nil
            # print(f"[{self._ts()}] eCO2: {value.find('eCO2')} ppm")
        end

        # print("--- SCD41 Update ---")
        # self._write_scd41_field("CarbonDioxide",  value.find("CarbonDioxide"))
        # self._write_scd41_field("Temperature",    value.find("Temperature"))
        # self._write_scd41_field("Humidity",       value.find("Humidity"))
        # self._write_scd41_field("DewPoint",       value.find("DewPoint"))

        var fields = ["CarbonDioxide", "Temperature", "Humidity", "DewPoint"]
        # API payload only
        var items_to_write = []
        # Local state updates applied only after successful write_many()
        var pending_updates = {}

        for field_name: fields
            var field_value = value.find(field_name)
            if field_value == nil
                continue
            end

            # Find target UUID + GA for this field
            var target = nil
            var ga_found = nil
            for ga: self._runtime_map.keys()
                var meta = self._runtime_map[ga]
                if meta != nil && meta.find("tele_key") == field_name
                    target = meta
                    ga_found = ga
                    break
                end
            end

            if target == nil
                print(f"[{self._ts()}] No KNX target configured for field {field_name}")
                continue
            end

            var uuid = target.find("uuid")
            var value_dump = json.dump(field_value)
            var last_dump = self._last_value_dump.find(ga_found)

            # Queue only changed values
            if last_dump != value_dump
                items_to_write.push({
                    "uuid": uuid,
                    "value": field_value,
                })
                pending_updates[ga_found] = value_dump
            end
        end

        if items_to_write.size() == 0
            print(f"[{self._ts()}] No value changes detected")
            return true
        end

        if self.write_many(items_to_write)
            for ga: pending_updates.keys()
                self._last_value_dump[ga] = pending_updates[ga]
            end
            # print(f"[{self._ts()}] KNX write_many success for {items_to_write.size()} fields")
            return true
        end

        print(f"[{self._ts()}] KNX write_many failed")
        return false
    end

    def write_uuid(uuid, value)
        if uuid == nil
            return false
        end

        if self._write_token == nil
            self._write_token = self._get_token("write")
            if self._write_token == nil
                print(f"[{self._ts()}] write token fetch failed")
                return false
            end
        end

        var body = {
            "data": [{
                "id": uuid,
                "attributes": {"value": str(value)},
            }],
        }

        var url = CFG_API_URL + CFG_API_BASE + "/datapoints/values"
        var body_str = json.dump(body)
        # print(f"[{self._ts()}] PUT {url} body={body_str}")

        var res = self._http_json("PUT", url, {
            "Authorization": "Bearer " + self._write_token,
            "Content-Type": "application/vnd.api+json",
            "Accept": "application/vnd.api+json",
        }, body_str)

        if res.find("code") == 401
            self._write_token = self._get_token("write")
            if self._write_token == nil
                return false
            end
            res = self._http_json("PUT", url, {
                "Authorization": "Bearer " + self._write_token,
                "Content-Type": "application/vnd.api+json",
                "Accept": "application/vnd.api+json",
            }, body_str)
        end

        if res.find("code") == 200 || res.find("code") == 204
            # print(f"[{self._ts()}] write_uuid success")
            return true
        end

        print(f"[{self._ts()}] write_uuid failed: HTTP {res.find('code')} body={res.find('raw')}")
        return false
    end

    def write_many(items)
        if items == nil || items.size() == 0
            return false
        end

        if self._write_token == nil
            self._write_token = self._get_token("write")
            if self._write_token == nil
                print(f"[{self._ts()}] write token fetch failed")
                return false
            end
        end

        # Build bulk body: [{"id": uuid, "attributes": {"value": v}}, ...]
        var data_array = []
        for item: items
            var uuid = item.find("uuid")
            var value = item.find("value")
            if uuid == nil || value == nil
                print(f"[{self._ts()}] write_many: skipping invalid item {json.dump(item)}")
                continue
            end
            data_array.push({
                "type": "datapoint",
                "id": uuid,
                "attributes": {"value": str(value)},
            })
        end

        if data_array.size() == 0
            print(f"[{self._ts()}] write_many: no valid items to write")
            return false
        end

        var body = {"data": data_array}
        var url = CFG_API_URL + CFG_API_BASE + "/datapoints/values"
        var body_str = json.dump(body)
        # print(f"[{self._ts()}] PUT {url} ({data_array.size()} items) body={body_str}")

        var res = self._http_json("PUT", url, {
            "Authorization": "Bearer " + self._write_token,
            "Content-Type": "application/vnd.api+json",
            "Accept": "application/vnd.api+json",
        }, body_str)

        if res.find("code") == 401
            self._write_token = self._get_token("write")
            if self._write_token == nil
                return false
            end
            res = self._http_json("PUT", url, {
                "Authorization": "Bearer " + self._write_token,
                "Content-Type": "application/vnd.api+json",
                "Accept": "application/vnd.api+json",
            }, body_str)
        end

        if res.find("code") == 200 || res.find("code") == 204
            # print(f"[{self._ts()}] write_many success ({data_array.size()} items)")
            return true
        end

        print(f"[{self._ts()}] write_many failed: HTTP {res.find('code')} body={res.find('raw')}")
        return false
    end

    # ---- Boot internals -----------------------------------------------------
    def _resolve_all_ga()
        var out = {}
        var critical_missing = false

        for item: CFG_POINTS
            var ga = item.find("ga")
            var meta = self._resolve_ga_with_retry(ga)
            if meta == nil
                print(f"[{self._ts()}] resolve failed for GA {ga}")
                if item.find("critical") == true
                    critical_missing = true
                end
                continue
            end

            out[ga] = {
                "uuid": meta.find("uuid"),
                "dpt": item.find("dpt"),
                "tele_key": item.find("tele_key"),
                "critical": item.find("critical"),
            }
        end

        if critical_missing
            return nil
        end
        return out
    end

    def _resolve_ga_with_retry(ga)
        var waits = [0, 200, 500]
        for wait_ms: waits
            if wait_ms > 0
                tasmota.delay(wait_ms)
            end
            var meta = self._fetch_dp_by_ga(ga)
            if meta != nil && meta.find("uuid") != nil
                return meta
            end
        end
        tasmota.delay(1000)
        return nil
    end

    def _fetch_dp_by_ga(ga)
        if self._read_token == nil
            return nil
        end

        var encoded_ga = string.replace(ga, "/", "%2F")
        var url = CFG_API_URL + CFG_API_BASE + "/datapoints?filter%5Bga%5D=" + encoded_ga
        var res = self._http_json("GET", url, {
            "Authorization": "Bearer " + self._read_token,
            "Accept": "application/vnd.api+json",
        }, nil)

        if res.find("code") == 401
            self._read_token = self._get_token("read")
            if self._read_token == nil
                return nil
            end
            res = self._http_json("GET", url, {
                "Authorization": "Bearer " + self._read_token,
                "Accept": "application/vnd.api+json",
            }, nil)
        end

        if res.find("code") != 200
            return nil
        end

        var payload = res.find("data")
        if payload == nil
            return nil
        end

        var arr = payload.find("data")
        if arr == nil || arr.size() == 0
            return nil
        end

        var d = arr[0]
        return {"uuid": d.find("id")}
    end

    def _register_scd41_rule()
        if self._tele_rule_registered
            return true
        end
        tasmota.add_rule("Tele#SCD41", /value, trigger, msg -> self.on_scd41_update(value, trigger, msg))
        self._tele_rule_registered = true
        print(f"[{self._ts()}] SCD41 Tele# rule registered")
        return true
    end

    # Legacy single-field write helper.
    # Currently not used by on_scd41_update(), retained only as fallback/debug path.
    def _write_scd41_field(field_name, field_value)
        if field_value == nil
            return false
        end

        var target = nil
        var ga_found = nil

        for ga: self._runtime_map.keys()
            var meta = self._runtime_map[ga]
            if meta != nil && meta.find("tele_key") == field_name
                target = meta
                ga_found = ga
                break
            end
        end

        if target == nil
            print(f"[{self._ts()}] No KNX target configured for field {field_name}")
            return false
        end

        var uuid = target.find("uuid")
        # print(f"[{self._ts()}] _write_scd41_field field={field_name} value={field_value} ga={ga_found} uuid={uuid}")

        var value_dump = json.dump(field_value)
        var last_dump = self._last_value_dump.find(ga_found)
        if last_dump == value_dump
            return true
        end

        if self.write_uuid(uuid, field_value)
            self._last_value_dump[ga_found] = value_dump
            # print(f"[{self._ts()}] KNX write GA={ga_found} field={field_name} value={value_dump}")
            return true
        end

        print(f"[{self._ts()}] KNX write failed GA={ga_found} field={field_name}")
        return false
    end

    def _cache_valid(cache)
        if cache == nil
            return false
        end
        if cache.find("version") != CFG_CACHE_VERSION
            return false
        end

        var mp = cache.find("map")
        if mp == nil
            return false
        end

        # Ensure all critical GAs exist in cache.
        for item: CFG_POINTS
            if item.find("critical") == true && mp.find(item.find("ga")) == nil
                return false
            end
        end
        return true
    end

    def _load_cache()
        if !persist.has("knx_driver_cache")
            return nil
        end
        return persist.knx_driver_cache
    end

    def _save_cache(cache)
        persist.knx_driver_cache = cache
        persist.save()
    end

    def _wait_network()
        for i: 1..20
            var info = tasmota.wifi()
            if info != nil
                var ip = info.find("ip")
                if ip != nil && ip != "0.0.0.0"
                    return true
                end
            end
            tasmota.delay(500)
        end
        return false
    end

    def _api_check()
        var url = CFG_API_URL + "/health"
        var res = self._http_json("GET", url, {}, nil)
        return res.find("code") == 200
    end

    def _get_token(scope)
        var body = "grant_type=client_credentials&scope=" + scope
        var res = self._http_json("POST", CFG_API_URL + "/oauth/access", {
            "Authorization": "Basic " + self._b64(CFG_OAUTH_ID + ":" + CFG_OAUTH_SECRET),
            "Content-Type": "application/x-www-form-urlencoded",
        }, body)

        if res.find("code") != 200
            print(f"[{self._ts()}] oauth '{scope}' failed (HTTP {res.find('code')})")
            return nil
        end

        var payload = res.find("data")
        if payload == nil
            return nil
        end
        return payload.find("access_token")
    end

    # ---- Generic helpers ----------------------------------------------------
    def _http_json(method, url, headers, body)
        var cl = webclient()
        cl.begin(url)

        if headers != nil
            for k: headers.keys()
                cl.add_header(k, headers[k])
            end
        end

        var code = 0
        if method == "GET"
            code = cl.GET()
        elif method == "POST"
            code = cl.POST(body)
        elif method == "PUT"
            code = cl.PUT(body)
        elif method == "PATCH"
            code = cl.PATCH(body)
        elif method == "DELETE"
            code = cl.DELETE()
        else
            cl.close()
            return {"code": 0, "raw": nil, "data": nil}
        end

        var raw = cl.get_string()
        cl.close()

        var parsed = nil
        if raw != nil && raw != ""
            parsed = json.load(raw)
        end
        return {"code": code, "raw": raw, "data": parsed}
    end

    def _transition(next_state)
        self._state = next_state
        print(f"[{self._ts()}] state -> {next_state}")
    end

    def _degrade(reason)
        self._transition(self.ST_DEGRADED)
        print(f"[{self._ts()}] degraded: {reason}")
        return false
    end

    def _ts()
        var s = tasmota.time_str(tasmota.rtc()["local"])
        var parts = string.split(s, "T")
        return parts[1]
    end

    def _b64(s)
        var b = bytes()
        b.fromstring(s)
        return b.tob64()
    end
end

# Global singleton + convenience functions
var knx_driver = KNXDriver()

def knx_start()
    return knx_driver.start()
end

def knx_stop()
    return knx_driver.stop()
end

# Autostart on load
knx_start()
