#include "shortcut_keys.h"
#include "scroll_spec.h"
#include <cstdlib>
#include <iostream>

void Check(bool ok, const char* label) {
  if (!ok) { std::cerr << "FAIL: " << label << '\n'; std::exit(1); }
}
int main() {
  for (int win : {91, 92}) {
    ShortcutKeys capture;
    Check(capture.Feed(win, true) && !capture.complete, "Win down is pending");
    Check(capture.keys == std::vector<int>{win}, "Win preview");
    Check(capture.Feed(win, false) && capture.complete && capture.down.empty(), "Win alone on release");
    Check(!capture.Feed('A', true), "pass subsequent keys after recording");
    capture = ShortcutKeys{};
    capture.Feed(win, true); capture.Feed(160, true); capture.Feed('K', true);
    Check(capture.keys == std::vector<int>({16, win, 'K'}), "Win Shift K preserves modifiers");
    Check(capture.Feed('K', true), "repeat is swallowed");
    Check(capture.Feed('K', false) && capture.Feed(win, false) && capture.Feed(160, false), "consume captured key releases");
    Check(capture.down.empty() && capture.keys.size() == 3, "retain combo after release");
  }
  ShortcutKeys capture;
  capture.Feed(162, true); capture.Feed(163, true); capture.Feed(162, false);
  Check(capture.keys == std::vector<int>{17}, "right Ctrl survives left Ctrl release");
  capture.Feed(91, true); capture.Feed(163, false); capture.Feed(91, false);
  Check(!capture.complete, "modifier-only combination cannot degrade to Win alone");
  for (int key : {9, 13, 27}) {
    capture = ShortcutKeys{}; capture.Feed(key, true); capture.Feed(key, false);
    Check(capture.complete && capture.keys == std::vector<int>{key}, "Tab Enter Escape record as keys");
  }
  Check(MakeScrollSpec("scrollLeft", 3)->delta == -360, "left sign");
  Check(MakeScrollSpec("scrollRight", 3)->delta == 360, "right sign");
  Check(MakeScrollSpec("scrollUp", 3)->delta == 360, "up sign");
  Check(MakeScrollSpec("scrollDown", 3)->delta == -360, "down sign");
  Check(MakeScrollSpec("scrollLeft", 1)->horizontal && !MakeScrollSpec("scrollUp", 1)->horizontal, "wheel axis");
  Check(!MakeScrollSpec("scrollUp", 0) && !MakeScrollSpec("scrollLeft", 21) && !MakeScrollSpec("invalid", 1), "invalid scroll rejected");
  std::cout << "27 shortcut and scroll checks passed\n";
}
