#pragma once
#include <cstdint>
#include <cstdlib>

// One gesture per contact; vertical movement, multi-touch and long holds cancel.
class SwipeNavigation {
 public:
  enum Direction { None, Left, Right };
  void begin(int x, int y, uint32_t now) {
    originX = x; originY = y; started = now; blocked = false;
  }
  void cancel() { blocked = true; }
  Direction move(int x, int y, uint32_t now, int contacts) {
    if (blocked) return None;
    if (contacts != 1 || std::abs(y - originY) > 30 || now - started > 800) {
      blocked = true; return None;
    }
    const int dx = x - originX;
    if (std::abs(dx) < 60) return None;
    blocked = true;
    return dx < 0 ? Left : Right;
  }
 private:
  int originX = 0, originY = 0;
  uint32_t started = 0;
  bool blocked = true;
};
