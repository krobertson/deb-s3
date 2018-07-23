# -*- encoding : utf-8 -*-
require File.expand_path('../../../spec_helper', __FILE__)
require 'deb/s3/lock'
require 'minitest/mock'

describe Deb::S3::Lock do
  describe :locked? do
    it 'returns true if lock file exists' do
      Deb::S3::Utils.stub :s3_exists?, true do
        Deb::S3::Lock.locked?("stable").must_equal true
      end
    end
    it 'returns true if lock file exists' do
      Deb::S3::Utils.stub :s3_exists?, false do
        Deb::S3::Lock.locked?("stable").must_equal false
      end
    end
  end

  describe :lock do
    it 'creates a lock file' do
      s3_store_mock = MiniTest::Mock.new
      s3_store_mock.expect(:call, nil, 4.times.map {Object})

      s3_read_mock = MiniTest::Mock.new
      s3_read_mock.expect(:call, "foo@bar\nabcde", [String])

      lock_content_mock = MiniTest::Mock.new
      lock_content_mock.expect(:call, "foo@bar\nabcde")

      Deb::S3::Utils.stub :s3_store, s3_store_mock do
        Deb::S3::Utils.stub :s3_read, s3_read_mock do
          Deb::S3::Lock.stub :generate_lock_content, lock_content_mock do
            Deb::S3::Lock.lock("stable")
          end
        end
      end

      s3_read_mock.verify
      s3_store_mock.verify
      lock_content_mock.verify
    end
  end

  describe :unlock do
    it 'deletes the lock file' do
      mock = MiniTest::Mock.new
      mock.expect(:call, nil, [String])
      Deb::S3::Utils.stub :s3_remove, mock do
        Deb::S3::Lock.unlock("stable")
      end
      mock.verify
    end
  end

  describe :current do
    before :each do
      mock = MiniTest::Mock.new
      mock.expect(:call, "alex@localhost", [String])
      Deb::S3::Utils.stub :s3_read, mock do
        @lock = Deb::S3::Lock.current("stable")
      end
    end

    it 'returns a lock object' do
      @lock.must_be_instance_of Deb::S3::Lock
    end

    it 'holds the user who currently holds the lock' do
      @lock.user.must_equal 'alex'
    end

    it 'holds the hostname from where the lock was set' do
      @lock.host.must_equal 'localhost'
    end
  end

end
