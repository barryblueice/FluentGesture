#pragma once
#include <set>
#include <vector>

// Physical keys are tracked independently (including left/right modifiers).
// No OS queries here: a low-level hook runs before async key state is updated.
class ShortcutKeys {
 public:
  bool armed = true, complete = false;
  bool win_only = true;
  std::set<int> down;
  std::vector<int> keys;
  static bool Modifier(int key) {
    return key == 16 || key == 17 || key == 18 || key == 91 || key == 92 ||
        (key >= 160 && key <= 165);
  }
  std::vector<int> Modifiers() const {
    std::vector<int> result;
    if (down.count(17) || down.count(162) || down.count(163)) result.push_back(17);
    if (down.count(18) || down.count(164) || down.count(165)) result.push_back(18);
    if (down.count(16) || down.count(160) || down.count(161)) result.push_back(16);
    if (down.count(91)) result.push_back(91);
    if (down.count(92)) result.push_back(92);
    return result;
  }
  bool Feed(int key, bool pressed) {
    if (key < 8 || key > 254) return false;
    if (pressed) {
      if (down.count(key)) return true;  // Consume repeats of captured keys.
      if (!armed) return false;
      if (down.empty()) win_only = true;
      if (key != 91 && key != 92) win_only = false;
      down.insert(key);
      keys = Modifiers();
      if (!Modifier(key)) {
        keys.push_back(key);
        complete = true;
        armed = false;
      }
    } else {
      if (!down.count(key)) return false;
      const bool win_alone = win_only && down.size() == 1 && keys.size() == 1 &&
          (key == 91 || key == 92);
      down.erase(key);
      if (armed && win_alone) {
        complete = true;
        armed = false;
      }
      if (armed) keys = Modifiers();
    }
    return true;
  }
};
