# -*- encoding : utf-8 -*-
require "aws-sdk"
require "thor"

# Hack: aws requires this!
require "json"

require "deb/s3"
require "deb/s3/utils"
require "deb/s3/manifest"
require "deb/s3/package"
require "deb/s3/release"
require "deb/s3/lock"

class Deb::S3::CLI < Thor
  class_option :bucket,
  :type     => :string,
  :aliases  => "-b",
  :desc     => "The name of the S3 bucket to upload to."

  class_option :prefix,
  :type     => :string,
  :desc     => "The path prefix to use when storing on S3."

  class_option :origin,
  :type     => :string,
  :aliases  => "-o",
  :desc     => "The origin to use in the repository Release file."

  class_option :suite,
  :type     => :string,
  :desc     => "The suite to use in the repository Release file."

  class_option :codename,
  :default  => "stable",
  :type     => :string,
  :aliases  => "-c",
  :desc     => "The codename of the APT repository."

  class_option :component,
  :default  => "main",
  :type     => :string,
  :aliases  => "-m",
  :desc     => "The component of the APT repository."

  class_option :section,
  :type     => :string,
  :aliases  => "-s",
  :hide     => true

  class_option :access_key_id,
  :type     => :string,
  :desc     => "The access key for connecting to S3."

  class_option :secret_access_key,
  :type     => :string,
  :desc     => "The secret key for connecting to S3."

  class_option :s3_region,
  :type     => :string,
  :desc     => "The region for connecting to S3.",
  :default  => "us-east-1"

  class_option :force_path_style,
  :default  => false,
  :type     => :boolean,
  :desc     => "Use S3 path style instead of subdomains."

  class_option :proxy_uri,
  :type     => :string,
  :desc     => "The URI of the proxy to send service requests through."

  #class_option :use_ssl,
  #:default  => true,
  #:type     => :boolean,
  #:desc     => "Whether to use HTTP or HTTPS for request transport."

  class_option :visibility,
  :default  => "public",
  :type     => :string,
  :aliases  => "-v",
  :desc     => "The access policy for the uploaded files. " +
    "Can be public, private, or authenticated."

  class_option :sign,
  :type     => :string,
  :desc     => "Sign the Release file when uploading a package, " +
    "or when verifying it after removing a package. " +
    "Use --sign with your key ID to use a specific key."

  class_option :gpg_options,
  :default => "",
  :type    => :string,
  :desc    => "Additional command line options to pass to GPG when signing."

  class_option :encryption,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-e",
  :desc     => "Use S3 server side encryption."

  class_option :quiet,
  :type => :boolean,
  :aliases => "-q",
  :desc => "Doesn't output information, just returns status appropriately."

  class_option :cache_control,
  :type     => :string,
  :aliases  => "-C",
  :desc     => "Add cache-control headers to S3 objects."

  desc "upload FILES",
  "Uploads the given files to a S3 bucket as an APT repository."

  option :arch,
  :type     => :string,
  :aliases  => "-a",
  :desc     => "The architecture of the package in the APT repository."

  option :preserve_versions,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-p",
  :desc     => "Whether to preserve other versions of a package " +
    "in the repository when uploading one."

  option :lock,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-l",
  :desc     => "Whether to check for an existing lock on the repository " +
    "to prevent simultaneous updates "

  option :fail_if_exists,
  :default  => false,
  :type     => :boolean,
  :desc     => "Whether to overwrite any existing package that has the same " +
    "filename in the pool or the same name and version in the manifest."

  option :skip_package_upload,
  :default  => false,
  :type     => :boolean,
  :desc     => "Whether to skip all package uploads." +
    "This is useful when hosting .deb files outside of the bucket."

  def upload(*files)
    if files.nil? || files.empty?
      error("You must specify at least one file to upload")
    end

    # make sure all the files exists
    if missing_file = files.find { |pattern| Dir.glob(pattern).empty? }
      error("File '#{missing_file}' doesn't exist")
    end

    # configure AWS::S3
    configure_s3_client

    begin
      if options[:lock]
        log("Checking for existing lock file")
        if Deb::S3::Lock.locked?(options[:codename], component, options[:arch], options[:cache_control])
          lock = Deb::S3::Lock.current(options[:codename], component, options[:arch], options[:cache_control])
          log("Repository is locked by another user: #{lock.user} at host #{lock.host}")
          log("Attempting to obtain a lock")
          Deb::S3::Lock.wait_for_lock(options[:codename], component, options[:arch], options[:cache_control])
        end
        log("Locking repository for updates")
        Deb::S3::Lock.lock(options[:codename], component, options[:arch], options[:cache_control])
        @lock_acquired = true
      end

      # retrieve the existing manifests
      log("Retrieving existing manifests")
      release  = Deb::S3::Release.retrieve(options[:codename], options[:origin], options[:suite], options[:cache_control])
      manifests = {}
      release.architectures.each do |arch|
        manifests[arch] = Deb::S3::Manifest.retrieve(options[:codename], component, arch, options[:cache_control], options[:fail_if_exists], options[:skip_package_upload])
      end

      packages_arch_all = []

      # examine all the files
      files.collect { |f| Dir.glob(f) }.flatten.each do |file|
        log("Examining package file #{File.basename(file)}")
        pkg = Deb::S3::Package.parse_file(file)

        # copy over some options if they weren't given
        arch = options[:arch] || pkg.architecture

        # If they've specified an arch type that doesn't match the package let them know
        if options.key?("arch") && options[:arch] != pkg.architecture
          warn("You specified architecture #{options[:arch]} but package #{pkg.name} has architecture type of #{pkg.architecture}") 
        end

        # validate we have them
        error("No architcture given and unable to determine one for #{file}. " +
              "Please specify one with --arch [i386|amd64|armhf].") unless arch

        # If the arch is all and the list of existing manifests is none, then
        # throw an error. This is mainly the case when initializing a brand new
        # repository. With "all", we won't know which architectures they're using.
        if arch == "all" && manifests.count == 0
          error("Package #{File.basename(file)} had architecture \"all\", " +
                "however noexisting package lists exist. This can often happen " +
                "if the first package you are add to a new repository is an " +
                "\"all\" architecture file. Please use --arch [i386|amd64|armhf] or " +
                "another platform type to upload the file.")
        end

        # retrieve the manifest for the arch if we don't have it already
        manifests[arch] ||= Deb::S3::Manifest.retrieve(options[:codename], component, arch, options[:cache_control], options[:fail_if_exists])

        # add package in manifests
        begin
          manifests[arch].add(pkg, options[:preserve_versions])
        rescue Deb::S3::Utils::AlreadyExistsError => e
          error("Preparing manifest failed because: #{e}")
        end

        # If arch is all, we must add this package in all arch available
        if arch == 'all'
          packages_arch_all << pkg
        end
      end

      manifests.each do |arch, manifest|
        next if arch == 'all'
        packages_arch_all.each do |pkg|
          begin
            manifest.add(pkg, options[:preserve_versions], false)
          rescue Deb::S3::Utils::AlreadyExistsError => e
            error("Preparing manifest failed because: #{e}")
          end
        end
      end

      # upload the manifest
      log("Uploading packages and new manifests to S3")
      manifests.each_value do |manifest|
        begin
          manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
        rescue Deb::S3::Utils::AlreadyExistsError => e
          error("Uploading manifest failed because: #{e}")
        end
        release.update_manifest(manifest)
      end
      release.write_to_s3 { |f| sublog("Transferring #{f}") }

      log("Update complete.")
    ensure
      if options[:lock] && @lock_acquired
        Deb::S3::Lock.unlock(options[:codename], component, options[:arch], options[:cache_control])
        log("Lock released.")
      end
    end
  end

  desc "list", "Lists packages in given codename, component, and optionally architecture"

  option :long,
  :type     => :boolean,
  :aliases  => '-l',
  :desc     => "Shows all package information in original format.",
  :default  => false

  option :arch,
  :type     => :string,
  :aliases  => "-a",
  :desc     => "The architecture of the package in the APT repository."

  def list
    configure_s3_client

    release = Deb::S3::Release.retrieve(options[:codename])
    archs = release.architectures
    archs &= [options[:arch]] if options[:arch] && options[:arch] != "all"
    widths = [0, 0]
    rows = archs.map { |arch|
      manifest = Deb::S3::Manifest.retrieve(options[:codename], component,
                                            arch, options[:cache_control],
                                            false)
      manifest.packages.map do |package|
        if options[:long]
          package.generate
        else
          [package.name, package.full_version, package.architecture].tap do |row|
            row.each_with_index do |col, i|
              widths[i] = [widths[i], col.size].max if widths[i]
            end
          end
        end
      end
    }.flatten(1)

    if options[:long]
      $stdout.puts rows.join("\n")
    else
      rows.each do |row|
        $stdout.puts "% -#{widths[0]}s  % -#{widths[1]}s  %s" % row
      end
    end
  end

  desc "show PACKAGE VERSION ARCH", "Shows information about a package."

  def show(package_name, version, arch)
    if version.nil?
      error "You must specify the name of the package to show."
    end
    if version.nil?
      error "You must specify the version of the package to show."
    end
    if arch.nil?
      error "You must specify the architecture of the package to show."
    end

    configure_s3_client

    # retrieve the existing manifests
    manifest = Deb::S3::Manifest.retrieve(options[:codename], component, arch,
                                          options[:cache_control], false)
    package = manifest.packages.detect { |p|
      p.name == package_name && p.full_version == version
    }
    if package.nil?
      error "No such package found."
    end

    puts package.generate
  end

  desc "copy PACKAGE TO_CODENAME TO_COMPONENT ",
    "Copy the package named PACKAGE to given codename and component. If --versions is not specified, copy all versions of PACKAGE. Otherwise, only the specified versions will be copied. Source codename and component is given by --codename and --component options."

  option :cache_control,
  :type     => :string,
  :aliases  => "-C",
  :desc     => "Add cache-control headers to S3 objects."

  option :arch,
    :type     => :string,
    :aliases  => "-a",
    :desc     => "The architecture of the package in the APT repository."

  option :versions,
    :default  => nil,
    :type     => :array,
    :desc     => "The space-delimited versions of PACKAGE to delete. If not " +
    "specified, ALL VERSIONS will be deleted. Fair warning. " +
    "E.g. --versions \"0.1 0.2 0.3\""

  option :preserve_versions,
    :default  => false,
    :type     => :boolean,
    :aliases  => "-p",
    :desc     => "Whether to preserve other versions of a package " +
    "in the repository when uploading one."

  option :fail_if_exists,
  :default  => true,
  :type     => :boolean,
  :desc     => "Whether to overwrite any existing package that has the same " +
    "filename in the pool or the same name and version in the manifest."

  def copy(package_name, to_codename, to_component)
    if package_name.nil?
      error "You must specify a package name."
    end
    if to_codename.nil?
      error "You must specify a codename to copy to."
    end
    if to_component.nil?
      error "You must specify a component to copy to."
    end

    arch = options[:arch]
    if arch.nil?
      error "You must specify the architecture of the package to copy."
    end

    versions = options[:versions]
    if versions.nil?
      warn "===> WARNING: Copying all versions of #{package_name}"
    else
      log "Versions to copy: #{versions.join(', ')}"
    end

    configure_s3_client

    # retrieve the existing manifests
    log "Retrieving existing manifests"
    from_manifest = Deb::S3::Manifest.retrieve(options[:codename],
                                               component, arch,
                                               options[:cache_control],
                                               false)
    to_release = Deb::S3::Release.retrieve(to_codename)
    to_manifest = Deb::S3::Manifest.retrieve(to_codename, to_component, arch,
                                             options[:cache_control],
                                             options[:fail_if_exists])
    packages = from_manifest.packages.select { |p|
      p.name == package_name &&
        (versions.nil? || versions.include?(p.full_version))
    }
    if packages.size == 0
      error "No packages found in repository."
    end

    packages.each do |package|
      begin
        to_manifest.add package, options[:preserve_versions], false
      rescue Deb::S3::Utils::AlreadyExistsError => e
        error("Preparing manifest failed because: #{e}")
      end
    end

    begin
      to_manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
    rescue Deb::S3::Utils::AlreadyExistsError => e
      error("Copying manifest failed because: #{e}")
    end
    to_release.update_manifest(to_manifest)
    to_release.write_to_s3 { |f| sublog("Transferring #{f}") }

    log "Copy complete."
  end

  desc "delete PACKAGE",
    "Remove the package named PACKAGE. If --versions is not specified, delete" +
    "all versions of PACKAGE. Otherwise, only the specified versions will be " +
    "deleted."

  option :arch,
    :type     => :string,
    :aliases  => "-a",
    :desc     => "The architecture of the package in the APT repository."

  option :versions,
    :default  => nil,
    :type     => :array,
    :desc     => "The space-delimited versions of PACKAGE to delete. If not " +
    "specified, ALL VERSIONS will be deleted. Fair warning. " +
    "E.g. --versions \"0.1 0.2 0.3\""

  option :lock,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-l",
  :desc     => "Whether to check for an existing lock on the repository " +
    "to prevent simultaneous updates "

  def delete(package)
    if package.nil?
      error("You must specify a package name.")
    end

    versions = options[:versions]
    if versions.nil?
      warn("===> WARNING: Deleting all versions of #{package}")
    else
      log("Versions to delete: #{versions.join(', ')}")
    end

    arch = options[:arch]
    if arch.nil?
      error("You must specify the architecture of the package to remove.")
    end

    configure_s3_client

    begin
      if options[:lock]
        log("Checking for existing lock file")
        if Deb::S3::Lock.locked?(options[:codename], component, options[:arch], options[:cache_control])
          lock = Deb::S3::Lock.current(options[:codename], component, options[:arch], options[:cache_control])
          log("Repository is locked by another user: #{lock.user} at host #{lock.host}")
          log("Attempting to obtain a lock")
          Deb::S3::Lock.wait_for_lock(options[:codename], component, options[:arch], options[:cache_control])
        end
        log("Locking repository for updates")
        Deb::S3::Lock.lock(options[:codename], component, options[:arch], options[:cache_control])
        @lock_acquired = true
      end

      # retrieve the existing manifests
      log("Retrieving existing manifests")
      release  = Deb::S3::Release.retrieve(options[:codename], options[:origin], options[:suite])
      manifest = Deb::S3::Manifest.retrieve(options[:codename], component, options[:arch], options[:cache_control], false)

      deleted = manifest.delete_package(package, versions)
      if deleted.length == 0
          if versions.nil?
              error("No packages were deleted. #{package} not found.")
          else
              error("No packages were deleted. #{package} versions #{versions.join(', ')} could not be found.")
          end
      else
          deleted.each { |p|
              sublog("Deleting #{p.name} version #{p.full_version}")
          }
      end

      log("Uploading new manifests to S3")
      manifest.write_to_s3 {|f| sublog("Transferring #{f}") }
      release.update_manifest(manifest)
      release.write_to_s3 {|f| sublog("Transferring #{f}") }

      log("Update complete.")
    ensure
      if options[:lock] && @lock_acquired
        Deb::S3::Lock.unlock(options[:codename], component, options[:arch], options[:cache_control])
        log("Lock released.")
      end
    end
  end


  desc "verify", "Verifies that the files in the package manifests exist"

  option :fix_manifests,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-f",
  :desc     => "Whether to fix problems in manifests when verifying."

  def verify
    configure_s3_client

    log("Retrieving existing manifests")
    release = Deb::S3::Release.retrieve(options[:codename], options[:origin], options[:suite])

    release.architectures.each do |arch|
      log("Checking for missing packages in: #{options[:codename]}/#{options[:component]} #{arch}")
      manifest = Deb::S3::Manifest.retrieve(options[:codename], component,
                                            arch, options[:cache_control], false)
      missing_packages = []

      manifest.packages.each do |p|
        unless Deb::S3::Utils.s3_exists? p.url_filename_encoded
          sublog("The following packages are missing:\n\n") if missing_packages.empty?
          puts(p.generate)
          puts("")

          missing_packages << p
        end
      end

      if options[:sign] || (options[:fix_manifests] && !missing_packages.empty?)
        log("Removing #{missing_packages.length} package(s) from the manifest...")
        missing_packages.each { |p| manifest.packages.delete(p) }
        manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
        release.update_manifest(manifest)
        release.write_to_s3 { |f| sublog("Transferring #{f}") }

        log("Update complete.")
      end
    end
  end

  private

  def component
    return @component if @component
    @component = if (section = options[:section])
                   warn("===> WARNING: The --section/-s argument is " \
                        "deprecated, please use --component/-m.")
                   section
                 else
                   options[:component]
                 end
  end

  def puts(*args)
    $stdout.puts(*args) unless options[:quiet]
  end

  def log(message)
    puts ">> #{message}" unless options[:quiet]
  end

  def sublog(message)
    puts "   -- #{message}" unless options[:quiet]
  end

  def error(message)
    $stderr.puts "!! #{message}" unless options[:quiet]
    exit 1
  end

  def provider
    access_key_id     = options[:access_key_id]
    secret_access_key = options[:secret_access_key]

    if access_key_id.nil? ^ secret_access_key.nil?
      error("If you specify one of --access-key-id or --secret-access-key, you must specify the other.")
    end
    static_credentials = {}
    static_credentials[:access_key_id]     = access_key_id     if access_key_id
    static_credentials[:secret_access_key] = secret_access_key if secret_access_key

    static_credentials
  end

  def configure_s3_client
    error("No value provided for required options '--bucket'") unless options[:bucket]

    settings = {
      :region => options[:s3_region],
      :http_proxy   => options[:proxy_uri],
      :force_path_style => options[:force_path_style]
    }
    settings.merge!(provider)

    Deb::S3::Utils.s3          = Aws::S3::Client.new(settings)
    Deb::S3::Utils.bucket      = options[:bucket]
    Deb::S3::Utils.signing_key = options[:sign]
    Deb::S3::Utils.gpg_options = options[:gpg_options]
    Deb::S3::Utils.prefix      = options[:prefix]
    Deb::S3::Utils.encryption  = options[:encryption]

    # make sure we have a valid visibility setting
    Deb::S3::Utils.access_policy =
      case options[:visibility]
      when "public"
        "public-read"
      when "private"
        "private"
      when "authenticated"
        "authenticated-read"
      when "bucket_owner"
        "bucket-owner-full-control"
      else
        error("Invalid visibility setting given. Can be public, private, authenticated, or bucket_owner.")
      end
  end
end
