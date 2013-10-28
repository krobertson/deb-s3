require "aws"
require "thor"

# Hack: aws requires this!
require "json"

require "deb/s3"
require "deb/s3/utils"
require "deb/s3/manifest"
require "deb/s3/package"
require "deb/s3/release"

class Deb::S3::CLI < Thor
  class_option :bucket,
  :type     => :string,
  :aliases  => "-b",
  :desc     => "The name of the S3 bucket to upload to."

  class_option :prefix,
  :type     => :string,
  :desc     => "The path prefix to use when storing on S3."

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

  class_option :endpoint,
  :type     => :string,
  :desc     => "The region endpoint for connecting to S3.",
  :default  => "s3.amazonaws.com"

  class_option :visibility,
  :default  => "public",
  :type     => :string,
  :aliases  => "-v",
  :desc     => "The access policy for the uploaded files. " +
    "Can be public, private, or authenticated."

  class_option :sign,
  :type     => :string,
  :desc     => "Sign the Release file when uploading a package," +
    "or when verifying it after removing a package." +
    "Use --sign with your key ID to use a specific key."

  class_option :gpg_options,
  :default => "",
  :type    => :string,
  :desc    => "Additional command line options to pass to GPG when signing"

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

  def upload(*files)
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    if files.nil? || files.empty?
      error("You must specify at least one file to upload")
    end

    # make sure all the files exists
    if missing_file = files.detect { |f| !File.exists?(f) }
      error("File '#{missing_file}' doesn't exist")
    end

    # configure AWS::S3
    configure_s3_client

    # retrieve the existing manifests
    log("Retrieving existing manifests")
    release  = Deb::S3::Release.retrieve(options[:codename])
    manifests = {}

    # examine all the files
    files.collect { |f| Dir.glob(f) }.flatten.each do |file|
      log("Examining package file #{File.basename(file)}")
      pkg = Deb::S3::Package.parse_file(file)

      # copy over some options if they weren't given
      arch = options[:arch] || pkg.architecture

      # validate we have them
      error("No architcture given and unable to determine one for #{file}. " +
            "Please specify one with --arch [i386,amd64].") unless arch

      # retrieve the manifest for the arch if we don't have it already
      manifests[arch] ||= Deb::S3::Manifest.retrieve(options[:codename], component, arch)

      # add in the package
      manifests[arch].add(pkg, options[:preserve_versions])
    end

    # upload the manifest
    log("Uploading packages and new manifests to S3")
    manifests.each_value do |manifest|
      manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
      release.update_manifest(manifest)
    end
    release.write_to_s3 { |f| sublog("Transferring #{f}") }

    log("Update complete.")
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
    :desc     => "The space-delimited versions of PACKAGE to delete. If not" +
    "specified, ALL VERSIONS will be deleted. Fair warning." +
    "E.g. --versions \"0.1 0.2 0.3\""

  def delete(package)
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

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

    # retrieve the existing manifests
    log("Retrieving existing manifests")
    release  = Deb::S3::Release.retrieve(options[:codename])
    manifest = Deb::S3::Manifest.retrieve(options[:codename], component, options[:arch])

    deleted = manifest.delete_package(package, versions)
    if deleted.length == 0
        if versions.nil?
            error("No packages were deleted. #{package} not found.")
        else
            error("No packages were deleted. #{package} versions #{versions.join(', ')} could not be found.")
        end
    else
        deleted.each { |p|
            sublog("Deleting #{p.name} version #{p.version}")
        }
    end

    log("Uploading new manifests to S3")
    manifest.write_to_s3 {|f| sublog("Transferring #{f}") }
    release.update_manifest(manifest)
    release.write_to_s3 {|f| sublog("Transferring #{f}") }

    log("Update complete.")
  end


  desc "verify", "Verifies that the files in the package manifests exist"

  option :fix_manifests,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-f",
  :desc     => "Whether to fix problems in manifests when verifying."

  def verify
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    configure_s3_client

    log("Retrieving existing manifests")
    release = Deb::S3::Release.retrieve(options[:codename])

    %w[amd64 armel i386 all].each do |arch|
      log("Checking for missing packages in: #{options[:codename]}/#{options[:component]} #{arch}")
      manifest = Deb::S3::Manifest.retrieve(options[:codename], component, arch)
      missing_packages = []

      manifest.packages.each do |p|
        unless Deb::S3::Utils.s3_exists? p.url_filename_encoded
          sublog("The following packages are missing:\n\n") if missing_packages.empty?
          puts(p.generate)
          puts("")

          missing_packages << p
        end
      end

      if options[:fix_manifests] && !missing_packages.empty?
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

  def log(message)
    puts ">> #{message}"
  end

  def sublog(message)
    puts "   -- #{message}"
  end

  def error(message)
    puts "!! #{message}"
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

    AWS::Core::CredentialProviders::DefaultProvider.new(static_credentials)
  end

  def configure_s3_client
    error("No value provided for required options '--bucket'") unless options[:bucket]

    settings = { :s3_endpoint => options[:endpoint] }
    settings.merge!(provider.credentials)

    Deb::S3::Utils.s3          = AWS::S3.new(settings)
    Deb::S3::Utils.bucket      = options[:bucket]
    Deb::S3::Utils.signing_key = options[:sign]
    Deb::S3::Utils.gpg_options = options[:gpg_options]
    Deb::S3::Utils.prefix      = options[:prefix]

    # make sure we have a valid visibility setting
    Deb::S3::Utils.access_policy =
      case options[:visibility]
      when "public"
        :public_read
      when "private"
        :private
      when "authenticated"
        :authenticated_read
      else
        error("Invalid visibility setting given. Can be public, private, or authenticated.")
      end
  end
end
