#include <cassert>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include "../boards/175/MotoNav/src/pages/GPageBudget.h"

int main() {
  GPageBudget budget;
  assert(GPageBudget::intervalMs == 200);
  assert(budget.due(1000));
  assert(!budget.due(1099));
  assert(!budget.due(1199));
  assert(budget.due(1200));
  assert(!budget.due(1399));
  assert(budget.due(1400));

  std::ifstream file("firmware/boards/175/MotoNav/src/pages/PageNavigation.h");
  assert(file);
  std::stringstream source;
  source << file.rdbuf();
  const std::string text = source.str();
  assert(text.find("GPageBudget") != std::string::npos);
  assert(text.find("millis()-last<100") == std::string::npos);
  std::printf("GPageBudgetTest passed\n");
  return 0;
}
