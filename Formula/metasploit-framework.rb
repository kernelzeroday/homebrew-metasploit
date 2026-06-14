class MetasploitFramework < Formula
  desc "Penetration testing framework"
  homepage "https://www.metasploit.com/"
  license "BSD-3-Clause"
  head "https://github.com/rapid7/metasploit-framework.git", branch: "master"

  depends_on "libpcap"
  depends_on "libpq"
  depends_on "libyaml"
  depends_on "nmap"
  depends_on "openssl@3"
  depends_on "postgresql@16"
  depends_on "ruby@3.4"
  depends_on "sqlite"
  depends_on :macos

  def install
    ENV["GEM_HOME"] = libexec/"gems"
    ENV["GEM_PATH"] = libexec/"gems"
    ENV["BUNDLE_GEMFILE"] = buildpath/"Gemfile"

    ruby = Formula["ruby@3.4"].opt_bin/"ruby"
    gem = Formula["ruby@3.4"].opt_bin/"gem"

    ENV.append "CPPFLAGS", "-I#{Formula["libpcap"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["libpcap"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["openssl@3"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["openssl@3"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["sqlite"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["sqlite"].opt_lib}"
    ENV.append "CPPFLAGS", "-I#{Formula["libpq"].opt_include}"
    ENV.append "LDFLAGS", "-L#{Formula["libpq"].opt_lib}"

    ENV["BUNDLE_BUILD__PG"] = "--with-pg-config=#{Formula["libpq"].opt_bin}/pg_config"
    ENV["BUNDLE_BUILD__SQLITE3"] = "--with-sqlite3-dir=#{Formula["sqlite"].opt_prefix}"
    ENV["BUNDLE_BUILD__PCAPRUB"] = "--with-pcap-dir=#{Formula["libpcap"].opt_prefix}"
    ENV["BUNDLE_BUILD__NOKOGIRI"] = "--use-system-libraries"
    ENV["BUNDLE_BUILD__THIN"] = "--with-openssl-dir=#{Formula["openssl@3"].opt_prefix}"
    ENV["BUNDLE_BUILD__EVENTMACHINE"] = "--with-openssl-dir=#{Formula["openssl@3"].opt_prefix}"

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
        exec "#{Formula["ruby@3.4"].opt_bin}/ruby" "#{libexec}/#{cmd}" "$@"
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
