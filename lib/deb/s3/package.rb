require "digest/sha1"
require "digest/sha2"
require "digest/md5"
require "socket"
require "tmpdir"

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
  attr_accessor :provides
  attr_accessor :conflicts
  attr_accessor :replaces
  attr_accessor :excludes


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
      if system("which dpkg 2>&1 >/dev/null")
        `dpkg -f #{package}`
      else
        # ar fails to find the control.tar.gz tarball within the .deb
        # on Mac OS. Try using ar to list the control file, if found,
        # use ar to extract, otherwise attempt with tar which works on OS X.
        extract_control_tarball_cmd = "ar p #{package} control.tar.gz"

        begin
          safesystem("ar t #{package} control.tar.gz")
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

    @provides = []
    @conflicts = []
    @replaces = []
    @dependencies = []

    @needs_uploading = false
  end

  def filename=(f)
    @filename = f
    @needs_uploading = true
    @filename
  end

  def url_filename
    @url_filename || "pool/#{self.name[0]}/#{self.name[0..1]}/#{File.basename(self.filename)}"
  end

  def url_filename_encoded
    @url_filename || "pool/#{self.name[0]}/#{self.name[0..1]}/#{s3_escape(File.basename(self.filename))}"
  end

  def needs_uploading?
    @needs_uploading
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
    self.epoch, self.version, self.iteration = m.captures

    self.architecture = parse.call("Architecture")
    self.category = parse.call("Section")
    self.license = parse.call("License") || self.license
    self.maintainer = parse.call("Maintainer")
    self.name = parse.call("Package")
    self.url = parse.call("Homepage")
    self.vendor = parse.call("Vendor") || self.vendor
    self.attributes[:deb_priority] = parse.call("Priority")
    self.attributes[:deb_origin] = parse.call("Origin")
    self.attributes[:deb_installed_size] = parse.call("Installed-Size")

    # Packages manifest fields
    self.url_filename = parse.call("Filename")
    self.sha1 = parse.call("SHA1")
    self.sha256 = parse.call("SHA256")
    self.md5 = parse.call("MD5sum")
    self.size = parse.call("Size")

    # The description field is a special flower, parse it that way.
    # The description is the first line as a normal Description field, but also continues
    # on future lines indented by one space, until the end of the file. Blank
    # lines are marked as ' .'
    description = control[/^Description: .*[^\Z]/m]
    description = description.gsub(/^[^(Description|\s)].*$/, "").split(": ", 2).last
    self.description = description.gsub(/^ /, "").gsub(/^\.$/, "")

    #self.config_files = config_files

    self.dependencies += Array(parse_depends(parse.call("Depends")))
    self.conflicts += Array(parse_depends(parse.call("Conflicts")))
    self.provides += Array(parse_depends(parse.call("Provides")))
    self.replaces += Array(parse_depends(parse.call("Replaces")))
  end # def extract_info

  def apply_file_info(file)
    self.size = File.size(file)
    self.sha1 = Digest::SHA1.file(file).hexdigest
    self.sha256 = Digest::SHA2.file(file).hexdigest
    self.md5 = Digest::MD5.file(file).hexdigest
  end
end
