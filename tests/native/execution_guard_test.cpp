#include "execution_guard.h"
#include <iostream>
#include <cstdlib>

void Require(bool condition, const char* name) {
  if (!condition) { std::cerr << "FAIL: " << name << '\n'; std::exit(1); }
}
int main() {
  ExecutionSession session{42, "pad-A", 1000, false, true};
  bool consumed = false;
  auto attempt = [&](int64_t id = 42, const std::string& device = "pad-A",
      uint64_t now = 1200, bool allowed = true, bool unchanged = true) {
    return ConsumeExecution(session, id, device, now, allowed, unchanged, consumed);
  };
  Require(!attempt(41), "stale session");
  Require(!attempt(42, "pad-B"), "different device");
  Require(!attempt(42, "pad-A", 999), "clock regression");
  Require(!attempt(42, "pad-A", 2501), "expired session");
  Require(!attempt(42, "pad-A", 1200, false), "paused/edit/test/locked mode");
  Require(!attempt(42, "pad-A", 1200, true, false), "foreground changed/exited/self target");
  session.touching = true;
  Require(!attempt(), "all fingers must lift");
  session.touching = false;
  session.valid = false;
  Require(!attempt(), "cancelled session");
  session.valid = true;
  session.completed = 0;
  Require(!attempt(), "incomplete session");
  session.completed = 1000;
  Require(!consumed, "rejections do not execute");
  Require(attempt(), "valid session executes");
  Require(consumed && !attempt(), "a session executes at most once");
  std::cout << "12 native execution guard checks passed\n";
}
