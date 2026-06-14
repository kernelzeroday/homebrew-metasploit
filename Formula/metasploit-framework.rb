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

class MetasploitFramework < Formula
  desc "Penetration testing framework"
  homepage "https://www.metasploit.com/"
  license "BSD-3-Clause"
  head "https://github.com/rapid7/metasploit-framework.git",
       branch: "master",
       using:  ShallowGitDownloadStrategy

  depends_on "libpcap"
  depends_on "libpq"
  depends_on "libyaml"
  depends_on :macos
  depends_on "nmap"
  depends_on "openssl@3"
  depends_on "postgresql@16"
  depends_on "ruby@3.4"
  depends_on "sqlite"

  def install
    ENV["GEM_HOME"] = libexec/"gems"
    ENV["GEM_PATH"] = libexec/"gems"
    ENV["BUNDLE_GEMFILE"] = buildpath/"Gemfile"
    ENV["SDKROOT"] = MacOS.sdk_path.to_s

    ruby = Formula["ruby@3.4"].opt_bin/"ruby"
    gem = Formula["ruby@3.4"].opt_bin/"gem"

    sdk_cxx = "#{MacOS.sdk_path}/usr/include/c++/v1"
    ENV.append "CPPFLAGS", "-I#{sdk_cxx}"
    ENV.append "CXXFLAGS", "-I#{sdk_cxx}"

    ENV.append "CPPFLAGS", "-I#{Formula["libpcap"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["libpcap"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["openssl@3"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["openssl@3"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["sqlite"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["sqlite"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["libpq"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["libpq"].opt_lib}"

    openssl = Formula["openssl@3"]
    ENV["BUNDLE_BUILD__PG"] = "--with-pg-config=#{Formula["libpq"].opt_bin}/pg_config"
    ENV["BUNDLE_BUILD__SQLITE3"] = "--with-sqlite3-dir=#{Formula["sqlite"].opt_prefix}"
    ENV["BUNDLE_BUILD__PCAPRUB"] = "--with-pcap-dir=#{Formula["libpcap"].opt_prefix}"
    ENV["BUNDLE_BUILD__NOKOGIRI"] = "--use-system-libraries"
    ENV["BUNDLE_BUILD__THIN"] = "--with-ssl-dir=#{openssl.opt_prefix} --with-cppflags=-I#{sdk_cxx} --with-cxxflags=-I#{sdk_cxx}"
    ENV["BUNDLE_BUILD__EVENTMACHINE"] = "--with-ssl-dir=#{openssl.opt_prefix} --with-cppflags=-I#{sdk_cxx} --with-cxxflags=-I#{sdk_cxx}"

    system gem, "install", "bundler", "--version", "~> 2.5",
           "--no-document", "--install-dir", libexec/"gems"

    bundler = libexec/"gems/bin/bundle"
    system ruby, bundler, "config", "set", "--local", "path", (libexec/"gems").to_s
    system ruby, bundler, "config", "set", "--local", "without", "development:coverage:test"
    system ruby, bundler, "config", "set", "--local", "jobs", ENV.make_jobs.to_s
    system ruby, bundler, "install"

    libexec.install Dir["*", ".ruby-version", ".bundle"]

    executables = %w[
      msfconsole msfvenom msfd msfdb msfrpc msfrpcd msfupdate msfmcpd
    ]

    executables.each do |cmd|
      next unless (libexec/cmd).exist?

      (bin/cmd).write <<~BASH
        #!/bin/bash
        export GEM_HOME="#{libexec}/gems"
        export GEM_PATH="#{libexec}/gems"
        export BUNDLE_GEMFILE="#{libexec}/Gemfile"
        export PATH="#{Formula["ruby@3.4"].opt_bin}:#{Formula["postgresql@16"].opt_bin}:#{Formula["libpq"].opt_bin}:$PATH"
        exec "#{Formula["ruby@3.4"].opt_bin}/ruby" -r bundler/setup "#{libexec}/#{cmd}" "$@"
      BASH
    end
  end

  def caveats
    <<~EOS
      To set up the database (recommended):
        brew services start postgresql@16
        msfdb init

      To update to latest:
        brew upgrade --fetch-HEAD metasploit-framework

      User data is stored in ~/.msf4/
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/msfvenom --help")
  end
end
