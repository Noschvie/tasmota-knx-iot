# tasmota-knx-io

> Experimental project. Tested with Tasmota on ESP32 and SCD41 telemetry.

Berry-based KNX IoT bridge for Tasmota devices.

`tasmota-knx-io` enables Tasmota devices to publish sensor telemetry to a KNX IoT backend using the KNX 3rd Party API. The driver is designed for reliability on resource-constrained ESP32 devices and focuses on efficient outbound value updates.

## Features

- KNX Group Address (GA) → Datapoint UUID resolution
- Persistent caching of resolved mappings
- Automatic cache validation during startup
- Change detection (only changed values are transmitted)
- Bulk datapoint updates for efficient communication
- OAuth2 Client Credentials authentication
- Automatic token refresh on authorization failures
- Lightweight state-machine driven startup process
- Designed for ESP32 devices running Tasmota

## Current Support

### Sensors

Currently tested with:

- SCD41
  - CarbonDioxide
  - Temperature
  - Humidity
  - DewPoint

Additional sensor support can be added by extending the telemetry mapping logic.

## Architecture

The driver follows a simple startup sequence:

```text
Network Check
      ↓
Backend API Check
      ↓
OAuth Authentication
      ↓
Cache Validation
      ↓
GA → UUID Resolution
      ↓
Operational Mode
```

During normal operation:

1. Tasmota publishes telemetry events.
2. The driver extracts configured values.
3. Values are compared against the previous state.
4. Only changed values are transmitted.
5. Updates are sent using bulk API requests.

## Why This Approach

The project intentionally avoids complex runtime subscriptions and focuses on:

- Predictable startup behavior
- Minimal runtime overhead
- Reduced network traffic
- Reliable operation on embedded hardware
- Simple deployment and troubleshooting

## Requirements

- ESP32-based device
- Tasmota with Berry scripting support
- Access to a KNX IoT backend supporting the KNX 3rd Party API
- OAuth2 Client Credentials authentication

## Installation

1. Install Tasmota on an ESP32 device.
2. Enable Berry scripting.
3. Upload the `*.be` script.
4. Configure:
   - Backend URL
   - OAuth credentials
   - KNX Group Addresses
   - Sensor mappings
5. Restart the device.

## Configuration Example

```text
CO2          -> 1/0/1
Temperature  -> 1/0/2
Humidity     -> 1/0/3
DewPoint     -> 1/0/4
```

During startup, the configured Group Addresses are resolved to backend datapoint UUIDs and stored locally.

## Status

### Current Focus

- Sensor → KNX IoT value updates
- Robust authentication handling
- Efficient datapoint transmission

## Contributing

Feedback, bug reports, and pull requests are welcome.

Particularly appreciated:

- Berry/Tasmota best practices
- Reliability improvements
- Additional sensor integrations
- KNX datapoint mapping suggestions

## Related Projects

- Tasmota
- KNX IoT
- KNX 3rd Party API
- KNX IoT API Server [semantic-knx-gateway](https://github.com/Noschvie/semantic-knx-gateway)

## License

This project is licensed under the Apache License 2.0.

See the [LICENSE](LICENSE) file for details.
