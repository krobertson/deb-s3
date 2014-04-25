require File.expand_path('../../../spec_helper', __FILE__)
require 'deb/s3/package'

describe Deb::S3::Package do
  describe ".parse_string" do
    it "creates a Package object with the right attributes" do
      package = Deb::S3::Package.parse_string(File.read(fixture("Packages")))
      package.version.must_equal("0.9.8.3")
      package.epoch.must_equal(nil)
      package.iteration.must_equal("1396474125.12e4179.wheezy")
      package.full_version.must_equal("0.9.8.3-1396474125.12e4179.wheezy")
    end
  end

  describe "#full_version" do
    it "returns nil if no version, epoch, iteration" do
      package = create_package
      package.full_version.must_equal nil
    end

    it "returns only the version if no epoch and no iteration" do
      package = create_package version: "0.9.8"
      package.full_version.must_equal "0.9.8"
    end

    it "returns epoch:version if epoch and version" do
      epoch = Time.now.to_i
      package = create_package version: "0.9.8", epoch: epoch
      package.full_version.must_equal "#{epoch}:0.9.8"
    end

    it "returns version-iteration if version and iteration" do
      package = create_package version: "0.9.8", iteration: "2"
      package.full_version.must_equal "0.9.8-2"
    end

    it "returns epoch:version-iteration if epoch and version and iteration" do
      epoch = Time.now.to_i
      package = create_package version: "0.9.8", iteration: "2", epoch: epoch
      package.full_version.must_equal "#{epoch}:0.9.8-2"
    end
  end
end
