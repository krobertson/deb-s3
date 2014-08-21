# -*- encoding : utf-8 -*-
require File.expand_path('../../../spec_helper', __FILE__)
require 'deb/s3/manifest'

describe Deb::S3::Manifest do
  before do
    @manifest = Deb::S3::Manifest.new
  end

  describe "#add" do
    it "removes packages which have the same full version" do
      epoch = Time.now.to_i
      existing_package_with_same_full_version = create_package :name => "discourse", :epoch =>  epoch, :version => "0.9.8.3", :iteration => "1"
      new_package = create_package :name => "discourse", :epoch =>  epoch, :version => "0.9.8.3", :iteration => "1"

      @manifest.stub :packages, [existing_package_with_same_full_version] do
        @manifest.add(new_package, preserve_versions=true)
        @manifest.packages.length.must_equal 1
      end
    end

    it "does not remove packages based only on the version" do
      existing_package_with_same_version = create_package :name => "discourse", :version => "0.9.8.3", :iteration => "1"
      new_package = create_package :name => "discourse", :version => "0.9.8.3", :iteration => "2"

      @manifest.stub :packages, [existing_package_with_same_version] do
        @manifest.add(new_package, preserve_versions=true)
        @manifest.packages.length.must_equal 2
      end
    end

    it "removes any package with the same name, independently of the full version, if preserve_versions is false" do
      existing_packages_with_same_name = [
        create_package(:name => "discourse", :version => "0.9.8.3", :iteration => "1"),
        create_package(:name => "discourse"),
        create_package(:name => "discourse", :version => "0.9.8.4", :iteration => "1", :epoch =>  "2")
      ]
      new_package = create_package :name => "discourse", :version => "0.9.8.5"

      @manifest.stub :packages, existing_packages_with_same_name do
        @manifest.add(new_package, preserve_versions=false)
        @manifest.packages.must_equal [new_package]
      end
    end
  end
end
