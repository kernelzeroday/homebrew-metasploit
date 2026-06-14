# homebrew-metasploit

Homebrew tap for [Metasploit Framework](https://www.metasploit.com/) — built from source, ARM64 native.

The official Homebrew cask (`homebrew/cask/metasploit`) ships an x86_64-only prebuilt
`.pkg` that requires Rosetta 2 and is scheduled for removal. This tap builds from the
latest git source so everything compiles natively on Apple Silicon.

## Install

```bash
brew tap kernelzeroday/metasploit
brew install --HEAD kernelzeroday/metasploit/metasploit-framework
```

If you have `HOMEBREW_REQUIRE_TAP_TRUST` set:

```bash
brew tap kernelzeroday/metasploit
brew trust --tap kernelzeroday/metasploit
brew install --HEAD kernelzeroday/metasploit/metasploit-framework
```

## Database setup

Metasploit works best with PostgreSQL for session/loot/cred storage:

```bash
brew services start postgresql@16
msfdb init
```

## Update

```bash
brew upgrade --fetch-HEAD kernelzeroday/metasploit/metasploit-framework
```

## What's included

Executables: `msfconsole`, `msfvenom`, `msfd`, `msfdb`, `msfrpc`, `msfrpcd`, `msfupdate`, `msfmcpd`

## Dependencies

Installed automatically by Homebrew:

- `ruby@3.4` — runtime
- `postgresql@16` — database server for `msfdb`
- `libpq` — PostgreSQL client library
- `libpcap` — packet capture
- `sqlite` — local storage
- `openssl@3` — TLS
- `libyaml` — YAML parsing
- `nmap` — network scanning (used by MSF modules)

## Troubleshooting

**pcaprub / packet capture permissions**: modules that capture packets need BPF device
access. Run `msfconsole` as root or add your user to the `access_bpf` group.

**Native extension build failures**: if a gem fails to compile, make sure Xcode
Command Line Tools are installed (`xcode-select --install`).

## License

This tap formula is MIT licensed. Metasploit Framework itself is BSD-3-Clause.
