# KNX ESP32 Driver – Requirements & Design Document

| | |
|---|---|
| **Version** | 1.0 |
| **Status** | Draft |
| **Datum** | 2025 |
| **Scope** | Intern / Projekt |

---

## Inhaltsverzeichnis

1. [Zweck & Überblick](#1-zweck--überblick)
2. [Ziele](#2-ziele)
3. [Systemarchitektur](#3-systemarchitektur)
4. [Boot-Lifecycle & State Machine](#4-boot-lifecycle--state-machine)
5. [Authentifizierung](#5-authentifizierung)
6. [GA → UUID Auflösung](#6-ga--uuid-auflösung)
7. [Cache-System](#7-cache-system)
8. [Laufzeitverhalten](#8-laufzeitverhalten)
9. [API Layer](#9-api-layer)
10. [Fehlerbehandlung](#10-fehlerbehandlung)
11. [System-States](#11-system-states)
12. [Randbedingungen & Constraints](#12-randbedingungen--constraints)
13. [Geplante Erweiterungen](#13-geplante-erweiterungen)
14. [Zusammenfassung](#14-zusammenfassung)

---

## 1 Zweck & Überblick

Dieses Dokument beschreibt die Anforderungen und das technische Design für einen ESP32-basierten KNX-Treiber auf Basis von Tasmota und Berry.

Das System fungiert als Bridge zwischen KNX Group Addresses (GA) und einer 3rd-Party KNX API, die auf UUID-basierten Datenpunkt-Referenzen operiert.

> **Kernziel:** GA-Adressen werden ausschließlich während des Boot-Vorgangs aufgelöst. Im Laufzeitbetrieb operiert das System UUID-only – ohne KNX-Konfigurationsabhängigkeit.

### 1.1 System Context

| Komponente | Technologie | Rolle |
|---|---|---|
| Mikrocontroller | ESP32 | Hardware-Plattform |
| Firmware | Tasmota | Runtime-Umgebung |
| Scripting | Berry | Treiber-Implementierung |
| KNX Anbindung | 3rd Party API (v2.1.0) | Datenpunkt-Zugriff |
| Auth | Basic Auth / OAuth2 | Zugriffssicherung |

---

## 2 Ziele

### 2.1 Funktionale Ziele

- **GA → UUID Auflösung:** Group Addresses werden über die API zu Datapoint UUIDs aufgelöst
- **UUID-only Laufzeitbetrieb:** Schreiboperationen ausschließlich via UUID nach dem Boot
- **Batch-Writes:** Mehrere Datenpunkte in einem einzigen API-Call
- **Authentifizierung:** Basic Auth und OAuth2 (inkl. automatischem Token-Re-Fetch)
- **Persistenter Cache:** Aufgelöste GA → UUID Mappings werden lokal gespeichert
- **Retry-Logik:** Robuste Fehlerbehandlung mit exponentiellem Backoff

### 2.2 Nicht-funktionale Ziele

- Schneller Boot via Cache-Reuse (kein unnötiger API-Roundtrip)
- Deterministisches State-Machine-Verhalten
- Resilienz gegenüber API/Netzwerkausfällen
- Minimaler RAM/CPU-Verbrauch (ESP32-Constraints)
- Keine MQTT-Abhängigkeit
- Keine Runtime-GA-Auflösung nach erfolgreichem Boot

---

## 3 Systemarchitektur

Das System ist in klar getrennte Schichten gegliedert:

```
KNXDriver
├── Runtime Layer    (UUID-only Execution)
├── Cache Layer      (GA → UUID Mapping, persistent)
├── Resolver Layer   (GA Resolution, Boot-only)
├── API Layer        (HTTP Abstraction, kein Business-Logic)
└── Auth Layer       (Basic Auth / OAuth2, Token-Verwaltung)
```

### 3.1 Kern-Konzepte

| Begriff | Format / Beispiel | Verwendung |
|---|---|---|
| Group Address (GA) | `5/1/1` | Nur während Initialisierung |
| Datapoint UUID | `uuid-abc-…` | Exklusiv im Laufzeitbetrieb |
| Datapoint Type (DPT) | `1.001`, `9.001`, … | Validierung (nicht blockierend) |

---

## 4 Boot-Lifecycle & State Machine

### 4.1 State Machine

Der Boot-Prozess durchläuft folgende States deterministisch:

```
INIT
 └─► WIFI_WAIT
      └─► API_CHECK
           └─► AUTH_INIT
                └─► CACHE_LOAD
                     └─► CACHE_VALIDATE
                          ├─► GA_RESOLVE   (nur wenn Cache ungültig)
                          └─► READY
                               └─► RUN
```

| State | Beschreibung |
|---|---|
| `INIT` | System startet, Konfiguration laden |
| `WIFI_WAIT` | Warten auf Netzwerkverbindung |
| `API_CHECK` | Erreichbarkeit der KNX API prüfen |
| `AUTH_INIT` | Beide OAuth2-Tokens holen (`manage` + `read`) |
| `CACHE_LOAD` | Cache aus Speicher laden |
| `CACHE_VALIDATE` | Cache-Integrität & Version prüfen |
| `GA_RESOLVE` | GA → UUID Auflösung (nur wenn Cache ungültig) |
| `READY` | System einsatzbereit |
| `RUN` | Laufzeitbetrieb (UUID-only) |

### 4.2 Boot-Regeln

- Das System **MUSS** entweder `READY` oder `DEGRADED` erreichen
- Partieller Laufzeitbetrieb ist nicht zulässig
- GA-Auflösung findet ausschließlich während des Boot-Vorgangs statt
- Nach erfolgreichem Boot: kein Cache-Write, kein GA-Lookup
- Schlägt `AUTH_INIT` fehl (ein Token ist `nil`): **Abort**, kein weiterer Boot-Fortschritt

---

## 5 Authentifizierung

Die Authentifizierung basiert auf dem **OAuth2 Client Credentials Grant Flow**, wie in `knx_subscribe.be` implementiert. Basic Auth dient ausschließlich als Transport-Mechanismus für den Token-Endpoint – nicht für den API-Zugriff selbst.

> **Prinzip:** Basic Auth → Token Endpoint → Bearer Token → API.
> Zwei separate Tokens für unterschiedliche Scopes (`manage` / `read`) werden unabhängig verwaltet.

### 5.1 Token-Übersicht

| Token | Scope | Verwendet für | Variable (Berry) |
|---|---|---|---|
| Manage Token | `manage` | Subscriptions (POST / PATCH / DELETE) | `_manage_token` |
| Read Token | `read` | Datenpunkt-Lookup (GET) | `_read_token` |

### 5.2 Token-Fetch Sequenz (`get_token`)

Implementiert in: `get_token(scope)` – `knx_subscribe.be`

| # | Schritt | Detail |
|---|---|---|
| 1 | HTTP POST | `POST /oauth/access` |
| 2 | Authorization Header | `Basic base64(client_id:client_secret)` |
| 3 | Content-Type | `application/x-www-form-urlencoded` |
| 4 | Body | `grant_type=client_credentials&scope=<manage\|read>` |
| 5 | Response (HTTP 200) | JSON mit `access_token` Feld |
| 6 | Fehler (non-200) | Log + return `nil` (kein crash) |

```berry
def get_token(scope)
    var cl = webclient()
    cl.begin(CFG_API_URL + "/oauth/access")
    cl.add_header("Authorization", "Basic " + b64(CFG_OAUTH_ID + ":" + CFG_OAUTH_SECRET))
    cl.add_header("Content-Type", "application/x-www-form-urlencoded")
    var body = "grant_type=client_credentials&scope=" + scope
    var code = cl.POST(body)
    if code != 200
        print(f"OAuth '{scope}' failed (HTTP {code})")
        cl.close()
        return nil
    end
    var data = json.load(cl.get_string())
    cl.close()
    return data["access_token"]
end
```

### 5.3 Token-Nutzung im API-Zugriff

Nach erfolgreichem Token-Fetch wird der Token als Bearer-Token in alle API-Requests injiziert:

```berry
# Read-Operationen (Datenpunkt-Lookup)
cl.add_header("Authorization", "Bearer " + _read_token)

# Manage-Operationen (Subscriptions)
cl.add_header("Authorization", "Bearer " + _manage_token)
```

### 5.4 Subscription-Renewal als impliziter Keep-Alive

In `knx_subscribe.be` wird **kein klassischer OAuth2 Refresh-Token-Flow** verwendet. Stattdessen wird die Subscription-Lifetime periodisch via `PATCH` erneuert, was den `_manage_token` aktiv hält.

Das Renewal-Intervall beträgt die **halbe konfigurierte Lifetime**:

```berry
# Renewal-Intervall = halbe Subscription-Lifetime
var interval_ms = (CFG_LIFETIME_MIN * 60 * 1000) / 2
tasmota.set_timer(interval_ms, renew_subscription)
```

| `CFG_LIFETIME_MIN` | Renewal-Intervall | PATCH Endpoint |
|---|---|---|
| 5 min (Default) | 150 Sekunden | `PATCH /api/v1/subscriptions/{id}` |
| 10 min | 300 Sekunden | `PATCH /api/v1/subscriptions/{id}` |
| 60 min | 1800 Sekunden | `PATCH /api/v1/subscriptions/{id}` |

```berry
def renew_subscription()
    var body = {
        "data": {
            "type": "subscription",
            "id":   _subscription_id,
            "attributes": {"lifetime": {"minutes": CFG_LIFETIME_MIN}},
        },
    }
    # PATCH mit _manage_token
    # Bei Erfolg: nächsten Renewal-Timer setzen
    var interval_ms = (CFG_LIFETIME_MIN * 60 * 1000) / 2
    tasmota.set_timer(interval_ms, renew_subscription)
end
```

### 5.5 Token-Refresh via Re-Fetch

Da kein OAuth2 Refresh-Token vorhanden ist, erfolgt bei abgelaufenem oder ungültigem Token eine vollständige Neuanforderung via `get_token(scope)` (erneuter Client-Credentials-Grant):

| Situation | Verhalten |
|---|---|
| Token gültig | Bearer Token direkt verwenden |
| Token `nil` (Initialisierung) | `get_token(scope)` → neuer Token |
| Token `nil` (nach Fehler) | `get_token(scope)` → neuer Token |
| HTTP 401 bei API-Call | Token als ungültig markieren → Re-Fetch |
| `get_token` liefert `nil` | Abort mit Log-Eintrag (kein crash) |

### 5.6 Token-Handling-Regeln

- Beide Tokens (`_manage_token`, `_read_token`) werden beim Start via `start_knx_subscription()` initial geholt
- Kein Refresh-Token-Flow: Token-Erneuerung erfolgt als erneuter Client-Credentials-Grant
- Basic Auth Credentials werden Base64-kodiert: `b64(id + ":" + secret)`
- Tokens leben nur im RAM – **kein persistentes Speichern auf Flash**
- Subscription-Renewal (PATCH) bei halber Lifetime hält die Session aktiv
- Bei `nil`-Token nach Boot: kein partieller Betrieb (Abort-Regel gilt)

### 5.7 Konfigurationsparameter (Auth)

| Variable (Berry) | Default | Beschreibung |
|---|---|---|
| `CFG_OAUTH_ID` | `knx-default-client` | OAuth2 Client-ID für Basic Auth Header |
| `CFG_OAUTH_SECRET` | `change-me-in-production` | Client-Secret (**MUSS produktiv geändert werden**) |
| `CFG_LIFETIME_MIN` | `5` | Subscription-Lifetime in Minuten |
| `CFG_API_URL` | `http://...:3000` | Basis-URL der KNX 3rd Party API |

---

## 6 GA → UUID Auflösung

### 6.1 Auflösungsregeln

- Jede GA wird via API zu einem Datapoint UUID aufgelöst
- Auflösung findet ausschließlich im State `GA_RESOLVE` (Boot) statt
- Maximale Versuche: 3 (mit exponentiellem Backoff)
- Fehler werden geloggt, crashen das System nicht
- Fehlende kritische Mappings → `DEGRADED` State

### 6.2 Retry-Strategie

| Versuch | Wartezeit | Aktion bei Fehler |
|---|---|---|
| 1 | – | Direkter Request |
| 2 | 200 ms | Retry nach kurzem Backoff |
| 3 | 500 ms | Retry nach mittlerem Backoff |
| Fail | 1000 ms | Logging + `DEGRADED` wenn kritisch |

---

## 7 Cache-System

### 7.1 Cache-Struktur

Der Cache wird als JSON-Blob in Tasmota-Speicher (Mem1 oder equivalentes Persistenz-Medium) abgelegt:

```json
{
  "version": 1,
  "map": {
    "5/1/1": "uuid-abc-...",
    "5/1/2": "uuid-def-..."
  }
}
```

### 7.2 Cache-Validierungsregeln

- Cache wird bei jedem Boot geladen und validiert
- Cache gilt als **ungültig** bei:
    - Version-Mismatch
    - Korrupter Struktur
    - Fehlenden Pflichtfeldern
- Ungültiger Cache → vollständige GA-Re-Auflösung
- Cache-Writes **nur** während Boot (`GA_RESOLVE` State), niemals im Laufzeitbetrieb

---

## 8 Laufzeitverhalten

### 8.1 Betriebsmodus

> Nach erfolgreichem Boot operiert das System ausschließlich mit UUIDs. GA-Lookups und Cache-Schreibvorgänge sind im `RUN`-State verboten.

### 8.2 Schreiboperationen

| Typ | Input → Verarbeitung | Output |
|---|---|---|
| Single Write | GA + Wert → In-Memory UUID Lookup | API-Write via UUID |
| Batch Write *(bevorzugt)* | N × GA + Wert → Batch-Auflösung | Einzel-API-Call für alle Datenpunkte |

---

## 9 API Layer

Der API Layer ist eine reine HTTP-Abstraktionsschicht ohne Business-Logik und ohne GA-Kenntnis.

### 9.1 API-Funktionen

| Funktion | Methode | Beschreibung |
|---|---|---|
| `getDatapointByGA(ga)` | GET | Datenpunkt per GA abfragen → UUID + DPT |
| `writeDatapoint(uuid, val)` | POST / PUT | Einzelnen Datenpunkt schreiben |
| `batchWrite(items[])` | POST / PUT | Mehrere Datenpunkte in einem Call |
| `createSubscription(dp_uuid, url)` | POST | HTTP Callback Subscription anlegen |
| `renewSubscription(id)` | PATCH | Subscription-Lifetime verlängern |
| `deleteSubscription(id)` | DELETE | Subscription entfernen |
| `injectAuthHeader(req, token)` | – | Bearer-Token automatisch anhängen |

---

## 10 Fehlerbehandlung

### 10.1 Fehlerkategorien & Recovery

| Fehlertyp | Schwere | Recovery-Strategie |
|---|---|---|
| Netzwerkausfall | Transient | Retry mit Backoff |
| Auth-Fehler (Token `nil`) | Transient | `get_token()` Re-Fetch |
| Auth-Fehler (HTTP 401) | Transient | Token invalidieren → Re-Fetch |
| Auth-Fehler (Re-Fetch fehlgeschlagen) | Kritisch | `DEGRADED` State |
| API Timeout | Transient | Retry (max. 3×) |
| Cache-Korruption | Warnung | Vollständige GA-Re-Auflösung |
| Fehlende GA-Mapping | Kritisch | `DEGRADED` wenn GA als kritisch markiert |
| Subscription-Renewal fehlgeschlagen | Warnung | Log + nächster Versuch beim nächsten Intervall |

---

## 11 System-States

| State | Bedeutung |
|---|---|
| ✅ `READY` | Vollständig operativ. UUID-only Execution aktiv. Alle GAs erfolgreich aufgelöst. |
| ⚠️ `DEGRADED` | Eingeschränkter Betrieb. Partielle oder keine API-Verfügbarkeit. Kritische GAs fehlen. |
| ❌ `INIT FAILURE` | Kein gültiger Laufzustand erreichbar. Manueller Eingriff erforderlich. |

---

## 12 Randbedingungen & Constraints

| Constraint | Beschreibung |
|---|---|
| ESP32 Memory | Begrenzter RAM erfordert sparsame Datenstrukturen |
| Tasmota Runtime | Berry-Scripting-Umgebung mit eingeschränktem Stdlib-Scope |
| Berry Limits | Keine nativen Threads, eingeschränkte Async-Patterns |
| Token Storage | Kein sicherer persistenter Tokenspeicher nativ verfügbar – Tokens nur im RAM |
| KNX API Version | Ausgelegt auf KNX IoT 3rd Party API v2.1.0 |
| OAuth2 Flow | Nur Client Credentials Grant – kein Authorization Code, kein Refresh-Token-Flow |

---

## 13 Geplante Erweiterungen

- Verschlüsselte Token-Speicherung (NVRAM / Secure Element)
- Multi-API Fallback Support
- Offline-Queue für Schreiboperationen bei Netzwerkausfall
- DPT-basierte Validierung (enforcement statt nur logging)
- Watchdog-basiertes Recovery-System
- OTA-Konfigurationsupdate für GA-Mappings
- Expliziter Refresh-Token-Flow (sofern API-seitig unterstützt)

---

## 14 Zusammenfassung

> **Designprinzip:** Strikte Trennung zwischen Konfigurationsphase (GA) und Laufzeitphase (UUID). Deterministisches Bootverhalten mit klaren State-Übergängen.

Diese Architektur stellt sicher:

- Strikte Trennung von Konfiguration (GA) und Runtime (UUID)
- Robustes Authentifizierungs-Handling: OAuth2 Client Credentials, Bearer Token, Keep-Alive via Subscription-Renewal
- Deterministisches Boot-Verhalten durch State Machine
- Minimale Runtime-Abhängigkeiten von der KNX-Konfiguration
- Stabiler Betrieb unter Netzwerk- und API-Instabilität

---

*KNX ESP32 Driver – Requirements & Design Document v1.0 | Intern / Projekt*
