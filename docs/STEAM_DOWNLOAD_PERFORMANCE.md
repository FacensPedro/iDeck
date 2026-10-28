# Steam CDN selection and chunk concurrency

The iDeck Steam content downloader now uses at most **12 concurrent chunk tasks**
under nominal thermal conditions, 6 when thermal state is fair, 3 when
serious, and 1 when critical. Low Power Mode limits it to 2.
The URLSession per-host connection cap is 12; actual effective concurrency
also depends on HTTP protocol, CDN availability and system networking.

During ordinary authenticated chunk downloads the client measures:

- The compressed bytes transferred and elapsed network-request time, used to
  estimate effective bytes per second (exponential moving average).
- Time to first response byte when URLSessionTaskMetrics is available, used as
  a smaller factor in server ranking.
- Consecutive failures: unreliable hosts are demoted, and recover after later
  successful transfers.

New installations initially rotate requests across eligible hosts to gather
measurements. Subsequent chunks prefer the best observed throughput and
response latency. Every twelfth work item explores less-sampled hosts so
regional CDN conditions can change without permanent lock-in. Retry attempts
avoid previously attempted hosts until all have been tried.

No unauthenticated content sources are added; depot keys, hashes, CRCs,
HTTPS server eligibility, manifest checks and authorized CDN tokens remain
unchanged. No artificial benchmark downloads are made.

This is an optimization, not a guarantee of 2x throughput. Compare actual
bytes per second and total time for the same game and network before/after.

## Selection based on the current public IP

Before each new game installation, iDeck requests Valve's SteamPipe content
server directory **without a `cell_id` override**. Steam then chooses a
regional server list using the outgoing public IP of the iPad's current
connection (Wi-Fi, cellular or VPN), not the device's GPS or a stored
Steam account cell. The directory call is refreshed per install instead
of holding a ten-minute list through network changes. The first eight
eligible HTTPS hosts are used for parallel chunks and existing throughput,
latency, failure and exploration logic ranks them while data transfers.

Steam's WebSocket CM directory likewise omits `cellid`, letting Valve select
login gateways for the current public IP. A failure can still use the
previously cached gateway list. No public IP is explicitly retrieved,
logged, sent to a third-party geolocation service or used to guess a
country. This optimizes **Steam download/authentication endpoints**, not
the region of multiplayer game servers.

The nearest datacenter is not always the fastest. Actual throughput and
connection stability take precedence as chunk samples become available.
