// https://codeforces.com/contest/2263/problem/F
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    mt19937_64 rng(stoull(argv[1]));

    // Example format only. Adapt to the actual problem and constraints.
    int n = 1 + rng() % 8;
    cout << n << '\n';
    for (int i = 0; i < n; ++i)
        cout << int(rng() % 21) - 10 << (i + 1 == n ? '\n' : ' ');
}
