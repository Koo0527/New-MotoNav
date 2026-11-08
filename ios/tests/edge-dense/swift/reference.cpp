// Test adapter only: leave the frozen probe and its admission unchanged.
#define main frozen_probe_main
#include "../probe.cpp"
#undef main
int main(int argc, char **argv) {
    if (argc == 2) { selfcheck(); selfcheck(true); bandSelfcheck(); return 0; }
    assert(argc == 5);
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<uint8_t> p((std::istreambuf_iterator<char>(f)), {});
    Stats st;
    auto words = encode(p, std::stoi(argv[3]), std::stoi(argv[4]), st, true, true);
    std::ofstream o(argv[2], std::ios::binary);
    for (auto w: words) { o.put(w & 255); o.put(w >> 8); }
}
