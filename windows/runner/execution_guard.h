#ifndef RUNNER_EXECUTION_GUARD_H_
#define RUNNER_EXECUTION_GUARD_H_
#include <cstdint>
#include <string>

// Shared by the native dispatcher and a side-effect-free test executable.
struct ExecutionSession {
  int64_t id;
  std::string device;
  uint64_t completed;
  bool touching;
  bool valid;
};

inline bool ConsumeExecution(const ExecutionSession& session, int64_t requested_id,
    const std::string& requested_device, uint64_t now, bool allowed,
    bool target_unchanged, bool& consumed) {
  if (!allowed || !target_unchanged || consumed || !session.valid ||
      session.touching || session.completed == 0 || now < session.completed ||
      now - session.completed > 1500 || requested_id != session.id ||
      requested_device != session.device) return false;
  consumed = true;
  return true;
}
#endif
