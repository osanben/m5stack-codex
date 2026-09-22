#include "SwipeNavigation.h"
#include "PageRotation.h"
#include "SettingsButtons.h"
#include <cassert>
#include <iostream>
int main() {
  SwipeNavigation swipe;
  swipe.begin(200, 100, 0);
  assert(swipe.move(190, 103, 40, 1) == SwipeNavigation::None);
  assert(swipe.move(130, 105, 200, 1) == SwipeNavigation::Left);
  assert(swipe.move(280, 100, 300, 1) == SwipeNavigation::None);
  swipe.begin(50, 100, 1000);
  assert(swipe.move(120, 100, 1200, 1) == SwipeNavigation::Right);
  swipe.begin(200, 100, 0);
  assert(swipe.move(200, 140, 50, 1) == SwipeNavigation::None);
  assert(swipe.move(100, 100, 100, 1) == SwipeNavigation::None);
  swipe.begin(200, 100, 0);
  assert(swipe.move(100, 100, 100, 2) == SwipeNavigation::None);
  assert(swipe.move(100, 100, 200, 1) == SwipeNavigation::None);
  swipe.begin(200, 100, 0);
  assert(swipe.move(100, 100, 1000, 1) == SwipeNavigation::None);
  swipe.begin(200, 100, UINT32_MAX - 100);
  assert(swipe.move(100, 100, 50, 1) == SwipeNavigation::Left);
  swipe.begin(200, 100, 0); swipe.cancel();
  assert(swipe.move(100, 100, 100, 1) == SwipeNavigation::None);
  std::cout << "Swipe navigation: all tests passed\n";
  PageRotation pages;
  assert(!pages.tick(4999, false));
  assert(pages.tick(5000, false) && pages.page == 1);
  assert(pages.tick(10000, false) && pages.page == 0);
  pages.manual(-1, 12000); assert(pages.page == 3);
  assert(!pages.tick(17000, false) && pages.page == 3);
  pages.manual(-1, 18000); assert(pages.page == 2);
  assert(!pages.tick(72000, false) && pages.page == 2);
  pages.manual(-1, 73000); assert(pages.page == 1);
  assert(!pages.tick(77999, false));
  assert(pages.tick(78000, false) && pages.page == 0);
  pages.manual(1, 79000); assert(pages.page == 1);
  pages.manual(1, 80000); assert(pages.page == 2);
  assert(!pages.tick(85000, false) && pages.page == 2);
  pages.manual(1, 86000); assert(pages.page == 3);
  pages.manual(1, 87000); assert(pages.page == 0);
  pages.setEnabled(false, 88000);
  assert(!pages.tick(100000, false) && pages.page == 0);
  pages.manual(1, 101000); assert(pages.page == 1);
  assert(!pages.tick(110000, false));
  pages.select(0, 111000); assert(pages.page == 0);
  pages.setEnabled(true, 112000);
  assert(!pages.tick(116999, false));
  assert(pages.tick(117000, false) && pages.page == 1);
  // Reset to independently test touch pause/release and timer wraparound.
  pages = PageRotation();
  assert(!pages.tick(20000, true));
  pages.interact(21000); // touch release restarts the full five seconds
  assert(!pages.tick(25999, false));
  assert(pages.tick(26000, false) && pages.page == 1);
  pages.interact(UINT32_MAX - 1000);
  assert(!pages.tick(1000, false));
  assert(pages.tick(4000, false));
  std::cout << "Page rotation: all tests passed\n";
  SettingsTap tap;
  tap.begin(30, 65, 0); assert(tap.active() == 0);
  tap.move(34, 68, 100, 1); assert(tap.release(200) == 0);
  assert(tap.release(201) == -1); // one action per contact
  tap.begin(30, 65, 0); tap.move(60, 65, 100, 1);
  tap.move(30, 65, 200, 1); assert(tap.release(300) == -1);
  tap.begin(30, 65, 0); tap.move(30, 65, 100, 2);
  assert(tap.release(200) == -1);
  tap.begin(30, 65, 0); assert(tap.release(900) == -1);
  tap.begin(13, 60, 0); tap.move(10, 60, 100, 1);
  assert(tap.release(200) == -1); // outside original button
  tap.begin(40, 120, 0); assert(tap.release(100) == 1);
  tap.begin(200, 120, 0); assert(tap.release(100) == 2);
  tap.begin(40, 180, 0); assert(tap.release(100) == 3);
  tap.begin(160, 120, 0); assert(tap.release(100) == -1);
  tap.begin(40, 65, UINT32_MAX - 100);
  assert(tap.release(50) == 0);
  std::cout << "Settings buttons: all tests passed\n";
}
