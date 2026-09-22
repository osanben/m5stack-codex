#include "SwipeNavigation.h"
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
}
