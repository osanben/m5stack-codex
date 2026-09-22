#pragma once
#include <cstdint>

class PageRotation {
 public:
  static constexpr int Count = 3;
  static constexpr int AutoCount = 2; // Codex and OpenCode; power is manual only.
  int page = 0;
  void interact(uint32_t now) { lastInteraction = now; }
  void manual(int direction, uint32_t now) {
    page = (page + direction + Count) % Count;
    interact(now);
  }
  bool tick(uint32_t now, bool touching) {
    if (touching) { interact(now); return false; }
    if (page >= AutoCount) return false;
    if (now - lastInteraction < 5000) return false;
    page = (page + 1) % AutoCount; interact(now); return true;
  }
 private:
  uint32_t lastInteraction = 0;
};
