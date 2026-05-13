# simulation.conf — Configuration Guide

The `configs/` folder contains two plain-text INI files that control every aspect
of how client-sim runs. They are designed to be readable and editable directly in
GitHub without any special tooling.

```
configs/
  simulation.conf      ← simulation profiles and global settings
  user-overrides.conf  ← per-user pin overrides (optional, ships with examples)
```

---

## How it works — the big picture

Each client VM is named `<username>-<vmid>` (e.g. `slynch-90001`).  
On startup, the client extracts its own hostname and uses the VMID digits to
determine which simulation profile to run. No database, no API call — pure math.

```
Hostname:  slynch-90001
              │       │
              │       └─ VMID = 90001
              └───────── username (from client-setup.conf)

site_based_num = 2
  → extract the 2nd-to-last digit of 90001  →  "0"
  → simulation bucket = s0
  → client runs the [s0] profile from simulation.conf
```

The `site_based_num` setting controls the grouping size:

| site_based_num | Digit extracted | Clients per bucket | Max clients |
|:--------------:|:---------------:|:------------------:|:-----------:|
| 2              | tens (x0-x9)    | ~10                | ~100        |
| 3              | hundreds        | ~100               | ~1,000      |
| 4              | thousands       | ~1,000             | ~10,000     |

**Example — site_based_num = 2:**

| VMID range  | Digit | Bucket | Profile        |
|-------------|:-----:|--------|----------------|
| 90001–90009 | 0     | s0     | DNS Fail — MIA |
| 90011–90019 | 1     | s1     | Normal Traffic |
| 90021–90029 | 2     | s2     | DNS Fail + iPerf |
| …           | …     | …      | …              |

**Example — site_based_num = 3 (100 clients per bucket):**

| VMID range    | Digit | Bucket |
|---------------|:-----:|--------|
| 90001–90099   | 0     | s0     |
| 90101–90199   | 1     | s1     |
| 90201–90299   | 2     | s2     |
| …             | …     | …      |

---

## simulation.conf

### [simulation] — Global settings

These apply to every client unless overridden in a bucket or user section.

```ini
[simulation]
kill_switch=off          # on = stop all simulations immediately (emergency stop)
rapid_update=off         # on  = run update.sh every iteration (dev/testing mode — frequent checks,
                         #       version check keeps it lightweight when nothing has changed).
                         # off = run update.sh only at exec-restart (every 100 iterations) — prevents
                         #       hammering update services in production deployments.
sim_load=100             # CPU throttle target for cpulimit (percentage)
github_repo=on           # on = repo cloned without auth
repo_location=https://github.com/solutions-hpe/client-sim/
server_url=http://169.253.1.1:8000   # webUI heartbeat endpoint (set in [server] section)
repo_branch=main          # which branch clients pull from
smb_repo=off             # on = enable Tier 2 SMB share as an update source (see [address] smb_address)
                         # Update priority: WebUI → SMB → GitHub (each tier only tried if previous fails)
vh_server=off            # on = start VirtualHere USB server daemon
site_based_ssid=on       # on  = prepend wsite to the SSID name when connecting.
                         #       e.g. wsite=MIA + ssid=PSK → connects to "MIA-PSK"
                         # off = connect to ssid exactly as written (e.g. "PSK")
site_based_num=2         # see table above — controls bucket group size
reboot_schedule=300      # minutes until client schedules a reboot (+ up to 600s jitter)
allow_offline=on         # on = after each 100-iteration cycle, bring all network interfaces
                         #      down for a random 1 second to 4 hours before restarting.
                         #      WHY: clients that are always connected look like IoT devices.
                         #      Going offline periodically makes them look like real user laptops
                         #      that leave the office, sleep, or roam off the network.
                         # off = client stays connected continuously between cycles.
ssidpw_fail=off          # global default — can be overridden per bucket or user
auth_fail=off
iperf_bw=1k              # iPerf bandwidth target
syslog=on                # on = forward all client logs to syslog_server via rsyslog.
                         #      The syslog_server address is set in the [address] section.
web_server=on            # on = sync scripts/config from WebUI server (preferred over GitHub)
```

### [server] — Alternate server block

Used internally when the client resolves the dashboard by hostname instead of IP.

```ini
[server]
server_url=http://sim-dashboard:8000
```

### [address] — Network targets

Addresses used by simulation scripts for DNS, ping, SMB, and iPerf tests.
Change these to match your lab network.

```ini
[address]
smb_address=//nas/scripts
ping_address=172.31.201.3
dns_latency_1=13.239.88.95    # External DNS servers used to generate latency
dns_latency_2=27.110.152.250
dns_latency_3=165.246.10.2
dns_bad_ip_1=10.0.0.1         # IPs that return bad DNS responses
dns_bad_ip_2=172.16.0.1
dns_bad_ip_3=192.168.0.1
dns_bad_record_1=172.31.201.1 # DNS records that resolve to wrong addresses
dns_bad_record_2=172.31.202.2
dns_bad_record_3=100.100.0.1
iperf_server=172.31.201.135
syslog_server=169.253.1.5
```

### [s0]–[s9] — Simulation bucket profiles

There are exactly 10 buckets (`s0` through `s9`). Each bucket defines the full
simulation behaviour for the clients whose VMID digit maps to it.

```ini
[s0]
name=DNS Fail — MIA
# central_check: the Aruba Central alert_type or insight category ID that should
# be firing when this simulation runs. Used by the dashboard for PASS/FAIL status.
# Leave blank if you are not mapping this simulation to a Central alert.
# Example: central_check=DNS_FAILURE
central_check=
wsite=MIA               # site label — must match a site_mappings entry in the webUI
ssid=PSK                # SSID to connect to
ssidpw=PassW0rd!        # WPA passphrase
dhcp_fail=off           # simulate DHCP failure
dns_fail=on             # simulate DNS failure (generates DNS alert in Central)
assoc_fail=off          # simulate 802.11 association failure
port_flap=off           # simulate wired port link flap
ping_test=on            # run continuous ICMP ping test
download=on             # run HTTP download traffic
www_traffic=on          # run web browsing simulation traffic
iperf=off               # run iPerf throughput test
sim_phy=wireless        # wireless or wired
```

**Simulation flags reference:**

| Flag          | When `on`                                          | Central alert generated      |
|---------------|----------------------------------------------------|------------------------------|
| `dns_fail`    | Resolves DNS to bad IPs / bad records              | DNS failure insight/alert    |
| `dhcp_fail`   | Releases and does not renew DHCP lease             | DHCP failure alert           |
| `ssidpw_fail` | Connects with wrong WPA passphrase                 | Auth failure alert           |
| `auth_fail`   | Sends bad 802.1X credentials                      | Auth failure alert           |
| `assoc_fail`  | Sends malformed association requests               | Assoc failure alert          |
| `port_flap`   | Bounces the wired interface repeatedly             | Port flap alert              |
| `ping_test`   | Sends ICMP to `ping_address` (traffic generation)  | —                            |
| `download`    | Downloads a file repeatedly (traffic generation)   | —                            |
| `www_traffic` | Fetches web pages (traffic generation)             | —                            |
| `iperf`       | Runs iPerf to `iperf_server` (bandwidth test)      | —                            |

#### How many clients does a simulation need to fire an alert?

Each alert or insight in Aruba Central has a minimum number of clients that must
be exhibiting the behaviour before the alert fires. The bucket system handles
this automatically — assign enough consecutive VMID groups so the total client
count meets or exceeds the threshold.

**Example:** DNS failure requires 10 clients → assign 1 bucket (10 clients per bucket
with `site_based_num=2`). If it required 25 clients, assign 3 buckets (s0, s1, s2)
all with `dns_fail=on`. Over-provisioning is fine — more clients = stronger signal.

#### Linking a simulation to a Central alert (PASS/FAIL)

Set `central_check` to the exact alert type or insight category string from
Aruba Central. The webUI Simulations tab will show **PASS** when that alert is
actively firing in Central, and **FAIL** when it is not.

```ini
[s0]
name=DNS Fail — MIA
central_check=DNS_FAILURE   ← exact string from Central API
wsite=MIA
dns_fail=on
…
```

To find the correct string: go to the webUI **Setup → Monitored Checks → Load
Available Checks**. The check IDs listed there are the strings to use here.

---

## user-overrides.conf

This file pins individual users to a custom simulation regardless of which
bucket their VMID falls in. It is loaded **after** `simulation.conf`, so any
key defined here wins over the bucket profile.

```ini
# Pin slynch to run ssidpw_fail instead of his bucket profile
[slynch]
dns_fail=off
ssidpw_fail=on
ping_test=off
download=off
www_traffic=off
```

You do not need to repeat every key — only specify the keys you want to override.
Keys not listed here fall through to the bucket (`[sX]`) value or the global
`[simulation]` default.

### When to use user overrides

- **Targeted failure testing** — pin one or two specific users to run a specific
  failure scenario for reproducibility.
- **Exclusion** — set `kill_switch=on` for a single user to stop their simulation
  without affecting others.
- **Alternate site** — change `wsite` for a user to point them at a different
  Aruba Central site than their bucket.

### Config resolution order (last wins)

```
[simulation] globals
      ↓
[sX] bucket profile  (determined by VMID digit + site_based_num)
      ↓
[username] override  (from user-overrides.conf)
```

---

## Scaling to larger deployments

Change `site_based_num` in `[simulation]` to scale the bucket group size. You
do **not** need to change `[s0]`–`[s9]` — the same 10 profiles work at any scale.

```
site_based_num=2  →  10 clients per bucket  →  up to ~100 clients
site_based_num=3  →  100 clients per bucket →  up to ~1,000 clients
site_based_num=4  →  1,000 clients/bucket   →  up to ~10,000 clients
```

When scaling up, also update `client-setup.conf` (in `proxmox/`) with the
additional VMID → username mappings.

---

## Contributing a new simulation

1. Fork the repo and create your branch.
2. Edit `configs/simulation.conf` — modify an existing `[sX]` profile or add
   settings to an unused bucket.
3. If you need a user-specific override, add it to `configs/user-overrides.conf`.
4. Test on your own hardware.
5. Submit a pull request. The PR diff will show exactly which simulation flags
   changed — easy to review with no code changes required.

> **Tip:** INI format is intentional — it renders clearly in GitHub, diffs are
> readable, and anyone can edit with any text editor. Keep it that way.
> Avoid JSON, YAML, or XML in any config file.
