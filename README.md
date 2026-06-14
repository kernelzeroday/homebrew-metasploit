# homebrew-metasploit

## A Homebrew tap that should not need to exist.

Apple Silicon Macs have been shipping since **November 2020**. It is now mid-2026. That is over five and a half years. And yet, if you go to [the official Metasploit Homebrew cask](https://formulae.brew.sh/cask/metasploit) right now, you will find:

- An **x86_64-only** prebuilt `.pkg` that requires Rosetta 2 to even launch
- A deprecation warning because it **fails macOS Gatekeeper** signature checks
- A scheduled **removal date of 2026-09-01** because nobody upstream can be bothered to fix it

The most widely used penetration testing framework on the planet — maintained by Rapid7, a publicly traded security company — still cannot ship a working macOS installer for an architecture that Apple has been selling *exclusively* for years. Every Mac sold since 2022 is ARM64. There is no Intel option anymore. And the official distribution answer is "here's an Intel binary, install Rosetta."

Homebrew's response has been to mark the cask as deprecated and schedule it for removal. No source-build formula as a fallback. No outreach to upstream. Just a countdown to deletion.

**This tap fills that gap.** It builds Metasploit Framework from source, from the latest git master, compiling every native extension natively on ARM64. It builds in under two minutes. Every native gem — `eventmachine`, `pg`, `pcaprub`, `nokogiri`, `thin`, `ffi`, `sqlite3` — compiles to ARM64 Mach-O. No Rosetta. No untrusted `.pkg`. No x86 translation layer burning your battery. Just native code running on native hardware, the way it should have been from day one.

---

## Install

```bash
brew tap kernelzeroday/metasploit
brew install --HEAD kernelzeroday/metasploit/metasploit-framework
```

If you have `HOMEBREW_REQUIRE_TAP_TRUST` set (and you should):

```bash
brew tap kernelzeroday/metasploit
brew trust --tap kernelzeroday/metasploit
brew install --HEAD kernelzeroday/metasploit/metasploit-framework
```

The `--HEAD` flag is required. This is a HEAD-only formula — it always builds from the latest commit on `master`. This is intentional. Metasploit is designed to be run from master; modules and exploits are updated constantly. Pinning to a release tag would defeat the purpose.

## Database setup

```bash
brew services start postgresql@16
msfdb init
```

If you had a previous MSF installation (e.g., from that broken cask), you may need `msfdb reinit` instead.

## Update

```bash
brew upgrade --fetch-HEAD kernelzeroday/metasploit/metasploit-framework
```

This fetches only the latest commit (shallow), not the entire 1.2GB history. More on that below.

## What's included

All MSF executables, linked into your Homebrew `bin/`:

`msfconsole` `msfvenom` `msfd` `msfdb` `msfrpc` `msfrpcd` `msfupdate` `msfmcpd`

---

## How we made this work (and why it was harder than it should have been)

This section documents every technical problem we hit and how we solved it, because upstream apparently cannot be bothered and someone should write it down.

### Problem 1: Homebrew downloads the entire 1.2GB repository

Homebrew's built-in `GitDownloadStrategy` does a full `git clone` with no depth limit. For Metasploit, that's over 59,000 commits and ~1.2GB of objects. Even with `--filter=blob:none` (treeless clone), the commit and tree objects alone are massive. Worse, if you somehow manage to create a shallow clone, Homebrew's `update_repo` method **explicitly unshallows it** on the next upgrade:

```ruby
# From Homebrew's git_download_strategy.rb, line 180-186:
def update_repo(timeout: nil)
  if shallow_dir?
    command! "git", args: ["fetch", "origin", "--unshallow"], ...
  end
end
```

That's right. Homebrew will actively undo any attempt to keep the clone small. Helpful.

**Our fix:** We define a custom `ShallowGitDownloadStrategy` that subclasses `GitDownloadStrategy` and overrides two methods:

```ruby
class ShallowGitDownloadStrategy < GitDownloadStrategy
  private

  def clone_args
    args = %w[clone --depth 1 --single-branch]
    case @ref_type
    when :branch, :tag
      args << "--branch" << @ref
    end
    args << "--config" << "advice.detachedHead=false"
    args << "--config" << "core.fsmonitor=false"
    args << @url << cached_location.to_s
  end

  def update_repo(timeout: nil)
    command! "git",
             args:      ["fetch", "--depth", "1", "origin", @ref],
             chdir:     cached_location,
             timeout:   Utils::Timer.remaining(timeout),
             reset_uid: true
  end
end
```

`clone_args` adds `--depth 1 --single-branch` to only fetch the tip of master. `update_repo` is overridden to fetch with `--depth 1` instead of `--unshallow`, so updates stay fast forever. The formula references this strategy via `using: ShallowGitDownloadStrategy` in the `head` directive.

Result: initial download drops from ~1.2GB to ~100MB. Updates fetch a single commit.

### Problem 2: eventmachine cannot find C++ standard library headers

The `eventmachine` gem (1.2.7) has native C++ extensions. On macOS, it needs `<iostream>` and other C++ standard library headers. These live inside the macOS SDK at:

```
$(xcrun --show-sdk-path)/usr/include/c++/v1/
```

Homebrew's build environment ("superenv") does not add this path automatically. The compiler cannot find `<iostream>`, and you get:

```
./project.h:25:10: fatal error: 'iostream' file not found
```

This affects both `eventmachine` and `thin` (which depends on eventmachine).

**Our fix:** Three things:

1. Set `SDKROOT` explicitly so the compiler finds the SDK:
   ```ruby
   ENV["SDKROOT"] = MacOS.sdk_path.to_s
   ```

2. Add the C++ include path to the global compiler flags:
   ```ruby
   sdk_cxx = "#{MacOS.sdk_path}/usr/include/c++/v1"
   ENV.append "CPPFLAGS", "-I#{sdk_cxx}"
   ENV.append "CXXFLAGS", "-I#{sdk_cxx}"
   ```

3. Pass the C++ include path specifically to the eventmachine and thin gem builds via Bundler's `BUNDLE_BUILD__` mechanism:
   ```ruby
   ENV["BUNDLE_BUILD__EVENTMACHINE"] = "--with-ssl-dir=#{openssl.opt_prefix} --with-cppflags=-I#{sdk_cxx} --with-cxxflags=-I#{sdk_cxx}"
   ENV["BUNDLE_BUILD__THIN"] = "--with-ssl-dir=#{openssl.opt_prefix} --with-cppflags=-I#{sdk_cxx} --with-cxxflags=-I#{sdk_cxx}"
   ```

Yes, you need all three. The global flags handle most gems. The `BUNDLE_BUILD__` flags handle gems whose extconf.rb overrides the global environment. Belt, suspenders, and duct tape — because eventmachine 1.2.7 was released in 2017 and its build system reflects that era.

### Problem 3: Native gems can't find keg-only Homebrew dependencies

Several of MSF's gem dependencies have native C extensions that link against system libraries. On Homebrew, many of these libraries are "keg-only" — installed but not symlinked into `/opt/homebrew/`. The compiler won't find them automatically.

The affected gems and their library dependencies:

| Gem | Needs | Homebrew Formula | Keg-only? |
|-----|-------|-----------------|-----------|
| `pg` (1.5.9) | libpq | `libpq` | Yes |
| `sqlite3` (1.7.3) | libsqlite3 | `sqlite` | Yes |
| `pcaprub` (0.13.3) | libpcap | `libpcap` | Yes |
| `nokogiri` (1.18.10) | libxml2, libxslt | system | N/A |
| `eventmachine` (1.2.7) | libssl | `openssl@3` | No |
| `thin` (2.0.1) | libssl (via eventmachine) | `openssl@3` | No |
| `ffi` (1.16.3) | libffi | system | N/A |

**Our fix:** Two-pronged approach.

First, add every keg-only dependency's include and lib paths to the global compiler/linker flags:

```ruby
ENV.append "CPPFLAGS", "-I#{Formula["libpcap"].opt_include}"
ENV.append "LDFLAGS", "-L#{Formula["libpcap"].opt_lib}"
ENV.append "CPPFLAGS", "-I#{Formula["openssl@3"].opt_include}"
ENV.append "LDFLAGS", "-L#{Formula["openssl@3"].opt_lib}"
ENV.append "CPPFLAGS", "-I#{Formula["sqlite"].opt_include}"
ENV.append "LDFLAGS", "-L#{Formula["sqlite"].opt_lib}"
ENV.append "CPPFLAGS", "-I#{Formula["libpq"].opt_include}"
ENV.append "LDFLAGS", "-L#{Formula["libpq"].opt_lib}"
```

Second, pass gem-specific build flags via `BUNDLE_BUILD__<GEMNAME>` (uppercased, double underscore — that's Bundler's convention):

```ruby
ENV["BUNDLE_BUILD__PG"] = "--with-pg-config=#{Formula["libpq"].opt_bin}/pg_config"
ENV["BUNDLE_BUILD__SQLITE3"] = "--with-sqlite3-dir=#{Formula["sqlite"].opt_prefix}"
ENV["BUNDLE_BUILD__PCAPRUB"] = "--with-pcap-dir=#{Formula["libpcap"].opt_prefix}"
ENV["BUNDLE_BUILD__NOKOGIRI"] = "--use-system-libraries"
```

The `pg` gem specifically needs `--with-pg-config` pointing to the keg-only `libpq`'s `pg_config` binary, not the system one (which may not exist). `nokogiri` gets `--use-system-libraries` to use macOS's built-in libxml2/libxslt instead of trying to compile its own vendored copies.

### Problem 4: The formula is HEAD-only, which is unusual for Homebrew

Most Homebrew formulas have a stable URL with a SHA256 checksum. HEAD-only formulas (no stable URL) are rare and require `--HEAD` at install time. We chose this deliberately:

- Metasploit is designed to run from `master`. New modules and exploits land daily.
- There are no official "release tarballs" to pin to — Rapid7 doesn't publish them for source builds.
- A stable formula would require constant SHA256 updates every time upstream pushes a commit.
- The `.ruby-version` in the repo targets 3.3.8, but the gemspec only requires `>= 3.1`, so our formula uses `ruby@3.4` (3.4.9) without issue. This would be harder to track if we pinned to specific versions.

### Problem 5: The libexec isolation pattern

Metasploit has 202 gem dependencies (after excluding dev/test groups). These cannot be installed into the system Ruby gems or Homebrew's Ruby gems — they'd conflict with everything. The formula uses Homebrew's standard `libexec` isolation pattern:

1. All MSF source code and gems are installed into `#{prefix}/libexec/`
2. `GEM_HOME` and `GEM_PATH` are scoped to `libexec/gems/`
3. Thin bash wrapper scripts in `#{prefix}/bin/` set up the environment and `exec` into the real Ruby scripts

Each wrapper script looks like:

```bash
#!/bin/bash
export GEM_HOME="/opt/homebrew/opt/metasploit-framework/libexec/gems"
export GEM_PATH="/opt/homebrew/opt/metasploit-framework/libexec/gems"
export BUNDLE_GEMFILE="/opt/homebrew/opt/metasploit-framework/libexec/Gemfile"
export PATH="/opt/homebrew/opt/ruby@3.4/bin:/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/opt/libpq/bin:$PATH"
exec "/opt/homebrew/opt/ruby@3.4/bin/ruby" -r bundler/setup "/opt/homebrew/opt/metasploit-framework/libexec/msfconsole" "$@"
```

This ensures MSF's gems are completely isolated, the correct Ruby version is always used, and keg-only dependencies (`libpq`, `postgresql@16`) are on `PATH` so `msfdb` can find `pg_ctl`, `createdb`, etc.

### Problem 6: Some MSF executables don't use Bundler

`msfconsole` loads gems through `config/boot.rb`, which calls `require 'bundler/setup'` to put all gems on Ruby's `$LOAD_PATH`. But other executables — notably `msfdb`, `msfd`, `msfrpc` — do raw `require 'rex/socket'` statements at the top of the file without ever invoking Bundler. This means even with `GEM_HOME` and `GEM_PATH` set correctly, Ruby can't find the gems because they're in Bundler's vendor-style directory layout (`gems/ruby/3.4.0/gems/...`), not a flat gem home.

**Our fix:** The wrapper scripts pass `-r bundler/setup` to the Ruby interpreter:

```bash
exec ruby -r bundler/setup "/path/to/msfdb" "$@"
```

This forces Bundler to set up the load path before the script's own `require` statements run. It's equivalent to `msfdb` having `require 'bundler/setup'` at the top of the file — but since we can't modify upstream's source, we inject it from the wrapper instead.

### Problem 7: brew audit is pedantic about dependency ordering

Homebrew's linter (`brew audit`) requires `depends_on` lines to be sorted alphabetically. Symbol dependencies like `:macos` are sorted as their string equivalent — so `:macos` sorts as `"macos"` and goes between `"libyaml"` and `"nmap"`, not at the beginning or end of the list. Getting this wrong produces audit errors that block formula acceptance. This is documented nowhere; you find out by failing the audit three times.

---

## Dependencies

All installed automatically by Homebrew:

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `ruby@3.4` | 3.4.9 | Runtime. MSF targets 3.3.8 but requires `>= 3.1`. |
| `postgresql@16` | 16.x | Full server for `msfdb init`. Keg-only. |
| `libpq` | latest | PostgreSQL client library for the `pg` gem. Keg-only. |
| `libpcap` | 1.10.x | Packet capture for the `pcaprub` gem. Keg-only. |
| `sqlite` | latest | SQLite for local storage via the `sqlite3` gem. Keg-only. |
| `openssl@3` | 3.x | TLS for `eventmachine` and `thin`. |
| `libyaml` | latest | YAML parsing (Ruby dependency). |
| `nmap` | latest | Network scanning, used by MSF modules at runtime. |

## Troubleshooting

**"undefined method 'key?' for nil" on msfconsole launch**: You have a stale database from a previous MSF installation. Run `msfdb reinit` (this drops and recreates the database) or launch without the database using `msfconsole -n`.

**pcaprub / packet capture permissions**: Modules that capture packets need BPF device access (`/dev/bpf*`). Either run `msfconsole` as root or add your user to the `access_bpf` group.

**Native extension build failures**: Make sure Xcode Command Line Tools are installed and reasonably current: `xcode-select --install`. The formula explicitly sets `SDKROOT` and C++ include paths, but extremely old CLT versions may still cause issues.

**Bundler version warnings**: The Gemfile.lock is bundled with Bundler 2.5.22. The formula installs `bundler ~> 2.5`. If you see version mismatch warnings, they're harmless — Bundler is backwards compatible within minor versions.

**ffi gem version**: MSF's gemspec constrains `ffi` to `< 1.17.0` because 1.17+ had breaking API changes. Bundler respects this constraint automatically from the lockfile. Do not try to force a newer ffi version.

---

## A note to Rapid7

It is 2026. Apple completed the ARM64 transition over four years ago. Every Mac sold since late 2022 ships with Apple Silicon exclusively. Your users — security professionals — overwhelmingly use Macs. Many of them have not been able to install Metasploit through official channels without Rosetta, a compatibility layer that was always meant to be transitional.

Building Metasploit from source on ARM64 macOS is not difficult. This formula does it in under two minutes. The gem dependencies all compile natively. The obstacles we encountered were:

1. A C++ include path that Homebrew's build environment doesn't set automatically (two lines of Ruby)
2. Pointing native gems at keg-only Homebrew libraries (six environment variables)
3. Overriding Homebrew's git clone strategy to avoid downloading 1.2GB of history (a 20-line subclass)
4. Injecting `bundler/setup` into wrapper scripts because some MSF executables don't invoke Bundler themselves

None of these are exotic problems. An official Homebrew formula or a universal ARM64 installer would save your users real time and frustration. We'd be happy to contribute this formula upstream or help with the effort.

## A note to Homebrew maintainers

We understand the cask maintainers are volunteers, and that upstream packaging failures aren't your responsibility to fix. That said, Metasploit is one of the most widely installed security tools on macOS. Marking the cask as deprecated and scheduling it for removal — without providing a source-build formula as an alternative or documenting a workaround — leaves a meaningful gap for a large user base. A little proactive effort here would go a long way.

---

## License

This tap formula is MIT licensed. Metasploit Framework itself is BSD-3-Clause.

If Rapid7 or the Homebrew maintainers want to adopt, adapt, or supersede this formula — please do. That would be the best possible outcome.
