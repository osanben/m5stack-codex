#include "SwipeNavigation.h"
#include "PageRotation.h"
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
  pages.manual(-1, 12000); assert(pages.page == 2);
  assert(!pages.tick(17000, false) && pages.page == 2);
  assert(!pages.tick(72000, false) && pages.page == 2);
  pages.manual(-1, 73000); assert(pages.page == 1);
  assert(!pages.tick(77999, false));
  assert(pages.tick(78000, false) && pages.page == 0);
  pages.manual(1, 79000); assert(pages.page == 1);
  pages.manual(1, 80000); assert(pages.page == 2);
  assert(!pages.tick(85000, false) && pages.page == 2);
  pages.manual(1, 86000); assert(pages.page == 0);
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
}
