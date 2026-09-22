#pragma once
#include <cstdint>
#include <cstdlib>

struct SettingsButton {
  int x, y, width, height;
  bool contains(int px, int py) const {
    return px >= x && px < x + width && py >= y && py < y + height;
  }
};
static constexpr SettingsButton settingsButtons[] = {
  {12, 48, 296, 48}, {12, 108, 142, 42}, {166, 108, 142, 42}, {12, 162, 296, 42}
};
inline int settingsButtonAt(int x, int y) {
  for (int i = 0; i < 4; ++i) if (settingsButtons[i].contains(x, y)) return i;
  return -1;
}

// Activate on release only. Moving outside a button, dragging, multi-touch,
// or a long hold permanently cancels that contact's tap.
class SettingsTap {
 public:
  void begin(int x, int y, uint32_t now) {
    button = settingsButtonAt(x, y); originX = x; originY = y; started = now;
  }
  void cancel() { button = -1; }
  int active() const { return button; }
  void move(int x, int y, uint32_t now, int contacts) {
    if (button < 0) return;
    if (contacts != 1 || now - started > 800 || std::abs(x - originX) > 12 ||
        std::abs(y - originY) > 12 || !settingsButtons[button].contains(x, y)) cancel();
  }
  int release(uint32_t now) {
    int result = now - started <= 800 ? button : -1;
    cancel(); return result;
  }
 private:
  int button = -1, originX = 0, originY = 0;
  uint32_t started = 0;
};
