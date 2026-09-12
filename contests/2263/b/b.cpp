// https://codeforces.com/contest/2263/problem/B
#include <bits/stdc++.h>
#include <vector>
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
  int n, k;
  cin >> n >> k;

  if (n > k || k > 2 * n - 1) {
    cout << -1 << nl;
    return;
  }

  int m = 2 * n - k;
  vector<vector<int>> a(n, vector<int>(n, 0));

  rep(i, 0, m) a[i][i] = i + 1;
  rep(r, m, n) a[r][0] = r + 1;
  rep(c, m, n) a[0][c] = (n - m) + (c + 1);

  int nxt = k + 1;
  rep(i, 0, n) rep(j, 0, n) if (a[i][j] == 0) a[i][j] = nxt++;

  rep(i, 0, n) { rep(j, 0, n) cout << a[i][j] << ((j + 1 < n) ? " " : nl); }
}

int main() {
  ios_base::sync_with_stdio(false);
  cin.tie(nullptr);

  int t = 1;
  cin >> t;
  while (t--)
    solve();

  return 0;
}
