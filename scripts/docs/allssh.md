# allssh

Run a command on multiple servers over SSH — sequentially or in parallel.

## What it does

- Reads a list of hosts from `~/.allssh_hosts`
- Runs any shell command on all of them via SSH
- Supports sequential and parallel execution
- Colour-coded output per host with a pass/fail summary
- SSH key auth with optional password fallback

## Installed files

| File | Location | Purpose |
|---|---|---|
| `allssh` | `/usr/local/bin/allssh` | Main command |
| `allssh-add` | `/usr/local/bin/allssh-add` | Add hosts to the hosts file |
| hosts file | `~/.allssh_hosts` | One host per line |

## Usage

```bash
# Run a command on all hosts (sequential)
allssh -u root "uptime"

# Run in parallel
allssh -u root -p "apt update && apt upgrade -y"

# Custom hosts file
allssh -f /etc/allssh/prod-hosts -u root "systemctl restart nginx"

# Custom identity file
allssh -i ~/.ssh/homelab -u root "date"
```

## Options

| Flag | Description | Default |
|---|---|---|
| `-f <file>` | Hosts file | `~/.allssh_hosts` or `$ALLSSH_HOSTS` |
| `-p` | Parallel execution | Sequential |
| `-u <user>` | SSH user | Current user or `$ALLSSH_USER` |
| `-i <identity>` | SSH identity file | `$ALLSSH_IDENTITY` |
| `-t <seconds>` | Connection timeout | `10` |

## Environment variables

```bash
export ALLSSH_USER=root        # Default SSH user
export ALLSSH_HOSTS=~/.allssh_hosts  # Default hosts file
export ALLSSH_IDENTITY=~/.ssh/id_ed25519  # Default key
```

Add these to `~/.bashrc` to make them permanent.

## Hosts file format

```
# one host per line, comments supported
server1.example.com
admin@server2.example.com   # per-host user override
192.168.1.50
```

## Adding hosts

```bash
# Single host
allssh-add server1.example.com

# With user prefix
allssh-add root@192.168.1.50

# Interactive (prompts for multiple)
allssh-add
```

## Setting up SSH keys on new servers

If SSH is disabled on target servers (e.g. fresh LXC containers), use `pct exec` on the Proxmox host to inject the key and enable SSH without any network access:

```bash
PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"

for id in 101 102 103; do
  pct exec $id -- bash -c "
    mkdir -p /root/.ssh &&
    chmod 700 /root/.ssh &&
    echo '$PUBKEY' >> /root/.ssh/authorized_keys &&
    chmod 600 /root/.ssh/authorized_keys &&
    systemctl enable ssh &&
    systemctl start ssh
  "
done
```

## Post-setup

Test a single host first:

```bash
ssh -i ~/.ssh/id_ed25519 root@<host>
```

Then run across all:

```bash
allssh -u root "date"
```
