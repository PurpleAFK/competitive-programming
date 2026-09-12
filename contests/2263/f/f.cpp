// https://codeforces.com/contest/2263/problem/F
#include <bits/stdc++.h>
using namespace std;

#define nl "\n"
#define ll long long
#define ull unsigned long long
#define str string
#define vs vector<string>
#define vi vector<int>
#define vll vector<long long>
#define pii pair<int, int>
#define pll pair<long long, long long>
#define pb push_back
#define mp make_pair
#define fi first
#define se second
#define all(v) (v).begin(), (v).end()
#define rall(v) (v).rbegin(), (v).rend()
#define aall(x) begin(x), end(x)
#define raall(x) end(x), begin(x)
#define sz(v) ((int)(v).size())
#define rep(i, a, b) for (int i = (a); i < (b); i++)
#define per(i, a, b) for (int i = (b) - 1; i >= (a); i--)

#ifdef LOCAL
#define debug(x) cerr << #x << " = " << (x) << endl
#define debugv(v)                                                              \
  {                                                                            \
    cerr << #v << " = [";                                                      \
    for (auto &x : v)                                                          \
      cerr << x << " ";                                                        \
    cerr << "]" << endl;                                                       \
  }
#else
#define debug(x)
#define debugv(v)
#endif

const int MOD = 1e9 + 7;
const int INF = 1e9;
const ll LINF = 1e18;

ll gcd(ll a, ll b) { return b ? gcd(b, a % b) : a; }
ll lcm(ll a, ll b) { return a / gcd(a, b) * b; }

ll modpow(ll a, ll n, ll m = MOD) {
  ll res = 1;
  a %= m;
  while (n > 0) {
    if (n & 1)
      res = res * a % m;
    a = a * a % m;
    n >>= 1;
  }
  return res;
}

void solve() {
  // j
}

int main() {
  ios_base::sync_with_stdio(false);
  cin.tie(nullptr);

  int t = 1;
  // cin >> t;
  while (t--)
    solve();

  return 0;
}
