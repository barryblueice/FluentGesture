#pragma once
#include <optional>
#include <string>

struct ScrollSpec { bool horizontal; int delta; };
inline std::optional<ScrollSpec> MakeScrollSpec(const std::string& kind, int step) {
  if (step < 1 || step > 20) return std::nullopt;
  if (kind == "scrollLeft") return ScrollSpec{true, -120 * step};
  if (kind == "scrollRight") return ScrollSpec{true, 120 * step};
  if (kind == "scrollUp") return ScrollSpec{false, 120 * step};
  if (kind == "scrollDown") return ScrollSpec{false, -120 * step};
  return std::nullopt;
}
