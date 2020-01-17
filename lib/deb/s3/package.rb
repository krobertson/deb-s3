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
  attr_accessor :url_filename
  attr_accessor :sha1
  attr_accessor :sha256
  attr_accessor :md5
  attr_accessor :size

  attr_accessor :filename

  class << self
    include Deb::S3::Utils

    def parse_file(package)
      p = self.new
      p.extract_info(extract_control(package))
      p.apply_file_info(package)
      p.filename = package
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
        # use ar to determine control file name (control.ext)
        package_files = `ar t #{package}`
        control_file = package_files.split("\n").select do |file|
          file.start_with?("control.")
        end.first
        if control_file === "control.tar.gz"
          compression = "z"
        else
          compression = "J"
        end

        # ar fails to find the control.tar.gz tarball within the .deb
        # on Mac OS. Try using ar to list the control file, if found,
        # use ar to extract, otherwise attempt with tar which works on OS X.
        extract_control_tarball_cmd = "ar p #{package} #{control_file}"

        begin
          safesystem("ar t #{package} #{control_file} &> /dev/null")
        rescue SafeSystemError
          warn "Failed to find control data in .deb with ar, trying tar."
          extract_control_tarball_cmd = "tar #{compression}xf #{package} --to-stdout #{control_file}"
        end

        Dir.mktmpdir do |path|
          safesystem("#{extract_control_tarball_cmd} | tar -#{compression}xf - -C #{path}")
          File.read(File.join(path, "control"))
        end
      end
    end
  end

  def initialize
    @attributes = {}

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

    @name = nil
    @architecture = "native"
    @description = "no description given"
    @version = nil
    @epoch = nil
    @iteration = nil
    @url = nil
    @category = "default"
    @license = "unknown"
    @vendor = "none"
    @sha1 = nil
    @sha256 = nil
    @md5 = nil
    @size = nil
    @filename = nil
    @url_filename = nil

    @dependencies = []
  end

  def full_version
    return nil if [epoch, version, iteration].all?(&:nil?)
    [[epoch, version].compact.join(":"), iteration].compact.join("-")
  end

  def filename=(f)
    @filename = f
    @filename
  end

  def url_filename(codename)
    @url_filename || "pool/#{codename}/#{self.name[0]}/#{self.name[0..1]}/#{File.basename(self.filename)}"
  end

  def url_filename_encoded(codename)
    @url_filename || "pool/#{codename}/#{self.name[0]}/#{self.name[0..1]}/#{s3_escape(File.basename(self.filename))}"
  end

  def generate(codename)
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
    fields = parse_control(control)

    # Parse 'epoch:version-iteration' in the version string
    full_version = fields.delete('Version')
    if full_version !~ /^(?:([0-9]+):)?(.+?)(?:-(.*))?$/
      raise "Unsupported version string '#{full_version}'"
    end
    self.epoch, self.version, self.iteration = $~.captures

    self.architecture = fields.delete('Architecture')
    self.category = fields.delete('Section')
    self.license = fields.delete('License') || self.license
    self.maintainer = fields.delete('Maintainer')
    self.name = fields.delete('Package')
    self.url = fields.delete('Homepage')
    self.vendor = fields.delete('Vendor') || self.vendor
    self.attributes[:deb_priority] = fields.delete('Priority')
    self.attributes[:deb_origin] = fields.delete('Origin')
    self.attributes[:deb_installed_size] = fields.delete('Installed-Size')

    # Packages manifest fields
    filename = fields.delete('Filename')
    self.url_filename = filename && URI.unescape(filename)
    self.sha1 = fields.delete('SHA1')
    self.sha256 = fields.delete('SHA256')
    self.md5 = fields.delete('MD5sum')
    self.size = fields.delete('Size')
    self.description = fields.delete('Description')

    #self.config_files = config_files

    self.dependencies += Array(parse_depends(fields.delete('Depends')))

    self.attributes[:deb_recommends] = fields.delete('Recommends')
    self.attributes[:deb_suggests]   = fields.delete('Suggests')
    self.attributes[:deb_enhances]   = fields.delete('Enhances')
    self.attributes[:deb_pre_depends] = fields.delete('Pre-Depends')

    self.attributes[:deb_breaks]    = fields.delete('Breaks')
    self.attributes[:deb_conflicts] = fields.delete('Conflicts')
    self.attributes[:deb_provides]  = fields.delete('Provides')
    self.attributes[:deb_replaces]  = fields.delete('Replaces')

    self.attributes[:deb_field] = Hash[fields.map { |k, v|
      [k.sub(/\AX[BCS]{0,3}-/, ''), v]
    }]
  end # def extract_info

  def apply_file_info(file)
    self.size = File.size(file)
    self.sha1 = Digest::SHA1.file(file).hexdigest
    self.sha256 = Digest::SHA2.file(file).hexdigest
    self.md5 = Digest::MD5.file(file).hexdigest
  end

  def parse_control(control)
    field = nil
    value = ""
    {}.tap do |fields|
      control.each_line do |line|
        if line =~ /^(\s+)(\S.*)$/
          indent, rest = $1, $2
          # Continuation
          if indent.size == 1 && rest == "."
            value << "\n"
            rest = ""
          elsif value.size > 0
            value << "\n"
          end
          value << rest
        elsif line =~ /^([-\w]+):(.*)$/
          fields[field] = value if field
          field, value = $1, $2.strip
        end
      end
      fields[field] = value if field
    end
  end
end
