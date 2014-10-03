# -*- encoding : utf-8 -*-
require "digest/sha1"
require "digest/sha2"
require "digest/md5"
require "socket"
require "tmpdir"
require "uri"

require 'deb/s3/utils'

class Deb::S3::Package
  include Deb::S3::Utils

  attr_accessor :name
  attr_accessor :version
  attr_accessor :epoch
  attr_accessor :iteration
  attr_accessor :maintainer
  attr_accessor :vendor
  attr_accessor :url
  attr_accessor :category
  attr_accessor :license
  attr_accessor :architecture
  attr_accessor :description

  attr_accessor :dependencies

  # Any other attributes specific to this package.
  # This is where you'd put rpm, deb, or other specific attributes.
  attr_accessor :attributes

  # hashes
  attr_accessor :sha1
  attr_accessor :sha256
  attr_accessor :md5
  attr_accessor :size

  attr_accessor :filename
  attr_accessor :file

  attr_accessor :codename

  class << self
    include Deb::S3::Utils

    def parse_file(file)
      p = self.new
      p.extract_info(extract_control(file))
      p.apply_file_info(file)
      p.file = file
      p
    end

    def parse_string(s)
      p = self.new
      p.extract_info(s)
      p
    end

    def extract_control(package)
      if system("which dpkg > /dev/null 2>&1")
        `dpkg -f #{package}`
      else
        # ar fails to find the control.tar.gz tarball within the .deb
        # on Mac OS. Try using ar to list the control file, if found,
        # use ar to extract, otherwise attempt with tar which works on OS X.
        extract_control_tarball_cmd = "ar p #{package} control.tar.gz"

        begin
          safesystem("ar t #{package} control.tar.gz &> /dev/null")
        rescue SafeSystemError
          warn "Failed to find control data in .deb with ar, trying tar."
          extract_control_tarball_cmd = "tar zxf #{package} --to-stdout control.tar.gz"
        end

        Dir.mktmpdir do |path|
          safesystem("#{extract_control_tarball_cmd} | tar -zxf - -C #{path}")
          File.read(File.join(path, "control"))
        end
      end
    end
  end

  def initialize(opt = {})
    @attributes = opt[:attributes] || {}

    # Reference
    # http://www.debian.org/doc/manuals/maint-guide/first.en.html
    # http://wiki.debian.org/DeveloperConfiguration
    # https://github.com/jordansissel/fpm/issues/37
    if ENV.include?("DEBEMAIL") and ENV.include?("DEBFULLNAME")
      # Use DEBEMAIL and DEBFULLNAME as the default maintainer if available.
      @maintainer = "#{ENV["DEBFULLNAME"]} <#{ENV["DEBEMAIL"]}>"
    else
      # TODO(sissel): Maybe support using 'git config' for a default as well?
      # git config --get user.name, etc can be useful.
      #
      # Otherwise default to user@currenthost
      @maintainer = "<#{ENV["USER"]}@#{Socket.gethostname}>"
    end

    @name = opt[:name]
    @architecture = opt[:architexture] || "native"
    @description = opt[:description] || "no description given"
    @version = opt[:version]
    @epoch = opt[:epoch]
    @iteration = opt[:iteration]
    @url = opt[:url]
    @category = opt[:category] || "default"
    @license = opt[:license] || "unknown"
    @vendor = opt[:vendor] || "none"
    @sha1 = opt[:sha1]
    @sha256 = opt[:sha256]
    @md5 = opt[:md5]
    @size = opt[:size]
    @filename = opt[:filename]
    @codename = opt[:codename]
    @dependencies = opt[:dependencies] || []
    @file = opt[:file]
  end

  def full_version
    return nil if [epoch, version, iteration].all?(&:nil?)
    [[epoch, version].compact.join(":"), iteration].compact.join("-")
  end

  def generate
    template("package.erb").result(binding)
  end

  # from fpm
  def parse_depends(data)
    return [] if data.nil? or data.empty?
    # parse dependencies. Debian dependencies come in one of two forms:
    # * name
    # * name (op version)
    # They are all on one line, separated by ", "

    dep_re = /^([^ ]+)(?: \(([>=<]+) ([^)]+)\))?$/
    return data.split(/, */).collect do |dep|
      m = dep_re.match(dep)
      if m
        name, op, version = m.captures
        # this is the proper form of dependency
        if op && version && op != "" && version != ""
          "#{name} (#{op} #{version})".strip
        else
          name.strip
        end
      else
        # Assume normal form dependency, "name op version".
        dep
      end
    end
  end # def parse_depends

  # from fpm
  def fix_dependency(dep)
    # Deb dependencies are: NAME (OP VERSION), like "zsh (> 3.0)"
    # Convert anything that looks like 'NAME OP VERSION' to this format.
    if dep =~ /[\(,\|]/
      # Don't "fix" ones that could appear well formed already.
    else
      # Convert ones that appear to be 'name op version'
      name, op, version = dep.split(/ +/)
      if !version.nil?
        # Convert strings 'foo >= bar' to 'foo (>= bar)'
        dep = "#{name} (#{debianize_op(op)} #{version})"
      end
    end

    name_re = /^[^ \(]+/
    name = dep[name_re]
    if name =~ /[A-Z]/
      dep = dep.gsub(name_re) { |n| n.downcase }
    end

    if dep.include?("_")
      dep = dep.gsub("_", "-")
    end

    # Convert gem ~> X.Y.Z to '>= X.Y.Z' and << X.Y+1.0
    if dep =~ /\(~>/
      name, version = dep.gsub(/[()~>]/, "").split(/ +/)[0..1]
      nextversion = version.split(".").collect { |v| v.to_i }
      l = nextversion.length
      nextversion[l-2] += 1
      nextversion[l-1] = 0
      nextversion = nextversion.join(".")
      return ["#{name} (>= #{version})", "#{name} (<< #{nextversion})"]
    elsif (m = dep.match(/(\S+)\s+\(!= (.+)\)/))
      # Append this to conflicts
      self.conflicts += [dep.gsub(/!=/,"=")]
      return []
    elsif (m = dep.match(/(\S+)\s+\(= (.+)\)/)) and
        self.attributes[:deb_ignore_iteration_in_dependencies?]
      # Convert 'foo (= x)' to 'foo (>= x)' and 'foo (<< x+1)'
      # but only when flag --ignore-iteration-in-dependencies is passed.
      name, version = m[1..2]
      nextversion = version.split('.').collect { |v| v.to_i }
      nextversion[-1] += 1
      nextversion = nextversion.join(".")
      return ["#{name} (>= #{version})", "#{name} (<< #{nextversion})"]
    else
      # otherwise the dep is probably fine
      return dep.rstrip
    end
  end # def fix_dependency

  # from fpm
  def extract_info(control)
    parse = lambda do |field|
      value = control[/^#{field}: .*/]
      if value.nil?
        return nil
      else
        return value.split(": ",2).last
      end
    end

    # Parse 'epoch:version-iteration' in the version string
    version_re = /^(?:([0-9]+):)?(.+?)(?:-(.*))?$/
    m = version_re.match(parse.call("Version"))
    if !m
      raise "Unsupported version string '#{parse.call("Version")}'"
    end
    epoch, self.version, self.iteration = m.captures

    @architecture = parse.call("Architecture")
    @category = parse.call("Section")
    @license = parse.call("License") || self.license
    @maintainer = parse.call("Maintainer")
    @name = parse.call("Package")
    @url = parse.call("Homepage")
    @vendor ||= parse.call("Vendor")
    @attributes[:deb_priority] = parse.call("Priority")
    @attributes[:deb_origin] = parse.call("Origin")
    @attributes[:deb_installed_size] = parse.call("Installed-Size")

    # Packages manifest fields
    @filename = parse.call("Filename") && URI.unescape(parse.call("Filename"))
    @sha1 = parse.call("SHA1")
    @sha256 = parse.call("SHA256")
    @md5 = parse.call("MD5sum")
    @size = parse.call("Size")

    # The description field is a special flower, parse it that way.
    # The description is the first line as a normal Description field, but also continues
    # on future lines indented by one space, until the end of the file. Blank
    # lines are marked as ' .'
    description = control[/^Description: .*[^\Z]/m]
    description = description.gsub(/^[^(Description|\s)].*$/, "").split(": ", 2).last
    @description = description.gsub(/^ /, "").gsub(/^\.$/, "")

    #self.config_files = config_files

    @dependencies += Array(parse_depends(parse.call("Depends")))

    @attributes[:deb_recommends] = parse.call('Recommends')
    @attributes[:deb_suggests]   = parse.call('Suggests')
    @attributes[:deb_enhances]   = parse.call('Enhances')
    @attributes[:deb_pre_depends] = parse.call('Pre-Depends')

    @attributes[:deb_breaks]    = parse.call('Breaks')
    @attributes[:deb_conflicts] = parse.call("Conflicts")
    @attributes[:deb_provides]  = parse.call("Provides")
    @attributes[:deb_replaces]  = parse.call("Replaces")
  end # def extract_info

  def apply_file_info(file)
    @size = File.size(file)
    @sha1 = Digest::SHA1.file(file).hexdigest
    @sha256 = Digest::SHA2.file(file).hexdigest
    @md5 = Digest::MD5.file(file).hexdigest
  end

  def hash
    [self.class, @name, @full_version].hash
  end

  def eql?(other)
    self.class == other.class &&
    name == other.name &&
    full_version == other.full_version
  end
  alias_method :==, :eql?

  def to_s
    "#{@name}_#{full_version}"
  end
end
