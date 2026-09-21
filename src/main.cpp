#include <M5Unified.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <WebServer.h>
#include <NimBLEDevice.h>

namespace {
// BLE is the primary transport and pushes updates as they happen. Keep the
// HTTP fallback responsive too when BLE is unavailable.
constexpr uint32_t POLL_MS = 500;
constexpr uint32_t WIFI_TIMEOUT_MS = 15000;
constexpr char AP_SSID[] = "CODEX-TIP-SETUP";
constexpr char AP_PASSWORD[] = "codex-tip";
constexpr char BLE_SERVICE_UUID[] = "5f6d0001-7f62-4da0-99e6-401b1de91a00";
constexpr char BLE_STATUS_UUID[] = "5f6d0002-7f62-4da0-99e6-401b1de91a00";

Preferences prefs;
WebServer portal(80);
M5Canvas screen(&M5.Display);
String bridgeUrl;
String configuredSsid;
String lastError;
uint32_t nextPoll = 0;
uint32_t lastDrawAt = 0;
bool wasTouching = false;
volatile bool bleConnected = false;
volatile uint32_t lastBleAt = 0;
volatile bool dashboardDirty = false;

struct Dashboard {
  String plan = "--";
  int primaryPercent = -1;
  int secondaryPercent = -1;
  bool quotaStale = false;
  int resetCredits = -1;
  uint64_t primaryReset = 0;
  uint64_t secondaryReset = 0;
  int primaryResetMinutes = -1;
  int secondaryResetMinutes = -1;
  uint64_t todayTokens = 0;
  uint64_t lifetimeTokens = 0;
  uint64_t peakDailyTokens = 0;
  int activeTasks = 0;
  int recentTasks = 0;
  String task = "Waiting for Codex…";
  String event;
  struct TaskBubble { String name; String status = "RUN"; uint64_t tokens = 0; } bubbles[4];
  int bubbleCount = 0;
  int incomingBubble = -1;
  bool valid = false;
} dashboard;

void applyBleStatus(const std::string& packet) {
  // The Mac sends a compact key=value frame. It fits in a single BLE write
  // with the negotiated MTU and deliberately carries no credentials.
  String data(packet.c_str());
  int start = 0;
  while (start < data.length()) {
    int end = data.indexOf(';', start);
    if (end < 0) end = data.length();
    String field = data.substring(start, end);
    int equals = field.indexOf('=');
    if (equals > 0) {
      String key = field.substring(0, equals);
      String value = field.substring(equals + 1);
      if (key == "PL") dashboard.plan = value;
      else if (key == "P") dashboard.primaryPercent = value.toInt();
      else if (key == "S") dashboard.secondaryPercent = value.toInt();
      else if (key == "Q") dashboard.quotaStale = value.toInt() != 0;
      else if (key == "PR") dashboard.primaryReset = strtoull(value.c_str(), nullptr, 10);
      else if (key == "SR") dashboard.secondaryReset = strtoull(value.c_str(), nullptr, 10);
      else if (key == "PM") dashboard.primaryResetMinutes = value.toInt();
      else if (key == "SM") dashboard.secondaryResetMinutes = value.toInt();
      else if (key == "C") dashboard.resetCredits = value.toInt();
      else if (key == "D") dashboard.todayTokens = strtoull(value.c_str(), nullptr, 10);
      else if (key == "L") dashboard.lifetimeTokens = strtoull(value.c_str(), nullptr, 10);
      else if (key == "M") dashboard.peakDailyTokens = strtoull(value.c_str(), nullptr, 10);
      else if (key == "A") dashboard.activeTasks = value.toInt();
      else if (key == "B") dashboard.bubbleCount = constrain(value.toInt(), 0, 4);
      else if (key == "I") dashboard.incomingBubble = constrain(value.toInt(), 0, 3);
      else if (key == "N" && dashboard.incomingBubble >= 0) dashboard.bubbles[dashboard.incomingBubble].name = value;
      else if (key == "V" && dashboard.incomingBubble >= 0) dashboard.bubbles[dashboard.incomingBubble].tokens = strtoull(value.c_str(), nullptr, 10);
      else if (key == "X" && dashboard.incomingBubble >= 0) dashboard.bubbles[dashboard.incomingBubble].status = value;
      else if (key == "R") dashboard.recentTasks = value.toInt();
      else if (key == "T") dashboard.task = value;
      else if (key == "E") dashboard.event = value;
    }
    start = end + 1;
  }
  dashboard.valid = true;
  lastBleAt = millis();
  dashboardDirty = true;
  lastError = "";
  Serial.printf("BLE dashboard frame: %u bytes\n", static_cast<unsigned>(packet.size()));
}

class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override { bleConnected = true; }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
    bleConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

class BleStatusCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo&) override {
    applyBleStatus(characteristic->getValue());
  }
};

void startBle() {
  NimBLEDevice::init("CODEX-TIP");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new BleServerCallbacks());
  NimBLEService* service = server->createService(BLE_SERVICE_UUID);
  NimBLECharacteristic* status = service->createCharacteristic(
      BLE_STATUS_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  status->setCallbacks(new BleStatusCallbacks());
  service->start();
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setName("CODEX-TIP");
  advertising->start();
}

String htmlEscape(const String& input) {
  String output;
  for (char c : input) {
    if (c == '&') output += "&amp;";
    else if (c == '<') output += "&lt;";
    else if (c == '>') output += "&gt;";
    else if (c == '\"') output += "&quot;";
    else output += c;
  }
  return output;
}

void startPortal() {
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  portal.on("/", HTTP_GET, [] {
    String page = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                  "<style>body{font:17px -apple-system,sans-serif;margin:24px;color:#101828}input{width:100%;box-sizing:border-box;padding:11px;margin:7px 0 16px;border:1px solid #98a2b3;border-radius:8px}button{background:#10a37f;color:white;border:0;border-radius:8px;padding:12px 18px;font-weight:700}</style>"
                  "<h2>Codex Tip setup</h2><p>Connect this M5Stack to your Wi-Fi and enter the Mac's LAN address for the local bridge.</p>"
                  "<form method=post action=/save><label>Wi-Fi name</label><input name=ssid value='" + htmlEscape(configuredSsid) + "' required>"
                  "<label>Wi-Fi password</label><input name=password type=password>"
                  "<label>Bridge URL</label><input name=bridge value='" + htmlEscape(bridgeUrl) + "' placeholder='http://192.168.1.20:8765/status' required>"
                  "<button>Save & connect</button></form><p>Setup AP: <b>CODEX-TIP-SETUP</b> · password: <b>codex-tip</b></p>";
    portal.send(200, "text/html; charset=utf-8", page);
  });
  portal.on("/save", HTTP_POST, [] {
    String ssid = portal.arg("ssid");
    String password = portal.arg("password");
    String bridge = portal.arg("bridge");
    prefs.putString("ssid", ssid);
    if (password.length()) prefs.putString("password", password);
    prefs.putString("bridge", bridge);
    portal.send(200, "text/html; charset=utf-8", "<meta http-equiv='refresh' content='2;url=/'><h2>Saved. Connecting…</h2>");
    delay(250);
    ESP.restart();
  });
  portal.begin();
}

void connectWiFi() {
  configuredSsid = prefs.getString("ssid", "");
  String password = prefs.getString("password", "");
  bridgeUrl = prefs.getString("bridge", "");
  WiFi.mode(WIFI_AP_STA);
  if (configuredSsid.length()) WiFi.begin(configuredSsid.c_str(), password.c_str());
  else WiFi.begin(); // Retains an existing ESP-IDF station configuration when available.
  uint32_t began = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - began < WIFI_TIMEOUT_MS) {
    M5.update();
    delay(100);
  }
  if (WiFi.status() != WL_CONNECTED) lastError = "Wi-Fi not connected";
}

String compactNumber(uint64_t value) {
  if (value >= 1000000) return String((float)value / 1000000.0f, 1) + "M";
  if (value >= 1000) return String((float)value / 1000.0f, 1) + "K";
  return String((unsigned long)value);
}

String until(uint64_t epoch) {
  if (!epoch) return "--";
  int64_t seconds = (int64_t)epoch - (int64_t)time(nullptr);
  if (seconds <= 0) return "now";
  uint32_t minutes = seconds / 60;
  if (minutes < 60) return String(minutes) + "m";
  return String(minutes / 60) + "h" + String(minutes % 60) + "m";
}

String duration(int minutes) {
  if (minutes < 0) return "--";
  uint32_t value = static_cast<uint32_t>(minutes);
  uint32_t days = value / 1440;
  uint32_t hours = (value % 1440) / 60;
  uint32_t mins = value % 60;
  if (days) return String(days) + "d " + String(hours) + "h " + String(mins) + "m";
  if (hours) return String(hours) + "h " + String(mins) + "m";
  return String(mins) + "m";
}

void text(int x, int y, const String& value, uint16_t color, int size = 1) {
  screen.setTextColor(color, TFT_BLACK);
  screen.setTextSize(size);
  screen.setCursor(x, y);
  screen.print(value);
}

void centered(int y, const String& value, uint16_t color, int size = 1) {
  screen.setTextSize(size);
  int x = (screen.width() - screen.textWidth(value)) / 2;
  text(max(0, x), y, value, color, size);
}

void progress(int x, int y, int percent, uint16_t color) {
  screen.fillRoundRect(x, y, 294, 9, 4, 0x2104);
  if (percent >= 0) screen.fillRoundRect(x, y, constrain(percent, 0, 100) * 294 / 100, 9, 4, color);
}

void bubbleText(int cx, int y, const String& value, uint16_t color) {
  screen.setTextSize(1);
  text(max(0, cx - screen.textWidth(value) / 2), y, value, color, 1);
}

String nextBubbleLine(const String& source, size_t& offset, int maxWidth) {
  String line;
  while (offset < source.length()) {
    uint8_t first = static_cast<uint8_t>(source[offset]);
    size_t bytes = first < 0x80 ? 1 : (first < 0xE0 ? 2 : (first < 0xF0 ? 3 : 4));
    if (offset + bytes > source.length()) break;
    String candidate = line + source.substring(offset, offset + bytes);
    // M5GFX measures UTF-8 glyphs correctly for whichever display font is in use.
    if (line.length() && screen.textWidth(candidate) > maxWidth) break;
    line = candidate;
    offset += bytes;
  }
  return line;
}

void drawTaskBubble(int cx, int cy, int radius, const Dashboard::TaskBubble& task, uint16_t color) {
  auto& d = screen;
  d.fillCircle(cx, cy, radius, 0x0842);
  d.drawCircle(cx, cy, radius + 1, color);
  d.drawCircle(cx, cy, radius - 3, 0x2945);
  if (task.status == "RUN") {
    // Animate locally; no extra BLE packets are needed. One revolution / 2s.
    float angle = (millis() % 2000) * (2.0f * PI / 2000.0f) - PI / 2;
    for (int i = 2; i >= 0; --i) {
      float a = angle - i * 0.22f;
      int x = cx + lroundf(cosf(a) * (radius - 1));
      int y = cy + lroundf(sinf(a) * (radius - 1));
      d.fillCircle(x, y, i == 0 ? 3 : 2, i == 0 ? TFT_WHITE : color);
    }
  }
  screen.setTextSize(2);
  int tokenX = max(0, cx - screen.textWidth(compactNumber(task.tokens)) / 2);
  text(tokenX, cy - 17, compactNumber(task.tokens), color, 2);
  String title = task.name.length() ? task.name : "Codex task";
  // BLE names are UTF-8. The default bitmap font has no Chinese glyphs;
  // select the bundled Simplified Chinese font for both measuring and drawing.
  d.setFont(&fonts::efontCN_12);
  d.setTextSize(1);
  size_t offset = 0;
  String firstLine = nextBubbleLine(title, offset, radius * 2 - 8);
  String secondLine = nextBubbleLine(title, offset, radius * 2 - 8);
  bubbleText(cx, cy - 1, firstLine, TFT_WHITE);
  bubbleText(cx, cy + 12, secondLine, TFT_WHITE);
  d.setFont(&fonts::Font0);
}

void draw() {
  auto& d = screen;
  d.fillScreen(TFT_BLACK);
  constexpr uint16_t headerColor = 0x0B2E;
  constexpr int headerHeight = 28;
  int count = min(4, dashboard.bubbleCount);
  uint64_t visibleTokens = 0;
  for (int i = 0; i < count; ++i) visibleTokens += dashboard.bubbles[i].tokens;
  d.fillRect(0, 0, 320, headerHeight, headerColor);
  d.setTextSize(2);
  d.setTextColor(TFT_WHITE, headerColor);
  int headerY = (headerHeight - d.fontHeight()) / 2;
  d.setCursor(12, headerY);
  d.print(dashboard.plan);
  String total = compactNumber(visibleTokens);
  d.setCursor(308 - d.textWidth(total), headerY);
  d.print(total);

  String reset = dashboard.primaryResetMinutes >= 0 ? duration(dashboard.primaryResetMinutes) : until(dashboard.primaryReset);
  String percent = dashboard.primaryPercent < 0 ? "--" : String(dashboard.primaryPercent) + "%";
  text(14, 34, percent, TFT_WHITE, 3);
  if (dashboard.quotaStale) text(104, 44, "STALE", 0xFD20, 1);
  if (dashboard.secondaryPercent >= 0) {
    text(170, 43, "LONG " + String(dashboard.secondaryPercent) + "%", 0xBDF7, 2);
  }
  progress(13, 65, dashboard.primaryPercent, dashboard.primaryPercent > 80 ? 0xFD20 : 0x05F6);

  if (count == 0) {
    centered(142, "NO ACTIVE TASK", 0xBDF7, 2);
  } else {
    static const int positions[4][4][2] = {
      {{160,148},{0,0},{0,0},{0,0}},
      {{92,148},{228,148},{0,0},{0,0}},
      {{65,171},{160,122},{255,171},{0,0}},
      {{88,113},{232,113},{88,185},{232,185}}
    };
    static const int minRadius[] = {44, 36, 29, 25};
    static const int maxRadius[] = {65, 60, 43, 32};
    uint64_t maxTokens = 1;
    for (int i = 0; i < count; ++i) maxTokens = max(maxTokens, dashboard.bubbles[i].tokens);
    for (int i = 0; i < count; ++i) {
      // Radius is directly proportional to the task's token count.
      int radius = minRadius[count - 1] + (int)((maxRadius[count - 1] - minRadius[count - 1]) * ((float)dashboard.bubbles[i].tokens / maxTokens));
      // Colour is only lifecycle state: yellow means running; green means a
      // just-completed task held on screen briefly for confirmation.
      uint16_t color = dashboard.bubbles[i].status == "WAIT" ? TFT_RED :
                       dashboard.bubbles[i].status == "STOP" ? 0xBDF7 :
                       dashboard.bubbles[i].status == "DONE" ? 0x07E0 : 0xFFE0;
      drawTaskBubble(positions[count - 1][i][0], positions[count - 1][i][1], radius, dashboard.bubbles[i], color);
    }
  }
  // Keep all secondary information on one line, reserving y=75..219 for tasks.
  String footer = "Life " + compactNumber(dashboard.lifetimeTokens) + "  R " + reset;
  if (dashboard.secondaryPercent >= 0) {
    String longReset = dashboard.secondaryResetMinutes >= 0 ? duration(dashboard.secondaryResetMinutes) : until(dashboard.secondaryReset);
    footer += "  R2 " + longReset;
  }
  d.setTextSize(2);
  int footerWidth = d.textWidth(footer);
  if (footerWidth > 304) d.setTextSize(2.0f * 304 / footerWidth);
  d.setTextColor(TFT_WHITE, TFT_BLACK);
  d.setCursor((320 - d.textWidth(footer)) / 2, 221 + (19 - d.fontHeight()) / 2);
  d.print(footer);
  d.setTextSize(1);
  screen.pushSprite(0, 0);
}

bool fetchDashboard() {
  if (WiFi.status() != WL_CONNECTED || !bridgeUrl.length()) return false;
  HTTPClient http;
  http.setTimeout(2500);
  if (!http.begin(bridgeUrl)) return false;
  int code = http.GET();
  if (code != HTTP_CODE_OK) { lastError = "Bridge HTTP " + String(code); http.end(); return false; }
  JsonDocument doc;
  DeserializationError error = deserializeJson(doc, http.getStream());
  http.end();
  if (error) { lastError = "Bad bridge response"; return false; }
  dashboard.plan = doc["plan"] | "--";
  dashboard.primaryPercent = doc["quota"]["primary"]["usedPercent"] | -1;
  dashboard.secondaryPercent = doc["quota"]["secondary"]["usedPercent"] | -1;
  dashboard.primaryReset = doc["quota"]["primary"]["resetsAt"] | 0ULL;
  dashboard.secondaryReset = doc["quota"]["secondary"]["resetsAt"] | 0ULL;
  dashboard.resetCredits = doc["resetCredits"] | -1;
  dashboard.todayTokens = doc["usage"]["todayTokens"] | 0ULL;
  dashboard.lifetimeTokens = doc["usage"]["lifetimeTokens"] | 0ULL;
  dashboard.activeTasks = doc["tasks"]["active"] | 0;
  dashboard.recentTasks = doc["tasks"]["recent"] | 0;
  dashboard.task = String((const char*)(doc["tasks"]["headline"] | "No recent task"));
  dashboard.valid = true;
  lastError = "";
  return true;
}
} // namespace

void setup() {
  Serial.begin(115200);
  auto config = M5.config();
  M5.begin(config);
  // CoreS3's 320x240 panel is used in its natural landscape orientation.
  M5.Display.setRotation(1);
  M5.Display.setTextWrap(false);
  screen.setColorDepth(16);
  screen.createSprite(320, 240);
  screen.setTextWrap(false);
  prefs.begin("codex-tip", false);
  startBle();
  connectWiFi();
  startPortal();
  Serial.printf("Codex Tip: BLE advertising; wifi=%s ip=%s bridge=%s\n",
                WiFi.status() == WL_CONNECTED ? "connected" : "setup-required",
                WiFi.localIP().toString().c_str(), bridgeUrl.c_str());
  configTime(0, 0, "pool.ntp.org", "time.cloudflare.com");
  draw();
}

void loop() {
  M5.update();
  portal.handleClient();
  bool touching = M5.Touch.getCount() > 0;
  if (touching && !wasTouching) {
    startPortal();
    lastError = "Setup AP enabled";
  }
  wasTouching = touching;
  bool running = false;
  for (int i = 0; i < min(4, dashboard.bubbleCount); ++i) {
    if (dashboard.bubbles[i].status == "RUN") running = true;
  }
  bool animate = running && millis() - lastDrawAt >= 80;
  if (dashboardDirty || millis() > nextPoll || animate) {
    bool shouldPoll = millis() > nextPoll;
    if (shouldPoll) nextPoll = millis() + POLL_MS;
    // Wi-Fi remains an optional fallback; BLE does not require any setup.
    if (shouldPoll && (!lastBleAt || millis() - lastBleAt > 10000)) fetchDashboard();
    draw();
    lastDrawAt = millis();
    dashboardDirty = false;
  }
  delay(20);
}
